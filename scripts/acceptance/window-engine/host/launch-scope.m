// Only the requested signed Host samples TCC or a registered window.
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <libproc.h>
#import <sys/sysctl.h>

static NSString *physical(NSString *path) {
    char result[PATH_MAX];
    return path && realpath(path.fileSystemRepresentation, result) ? @(result) : nil;
}

static NSDictionary *session(void) {
    NSDictionary *c = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    SecuritySessionId sid = 0;
    OSStatus rc = SessionGetInfo(callerSecuritySession, &sid, NULL);
    BOOL active = getuid() != 0 && getuid() == geteuid() && [c[(__bridge NSString *)kCGSessionUserIDKey] isEqual:@(getuid())] &&
        [c[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] && [c[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES] &&
        ![c[@"CGSSessionScreenIsLocked"] boolValue] && rc == errSecSuccess && sid > 0;
    return @{@"qualified":@(active), @"securitySessionID":@(sid)};
}

// Launch Services sees registered instances. The kernel also sees an exact product executable
// still starting, directly invoked, or finishing outside Launch Services' registered lifetime.
static NSDictionary *census(NSBundle *bundle) {
    NSString *target = bundle.bundleIdentifier;
    NSMutableSet<NSNumber *> *matches = [NSMutableSet set];
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:target]) {
        if (!app.terminated && app.processIdentifier > 0) [matches addObject:@(app.processIdentifier)];
    }
    int mib[] = {CTL_KERN,KERN_PROC,KERN_PROC_UID,(int)getuid()};
    size_t size = 0;
    BOOL ok = sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0 && size < 16 * 1024 * 1024;
    NSMutableData *rows = [NSMutableData dataWithLength:ok ? size + 64 * sizeof(struct kinfo_proc) : 0];
    if (ok) {
        size = rows.length;
        ok = sysctl(mib, 4, rows.mutableBytes, &size, NULL, 0) == 0 && size % sizeof(struct kinfo_proc) == 0;
    }
    const struct kinfo_proc *p = rows.bytes;
    const char *host = bundle.executableURL.lastPathComponent.fileSystemRepresentation;
    NSString *expectedExecutable = physical(bundle.executableURL.path);
    for (size_t i = 0; ok && i < size / sizeof(*p); i++) {
        if (strncmp(p[i].kp_proc.p_comm, host, sizeof(p[i].kp_proc.p_comm))) continue;
        pid_t pid = p[i].kp_proc.p_pid;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        // An unresolved matching executable is ambiguous while that generation remains alive.
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
            if (kill(pid, 0) == 0 || errno != ESRCH) ok = NO;
            continue;
        }
        if ([@(path) isEqual:expectedExecutable]) {
            [matches addObject:@(pid)]; continue;
        }
        // A renamed bundle, moved image or an unbundled product binary can still carry this identifier.
        SecCodeRef guest = NULL; SecStaticCodeRef code = NULL; CFDictionaryRef raw = NULL;
        OSStatus rc = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge NSString *)kSecGuestAttributePid:@(pid)}, 0, &guest);
        if (rc == 0) rc = SecCodeCopyStaticCode(guest, 0, &code);
        if (rc == 0) rc = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
        NSDictionary *info = CFBridgingRelease(raw);
        if (code) CFRelease(code);
        if (guest) CFRelease(guest);
        NSString *identifier = info[(__bridge NSString *)kSecCodeInfoIdentifier];
        if (rc == 0 && identifier.length) {
            if ([identifier isEqual:target]) [matches addObject:@(pid)];
        } else if (kill(pid, 0) == 0 || errno != ESRCH) ok = NO;
    }
    return @{@"complete":@(ok), @"pids":[matches.allObjects sortedArrayUsingSelector:@selector(compare:)], @"session":session()};
}

static int emit(NSDictionary *row) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
    if (!data) return 3;
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3 || argc > 5) return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES].URLByResolvingSymlinksInPath;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        if (![@[@"com.holdsnow.nearpane.alpha", @"com.holdsnow.nearpane.host"] containsObject:bundle.bundleIdentifier ?: @""] ||
            ![bundle.executableURL.lastPathComponent isEqual:@"NearpaneHost"]) return 2;
        NSDictionary *before = census(bundle);
        if (argc == 3 && !strcmp(argv[2], "--roster")) return emit(before);
        NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:@(argv[2])];
        BOOL cycle = argc == 5 && !strcmp(argv[3], "--await-registered-window") && !strcmp(argv[4], "--enrolled-spaces-cycle") &&
            [physical(url.path) isEqual:@"/Applications/Nearpane.app"] && [bundle.bundleIdentifier isEqual:@"com.holdsnow.nearpane.alpha"];
        if (!nonce || (argc == 5 && !cycle) || (argc >= 4 && ![@[@"--registered-window",@"--await-registered-window"] containsObject:@(argv[3])])) return 2;
        if (![before[@"complete"] boolValue] || [before[@"pids"] count] || ![before[@"session"][@"qualified"] boolValue])
            return emit(@{@"prelaunch":before, @"launched":@NO, @"exactLaunchPath":@NO, @"pid":@0, @"reason":@"singleInstanceOrLoginUnavailable"});
        NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
        config.promptsUserIfNeeded = NO;
        config.activates = NO;
        config.addsToRecentItems = NO;
        config.allowsRunningApplicationSubstitution = NO;
        config.createsNewApplicationInstance = NO;
        NSMutableArray *args = [@[@"--read-stage-engine-scope", nonce.UUIDString, @"--private-receipt"] mutableCopy];
        if (argc >= 4) [args addObject:@(argv[3])];
        if (cycle) [args addObject:@"--enrolled-spaces-cycle"];
        config.arguments = args;
        __block NSDictionary *result;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:config completionHandler:
            ^(NSRunningApplication *app, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    pid_t pid = app.processIdentifier;
                    struct proc_bsdinfo info = {0}; char buffer[PROC_PIDPATHINFO_MAXSIZE];
                    BOOL live = pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == (int)sizeof(info) &&
                        info.pbi_pid == (uint32_t)pid && info.pbi_uid == getuid() && proc_pidpath(pid, buffer, sizeof(buffer)) > 0;
                    NSString *path = live ? physical(@(buffer)) : nil;
                    uint64_t birth = live ? info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec : 0;
                    NSDictionary *after = census(bundle);
                    BOOL exact = !error && birth && [app.bundleIdentifier isEqual:bundle.bundleIdentifier] &&
                        [physical(app.bundleURL.path) isEqual:physical(url.path)] && [path isEqual:physical(bundle.executableURL.path)] &&
                        [after[@"complete"] boolValue] && [after[@"pids"] isEqual:@[@(pid)]] && [after[@"session"] isEqual:before[@"session"]];
                    result = @{@"prelaunch":before, @"postlaunch":after, @"launched":@YES, @"exactLaunchPath":@(exact),
                               @"pid":@(pid), @"birth":@(birth), @"kernelExecutable":path ?: @"", @"errorDomain":error.domain ?: @"", @"errorCode":@(error.code)};
                });
            }];
        double end = NSProcessInfo.processInfo.systemUptime + 8;
        while (!result && NSProcessInfo.processInfo.systemUptime < end)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        return emit(result ?: @{@"prelaunch":before, @"launched":@YES, @"exactLaunchPath":@NO, @"pid":@0, @"errorDomain":@"launchTimeout", @"errorCode":@0});
    }
}
