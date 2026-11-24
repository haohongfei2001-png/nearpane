// Per-display click-through corner sheet. Pinned upstream provenance is in origins/corner.json.
#import "patch_sheet.h"
#import "../../include/nearpane_window_engine.h"
#import <ColorSync/ColorSync.h>
#import "patch_pixels.h"
#import <libproc.h>
#include <time.h>

@interface NCWallpaperPanel : NSPanel
@property(nonatomic, copy) NSSet<NSNumber *> *members;
@property(nonatomic, copy) NSData *displayIdentity;
@property(nonatomic) NCFrame verifiedFrame;
@end
@implementation NCWallpaperPanel
- (BOOL)canBecomeKeyWindow {
    return NO;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end
static NCWallpaperPanel *patchPanel(NSRect f, CGImageRef crop) {
    if (!NSThread.isMainThread || !crop || NSIsEmptyRect(f))
        return nil;
    NCWallpaperPanel *panel = [[NCWallpaperPanel alloc]
        initWithContentRect:f
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.ignoresMouseEvents = YES;
    panel.hasShadow = NO;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.opaque = YES;
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = NO;
    panel.level = NSNormalWindowLevel;
    panel.releasedWhenClosed = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.excludedFromWindowsMenu = YES;
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, f.size.width, f.size.height)];
    view.imageScaling = NSImageScaleAxesIndependently;
    view.image = [[NSImage alloc] initWithCGImage:crop size:NSMakeSize(f.size.width, f.size.height)];
    panel.contentView = view;
    return panel;
}
uint32_t np_corner_patch_visible(const uint32_t *ids, uint32_t count, const uint8_t display[16],
                                 NCFrame frame) {
    if (!NSThread.isMainThread || !ids || !display || !count || count > 64)
        return 0;
    NSMutableSet *targets = [NSMutableSet setWithCapacity:count];
    for (uint32_t i = 0; i < count; i++)
        [targets addObject:@(ids[i])];
    if (targets.count != count || [targets containsObject:@0])
        return 0;
    NSData *key = [NSData dataWithBytes:display length:16];
    uint32_t found = 0;
    for (NCWallpaperPanel *panel in NSApp.windows) {
        if (![panel isMemberOfClass:NCWallpaperPanel.class] || !panel.visible || !panel.onActiveSpace ||
            ![targets isEqual:panel.members] || ![key isEqual:panel.displayIdentity])
            continue;
        NCFrame actual = panel.verifiedFrame;
        if (found || panel.windowNumber <= 0 || panel.windowNumber > UINT32_MAX || panel.isKeyWindow ||
            panel.isMainWindow || !panel.ignoresMouseEvents || memcmp(&frame, &actual, sizeof(frame)))
            return 0;
        found = (uint32_t)panel.windowNumber;
    }
    return found;
}

static CGRect patchRect(NCFrame r) { return CGRectMake(r.x, r.y, r.w, r.h); }

#include "patch_material.inc"
#include "patch_display.inc"
#include "patch_site.h"

// Only the actual R4 panel of this Host is a known interactive surface above the sheet.
// It stays in both CG lists, so normal sidebar clicks and drags continue to reach it.
static BOOL ownSidebarAbove(const NCListed *row, NSScreen *screen) {
    if (!screen || row->pid != getpid() || row->layer != NSFloatingWindowLevel) return NO;
    Class type = NSClassFromString(@"NearpaneR4EdgePanel");
    NSWindow *side = [NSApp windowWithWindowNumber:row->window];
    if (!type || ![side isMemberOfClass:type] || !side.visible || !side.onActiveSpace ||
        ![side.screen.deviceDescription[@"NSScreenNumber"] isEqual:screen.deviceDescription[@"NSScreenNumber"]] ||
        side.isKeyWindow || side.isMainWindow || side.ignoresMouseEvents ||
        side.level != NSFloatingWindowLevel || !(side.styleMask & NSWindowStyleMaskNonactivatingPanel)) return NO;
    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    return NSEqualRects(side.frame, cornerPanelFrame(screen, CGDisplayBounds(display), patchRect(row->frame)));
}

