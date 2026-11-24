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
#ifdef NP_VISIBLE_RECOVERY_WINDOW
#import "../../../../Engine/nearpane-window-engine/src/corner/guardian/identity.h"
static NSDictionary *jobRecord(int dir, const char *name) {
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return nil;
    struct stat st;
    uint8_t data[4096];
    ssize_t n = -1;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == getuid() && (st.st_mode & 0777) == 0600 &&
        st.st_nlink == 1 && st.st_size > 0 && (uint64_t)st.st_size <= sizeof(data))
        n = pread(fd, data, (size_t)st.st_size, 0);
    close(fd);
    if (n <= 0 || n != st.st_size)
        return nil;
    id row = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:data length:(size_t)n]
                                             options:0
                                               error:NULL];
    return [row isKindOfClass:NSDictionary.class] ? row : nil;
}
static BOOL verifiedFixturePeer(pid_t pid, NSString *path, NSString *identifier, NSString *expected) {
    NSString *rule = [NSString
        stringWithFormat:
            @"anchor apple generic and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and identifier \"%@\"",
            identifier];
    NSData *hash = ncg_rule_hash(pid, path, rule);
    if (!hash.length || hash.length * 2 != expected.length)
        return NO;
    NSMutableString *hex = [NSMutableString string];
    for (size_t i = 0; i < hash.length; i++)
        [hex appendFormat:@"%02x", ((const uint8_t *)hash.bytes)[i]];
    return [expected isEqual:hex];
}
static BOOL fixtureCanMove(NSDictionary *row, NSUUID *nonce, NSWindow *w, uint64_t birth, NSArray *original) {
    NSDictionary *window = row[@"window"];
    pid_t parent = [row[@"hostPID"] intValue], child = [row[@"guardianPID"] intValue], actual = 0;
    char host[PROC_PIDPATHINFO_MAXSIZE];
    if (![row[@"scope"] isEqual:@"restoreOneVisibleSignedFixture"] ||
        ![[[NSUUID alloc] initWithUUIDString:row[@"challenge"]] isEqual:nonce] ||
        ![window[@"pid"] isEqual:@(getpid())] || ![window[@"birth"] isEqual:@(birth)] ||
        ![window[@"number"] isEqual:@(w.windowNumber)] || ![row[@"original"] isEqual:original] ||
        ![row[@"displaced"]
            isEqual:@[ @([original[0] doubleValue] + 24), original[1], original[2], original[3] ]] ||
        !ncg_birth(parent, NULL) || ![row[@"hostBirth"] isEqual:@(ncg_birth(parent, NULL))] ||
        ![row[@"guardianBirth"] isEqual:@(ncg_birth(child, &actual))] || actual != parent ||
        proc_pidpath(parent, host, sizeof(host)) <= 0)
        return NO;
    NSString *bundle =
        @(host)
            .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *container = bundle.stringByDeletingLastPathComponent;
    struct stat st;
    if (![container.stringByDeletingLastPathComponent isEqual:@"/private/tmp"] ||
        ![container.lastPathComponent hasPrefix:@"nearpane-stage-engine-dev."] ||
        ![bundle.lastPathComponent isEqual:@"Nearpane.app"] || lstat(container.fileSystemRepresentation, &st) ||
        !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0700)
        return NO;
    return verifiedFixturePeer(parent, [bundle stringByAppendingPathComponent:@"Contents/MacOS/NearpaneHost"],
                               @"com.holdsnow.nearpane.host", row[@"hostHash"]) &&
           verifiedFixturePeer(child,
                               [bundle stringByAppendingPathComponent:@"Contents/Helpers/NearpaneCornerGuardian"],
                               @"com.holdsnow.nearpane.host.corner-guardian", row[@"guardianHash"]);
}
#endif
#endif
#ifdef NP_FIXTURE_VISUAL_WINDOW
#import <QuartzCore/QuartzCore.h>
// AppKit may defer drawRect: indefinitely for a window ordered behind other apps.
// Publish immutable fixture-owned content to the compositor without activating it.
static CGImageRef fixtureMarker(NSUUID *nonce) CF_RETURNS_RETAINED {
    uuid_t bytes;
    [nonce getUUIDBytes:bytes];
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!color) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, 16, 1, 8, 64, color, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    if (!ctx) return NULL;
    for (int i = 0; i < 16; i++) {
        BOOL green = (bytes[i / 8] & (1u << (i % 8))) != 0;
        CGContextSetRGBFillColor(ctx, green ? .05 : .92, green ? .92 : .05, green ? .12 : .88, 1);
        CGContextFillRect(ctx, CGRectMake(i, 0, 1, 1));
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

// Put only the fixture into unused work area, if there is room. It will still
// be ordered behind ordinary windows, including any that appear after this read.
static NSRect freeMarkerContent(NSScreen *screen, NSRect original, NSWindowStyleMask style, BOOL *found) {
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    if (!rows || !screen || NSScreen.screens.count != 1) return original;
    CGRect native = CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    NSMutableArray<NSValue *> *occupied = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSNumber *layer = row[(__bridge NSString *)kCGWindowLayer];
        NSNumber *alpha = row[(__bridge NSString *)kCGWindowAlpha];
        if (!layer || !alpha) return original;
        if (layer.integerValue < kCGNormalWindowLevel || alpha.doubleValue == 0) continue;
        CGRect rect;
        NSDictionary *value = row[(__bridge NSString *)kCGWindowBounds];
        if (!value || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value,&rect)) return original;
        if (!CGRectIsEmpty(rect)) [occupied addObject:[NSValue valueWithRect:CGRectInset(rect,-32,-32)]];
    }
    NSRect available = NSInsetRect(screen.visibleFrame,8,8);
    NSPoint pointer = NSEvent.mouseLocation;
    NSRect avoidPointer = NSMakeRect(pointer.x-32,pointer.y-32,64,64);
    NSRect frame = [NSWindow frameRectForContentRect:original styleMask:style];
    if (frame.size.width > available.size.width || frame.size.height > available.size.height) return original;
    for (int i=-1; i<16*12; i++) {
        NSRect candidate = frame;
        if (i >= 0) {
            candidate.origin.x = round(NSMinX(available) + (i%16)*(NSWidth(available)-NSWidth(frame))/15);
            candidate.origin.y = round(NSMinY(available) + (i/16)*(NSHeight(available)-NSHeight(frame))/11);
        }
        if (!NSContainsRect(available,candidate) || NSIntersectsRect(candidate,avoidPointer)) continue;
        CGRect cg = CGRectMake(native.origin.x + NSMinX(candidate)-NSMinX(screen.frame),
                               native.origin.y + NSMaxY(screen.frame)-NSMaxY(candidate),
                               NSWidth(candidate),NSHeight(candidate));
        BOOL clear = YES;
        for (NSValue *other in occupied) {
            if (CGRectIntersectsRect(cg,other.rectValue)) { clear = NO; break; }
        }
        if (clear) {
            *found = YES;
            return [NSWindow contentRectForFrameRect:candidate styleMask:style];
        }
    }
    return original;
}
#endif
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL cycle = argc == 4 && !strcmp(argv[3], "--enrolled-spaces-cycle");
#ifdef NP_SURVIVAL_WINDOW
        BOOL survival = argc == 4 && (!strcmp(argv[3], "--guardian-survival") || !strcmp(argv[3], "--ordinary-window"));
