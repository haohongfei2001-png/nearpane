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
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 || strcmp(argv[1], "--read-membership") || getuid() == 0 || getuid() != geteuid())
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
        // These two properties prevent covering the user's pixels or accepting their clicks. This fixture
        // proves membership only.
        w.releasedWhenClosed = NO;
        w.title = @"Nearpane membership fixture";
        w.alphaValue = 0;
        w.ignoresMouseEvents = YES;
        w.hasShadow = NO;
        w.animationBehavior = NSWindowAnimationBehaviorNone;
        [w orderBack:nil];
        NSInteger window = w.windowNumber;
        NSDictionary * (^read)(void) = ^NSDictionary * {
          return @{
              @"pid" : @(getpid()),
              @"birth" : @(birth),
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
        BOOL ready = window > 0 && window <= UINT32_MAX && emit(dir, "owner-start.json", read());
        double deadline = NSProcessInfo.processInfo.systemUptime + 20;
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