// Read the potential shadow area before the coordinator changes focus and again before a hide.
// A clear site still requires the actual measured sliver, sheet, input and ordering after the move.
uint32_t np_corner_patch_sites(const NCMember *home, const NCFrame *footprints, uint32_t sites,
                               bool firstIsAlternate, uint32_t *reasons) {
    if (!home || !footprints || !reasons || !sites || sites > 4 || NSThread.isMainThread || !stillOrdinaryHome(home))
        return NP_CORNER_SITE_UNAVAILABLE;
    NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
    NSMutableData *storage = [NSMutableData dataWithLength:2048 * sizeof(NCListed)];
    NCDock dock = {};
    uint32_t count = 0;
    if (np_corner_visual_zorder(storage.mutableBytes, 2048, &count, &dock) || !count)
        return NP_CORNER_SITE_UNAVAILABLE;
    NCMember scope = *home;
    // The main queue may finish after a timeout. Never retain the worker's input or output pointers.
    NSData *requested = [NSData dataWithBytes:footprints length:sites * sizeof(*footprints)];
    NSMutableData *results = [NSMutableData dataWithLength:sites * sizeof(*reasons)];
    __block BOOL complete = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSScreen *screen = cornerScreen(&scope);
        CGDirectDisplayID id = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGRect display = CGDisplayBounds(id);
        const NCFrame *areas = requested.bytes;
        uint32_t *siteReasons = results.mutableBytes;
        complete = screen != nil;
        for (uint32_t s = 0; complete && s < sites; s++) {
            CGRect area = patchRect(areas[s]);
            complete = !CGRectIsEmpty(area) && CGRectEqualToRect(CGRectIntegral(area), area) &&
                CGRectContainsRect(display, area) && area.size.width <= 128 &&
                (CGRectGetMinX(display) == CGRectGetMinX(area) || CGRectGetMaxX(display) == CGRectGetMaxX(area));
        }
        if (complete) {
            const NCListed *rows = storage.bytes;
            CGWindowLevel icons = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
            for (uint32_t i = 0; i < count; i++) {
                BOOL sidebar = ownSidebarAbove(&rows[i], screen);
                for (uint32_t s = 0; s < sites; s++) {
                    // A new alternative must be clear over its entire potential footprint.
                    if (!siteReasons[s]) siteReasons[s] = nc_site_layer(&rows[i], patchRect(areas[s]), icons, &dock,
                                                                         sidebar, firstIsAlternate || s != 0);
                }
            }
        }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) ||
        !complete || NSProcessInfo.processInfo.systemUptime - began >= .25 || !stillOrdinaryHome(home))
        return NP_CORNER_SITE_UNAVAILABLE;
    memcpy(reasons, results.bytes, results.length);
    return 0;
}

typedef NS_ENUM(NSUInteger, NCOrderRead) { NCOrderConfirmed, NCOrderPlanned, NCOrderSettling };

static uint32_t targetOrder(const NCParkedPatchMember *members, unsigned count, NCFrame frame, uint32_t panel,
                            NCOrderRead read, uint32_t *obstruction) {
    NCListed *rows = calloc(2048, sizeof(*rows));
    if (!rows)
        return 0;
    NCDock dock = {};
    uint32_t n = 0, ids[64], above = 0;
    if (np_corner_visual_zorder(rows, 2048, &n, &dock) != 0) {
        free(rows);
        return 0;
    }
    for (unsigned j = 0; j < count; j++)
        ids[j] = members[j].member.window;
    CGWindowLevel icons = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
    NSScreen *screen = cornerScreen(&members[0].member);
    BOOL passedSheet = NO;
    uint64_t matched = 0;
    uint32_t reason = 0;
    for (unsigned i = 0; i < n; i++) {
        const NCListed *w = &rows[i];
        if (w->window == panel) {
            if (passedSheet || w->pid != getpid() || (read == NCOrderSettling &&
                (w->layer != NSNormalWindowLevel || w->alpha != 1 || !CGRectEqualToRect(patchRect(w->frame), patchRect(frame))))) {
                free(rows); return 0;
            }
            passedSheet = YES;
        }
        if (!CGRectIntersectsRect(patchRect(frame), patchRect(w->frame)))
            continue;
        unsigned j = 0;
        while (j < count && ids[j] != w->window)
            j++;
        if (j < count) {
            struct proc_bsdinfo process = {};
            if (proc_pidinfo(w->pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) != sizeof(process) ||
                process.pbi_start_tvsec * 1000000ULL + process.pbi_start_tvusec != members[j].member.birth ||
                w->pid != members[j].member.pid || w->layer != 0 || w->alpha <= 0 ||
                !CGRectEqualToRect(patchRect(w->frame), patchRect(members[j].frame))) {
                free(rows);
                return 0;
            }
            if (!above)
                above = w->window;
            uint64_t bit = UINT64_C(1) << j;
            if (matched & bit) { free(rows); return 0; }
            matched |= bit;
        } else if (w->window != panel && !reason) {
            // A lagging sheet may sit below an enrolled window. It may never cover an ordinary bystander.
            if (read == NCOrderSettling && passedSheet && w->layer == NSNormalWindowLevel && w->alpha > 0) {
                free(rows); return 0;
            }
            reason = nc_site_layer(w, patchRect(frame), icons, &dock,
                                   !above && !passedSheet && ownSidebarAbove(w, screen), true);
        }
    }
    BOOL complete = matched == (UINT64_MAX >> (64 - count));
    if (complete) *obstruction = reason;
    BOOL ok = complete && !reason && above && np_corner_patch_order(rows, n, ids, count, panel, above, frame,
                                                                     read != NCOrderConfirmed);
    free(rows);
    return ok ? above : 0;
}

