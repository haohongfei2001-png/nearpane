#include "skylight-shim.h"
#include <CoreGraphics/CGWindow.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(CHAR_BIT == 8 && sizeof(int) == 4, "C int must match Swift Int32");
_Static_assert(sizeof(SInt32) == 4 && sizeof(CGWindowID) == 4, "window widths");
_Static_assert(sizeof(uint64_t) == 8 && sizeof(void *) == 8, "64-bit process required");
_Static_assert(__builtin_types_compatible_p(CGWindowID, uint32_t), "CGWindowID unsigned");
_Static_assert(__builtin_types_compatible_p(__typeof__(&SLSMainConnectionID), NPMainFunction), "main ABI");
_Static_assert(__builtin_types_compatible_p(__typeof__(&SLSCopyManagedDisplaySpaces), NPManagedFunction), "managed ABI");
_Static_assert(__builtin_types_compatible_p(__typeof__(&SLSCopySpacesForWindows), NPMembershipFunction), "membership ABI");

#ifndef NEARPANE_ENABLE_LIVE
#define NEARPANE_ENABLE_LIVE 0
#endif
#if NEARPANE_ENABLE_LIVE
static void *handle;
#endif
static NPMainFunction main_fn;
static NPManagedFunction managed_fn;
static NPMembershipFunction membership_fn;
static int connection, last_error;
static int initialized, fixture_backend, fixture_fault;
static NPCounters counters;
static CFAllocatorRef fixture_allocator;
static NPAllocatorCounters allocator_counters;
// Only locally-created fixture/input CF objects use this observer. It does not
// interpose on malloc, inspect other processes, or measure SkyLight allocations.
typedef union { max_align_t alignment; size_t size; } AllocationHeader;
static void *fixture_allocate(CFIndex size, CFOptionFlags hint, void *info) {
    (void)hint; (void)info;
    if (size < 0 || (size_t)size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *block = malloc(sizeof(*block) + (size_t)size);
    if (!block) return NULL;
    block->size = (size_t)size;
    allocator_counters.allocations++; allocator_counters.outstanding_blocks++;
    allocator_counters.outstanding_bytes += (uint64_t)size;
    return block + 1;
}
static void fixture_deallocate(void *pointer, void *info) {
    (void)info;
    if (!pointer) return;
    AllocationHeader *block = (AllocationHeader *)pointer - 1;
    allocator_counters.deallocations++; allocator_counters.outstanding_blocks--;
    allocator_counters.outstanding_bytes -= block->size;
    free(block);
}
static void *fixture_reallocate(void *pointer, CFIndex size, CFOptionFlags hint, void *info) {
    if (!pointer) return fixture_allocate(size, hint, info);
    if (size <= 0) { fixture_deallocate(pointer, info); return NULL; }
    if ((size_t)size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *old = (AllocationHeader *)pointer - 1;
    size_t old_size = old->size;
    AllocationHeader *block = realloc(old, sizeof(*block) + (size_t)size);
    if (!block) return NULL;
    block->size = (size_t)size;
    allocator_counters.reallocations++;
    allocator_counters.outstanding_bytes = allocator_counters.outstanding_bytes - old_size + (uint64_t)size;
    return block + 1;
}
NPAllocatorCounters NPGetFixtureAllocatorCounters(void) { return allocator_counters; }

int NPInitialize(int fault, char *error, size_t capacity) {
#if !NEARPANE_ENABLE_LIVE
    (void)fault;
    if (error && capacity) snprintf(error, capacity, "live backend disabled at compile time");
    return 90;
#else
    if (!pthread_main_np() || initialized || fault < 0 || fault > 2) return 1;
    const char *path = fault == 1 ? "/nonexistent/nearpane-p1-abi/SkyLight" :
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
    handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        if (error && capacity) snprintf(error, capacity, "dlopen: %s", dlerror());
        return 2;
    }
    main_fn = (NPMainFunction)dlsym(handle, "SLSMainConnectionID");
    managed_fn = (NPManagedFunction)dlsym(handle, "SLSCopyManagedDisplaySpaces");
    membership_fn = (NPMembershipFunction)dlsym(handle,
        fault == 2 ? "NearpaneDeliberatelyMissingSymbol" : "SLSCopySpacesForWindows");
    if (!main_fn || !managed_fn || !membership_fn) {
        if (error && capacity) snprintf(error, capacity, "required symbol unavailable");
        main_fn = NULL; managed_fn = NULL; membership_fn = NULL;
        dlclose(handle); handle = NULL;
        return 3;
    }
    // Borrow the process main connection. Never create/release/reconfigure it.
    connection = main_fn(); counters.main_calls++;
    initialized = 1;
    return 0;
#endif
}

// These fixture rules are deliberately synthetic, NOT SkyLight semantics.
static int fixture_main(void) { return 42; }
static CFDictionaryRef fixture_space(int64_t sid) {
    int32_t type = 0;
    CFNumberRef id = CFNumberCreate(fixture_allocator, kCFNumberSInt64Type, &sid);
    CFNumberRef kind = CFNumberCreate(fixture_allocator, kCFNumberSInt32Type, &type);
    const void *keys[] = {CFSTR("id64"), CFSTR("type"), CFSTR("uuid")};
    const void *values[] = {id, kind, CFSTR("synthetic-space")};
    CFDictionaryRef result = CFDictionaryCreate(fixture_allocator, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(id); CFRelease(kind);
    return result;
}
static CFArrayRef fixture_managed(int cid) {
    (void)cid;
    if (fixture_fault == 3) return NULL;
    if (fixture_fault == 4) {
        CFDictionaryRef malformed = CFDictionaryCreate(fixture_allocator, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *values[] = {malformed};
        CFArrayRef result = CFArrayCreate(fixture_allocator, values, 1, &kCFTypeArrayCallBacks);
        CFRelease(malformed);
        return result;
    }
    CFDictionaryRef a = fixture_space(INT64_C(4294967313));
    CFDictionaryRef b = fixture_space(INT64_C(9007199254740993));
    const void *records[] = {a, b};
    CFArrayRef spaces = CFArrayCreate(fixture_allocator, records, 2, &kCFTypeArrayCallBacks);
    const void *keys[] = {CFSTR("Display Identifier"), CFSTR("Current Space"), CFSTR("Spaces")};
    const void *values[] = {CFSTR("synthetic-display"), a, spaces};
    CFDictionaryRef scope = CFDictionaryCreate(fixture_allocator, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *scopes[] = {scope};
    CFArrayRef result = CFArrayCreate(fixture_allocator, scopes, 1, &kCFTypeArrayCallBacks);
    CFRelease(scope); CFRelease(spaces); CFRelease(a); CFRelease(b);
    return result;
}
static CFArrayRef fixture_membership(int cid, int selector, CFArrayRef windows) {
    (void)cid;
    if (selector != 0x7 || fixture_fault == 5 || CFArrayGetCount(windows) == 0) return NULL;
    if (fixture_fault == 6) return (CFArrayRef)CFStringCreateWithCString(fixture_allocator, "wrong-top-type", kCFStringEncodingUTF8);
    CFMutableArrayRef result = CFArrayCreateMutable(fixture_allocator, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
        int64_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(windows, i), kCFNumberSInt64Type, &wid);
        const int64_t ids[] = {INT64_C(4294967313), INT64_C(9007199254740993)};
        for (int j = 0; j < 2; ++j) {
            if (wid != 303 && !((wid == 101 && j == 0) || (wid == 202 && j == 1))) continue;
            CFNumberRef number = CFNumberCreate(fixture_allocator, kCFNumberSInt64Type, &ids[j]);
            if (!CFArrayContainsValue(result, CFRangeMake(0, CFArrayGetCount(result)), number)) CFArrayAppendValue(result, number);
            CFRelease(number);
        }
    }
    return result;
}
int NPInitializeFixtures(int fault, char *error, size_t capacity) {
    if (!pthread_main_np() || initialized || fault < 0 || fault > 6) return 1;
    fixture_backend = 1; fixture_fault = fault;
    if (fault == 1 || fault == 2) {
        if (error && capacity) snprintf(error, capacity, "injected %s failure; no dlopen", fault == 1 ? "library" : "symbol");
        return fault + 1;
    }
    CFAllocatorContext context = {0, NULL, NULL, NULL, NULL, fixture_allocate, fixture_reallocate, fixture_deallocate, NULL};
    fixture_allocator = CFAllocatorCreate(NULL, &context);
    if (!fixture_allocator) return 7;
    main_fn = fixture_main; managed_fn = fixture_managed; membership_fn = fixture_membership;
    connection = main_fn(); counters.main_calls++;
    initialized = 1;
    return 0;
}
int NPLiveBackendCompiled(void) { return NEARPANE_ENABLE_LIVE; }
int NPIsFixtureBackend(void) { return fixture_backend; }
int NPShutdown(void) {
    if (counters.output_releases != counters.managed_nonnull + counters.membership_nonnull ||
        counters.input_creates != counters.input_releases ||
        counters.number_creates != counters.number_releases) return 1;
    main_fn = NULL; managed_fn = NULL; membership_fn = NULL;
    connection = 0; initialized = 0;
    if (fixture_allocator) { CFRelease(fixture_allocator); fixture_allocator = NULL; }
#if NEARPANE_ENABLE_LIVE
    if (handle) { int status = dlclose(handle); handle = NULL; return status; }
#endif
    return 0;
}
int NPMainConnection(void) {
    if (!main_fn || !pthread_main_np()) { last_error = 1; return 0; }
    counters.main_calls++;
    return main_fn();
}
void *NPFunctionAddress(int index) {
    if (!initialized || !pthread_main_np()) return NULL;
    switch (index) {
        case 0: return (void *)main_fn;
        case 1: return (void *)managed_fn;
        case 2: return (void *)membership_fn;
        default: return NULL;
    }
}
const void *NPCopyManaged(void) {
    if (!managed_fn || !pthread_main_np()) { last_error = 1; return NULL; }
    last_error = 0; counters.managed_calls++;
    CFArrayRef result = managed_fn(connection);
    if (result) counters.managed_nonnull++;
    return result;
}
int NPValidateInput(const void *windows) {
    if (!windows || CFGetTypeID(windows) != CFArrayGetTypeID()) return 2;
    CFArrayRef array = (CFArrayRef)windows;
    if (CFArrayGetCount(array) > 64) return 6;
    for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(array, i);
        if (!value || CFGetTypeID(value) != CFNumberGetTypeID() || CFNumberIsFloatType(value)) return 4;
        // NSNumber(UInt64.max) can report a successful SInt64 conversion to -1.
        // All allowed 32-bit window integers are exactly representable as double;
        // check that small domain before interpreting the signed result. This is
        // only an input range guard, never the 64-bit Space ID parsing path.
        double bounded = 0;
        if (!CFNumberGetValue(value, kCFNumberFloat64Type, &bounded) ||
            bounded < INT32_MIN || bounded > UINT32_MAX) return 5;
        int64_t integer = 0;
        if (!CFNumberGetValue(value, kCFNumberSInt64Type, &integer) ||
            integer < INT32_MIN || integer > UINT32_MAX) return 5;
    }
    return 0;
}
const void *NPCopyMembership(const void *windows) {
    if (!membership_fn || !pthread_main_np()) { last_error = 1; return NULL; }
    last_error = NPValidateInput(windows);
    if (last_error) { counters.rejected_inputs++; return NULL; }
    counters.membership_calls++;
    CFArrayRef result = membership_fn(connection, 0x7, (CFArrayRef)windows);
    if (result) counters.membership_nonnull++;
    return result;
}
const void *NPCreateSInt32Windows(const uint32_t *ids, size_t count) {
    if (count > 64 || (count && !ids)) return NULL;
    CFMutableArrayRef array = CFArrayCreateMutable(fixture_allocator, (CFIndex)count, &kCFTypeArrayCallBacks);
    if (!array) return NULL;
    counters.input_creates++;
    for (size_t i = 0; i < count; ++i) {
        SInt32 signed_bits;
        // Preserve the uint32_t bit pattern, including the two invalid high IDs.
        memcpy(&signed_bits, ids + i, sizeof(signed_bits));
        CFNumberRef number = CFNumberCreate(fixture_allocator, kCFNumberSInt32Type, &signed_bits);
        if (!number) { NPReleaseInput(array); return NULL; }
        counters.number_creates++;
        CFArrayAppendValue(array, number); // array retains number
        CFRelease(number); counters.number_releases++;
    }
    return array;
}
void NPReleaseInput(const void *input) {
    if (input) { CFRelease(input); counters.input_releases++; }
}
void NPReleaseOutput(const void *output) {
    if (output) { CFRelease(output); counters.output_releases++; }
}
int NPLastError(void) { return last_error; }
NPCounters NPGetCounters(void) { return counters; }
NPMemory NPGetMemory(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    malloc_statistics_t stats = {0};
    malloc_zone_statistics(NULL, &stats);
    return (NPMemory){info.resident_size, stats.size_in_use, stats.blocks_in_use, status};
}
int NPIntBytes(void) { return (int)sizeof(int); }
int NPWindowIDBytes(void) { return (int)sizeof(CGWindowID); }
