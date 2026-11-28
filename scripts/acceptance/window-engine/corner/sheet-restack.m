// GUI-only check of the linked Corner sheet. Three click-through, observer-owned
// panels below the desktop icons. Read only their IDs; no capture or input events.
#import "patch_sheet.h"
#import "scope_binding.h"
#import "nearpane_host_scope.h"
#include <unistd.h>

@interface NCWallpaperPanel : NSPanel @end
@interface NCPatchSheet : NSObject
@property(nonatomic, strong) NCWallpaperPanel *panel;
@property(nonatomic, readonly) uint64_t orderStartedNS;
- (BOOL)placeAbove:(uint32_t)anchor packet:(NSData *)packet;
@end

static NSDictionary *home(void) {
    int32_t connection = 0, error = 0;
    NSArray *rows = CFBridgingRelease(np_host_scope_copy_managed(&connection, &error));
    if (error || rows.count != 1 || NSScreen.screens.count != 1) return nil;
    NSDictionary *row = rows.firstObject;
    NSUUID *display = nc_single_main_uuid(rows.count);
    NSString *token = row[@"Display Identifier"];
    if (!display || ![token isKindOfClass:NSString.class]) return nil;
    uint64_t direct = np_host_scope_direct(connection, (__bridge CFStringRef)token, &error);
    if (error || !direct) return nil;
    return nc_bound_scope(row, display.UUIDString, [token isEqual:@"Main"], direct, nil);
}

static NSArray *order(NSArray<NSNumber *> *registered) {
    CFArrayRef list = CGWindowListCreate(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return nil;
    NSMutableArray *found = [NSMutableArray array];
    // CGWindowListCreate returns raw CGWindowIDs, not CFNumbers.
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        NSNumber *number = @((CGWindowID)(uintptr_t)CFArrayGetValueAtIndex(list, i));
        if ([registered containsObject:number]) [found addObject:number];
    }
    CFRelease(list);
    return found;
}

static BOOL readTwice(NSArray *registered, NSArray *expected, NSMutableArray *reads) {
    unsigned consecutive = 0;
    for (unsigned i = 0; i < 20 && consecutive < 2; ++i) {
        NSArray *actual = order(registered);
        [reads addObject:@{@"at":@(NSProcessInfo.processInfo.systemUptime), @"order":actual ?: NSNull.null}];
        consecutive = [actual isEqual:expected] ? consecutive + 1 : 0;
        if (consecutive < 2) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.012]];
    }
    return consecutive == 2;
}

static NCWallpaperPanel *panel(NSRect area) {
    NCWallpaperPanel *p = [[NCWallpaperPanel alloc] initWithContentRect:area
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    p.releasedWhenClosed = NO;
    p.ignoresMouseEvents = YES;
    p.hasShadow = NO;
    p.hidesOnDeactivate = NO;
    p.opaque = YES;
    p.animationBehavior = NSWindowAnimationBehaviorNone;
    p.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
    p.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    return p;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSDictionary *before = home();
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        NSMutableDictionary *r = [@{@"scope":@"linkedProductSheetBetweenOwnWindowsOnly", @"status":@"BLOCKED",
            @"thirdPartyWindowWrites":@0, @"screenCaptures":@0, @"inputSent":@0, @"nativeSpaceWrites":@0} mutableCopy];
        if (before && front && front.processIdentifier != getpid()) {
            uint32_t hid[13], afterHID[13];
            np_corner_inputs(hid);
            r[@"homeBefore"] = before;
            NSRect screen = NSScreen.screens.firstObject.frame;
            NSRect box = NSMakeRect(NSMidX(screen), NSMinY(screen) + 2, 8, 8);
            NCWallpaperPanel *a = panel(box), *sheet = panel(box), *b = panel(box);
            NCPatchSheet *product = [NCPatchSheet new];
            product.panel = sheet;
            NSArray *ids = @[@(a.windowNumber), @(sheet.windowNumber), @(b.windowNumber)];
            r[@"registered"] = ids;
            r[@"ownerPID"] = @(getpid());
            r[@"level"] = @(sheet.level);
            NSMutableArray *initial = [NSMutableArray array], *after = [NSMutableArray array], *closed = [NSMutableArray array];
            @try {
                [a orderBack:nil];
                [sheet orderWindow:NSWindowAbove relativeTo:a.windowNumber];
                [b orderWindow:NSWindowAbove relativeTo:sheet.windowNumber];
                BOOL started = readTwice(ids, @[ids[2],ids[1],ids[0]], initial);
                np_corner_inputs(afterHID);
                if (started && [before isEqual:home()] && [front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication] &&
                    !memcmp(hid, afterHID, sizeof(hid))) {
                    r[@"status"] = @"UNKNOWN";
                    r[@"issuedAt"] = @(NSProcessInfo.processInfo.systemUptime);
                    NSData *publication = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
                    BOOL placed = [product placeAbove:(uint32_t)b.windowNumber packet:publication];
                    r[@"returnedAt"] = @(NSProcessInfo.processInfo.systemUptime);
                    r[@"returned"] = @(placed);
                    uint64_t issued = product.orderStartedNS;
                    r[@"immediate"] = order(ids) ?: NSNull.null;
                    BOOL waiting = [product placeAbove:(uint32_t)b.windowNumber packet:publication];
                    BOOL singleRequest = waiting && issued != 0 && issued == product.orderStartedNS;
                    r[@"samePendingOrder"] = @(singleRequest);
                    BOOL measured = readTwice(ids, @[ids[1],ids[2],ids[0]], after);
                    // Deliberately withhold confirmation from this private sheet instance.
                    // An expired publication must never send a second order for the same request.
                    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.26]];
                    BOOL expired = ![product placeAbove:(uint32_t)b.windowNumber packet:publication] && issued == product.orderStartedNS;
                    r[@"expiredWithoutReissue"] = @(expired);
                    r[@"status"] = placed && singleRequest && measured && expired ? @"PASS" : @"FAIL";
                }
            } @finally {
                for (NSPanel *owned in @[sheet,b,a]) { [owned orderOut:nil]; [owned close]; }
                BOOL cleaned = readTwice(ids, @[], closed);
                np_corner_inputs(afterHID);
                r[@"cleaned"] = @(cleaned);
                r[@"sameHID"] = @(!memcmp(hid, afterHID, sizeof(hid)));
                r[@"sameForeground"] = @([front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication]);
                NSDictionary *afterHome = home();
                if (afterHome) r[@"homeAfter"] = afterHome;
                r[@"initial"] = initial; r[@"after"] = after; r[@"cleanup"] = closed;
                if (!cleaned || ![r[@"sameHID"] boolValue] || ![r[@"sameForeground"] boolValue] ||
                    ![before isEqual:afterHome]) r[@"status"] = @"UNKNOWN";
            }
        } else {
            r[@"reason"] = @"singleOrdinaryDesktopAndExistingForegroundRequired";
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL];
        if (!json) return 2;
        [NSFileHandle.fileHandleWithStandardOutput writeData:json];
        return [r[@"status"] isEqual:@"PASS"] ? 0 : 1;
    }
}