#ifdef NP_VISIBLE_RECOVERY_WINDOW
        BOOL visibleRecovery = argc==4 && !strcmp(argv[3],"--visible-recovery");
        survival = survival || visibleRecovery;
#endif
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
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
#ifdef NP_FIXTURE_VISUAL_WINDOW
        BOOL freeSite = NO;
        if (survival && !strcmp(argv[3], "--ordinary-window"))
            bounds = freeMarkerContent(NSScreen.screens.firstObject,bounds,style,&freeSite);
#endif
        NSWindow *w =
            [[NSWindow alloc] initWithContentRect:bounds
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
        // Survival uses an ordinary opaque window ordered behind the foreground app.
        // The older membership experiment retains its transparent, mouse-inert fixture.
        w.releasedWhenClosed = NO;
        w.title = @"Nearpane membership fixture";
#ifdef NP_SURVIVAL_WINDOW
        w.alphaValue = survival ? 1 : 0;
        w.ignoresMouseEvents = !survival;
#ifdef NP_FIXTURE_VISUAL_WINDOW
        NSView *marker = nil;
        if (survival && !strcmp(argv[3], "--ordinary-window")) {
            marker = [[NSView alloc] initWithFrame:w.contentView.bounds];
            marker.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            marker.layer = [CALayer layer];
            marker.wantsLayer = YES;
            w.contentView = marker;
        } else
#endif
        if (survival) w.contentView = [NSTextField labelWithString:@"Nearpane Guardian verification"];
#else
        w.alphaValue = 0;
        w.ignoresMouseEvents = YES;
#endif
        w.hasShadow = NO;
        w.animationBehavior = NSWindowAnimationBehaviorNone;
        [w orderBack:nil];
#ifdef NP_FIXTURE_VISUAL_WINDOW
        BOOL markerPublished = NO;
        if (marker) {
            [w.contentView layoutSubtreeIfNeeded];
            CGImageRef image = fixtureMarker(id);
            if (image) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                marker.layer.magnificationFilter = kCAFilterNearest;
                marker.layer.contentsGravity = kCAGravityResize;
                marker.layer.contents = (__bridge NSObject *)image;
                [CATransaction commit];
                [CATransaction flush];
                markerPublished = marker.layer.contents == (__bridge NSObject *)image;
                CGImageRelease(image);
            }
            emit(dir, "owner-drawing.json", @{@"layerPublished":@(markerPublished), @"unoccupiedFrameAtCreation":@(freeSite),
                @"width":@(NSWidth(marker.bounds)), @"height":@(NSHeight(marker.bounds))});
        }
