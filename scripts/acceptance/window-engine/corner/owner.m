// One of two ordinary, independently signed fixture owners on a disposable login only.
#import <AppKit/AppKit.h>
#import <libproc.h>
#import "gesture_witness.h"

// The hosted and installed-fixture owners create the same ordinary AppKit window.
static NSWindow *ordinaryFixtureWindow(NSRect content, NSView *view, NSString *title, NSColor *color) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:content
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                    backing:NSBackingStoreBuffered defer:NO];
    window.contentView = view;
    window.title = title;
    window.releasedWhenClosed = NO;
    window.backgroundColor = color;
    return window;
}

#ifdef NP_HOST_INTERACTIVE_FIXTURE
#import "interactive/session.inc"
#else
static NSString *root, *label;
static NSMutableArray<NSWindow *> *wins;
static NSMutableDictionary *counts, *recentMarkers;
static uint64_t version;

static void writeState(NSString *nonce) {
    NSMutableArray *rows = [NSMutableArray array];
    CGFloat height = NSMaxY(NSScreen.screens.firstObject.frame);
    for (NSWindow *w in wins) {
        NSRect f = w.frame;
        [rows addObject:@{
            @"window" : @(w.windowNumber),
            @"frame" : @[ @(f.origin.x), @(height - NSMaxY(f)), @(NSWidth(f)), @(NSHeight(f)) ],
            @"minimized" : @(w.isMiniaturized),
            @"current" : @(w.isOnActiveSpace),
            @"counts" : counts[@(w.windowNumber)],
            @"markers" : recentMarkers[@(w.windowNumber)]
        }];
    }
    struct proc_bsdinfo p = {0};
    proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &p, sizeof p);
    NSDictionary *o = @{
        @"pid" : @(getpid()),
        @"birth" : @(p.pbi_start_tvsec * 1000000ULL + p.pbi_start_tvusec),
        @"nonce" : nonce,
        @"rows" : rows,
        @"version" : @(++version),
        @"uptime" : @(NSProcessInfo.processInfo.systemUptime)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];
    [data writeToFile:[root stringByAppendingPathComponent:[label stringByAppendingString:@".json"]]
           atomically:YES];
}
@interface ClickFixtureView : NSView
@end
@implementation ClickFixtureView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    return nil;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 || (![NSUserName() isEqual:@"runner"] && ![NSUserName() hasPrefix:@"nearpane-fixture-"]))
            return 2;
        root = @(argv[1]);
        label = @(argv[2]);
        if (![NSBundle.mainBundle.bundleIdentifier
                isEqual:[@"com.holdsnow.nearpane.engine-fixture." stringByAppendingString:label]])
            return 3;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        if (NSScreen.screens.count != 1)
            return 4;
        NSRect v = NSScreen.screens.firstObject.visibleFrame;
        CGFloat w = MAX(124, MIN(264, NSWidth(v) / 3.5)), h = MAX(92, MIN(180, NSHeight(v) / 3.7));
        wins = [NSMutableArray array];
        counts = [NSMutableDictionary dictionary];
        recentMarkers = [NSMutableDictionary dictionary];
        BOOL first = [label isEqual:@"a"];
        for (unsigned i = 0; i < (first ? 2 : 3); i++) {
            unsigned slot = first ? i : i + 2;
            NSRect f = NSMakeRect(NSMinX(v) + 20 + (slot % 3) * (w + 10),
                                  NSMaxY(v) - 55 - h - (slot / 3) * (h + 40), w, h);
            NSWindow *window = ordinaryFixtureWindow(f, [[ClickFixtureView alloc] initWithFrame:NSMakeRect(0, 0, w, h)],
                @"Nearpane isolated window", first ? NSColor.systemBlueColor : NSColor.systemOrangeColor);
            [wins addObject:window];
            [window orderFront:nil];
            recentMarkers[@(window.windowNumber)] = [NSMutableArray array];
            counts[@(window.windowNumber)] =
                [NSMutableArray arrayWithArray:@[ @0, @0, @0, @0, @0, @0, @0, @0, @0 ]];
        }
        // A separate owner window models a user's pre-existing minimized window.
        if (!first)
            [wins.lastObject miniaturize:nil];
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                           NSEventMaskRightMouseDown | NSEventMaskRightMouseDragged | NSEventMaskRightMouseUp |
                           NSEventMaskOtherMouseDown | NSEventMaskOtherMouseDragged | NSEventMaskOtherMouseUp;
        id monitor =
            [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                  handler:^NSEvent *(NSEvent *event) {
                                                    const NSEventType types[] = {
                                                        NSEventTypeLeftMouseDown,     NSEventTypeLeftMouseDragged,
                                                        NSEventTypeLeftMouseUp,       NSEventTypeRightMouseDown,
                                                        NSEventTypeRightMouseDragged, NSEventTypeRightMouseUp,
                                                        NSEventTypeOtherMouseDown,    NSEventTypeOtherMouseDragged,
                                                        NSEventTypeOtherMouseUp};
                                                    NSMutableArray *a = counts[@(event.windowNumber)];
                                                    if (a) {
                                                        CGEventRef cg = event.CGEvent;
                                                        uint64_t tag = cg ? (uint64_t)CGEventGetIntegerValueField(cg, kCGEventSourceUserData) : 0;
                                                        if ((tag & NC_FIXTURE_GESTURE_MASK) == NC_FIXTURE_GESTURE_PREFIX) {
                                                            NSMutableArray *seen = recentMarkers[@(event.windowNumber)];
                                                            if (seen.count == 3) [seen removeObjectAtIndex:0];
                                                            [seen addObject:@{@"tag" : @(tag), @"type" : @(CGEventGetType(cg)),
                                                                @"sourcePID" : @(CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID))}];
                                                        }
                                                        for (unsigned i = 0; i < 9; i++)
                                                            if (types[i] == event.type) {
                                                                a[i] = @([a[i] unsignedIntValue] + 1);
                                                                break;
                                                            }
                                                    }
                                                    return event;
                                                  }];
        __block NSString *previous = @"initial";
        writeState(previous);
        [NSTimer
            scheduledTimerWithTimeInterval:.035
                                   repeats:YES
                                     block:^(NSTimer *timer) {
                                       if ([[NSFileManager defaultManager]
                                               fileExistsAtPath:[root stringByAppendingPathComponent:@"stop"]]) {
                                           [timer invalidate];
                                           [NSEvent removeMonitor:monitor];
                                           for (NSWindow *window in wins)
                                               [window close];
                                           [NSApp terminate:nil];
                                           return;
                                       }
                                       NSString *nonce = [NSString
                                           stringWithContentsOfFile:[root stringByAppendingPathComponent:@"sample"]
                                                           encoding:NSUTF8StringEncoding
                                                              error:NULL];
                                       if (nonce && [[NSUUID alloc] initWithUUIDString:nonce] &&
                                           ![previous isEqual:nonce]) {
                                           previous = nonce;
                                           writeState(nonce);
                                       }
                                     }];
        [NSApp run];
        return 0;
    }
}
#endif