@interface NCPatchSheet : NSObject
@property(nonatomic, strong) NCWallpaperPanel *panel;
@property(nonatomic, strong) NSArray *source;
@property(nonatomic, strong) id materialImage;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL sampling;
@property(nonatomic) NSTimeInterval lastAttempt, lastMatch;
@property(nonatomic, strong) NSData *orderPacket;
@property(nonatomic) uint32_t orderAnchor;
@property(nonatomic) uint64_t orderStartedNS;
@property(nonatomic) BOOL orderReadScheduled;
- (BOOL)orderExpired;
- (BOOL)placeAbove:(uint32_t)anchor packet:(NSData *)packet;
@end
@implementation NCPatchSheet
- (void)invalidatePicture {
    self.generation++;
    self.sampling = NO;
    self.lastAttempt = 0;
    self.lastMatch = 0;
}
- (BOOL)orderExpired {
    return self.orderPacket && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - self.orderStartedNS >= 250 * NSEC_PER_MSEC;
}
- (BOOL)placeAbove:(uint32_t)anchor packet:(NSData *)packet {
    NCWallpaperPanel *panel = self.panel;
    if (!anchor || !packet || !panel || panel.keyWindow || panel.mainWindow || !panel.ignoresMouseEvents ||
        (panel.visible && !panel.onActiveSpace)) return NO;
    if (self.orderPacket == packet) {
        return self.orderAnchor == anchor && panel.visible && ![self orderExpired];
    }
    [self invalidatePicture];
    self.orderPacket = packet;
    self.orderAnchor = anchor;
    self.orderStartedNS = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    // AppKit can restack a visible sheet in place. Ordering it out here would expose its previous members.
    [panel orderWindow:NSWindowAbove relativeTo:anchor];
    return panel.visible && panel.onActiveSpace && !panel.keyWindow && !panel.mainWindow && panel.ignoresMouseEvents;
}
@end

@interface NCPatchSession : NSObject {
  @public
    NSData *latest, *verifiedMembers;
    uint64_t validUntil, verifiedAt;
    BOOL stopped, scheduled, interrupted;
    void (^interruptInput)(uint32_t);
}
@property(nonatomic, strong) NSMutableDictionary<NSData *, NCPatchSheet *> *sheets;
@property(nonatomic, strong) NSMutableDictionary<NSData *, NCCornerStill *> *materials;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) id spaceObserver;
@end