#endif
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
#ifdef NP_VISIBLE_RECOVERY_WINDOW
        BOOL moved = NO, published = NO, returned = NO;
        NSArray *original = visibleRecovery ? serverWindow((CGWindowID)window)[@"frame"] : nil;
#endif
        while (ready && !stopped(dir) && NSProcessInfo.processInfo.systemUptime < deadline && !NSApp.isActive &&
               !w.isKeyWindow && !w.isMainWindow &&
               front == NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) {
#ifdef NP_VISIBLE_RECOVERY_WINDOW
            if (visibleRecovery && original.count == 4 && !moved) {
                NSDictionary *record = jobRecord(dir, "guardian-prepared.json");
                if (record && fixtureCanMove(record, id, w, birth, original) &&
                    [serverWindow((CGWindowID)window)[@"frame"] isEqual:original]) {
                    NSRect shifted = NSOffsetRect(w.frame, 24, 0);
                    if (NSContainsRect(screen, w.frame) && NSContainsRect(screen, shifted)) {
                        moved = YES;
                        [w setFrameOrigin:shifted.origin];
                    }
                }
            } else if (visibleRecovery && moved && !returned) {
                NSDictionary *live = serverWindow((CGWindowID)window);
                if (!published &&
                    [live[@"frame"]
                        isEqual:@[ @([original[0] doubleValue] + 24), original[1], original[2], original[3] ]])
                    published = emit(dir, "owner-displaced.json", live);
                else if (published && [live[@"frame"] isEqual:original])
                    returned=emit(dir,"owner-returned.json",live);
            }
#endif
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.015]];
        }
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
