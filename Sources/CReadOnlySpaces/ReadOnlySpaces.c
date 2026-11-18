#include "ReadOnlySpaces.h"
#include <CoreGraphics/CGError.h>
#include <CoreGraphics/CGWindow.h>
#include <dlfcn.h>
#include <pthread.h>
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

// P1-A 0a704fd7: signed 32-bit connection, CGWindowID in an explicit CFArray, selector 7 only.
_Static_assert(sizeof(int) == 4 && sizeof(uint32_t) == 4, "unreviewed ABI");
typedef int (*MainConnection)(void);
typedef CFArrayRef (*CopyManaged)(int);
typedef CFArrayRef (*CopyMembership)(int, int, CFArrayRef);
static CopyManaged managed;
static CopyMembership membership;
typedef CGError (*ReadLogicalBounds)(int, uint32_t, CGRect *);
static ReadLogicalBounds logicalBounds;
static int connection;

static MainConnection mainConnection;
static pthread_once_t resolveOnce = PTHREAD_ONCE_INIT;

static void resolveGetters(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
    if (!handle) return;
    mainConnection = (MainConnection)dlsym(handle, "SLSMainConnectionID");
    managed = (CopyManaged)dlsym(handle, "SLSCopyManagedDisplaySpaces");
    membership = (CopyMembership)dlsym(handle, "SLSCopySpacesForWindows");
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (!sysctlbyname("kern.osversion", build, &length, NULL, 0) && !strcmp(build, "26A428"))
        logicalBounds = (ReadLogicalBounds)dlsym(handle, "SLSGetWindowBounds");
#endif
}

int NPReadCatalogLogicalBounds(uint32_t window, CGRect *bounds) {
    if (!window || connection <= 0 || !logicalBounds) return 0;
    CGRect rect = CGRectNull;
    if (logicalBounds(connection, window, &rect) != kCGErrorSuccess ||
        CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) return 0;
    *bounds = rect;
    return 1;
}

static int openGetters(int observeOnly) {
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0)) return 0;
    // Only the read-only catalogue may probe other builds in this ABI family.
    // Selection, movement and private AX identity have separate reviewed bounds.
    if (observeOnly) {
        if (strncmp(build, "26", 2) || build[2] < 'A' || build[2] > 'Z') return 0;
    } else if (strcmp(build, "26A428")) return 0;
    pthread_once(&resolveOnce, resolveGetters);
    if (!mainConnection || !managed || !membership) return -1;
    connection = mainConnection();
    return connection > 0 ? 1 : -1;
#else
    return 0;
#endif
}

int NPReadOnlySpacesOpen(void) { return openGetters(0); }

int NPProbeReadOnlyCatalog(void) {
    int opened = openGetters(1);
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

CFArrayRef NPReadInventory(void) {
    return connection > 0 && managed ? checkedArray(managed(connection)) : NULL;
}

CFArrayRef NPReadWindowSpaces(uint32_t window) {
    if (!window || connection <= 0 || !membership) return NULL;
    int32_t id;
    memcpy(&id, &window, sizeof(id));
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &id);
    if (!number) return NULL;
    const void *values[] = { number };
    CFArrayRef input = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    if (!input) return NULL;
    CFArrayRef copy = checkedArray(membership(connection, 7, input));
    CFRelease(input);
    return copy;
}

uint32_t NPReadAXWindowNumber(CFTypeRef element) {
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0) || strcmp(build, "26A428")) return 0;
    typedef int32_t (*ReadNumber)(CFTypeRef, uint32_t *);
    ReadNumber readNumber = (ReadNumber)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    uint32_t number = 0;
    if (readNumber && readNumber(element, &number) == 0) return number;
#endif
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
