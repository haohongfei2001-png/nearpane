// Per-display click-through corner sheet. Pinned upstream provenance is in origins/corner.json.
#import "patch_sheet.h"
#import <ColorSync/ColorSync.h>
#import "patch_crop.h"
#import <libproc.h>
#include <sys/mount.h>
#include <sys/stat.h>
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

// Static Apple wallpaper only. Unreadable, dynamic, custom and ambiguous
// wallpapers leave the corner uncovered; this visual never intercepts input.
static NSURL *staticWallpaper(NSScreen *screen, struct stat *st) {
    NSURL *url = [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
    if (!url.isFileURL)
        return nil;
    NSArray *roots = @[ @"/System/Library/Desktop Pictures/", @"/System/Library/Wallpapers/" ];
    NSString *raw = url.path;
    if (![raw hasPrefix:roots[0]] && ![raw hasPrefix:roots[1]])
        return nil;
    NSString *file = raw.stringByResolvingSymlinksInPath;
    if (![file hasPrefix:roots[0]] && ![file hasPrefix:roots[1]])
        return nil;
    struct stat system = {0};
    struct statfs volume = {0};
    const char *name = file.fileSystemRepresentation;
    if (stat("/System/Library", &system) || lstat(name, st) || statfs(name, &volume) ||
        !(volume.f_flags & MNT_RDONLY) || st->st_dev != system.st_dev || st->st_uid != 0 ||
        !S_ISREG(st->st_mode) || st->st_mode & 022 || st->st_size < 1 || st->st_size > 100 * 1024 * 1024 ||
        ![@[ @"jpg", @"jpeg", @"png", @"heic", @"tif", @"tiff" ]
            containsObject:file.pathExtension.lowercaseString])
        return nil;
    return [NSURL fileURLWithPath:file];
}

static uint32_t targetOrder(const NCParkedPatchMember *members, unsigned count, NCFrame frame, uint32_t panel,
                            BOOL planned) {
    NCListed *rows = calloc(2048, sizeof(*rows));
    if (!rows)
        return 0;
    NCDock dock = {};
    uint32_t n = 0, ids[64], above = 0;
    if (np_corner_zorder(rows, 2048, &n, &dock) != 0) {
        free(rows);
        return 0;
    }
    for (unsigned j = 0; j < count; j++)
        ids[j] = members[j].member.window;
    CGWindowLevel icons = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
    for (unsigned i = 0; i < n; i++) {
        const NCListed *w = &rows[i];
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
        } else if (w->window != panel && w->alpha > 0) {
            // Do not paint wallpaper over desktop icons, widgets, a menu, or the actual Dock.
            if (w->layer >= icons && w->layer < 0) {
                free(rows);
                return 0;
            }
            if (w->layer > 0) {
                if (w->pid != dock.pid || w->layer != 20 || !dock.count) {
                    free(rows);
                    return 0;
                }
                for (unsigned k = 0; k < dock.count; k++)
                    if (CGRectIntersectsRect(patchRect(dock.bars[k]), patchRect(frame))) {
                        free(rows);
                        return 0;
                    }
            }
        }
    }
    BOOL ok = above && np_corner_patch_order(rows, n, ids, count, panel, above, frame, planned);
    free(rows);
    return ok ? above : 0;
}

@interface NCPatchSheet : NSObject
@property(nonatomic, strong) NCWallpaperPanel *panel;
@property(nonatomic, strong) NSArray *source;
@property(nonatomic) uint32_t anchor;
@end
@implementation NCPatchSheet
@end

