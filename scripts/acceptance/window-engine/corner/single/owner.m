#import "lease.h"
@interface QuietOrdinaryWindow : NSWindow
@end
@implementation QuietOrdinaryWindow
- (BOOL)canBecomeKeyWindow {
    return NO;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2 || strcmp(argv[1], "--one-window") || !singleCode(getpid(), YES) ||
            !singleCode(getppid(), NO))
            return 2;
        pid_t host = getppid();
        uint64_t birth = ncg_birth(host, NULL);
        if (!birth)
            return 2;
        fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1);
        if (!singleWrite(
                STDOUT_FILENO,
                @{@"phase" : @"ready",
                  @"pid" : @(getpid()),
                  @"birth" : @(ncg_birth(getpid(), NULL))}))
            return 3;
        char c = 0;
        struct pollfd in = {.fd = STDIN_FILENO, .events = POLLIN};
        if (poll(&in, 1, 5000) <= 0 || read(STDIN_FILENO, &c, 1) != 1 || c != 'C' || host != getppid() ||
            ncg_birth(host, NULL) != birth)
            return 3;
        [NSApplication sharedApplication];
        if (![NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory] || NSApp.isActive ||
            NSScreen.screens.count != 1)
            return 4;
        NSScreen *screen = NSScreen.screens[0];
        NSRect area = screen.visibleFrame;
        if (NSWidth(area) < 400 || NSHeight(area) < 300)
            return 4;
        NSRect source = NSMakeRect(NSMidX(area) - 80, NSMidY(area) - 60, 160, 120);
        QuietOrdinaryWindow *w =
            [[QuietOrdinaryWindow alloc] initWithContentRect:source
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
        // The ordinary window has zero composited alpha before the first WindowServer ordering operation.
        w.releasedWhenClosed = NO;
        w.alphaValue = 0;
        w.ignoresMouseEvents = YES;
        w.opaque = NO;
        w.hasShadow = NO;
        w.backgroundColor = NSColor.clearColor;
        w.animationBehavior = NSWindowAnimationBehaviorNone;
        [w orderBack:nil];
        unsigned sequence = 0;
        double end = NSProcessInfo.processInfo.systemUptime + 16;
        while (NSProcessInfo.processInfo.systemUptime < end && getppid() == host &&
               ncg_birth(host, NULL) == birth) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.008]];
            if (poll(&in, 1, 0) <= 0)
                continue;
            if (read(STDIN_FILENO, &c, 1) != 1 || c == 'X')
                break;
            if (c != 'Q')
                break;
            NSRect f = w.frame;
            NSDictionary *facts = @{
                @"sequence" : @(++sequence),
                @"window" : @(w.windowNumber),
                @"pid" : @(getpid()),
                @"birth" : @(ncg_birth(getpid(), NULL)),
                @"frame" : @[ @(NSMinX(f)), @(NSMaxY(screen.frame) - NSMaxY(f)), @(NSWidth(f)), @(NSHeight(f)) ],
                @"alpha" : @(w.alphaValue),
                @"clickThrough" : @(w.ignoresMouseEvents),
                @"opaque" : @(w.isOpaque),
                @"key" : @(w.isKeyWindow),
                @"main" : @(w.isMainWindow),
                @"canKey" : @(w.canBecomeKeyWindow),
                @"canMain" : @(w.canBecomeMainWindow),
                @"panel" : @([w isKindOfClass:NSPanel.class]),
                @"shadow" : @(w.hasShadow),
                @"mini" : @(w.isMiniaturized),
                @"activeApp" : @(NSApp.isActive),
                @"onActiveSpace" : @(w.isOnActiveSpace),
                @"ordered" : @(w.isVisible)
            };
            if (!singleWrite(STDOUT_FILENO, facts) || !singleInvisible(facts))
                break;
        }
        [w orderOut:nil];
        [w close];
        return 0;
    }
}
