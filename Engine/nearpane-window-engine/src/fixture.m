// Compiled only into isolated test binaries. A PID, flag or environment variable
// alone cannot make a daily application eligible for an experimental OS write.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <libproc.h>
#include <unistd.h>

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