@implementation NCPatchSession
- (void)withdraw:(NSData *)key {
    NSPanel *p = self.sheets[key].panel;
    [p orderOut:nil];
    [p close];
    [self.sheets removeObjectForKey:key];
}
- (BOOL)current:(NSData *)packet {
    @synchronized(self) {
        return packet && !stopped && !interrupted && latest == packet && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < validUntil;
    }
}
- (void)interrupt:(uint32_t)reason packet:(NSData *)packet {
    @synchronized(self) {
        if (![self current:packet]) return;
        interrupted = YES;
        verifiedMembers = nil;
        // The worker may be inside an AX command. Revoke its input generation before returning to AppKit.
        interruptInput(reason);
    }
}
- (uint32_t)order:(NSData *)group frame:(NCFrame)frame panel:(uint32_t)panel read:(NCOrderRead)read packet:(NSData *)packet {
    if (![self current:packet]) return 0;
    uint32_t obstruction = 0;
    uint32_t anchor = targetOrder(group.bytes, (unsigned)(group.length / sizeof(NCParkedPatchMember)),
                                  frame, panel, read, &obstruction);
    if (obstruction) [self interrupt:obstruction packet:packet];
    return anchor;
}
- (BOOL)picture:(NCPatchSheet *)sheet home:(const NCMember *)home key:(NSData *)key frame:(NCFrame)frame packet:(NSData *)packet {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // The geometry/tap path remains independent. Only live parked sheets incur captures.
    // Recheck before expiry, and never block the event-tap or the AppKit run loop.
    if (!sheet.sampling && (!sheet.lastAttempt || now - sheet.lastAttempt >= 0.75)) {
        NSUInteger epoch = sheet.generation;
        sheet.sampling = YES;
        sheet.lastAttempt = now;
        __weak NCPatchSession *weak = self;
        np_corner_compare_panel(sheet.panel, *home, frame, ^(NCCornerPicture verdict) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NCPatchSession *session = weak;
                if (session.sheets[key] != sheet || sheet.generation != epoch) return;
                sheet.sampling = NO;
                if (![session current:packet]) return;
                if (verdict == NCCornerPictureDifferent && sheet.lastMatch > 0)
                    [session interrupt:NP_CORNER_PICTURE_CHANGED packet:packet];
                sheet.lastMatch = verdict == NCCornerPictureMatch ? now : 0;
                [session update];
            });
        });
    }
    return sheet.lastMatch > 0 && now - sheet.lastMatch < 1.25;
}
- (BOOL)show:(NSData *)group key:(NSData *)key packet:(NSData *)packet verified:(BOOL *)verified {
    *verified = NO;
    uint32_t count = (uint32_t)(group.length / sizeof(NCParkedPatchMember));
    if (!count || count > 64)
        return NO;
    const NCParkedPatchMember *members = group.bytes;
    NCFrame frames[64], frame = {};
    for (unsigned j = 0; j < count; j++) {
        if (memcmp(members[0].member.space, members[j].member.space, 16) ||
            members[0].member.native != members[j].member.native)
            return NO;
        frames[j] = members[j].frame;
    }
    NSScreen *screen = cornerScreen(&members[0].member);
    if (!screen) return NO;
    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect raw = CGDisplayBounds(display);
    NCFrame d = {raw.origin.x, raw.origin.y, raw.size.width, raw.size.height};
    if (!np_corner_patch_bounds(frames, count, d, &frame))
        return NO;
    NSRect f = cornerPanelFrame(screen, raw, patchRect(frame));
    NCCornerStill *still = self.materials[key];
    if (!still || ![still sourceCurrent:screen home:&members[0].member] || ![still readyFor:patchRect(frame)] ||
        ![stillWallpaperWindow(raw) isEqual:still.wallpaper]) {
        if (still && !still.pending) [self.materials removeObjectForKey:key];
        return NO;
    }
    if (@available(macOS 14.2, *)) {
        if (!still.pending && NSProcessInfo.processInfo.systemUptime - still.sampled > 5)
            [still refresh:screen completion:^(BOOL fresh) { (void)fresh; }];
    }
    NSArray *source = @[still, [NSValue valueWithRect:f]];
    NCPatchSheet *sheet = self.sheets[key];
    if (sheet && ![sheet.source isEqual:source]) {
        [self withdraw:key];
        sheet = nil;
    }
    if (!sheet) {
        // Plan first so an obstructed corner never incurs a wallpaper decode.
        if (![self order:group frame:frame panel:UINT32_MAX read:NCOrderPlanned packet:packet])
            return NO;
        sheet = [NCPatchSheet new];
        sheet.source = source;
        sheet.panel = (NCWallpaperPanel *)np_corner_material_panel((__bridge void *)self.materials, &members[0].member, frame);
        if (!sheet.panel) return NO;
        sheet.materialImage = still.pixels;
        self.sheets[key] = sheet;
    }
    NCWallpaperPanel *panel = sheet.panel;
    if (sheet.materialImage != still.pixels) {
        CGImageRef crop = [still copyCrop:patchRect(frame)];
        if (!crop) return NO;
        ((NSImageView *)panel.contentView).image = [[NSImage alloc] initWithCGImage:crop size:f.size];
        CGImageRelease(crop);
        sheet.materialImage = still.pixels;
        [sheet invalidatePicture];
    }
    if (panel.windowNumber <= 0 || panel.windowNumber > UINT32_MAX || panel.isKeyWindow || panel.isMainWindow ||
        !panel.ignoresMouseEvents)
        return NO;
    uint32_t number = (uint32_t)panel.windowNumber;
    if (![self current:packet])
        return NO;
    NSMutableSet *ids = [NSMutableSet setWithCapacity:count];
    for (unsigned j = 0; j < count; j++)
        [ids addObject:@(members[j].member.window)];
    panel.members = ids;
    panel.verifiedFrame = frame;
    panel.displayIdentity = key;
    // A new member may change the highest parked window without moving the existing sheet.
    // Its real Z-order must already cover this exact roster. The surface proof still belongs
    // to the same panel, material, native desktop, display and pixel rectangle.
    if (sheet.orderPacket == packet && [sheet orderExpired]) {
        [self interrupt:NP_CORNER_SITE_UNAVAILABLE packet:packet];
        return NO;
    }
    uint32_t covered = panel.visible && panel.onActiveSpace ? [self order:group frame:frame panel:number read:NCOrderConfirmed packet:packet] : 0;
    if (covered) {
        sheet.orderPacket = nil;
        *verified = [self picture:sheet home:&members[0].member key:key frame:frame packet:packet];
        return YES;
    }
    uint32_t anchor = [self order:group frame:frame panel:number read:NCOrderSettling packet:packet];
    if (!anchor || ![self current:packet]) {
        if (panel.visible) [self interrupt:NP_CORNER_SITE_UNAVAILABLE packet:packet];
        return NO;
    }
    if (![sheet placeAbove:anchor packet:packet]) {
        [self interrupt:NP_CORNER_SITE_UNAVAILABLE packet:packet];
        return NO;
    }
    // WindowServer may still list the old order on return from AppKit. Keep the
    // sheet unverified and re-read the roster; never reissue the same pending order.
    if (!sheet.orderReadScheduled) {
        sheet.orderReadScheduled = YES;
        __weak NCPatchSession *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            sheet.orderReadScheduled = NO;
            NCPatchSession *session = weak;
            if (session.sheets[key] == sheet && [session current:sheet.orderPacket]) [session update];
        });
    }
    return YES;
}
- (void)update {
    NSData *packet;
    @synchronized(self) {
        scheduled = NO;
        if (stopped || interrupted || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= validUntil)
            latest = nil;
        packet = latest;
    }
    NSMutableDictionary<NSData *, NSMutableData *> *groups = [NSMutableDictionary dictionary];
    const NCParkedPatchMember *m = packet.bytes;
    NSUInteger n = packet.length / sizeof(*m);
    for (NSUInteger i = 0; i < n; i++) {
        NSData *key = [NSData dataWithBytes:m[i].member.display length:16];
        if (!groups[key])
            groups[key] = [NSMutableData data];
        [groups[key] appendBytes:&m[i] length:sizeof(*m)];
    }
    for (NSData *key in self.sheets.allKeys)
        if (!groups[key])
            [self withdraw:key];
    NSMutableData *confirmed = [NSMutableData data];
    uint64_t observed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (NSData *key in groups) {
        @try {
            BOOL visible = NO;
            if ([self show:groups[key] key:key packet:packet verified:&visible]) {
                if (visible) [confirmed appendData:groups[key]];
                continue;
            }
        } @catch (NSException *error) {
            (void)error;
        }
        [self withdraw:key];
    }
    @synchronized(self) {
        if ([self current:packet]) {
            verifiedMembers = [confirmed copy];
            verifiedAt = observed;
        }
    }
    if (!groups.count) {
        [self.timer invalidate];
        self.timer = nil;
        if (self.spaceObserver)
            [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.spaceObserver];
        self.spaceObserver = nil;
        return;
    }
    if (!self.timer) {
        __weak NCPatchSession *weak = self;
        self.timer = [NSTimer timerWithTimeInterval:0.18
                                            repeats:YES
                                              block:^(NSTimer *t) {
                                                (void)t;
                                                [weak update];
                                              }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        self.spaceObserver = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                      (void)note;
                      NCPatchSession *session = weak;
                      if (!session)
                          return;
                      @synchronized(session) {
                          session->latest = nil;
                          session->verifiedMembers = nil;
                          session->validUntil = 0;
                      }
                      [session update];
                    }];
    }
}
@end
void *np_corner_patch_material(void) {
    return (__bridge_retained void *)[NSMutableDictionary dictionary];
}
void np_corner_patch_material_end(void *material) {
    if (material) CFRelease(material);
}
uint32_t np_corner_patch_prepare_source(void *material, const NCMember *requested, NCFrame footprint, bool prepare) {
    if (!material || !requested || !requested->native || NSThread.isMainThread || !stillOrdinaryHome(requested)) return false;
    if (!CGPreflightScreenCaptureAccess()) return false;
    if (@available(macOS 14.2, *)) {
        NSMutableDictionary *store = (__bridge NSMutableDictionary *)material;
        NCMember home = {.native = requested->native};
        memcpy(home.space, requested->space, 16); memcpy(home.display, requested->display, 16);
        CGRect region = patchRect(footprint);
        if (CGRectIsEmpty(region) || !CGRectEqualToRect(region, CGRectIntegral(region)) || region.size.width > 128) return false;
        __block BOOL ready = NO;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(BOOL) = ^(BOOL ok) { ready = ok; dispatch_semaphore_signal(done); };
            NSData *key = [NSData dataWithBytes:home.display length:16];
            for (NSScreen *screen in NSScreen.screens) {
                CGDirectDisplayID d = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
                CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(d);
                if (!uuid) continue;
                CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
                CFRelease(uuid);
                if (memcmp(home.display, &bytes, 16)) continue;
                CGRect frame = CGDisplayBounds(d);
                if (!CGRectContainsRect(frame, region) || (CGRectGetMinX(region) != CGRectGetMinX(frame) &&
                    CGRectGetMaxX(region) != CGRectGetMaxX(frame))) break;
                NCCornerStill *existing = store[key];
                if (existing && [existing sourceCurrent:screen home:&home] && [existing readyFor:region] &&
                    NSProcessInfo.processInfo.systemUptime - existing.sampled < 7 &&
                    [stillWallpaperWindow(frame) isEqual:existing.wallpaper]) { finish(YES); return; }
                if (!prepare || (existing.pending && NSProcessInfo.processInfo.systemUptime - existing.started <= 3)) break;
                if (!existing && store.count >= 8) break;
                NCCornerStill *still = [NCCornerStill new];
                still.home = home;
                still.display = d;
                still.region = region;
                still.displayFrame = frame;
                store[key] = still;
                [still refresh:screen completion:^(BOOL ok) {
                    if (store[key] == still && !ok) [store removeObjectForKey:key];
                    finish(ok && store[key] == still);
                }];
                return;
            }
            finish(NO);
        });
        if (!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, prepare ? 3200 * NSEC_PER_MSEC : 250 * NSEC_PER_MSEC)) && ready)
            return NP_CORNER_MATERIAL_WALLPAPER_SURFACE;
    }
    return false;
}
void *np_corner_patch_session(void *material, const void *context, NCSurfaceInterrupted notify) {
    if (!material || !context || !notify) return NULL;
    NCPatchSession *s = [NCPatchSession new];
    s->interruptInput = ^(uint32_t reason) { notify(context, reason); };
    s.materials = (__bridge NSMutableDictionary *)material;
    s.sheets = [NSMutableDictionary dictionary];
    return (void *)CFBridgingRetain(s);
}
void np_corner_patch_publish(void *owner, const NCParkedPatchMember *members, uint32_t count) {
    if (!owner)
        return;
    @autoreleasepool {
        NCPatchSession *s = (__bridge NCPatchSession *)owner;
        NSData *packet = members && count && count <= 64
                             ? [NSData dataWithBytes:members length:sizeof(*members) * count]
                             : nil;
        @synchronized(s) {
            if (s->stopped || s->interrupted)
                return;
            BOOL same = (s->latest == packet || [s->latest isEqual:packet]);
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            // An expired publication cannot extend the lifetime of an old in-flight sample.
            same = same && now < s->validUntil;
            s->validUntil = now + 450000000;
            if (same)
                return;
            s->verifiedMembers = nil;
            s->latest = packet;
            if (s->scheduled)
                return;
            s->scheduled = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          [s update];
        });
    }
}
bool np_corner_patch_verified(void *owner, const NCParkedPatchMember *member) {
    if (!owner || !member) return false;
    NCPatchSession *s = (__bridge NCPatchSession *)owner;
    @synchronized(s) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (s->stopped || s->interrupted || !s->latest || now >= s->validUntil || now - s->verifiedAt >= 450000000)
            return false;
        const NCParkedPatchMember *rows = s->verifiedMembers.bytes;
        for (size_t i = 0; i < s->verifiedMembers.length / sizeof(*rows); ++i)
            if (!memcmp(&rows[i], member, sizeof(*rows))) return true;
        return false;
    }
}
void np_corner_patch_end(void *owner) {
    if (!owner)
        return;
    NCPatchSession *s = CFBridgingRelease(owner);
    @synchronized(s) {
        s->stopped = YES;
        s->interruptInput = nil;
        s->latest = nil;
        s->verifiedMembers = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [s update];
    });
}
