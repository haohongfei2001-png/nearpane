// A separate, nonactivating reproduction of the shipping panel geometry. Only this process's own window is enrolled.
#import <AppKit/AppKit.h>
#import "ReadOnlySpaces.h"
#import "platform.h"

@interface MembershipPanel : NSPanel
@end
@implementation MembershipPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSDictionary *current(void) {
    NSArray *rows = CFBridgingRelease(NPReadInventory());
    if (rows.count != 1) return nil;
    return rows[0][@"Current Space"];
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        if (app.activationPolicy != NSApplicationActivationPolicyProhibited)
            [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        int catalog = NPProbeReadOnlyCatalog(), target = np_stage_target_build(), sip = np_stage_sip_enabled();
        if (app.activationPolicy != NSApplicationActivationPolicyProhibited || catalog != 1 || target != 1 || sip != 1) {
            printf("{\"status\":\"BLOCKED\",\"reason\":\"probePreflight\",\"policy\":%ld,\"catalog\":%d,\"target\":%d,\"sip\":%d}\n",
                   (long)app.activationPolicy, catalog, target, sip);
            return 2;
        }
        int c = np_stage_connection();
        NSDictionary *home = current();
        NSNumber *sid = home[@"ManagedSpaceID"];
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (!front || !sid || ![home[@"type"] isEqual:@0] || !NSScreen.mainScreen || c <= 0) {
            puts("{\"status\":\"BLOCKED\",\"reason\":\"ordinaryDesktopRequired\"}"); return 2;
        }
        NSRect screen = NSScreen.mainScreen.frame;
        MembershipPanel *panel = [[MembershipPanel alloc] initWithContentRect:NSMakeRect(NSMidX(screen), NSMidY(screen), 4, 4)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed = NO; panel.opaque = NO; panel.backgroundColor = NSColor.clearColor;
        panel.alphaValue = 0; panel.hasShadow = NO; panel.ignoresMouseEvents = YES; panel.hidesOnDeactivate = NO;
        panel.excludedFromWindowsMenu = YES; panel.level = NSNormalWindowLevel; panel.animationBehavior = NSWindowAnimationBehaviorNone;
        panel.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorFullScreenNone;
        [panel orderFront:nil];
        uint32_t wid = (uint32_t)panel.windowNumber;
        NSMutableArray *reads = [NSMutableArray array];
        BOOL stable = YES;
        for (NSNumber *interval in @[@0, @0.016, @0.05, @0.15, @0.4, @0.9]) {
            if (interval.doubleValue > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:interval.doubleValue]];
            if (wid == 0 || panel.windowNumber != wid || panel.keyWindow || panel.mainWindow ||
                ![current() isEqual:home] || ![NSWorkspace.sharedWorkspace.frontmostApplication isEqual:front]) { stable = NO; break; }
            uint64_t ids[128], occupants[8192];
            int n = np_stage_membership(c, wid, ids, 128);
            NSMutableArray *engine = [NSMutableArray array];
            for (int i = 0; i < n; i++) [engine addObject:@(ids[i])];
            NSArray *catalog = CFBridgingRelease(NPReadWindowSpaces(wid));
            int occupantsCount = np_stage_occupants(c, sid.unsignedLongLongValue, occupants, 8192);
            unsigned hits = 0;
            for (int i = 0; i < occupantsCount; i++) if (occupants[i] == wid) hits++;
            [reads addObject:@{@"uptime":@(NSProcessInfo.processInfo.systemUptime), @"window":@(wid),
                @"engineMask15":n < 0 ? (id)NSNull.null : engine, @"catalogMask7":catalog ?: (id)NSNull.null,
                @"forwardHits":occupantsCount < 0 ? (id)NSNull.null : @(hits), @"appKitOnActiveSpace":@(panel.onActiveSpace)}];
        }
        [panel close];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.18]];
        NSArray *end = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid));
        BOOL closed = end != nil && end.count == 0;
        NSDictionary *report = @{@"schema":@1, @"status":stable && closed ? @"OBSERVED" : @"UNKNOWN",
            @"scope":@"separateOwnTransparentPanelMembership", @"qualification":@NO, @"home":sid,
            @"reads":reads, @"windowServerAbsentAfterClose":@(closed),
            @"originalForegroundAtEnd":@([NSWorkspace.sharedWorkspace.frontmostApplication isEqual:front]),
            @"spaceWriteAttempts":@0, @"postedInput":@0};
        NSData *bytes = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
        [NSFileHandle.fileHandleWithStandardOutput writeData:bytes];
        return stable && closed ? 0 : 2;
    }
}