@interface NCPatchSession : NSObject {
  @public
    NSData *latest;
    uint64_t validUntil;
    BOOL stopped, scheduled;
}
@property(nonatomic, strong) NSMutableDictionary<NSData *, NCPatchSheet *> *sheets;
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
        return !stopped && latest == packet && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < validUntil;
    }
}
- (BOOL)show:(NSData *)group key:(NSData *)key packet:(NSData *)packet {
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
    NSScreen *screen = nil;
    CGDirectDisplayID display = 0;
    for (NSScreen *s in NSScreen.screens) {
        CGDirectDisplayID id = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(id);
        if (!uuid)
            return NO;
        CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
        CFRelease(uuid);
        if (!memcmp(&bytes, key.bytes, 16)) {
            if (screen)
                return NO;
            screen = s;
            display = id;
        }
    }
    if (!screen || !CGDisplayIsActive(display) || CGDisplayIsInMirrorSet(display))
        return NO;
    CGRect raw = CGDisplayBounds(display);
    NCFrame d = {raw.origin.x, raw.origin.y, raw.size.width, raw.size.height};
    if (!np_corner_patch_bounds(frames, count, d, &frame))
        return NO;
    NSRect f = NSMakeRect(NSMinX(screen.frame) + frame.x - d.x,
                          NSMaxY(screen.frame) - (frame.y - d.y) - frame.h, frame.w, frame.h);
    struct stat st = {};
    NSURL *url = staticWallpaper(screen, &st);
    if (!url)
        return NO;
    NSDictionary *options = [NSWorkspace.sharedWorkspace desktopImageOptionsForScreen:screen];
    if (!options)
        return NO;
    NSArray *source = @[
        url, options, @(st.st_ino), @(st.st_size), @(st.st_mtimespec.tv_sec), @(st.st_mtimespec.tv_nsec),
        [NSValue valueWithRect:f], @(members[0].member.native),
        [NSData dataWithBytes:members[0].member.space length:16]
    ];
    NCPatchSheet *sheet = self.sheets[key];
    if (sheet && ![sheet.source isEqual:source]) {
        [self withdraw:key];
        sheet = nil;
    }
    if (!sheet) {
        // Plan first so an obstructed corner never incurs a wallpaper decode.
        if (!targetOrder(members, count, frame, UINT32_MAX, YES))
            return NO;
        // Rust's retained AX reference and the WindowServer frame already agree at publication.
        // A background ImageIO decode cannot stall an event-tap update or a group transition.
        sheet = [NCPatchSheet new];
        sheet.source = source;
        self.sheets[key] = sheet;
        __weak NCPatchSession *weak = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          CGImageRef crop = cropWallpaper(url, options, d, frame);
          dispatch_async(dispatch_get_main_queue(), ^{
            NCPatchSession *session = weak;
            if (crop && session.sheets[key] == sheet && [session current:packet]) {
                sheet.panel = patchPanel(f, crop);
                [session update];
            } else if (session.sheets[key] == sheet && ![session current:packet]) {
                [session withdraw:key];
            }
            if (crop)
                CGImageRelease(crop);
          });
        });
        return YES;
    }
    if (!sheet.panel)
        return YES;
    NCWallpaperPanel *panel = sheet.panel;
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
    if (panel.visible && panel.onActiveSpace && sheet.anchor &&
        targetOrder(members, count, frame, number, NO) == sheet.anchor)
        return YES;
    if (panel.visible)
        [panel orderOut:nil];
    uint32_t anchor = targetOrder(members, count, frame, number, YES);
    if (!anchor || ![self current:packet])
        return NO;
    [panel orderWindow:NSWindowAbove relativeTo:anchor];
    sheet.anchor = anchor;
    return panel.visible && panel.onActiveSpace && [self current:packet] &&
           targetOrder(members, count, frame, number, NO) == anchor;
}
- (void)update {
    NSData *packet;
    @synchronized(self) {
        scheduled = NO;
        if (stopped || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= validUntil)
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
    for (NSData *key in groups) {
        @try {
            if ([self show:groups[key] key:key packet:packet])
                continue;
        } @catch (NSException *error) {
            (void)error;
        }
        [self withdraw:key];
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
                          session->validUntil = 0;
                      }
                      [session update];
                    }];
    }
}
@end
void *np_corner_patch_session(void) {
    NCPatchSession *s = [NCPatchSession new];
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
            if (s->stopped)
                return;
            BOOL same = (s->latest == packet || [s->latest isEqual:packet]);
            s->validUntil = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 450000000;
            if (same)
                return;
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
void np_corner_patch_end(void *owner) {
    if (!owner)
        return;
    NCPatchSession *s = CFBridgingRelease(owner);
    @synchronized(s) {
        s->stopped = YES;
        s->latest = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [s update];
    });
}
