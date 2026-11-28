#import <Foundation/Foundation.h>
#include <libproc.h>
#import <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>
static inline uint64_t ncg_birth(pid_t pid, pid_t *parent) {
    struct proc_bsdinfo p = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &p, sizeof(p)) != sizeof(p) ||
        p.pbi_pid != (uint32_t)pid || p.pbi_uid != getuid())
        return 0;
    if (parent)
        *parent = (pid_t)p.pbi_ppid;
    return p.pbi_start_tvsec * UINT64_C(1000000) + p.pbi_start_tvusec;
}
#if defined(NP_CORNER_FIXTURE)
static inline BOOL ncg_disposable(void) {
    NSDictionary *e = NSProcessInfo.processInfo.environment;
    return ([NSUserName() isEqual:@"runner"] && [e[@"GITHUB_ACTIONS"] isEqual:@"true"] &&
            [e[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"]) ||
           ([NSUserName() hasPrefix:@"nearpane-fixture-"] &&
            [e[@"NP_DISPOSABLE_CORNER_LOGIN"] isEqual:NSUserName()]);
}
#endif
// Check running code against both its expected bundle identity and the signed artifact in the private kit.
static inline NSData *ncg_rule_hash(pid_t pid, NSString *path, NSString *requirement) {
    char actual[PROC_PIDPATHINFO_MAXSIZE], file[PATH_MAX], process[PATH_MAX];
    if (!proc_pidpath(pid, actual, sizeof(actual)) || !realpath(actual, process) ||
        !realpath(path.fileSystemRepresentation, file) || strcmp(file, process))
        return nil;
    SecCodeRef live = NULL;
    SecStaticCodeRef disk = NULL;
    SecRequirementRef req = NULL;
    CFDictionaryRef a = NULL, b = NULL;
    OSStatus err = SecRequirementCreateWithString((__bridge CFStringRef)requirement, 0, &req);
    if (!err)
        err = SecCodeCopyGuestWithAttributes(
            NULL,
            (__bridge CFDictionaryRef)
                @{(__bridge NSString *)kSecGuestAttributePid : @(pid)},
            0, &live);
    if (!err)
        err = SecCodeCheckValidity(live, kSecCSStrictValidate, req);
    if (!err)
        err = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], 0, &disk);
    if (!err)
        err = SecStaticCodeCheckValidity(disk, kSecCSStrictValidate, req);
    if (!err)
        err = SecCodeCopySigningInformation(live, kSecCSSigningInformation, &a);
    if (!err)
        err = SecCodeCopySigningInformation(disk, kSecCSSigningInformation, &b);
    NSData *digest = nil;
    if (!err && a && b) {
        id x = (__bridge id)CFDictionaryGetValue(a, kSecCodeInfoUnique),
           y = (__bridge id)CFDictionaryGetValue(b, kSecCodeInfoUnique);
        if ([x isKindOfClass:NSData.class] && [x length] >= 20 && [x isEqual:y])
            digest = [x copy];
    }
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    if (req)
        CFRelease(req);
    if (disk)
        CFRelease(disk);
    if (live)
        CFRelease(live);
    return digest;
}
#if defined(NP_CORNER_FIXTURE)
static inline NSData *ncg_hash(pid_t pid, NSString *path, NSString *ident) {
    return ncg_rule_hash(pid, path, [NSString stringWithFormat:@"identifier \"%@\"", ident]);
}
static inline NSData *ncg_fixture_hash(pid_t pid, NSString *kit) {
    for (NSString *suffix in @[ @"a", @"b" ]) {
        NSString *path =
            [kit stringByAppendingPathComponent:[NSString stringWithFormat:@"Fixture%@.app/Contents/MacOS/Owner",
                                                                           suffix]];
        NSData *digest =
            ncg_hash(pid, path, [@"com.holdsnow.nearpane.engine-fixture." stringByAppendingString:suffix]);
        if (digest)
            return digest;
    }
    return nil;
}

#endif
