#include "ReadOnlySpaces.h"
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CGError.h>
#include <CoreGraphics/CGWindow.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/sysctl.h>

int NPReadWindowNumberPresence(uint32_t window) {
    if (window == kCGNullWindowID) return -1;
    CFArrayRef numbers = CGWindowListCreate(kCGWindowListOptionIncludingWindow, window);
    if (numbers == NULL) return -1;
    CFIndex count = CFArrayGetCount(numbers);
    CFRelease(numbers);
    return count == 0 ? 0 : (count == 1 ? 1 : -1);
}

CFArrayRef NPReadVisibleWindowDescriptions(const uint32_t *windows, int count) {
    if (!windows || count <= 0 || count > 48) return NULL;
    CFArrayRef ordered = CGWindowListCreate(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                            kCGNullWindowID);
    if (!ordered) return NULL;
    // CG's window-number arrays contain raw integers cast to pointers, not CFNumber objects.
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, count, NULL);
    if (selected) {
        for (CFIndex i = 0; i < CFArrayGetCount(ordered); i++) {
            const void *value = CFArrayGetValueAtIndex(ordered, i);
            for (int j = 0; j < count; j++) {
                if ((uintptr_t)value == windows[j]) {
                    CFArrayAppendValue(selected, value);
                    break;
                }
            }
        }
    }
    CFRelease(ordered);
    if (!selected) return NULL;
    CFArrayRef descriptions = CFArrayGetCount(selected) ? CGWindowListCreateDescriptionFromArray(selected)
                                                        : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    // The description API can omit a window closed during the call. Join by number
    // and retain the ordering from the independent on-screen number list.
    CFMutableArrayRef result = descriptions ? CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks) : NULL;
    if (result) {
        for (CFIndex i = 0; i < CFArrayGetCount(selected); i++) {
            int64_t expected = (uintptr_t)CFArrayGetValueAtIndex(selected, i);
            for (CFIndex j = 0; j < CFArrayGetCount(descriptions); j++) {
                CFDictionaryRef row = CFArrayGetValueAtIndex(descriptions, j);
                CFNumberRef number = CFDictionaryGetValue(row, kCGWindowNumber);
                int64_t id = 0;
                if (number && CFNumberGetValue(number, kCFNumberSInt64Type, &id) && id == expected) {
                    CFArrayAppendValue(result, row);
                    break;
                }
            }
        }
    }
    if (descriptions) CFRelease(descriptions);
    CFRelease(selected);
    return result;
}

// Signed 32-bit connection and CGWindowID in an explicit CFArray. These are
// read-only lookups; engine write qualification is independent of this shim.
_Static_assert(sizeof(int) == 4 && sizeof(uint32_t) == 4, "unreviewed ABI");
typedef int (*MainConnection)(void);
typedef CFArrayRef (*CopyManaged)(int);
typedef CFArrayRef (*CopyMembership)(int, int, CFArrayRef);
typedef CFArrayRef (*CopyAllSpaces)(int, int);
static CopyManaged managed;
static CopyMembership membership;
static CopyAllSpaces allSpaces;
typedef CGError (*ReadLogicalBounds)(int, uint32_t, CGRect *);
static ReadLogicalBounds logicalBounds;
typedef CFArrayRef (*CopySpaceWindowNumbers)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
static CopySpaceWindowNumbers spaceWindowNumbers;
// Read-only sampling can run off the UI thread while another caller probes.
static _Atomic int connection;

static MainConnection mainConnection;
static pthread_once_t resolveOnce = PTHREAD_ONCE_INIT;

static int readOnlyABISupported(void) {
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0)) return 0;
    // Read the current arm64 Darwin 26 ABI family only. A matching family is
    // permission to attempt symbol/shape reads, not proof of window behavior.
    return length >= 4 && length <= sizeof(build) && !strncmp(build, "26", 2) &&
        build[2] >= 'A' && build[2] <= 'Z';
#else
    return 0;
#endif
}

static void resolveGetters(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
    if (!handle) return;
    mainConnection = (MainConnection)dlsym(handle, "SLSMainConnectionID");
    managed = (CopyManaged)dlsym(handle, "SLSCopyManagedDisplaySpaces");
    membership = (CopyMembership)dlsym(handle, "SLSCopySpacesForWindows");
    allSpaces = (CopyAllSpaces)dlsym(handle, "SLSCopySpaces");
    logicalBounds = (ReadLogicalBounds)dlsym(handle, "SLSGetWindowBounds");
    spaceWindowNumbers = (CopySpaceWindowNumbers)dlsym(handle, "SLSCopyWindowsWithOptionsAndTags");
}

int NPReadCatalogLogicalBounds(uint32_t window, CGRect *bounds) {
    if (!window || connection <= 0 || !logicalBounds) return 0;
    CGRect rect = CGRectNull;
    if (logicalBounds(connection, window, &rect) != kCGErrorSuccess ||
        CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect) ||
        !isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return 0;
    *bounds = rect;
    return 1;
}

static int openGetters(void) {
    if (!readOnlyABISupported()) return 0;
    pthread_once(&resolveOnce, resolveGetters);
    if (!mainConnection || !managed || !membership) return -1;
    connection = mainConnection();
    return connection > 0 ? 1 : -1;
}

