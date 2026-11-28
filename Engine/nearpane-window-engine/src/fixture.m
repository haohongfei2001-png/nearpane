// Compiled only into isolated test binaries. A PID, flag or environment variable
// alone cannot make a daily application eligible for an experimental OS write.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "corner/mouse_event.h"
#include <libproc.h>
#include <unistd.h>

// Exercise the SDK-to-Rust callback in memory. No tap is installed and the event is never posted.
int np_fixture_corner_unposted_mouse(void *context, NCDecide decide, uint32_t kind,
                                     double x, double y, int64_t window, int64_t owner) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kind, CGPointMake(x, y), kCGMouseButtonLeft);
    if (!event) return -1;
    CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, window);
    CGEventSetIntegerValueField(event, kCGEventTargetUnixProcessID, owner);
    int result = nc_mouse_decision(CGEventGetType(event), event, context, decide);
    CFRelease(event);
    return result;
}

bool np_is_enrolled_fixture(int pid, uint64_t birth) {
    @autoreleasepool {
        struct proc_bsdinfo info = {0};
        if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.pbi_start_tvsec * UINT64_C(1000000) + info.pbi_start_tvusec != birth ||
            (pid != getpid() && info.pbi_ppid != (uint32_t)getpid())) return false;
        SecCodeRef guest = NULL;
        NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
        if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &guest) != errSecSuccess)
            return false;
        SecRequirementRef requirement = NULL;
        OSStatus result = SecRequirementCreateWithString(
            CFSTR("identifier \"com.holdsnow.nearpane.engine-fixture\" or identifier \"com.holdsnow.nearpane.engine-fixture.a\" or identifier \"com.holdsnow.nearpane.engine-fixture.b\""),
            kSecCSDefaultFlags, &requirement);
        if (result == errSecSuccess) result = SecCodeCheckValidity(guest, kSecCSStrictValidate, requirement);
        if (requirement) CFRelease(requirement);
        CFRelease(guest);
        return result == errSecSuccess;
    }
}
