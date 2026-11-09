#include "ReadOnlySpaces.h"
#include <dlfcn.h>
#include <string.h>
#include <sys/sysctl.h>

// P1-A 0a704fd7: signed 32-bit connection, CGWindowID in an explicit CFArray, selector 7 only.
_Static_assert(sizeof(int) == 4 && sizeof(uint32_t) == 4, "unreviewed ABI");
typedef int (*MainConnection)(void);
typedef CFArrayRef (*CopyManaged)(int);
typedef CFArrayRef (*CopyMembership)(int, int, CFArrayRef);
static CopyManaged managed;
static CopyMembership membership;
static int connection;

int NPReadOnlySpacesOpen(void) {
#if defined(__arm64__)
    char build[64] = {0};
    size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0) || strcmp(build, "26A428")) return 0;
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
    if (!handle) return -1;
    MainConnection mainConnection = (MainConnection)dlsym(handle, "SLSMainConnectionID");
    managed = (CopyManaged)dlsym(handle, "SLSCopyManagedDisplaySpaces");
    membership = (CopyMembership)dlsym(handle, "SLSCopySpacesForWindows");
    if (!mainConnection || !managed || !membership) return -1;
    connection = mainConnection();
    return connection > 0 ? 1 : -1;
#else
    return 0;
#endif
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
