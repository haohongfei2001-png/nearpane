// A regular signed app supplies only its own AppKit window and heartbeat. It never requests TCC.
#import <AppKit/AppKit.h>
#import <fcntl.h>
#import <libproc.h>
#import <sys/stat.h>
#import <unistd.h>

static BOOL emit(int dir, const char *name, NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (!data)
        return NO;
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0)
        return NO;
    NSFileHandle *out = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    return [out writeData:data error:NULL] &&
           [out writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] error:NULL] &&
           [out closeAndReturnError:NULL];
}
static BOOL stopped(int dir) {
    struct stat st;
    return fstatat(dir, "stop", &st, AT_SYMLINK_NOFOLLOW) == 0;
}
#ifdef NP_SURVIVAL_WINDOW
// AppKit assigns a number before the compositor necessarily exposes its owner and frame.
// Publish the fixture only after two separate WindowServer reads of this one window agree.
static NSDictionary *serverWindow(CGWindowID number) {
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, number));
    if (rows.count != 1) return nil;
    NSDictionary *r = rows.firstObject;
    CGRect b;
    if (![r[(__bridge NSString *)kCGWindowNumber] isEqual:@(number)] ||
        ![r[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(getpid())] ||
        ![r[(__bridge NSString *)kCGWindowLayer] isEqual:@0] ||
        ![r[(__bridge NSString *)kCGWindowIsOnscreen] boolValue] ||
        !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r[(__bridge NSString *)kCGWindowBounds], &b) ||
        CGRectIsEmpty(b) || CGRectIsInfinite(b)) return nil;
    return @{@"pid":@(getpid()), @"window":@(number), @"frame":@[@(b.origin.x),@(b.origin.y),@(b.size.width),@(b.size.height)]};
}
static BOOL waitForPublication(NSWindow *w, pid_t front, int dir) {
    NSDictionary *previous = nil;
    double priorTime = 0, deadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (NSProcessInfo.processInfo.systemUptime < deadline && !stopped(dir) && !NSApp.isActive &&
           NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == front && w.isOnActiveSpace) {
        NSDictionary *read = serverWindow((CGWindowID)w.windowNumber);
        double now = NSProcessInfo.processInfo.systemUptime;
        if (read && [previous isEqual:read] && now - priorTime >= .04)
            return emit(dir, "owner-published.json", @{@"first":previous, @"second":read,
                        @"firstUptime":@(priorTime), @"secondUptime":@(now)});
        if (![previous isEqual:read]) { previous = read; priorTime = now; }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
    return NO;
}
#endif
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL cycle = argc == 4 && !strcmp(argv[3], "--enrolled-spaces-cycle");
#ifdef NP_SURVIVAL_WINDOW
        BOOL survival = argc == 4 && (!strcmp(argv[3], "--guardian-survival") || !strcmp(argv[3], "--ordinary-window"));
        if ((!cycle && !survival && argc != 3) || strcmp(argv[1], "--read-membership") || getuid() == 0 || getuid() != geteuid())
#else
        if ((!cycle && argc != 3) || strcmp(argv[1], "--read-membership") || getuid() == 0 || getuid() != geteuid())
#endif
            return 2;
        NSUUID *id = [[NSUUID alloc] initWithUUIDString:@(argv[2])];
        if (!id)
            return 2;
        NSString *root =
            [@"/private/tmp/nearpane-membership." stringByAppendingString:id.UUIDString.lowercaseString];
        NSBundle *app = NSBundle.mainBundle;
        int dir = open(root.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        struct stat folder;
        struct proc_bsdinfo proc = {0};
        if (dir < 0 || fstat(dir, &folder) || folder.st_uid != getuid() || (folder.st_mode & 0777) != 0700 ||
            proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &proc, sizeof(proc)) != sizeof(proc))
            return 2;
        // Foundation presents /private/tmp as /tmp for the same directory. Compare the kernel paths.
        NSString *expected = [root stringByAppendingPathComponent:@"Membership Window.app"];
        char actual[PATH_MAX], target[PATH_MAX];
        BOOL exact = realpath(app.bundleURL.fileSystemRepresentation, actual) &&
                     realpath(expected.fileSystemRepresentation, target) && strcmp(actual, target) == 0 &&
                     strcmp(target, expected.fileSystemRepresentation) == 0;
        BOOL signedID = [app.bundleIdentifier isEqual:@"com.holdsnow.nearpane.engine-fixture.a"];
        if (!emit(
                dir, "owner-preflight.json", @{
                    @"pid" : @(getpid()),
                    @"exactBundleDirectory" : @(exact),
                    @"expectedBundleID" : @(signedID)
                }) ||
            !exact || !signedID)
            return 2;
        uint64_t birth = (uint64_t)proc.pbi_start_tvsec * 1000000 + proc.pbi_start_tvusec;
        [NSApplication sharedApplication];
        [NSApp finishLaunching];
        pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        BOOL quiet = front > 0 && front != getpid() && !NSApp.isActive;
        BOOL regular = NSApp.activationPolicy == NSApplicationActivationPolicyRegular;
        BOOL single = NSScreen.screens.count == 1;
        if (!emit(
                dir, "owner-session.json",
                @{@"background" : @(quiet),
                  @"regular" : @(regular),
                  @"singleScreen" : @(single)}) ||
            !quiet || !regular || !single)
            return 3;
        NSRect screen = NSScreen.screens.firstObject.visibleFrame;
        NSRect bounds = NSMakeRect(NSMidX(screen) - 110, NSMidY(screen) - 55, 220, 110);
        NSWindow *w =
            [[NSWindow alloc] initWithContentRect:bounds
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
        // Survival uses an ordinary opaque window ordered behind the foreground app.
        // The older membership experiment retains its transparent, mouse-inert fixture.
        w.releasedWhenClosed = NO;
        w.title = @"Nearpane membership fixture";
#ifdef NP_SURVIVAL_WINDOW
        w.alphaValue = survival ? 1 : 0;
        w.ignoresMouseEvents = !survival;
        if (survival) w.contentView = [NSTextField labelWithString:@"Nearpane Guardian verification"];
#else
        w.alphaValue = 0;
        w.ignoresMouseEvents = YES;
#endif
        w.hasShadow = NO;
        w.animationBehavior = NSWindowAnimationBehaviorNone;
        [w orderBack:nil];
        NSInteger window = w.windowNumber;
        double started = NSProcessInfo.processInfo.systemUptime, deadline = started + (cycle ? 75 : 20);
        NSDictionary * (^read)(void) = ^NSDictionary * {
          return @{
              @"pid" : @(getpid()),
              @"birth" : @(birth),
              @"startedUptime" : @(started),
              @"deadlineUptime" : @(deadline),
              @"window" : @(window),
              @"regularApplication" : @(NSApp.activationPolicy == NSApplicationActivationPolicyRegular),
              @"ordinaryWindow" : @([w isMemberOfClass:NSWindow.class]),
              @"visible" : @(w.isVisible),
              @"onActiveSpace" : @(w.isOnActiveSpace),
              @"sameFront" : @(front == NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
              @"active" : @(NSApp.isActive),
              @"key" : @(w.isKeyWindow),
              @"main" : @(w.isMainWindow),
              @"ignoresMouseEvents" : @(w.ignoresMouseEvents),
              @"alpha" : @(w.alphaValue)
          };
        };
#ifdef NP_SURVIVAL_WINDOW
        BOOL ready = window > 0 && window <= UINT32_MAX && (!survival || waitForPublication(w, front, dir)) &&
                     emit(dir, "owner-start.json", read());
#else
        BOOL ready = window > 0 && window <= UINT32_MAX && emit(dir, "owner-start.json", read());
#endif
        while (ready && !stopped(dir) && NSProcessInfo.processInfo.systemUptime < deadline &&
               !NSApp.isActive && !w.isKeyWindow && !w.isMainWindow &&
               front == NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        NSMutableDictionary *last = [read() mutableCopy];
        [w orderOut:nil];
        [w close];
        last[@"closed"] = @(!w.isVisible);
        last[@"stopSeen"] = @(stopped(dir));
        BOOL receipt = emit(dir, "owner-closed.json", last);
        close(dir);
        return ready && receipt ? 0 : 3;
    }
}