int NPReadOnlySpacesOpen(void) { return openGetters(); }

int NPProbeReadOnlyCatalog(void) {
    int opened = openGetters();
    if (opened != 1) return opened;
    CFArrayRef raw = NPReadInventory();
    if (!raw) return -1;
    CFIndex count = CFArrayGetCount(raw);
    int valid = count > 0 && count <= 32;
    for (CFIndex i = 0; valid && i < count; i++) {
        CFDictionaryRef display = CFArrayGetValueAtIndex(raw, i);
        if (!display || CFGetTypeID(display) != CFDictionaryGetTypeID()) { valid = 0; break; }
        CFTypeRef identifier = CFDictionaryGetValue(display, CFSTR("Display Identifier"));
        CFTypeRef current = CFDictionaryGetValue(display, CFSTR("Current Space"));
        CFTypeRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        valid = identifier && CFGetTypeID(identifier) == CFStringGetTypeID() &&
                current && CFGetTypeID(current) == CFDictionaryGetTypeID() &&
                spaces && CFGetTypeID(spaces) == CFArrayGetTypeID() &&
                CFArrayGetCount(spaces) > 0 && CFArrayGetCount(spaces) <= 256;
    }
    CFRelease(raw);
    return valid ? 1 : -1;
}

static CFArrayRef checkedArray(CFArrayRef copy) {
    if (copy && CFGetTypeID(copy) != CFArrayGetTypeID()) {
        CFRelease(copy);
        return NULL;
    }
    return copy;
}

CFArrayRef NPReadCatalogSpaceWindowNumbers(uint64_t space) {
    if (connection <= 0 || !spaceWindowNumbers || !space || space > INT64_MAX) return NULL;
    int64_t sid = (int64_t)space;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    if (!number) return NULL;
    const void *values[] = { number };
    CFArrayRef request = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    if (!request) return NULL;
    uint64_t setTags = 0, clearTags = 0;
    CFArrayRef result = checkedArray(spaceWindowNumbers(connection, 0, request, 7, &setTags, &clearTags));
    CFRelease(request);
    if (result && CFArrayGetCount(result) > 8192) { CFRelease(result); return NULL; }
    return result;
}

CFArrayRef NPReadInventory(void) {
    return connection > 0 && managed ? checkedArray(managed(connection)) : NULL;
}

CFArrayRef NPReadAllSpaceNumbers(void) {
    if (connection <= 0 || !allSpaces) return NULL;
    CFArrayRef result = checkedArray(allSpaces(connection, 15));
    if (!result) return NULL;
    CFIndex count = CFArrayGetCount(result);
    int valid = count > 0 && count <= 2048;
    for (CFIndex i = 0; valid && i < count; i++) {
        CFTypeRef value = CFArrayGetValueAtIndex(result, i);
        int64_t number = 0;
        valid = value && CFGetTypeID(value) == CFNumberGetTypeID() &&
            !CFNumberIsFloatType((CFNumberRef)value) &&
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number) && number > 0;
    }
    // Some native fullscreen Spaces occur twice in the raw all-Space list.
    // Preserve the actual list; callers checking absence must not invent IDs.
    if (!valid) { CFRelease(result); return NULL; }
    return result;
}

static CFArrayRef copyWindowSpaces(uint32_t window, int selector) {
    if (!window || connection <= 0 || !membership) return NULL;
    int32_t id;
    memcpy(&id, &window, sizeof(id));
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &id);
    if (!number) return NULL;
    const void *values[] = { number };
    CFArrayRef input = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    if (!input) return NULL;
    CFArrayRef copy = checkedArray(membership(connection, selector, input));
    CFRelease(input);
    return copy;
}

CFArrayRef NPReadWindowSpaces(uint32_t window) {
    return copyWindowSpaces(window, 7);
}

CFArrayRef NPReadWindowSpacesIncludingHidden(uint32_t window) {
    // Classic hidden Spaces are omitted by the ordinary managed-space selector.
    // Physical engine witnesses must observe both ordinary and hidden membership.
    return copyWindowSpaces(window, 15);
}

uint32_t NPReadAXWindowNumber(CFTypeRef element) {
    if (!readOnlyABISupported() || !element || CFGetTypeID(element) != AXUIElementGetTypeID()) return 0;
    typedef int32_t (*ReadNumber)(CFTypeRef, uint32_t *);
    ReadNumber readNumber = (ReadNumber)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    uint32_t number = 0;
    if (readNumber && readNumber(element, &number) == kAXErrorSuccess && number > 0) return number;
    return 0;
}

int NPReadExistingWindowNumbers(uint32_t *out, int capacity) {
    CFArrayRef ids = CGWindowListCreate(kCGWindowListOptionAll, kCGNullWindowID);
    if (!ids) return -1;
    CFIndex count = CFArrayGetCount(ids);
    int result = -1;
    if (count > 0 && count <= capacity) {
        result = (int)count;
        for (CFIndex i = 0; i < count; i++) {
            uintptr_t id = (uintptr_t)CFArrayGetValueAtIndex(ids, i);
            if (!id || id > UINT32_MAX) { result = -1; break; }
            out[i] = (uint32_t)id;
        }
    }
    CFRelease(ids);
    return result;
}
