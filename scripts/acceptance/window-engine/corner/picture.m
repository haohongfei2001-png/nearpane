// Evidence for a real, click-through optional patch. No full-display or foreign-window capture.
#import "picture.h"
#import "guardian/identity.h"
#include "macos.h"
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <sys/mount.h>

extern bool np_fixture_patch_bounds(NCFrame, NCFrame, NCFrame, NCFrame *);
extern bool np_fixture_patch_order(const NCListed *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, NCFrame,
                                   bool);
static CGRect cg(NCFrame r) { return CGRectMake(r.x, r.y, r.w, r.h); }
static void requirePatch(BOOL ok, NSString *reason) {
    if (!ok)
        @throw [NSException exceptionWithName:@"patch" reason:reason userInfo:nil];
}
static BOOL readWindow(const NPRequest *r, NCSample *sample) {
    NCMember m = {.pid = r->pid, .birth = r->birth, .window = r->window, .native = r->native_id};
    memcpy(m.display, r->display, 16);
    memcpy(m.space, r->native_space, 16);
    return !np_corner_sample(&m, sample) && !sample->minimized && sample->onscreen;
}
static NSURL *sealedWall(NSScreen *screen, struct stat *identity, NSString **reason) {
    *reason = @"noCertifiedStaticSystemWallpaper";
    NSURL *url = [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
    char path[PATH_MAX];
    struct stat system = {0};
    struct statfs volume;
    if (!url.isFileURL || !realpath(url.path.fileSystemRepresentation, path))
        return nil;
    NSString *s = [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)];
    if (![s hasPrefix:@"/System/Library/Desktop Pictures/"] && ![s hasPrefix:@"/System/Library/Wallpapers/"]) {
        *reason = @"outsideSealedAppleWallpaperDirectories";
        return nil;
    }
    if (lstat(path, identity) || stat("/System/Library", &system) || statfs(path, &volume) ||
        !(volume.f_flags & MNT_RDONLY) || identity->st_dev != system.st_dev || identity->st_uid != 0 ||
        !S_ISREG(identity->st_mode) || (identity->st_mode & 022) || identity->st_size < 1 ||
        identity->st_size > 100 * 1024 * 1024)
        return nil;
    if (![@[ @"jpg", @"jpeg", @"heic", @"png", @"tiff", @"tif" ] containsObject:s.pathExtension.lowercaseString])
        return nil;
    return [NSURL fileURLWithPath:s];
}
static BOOL sameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
           a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec;
}
static BOOL isolatedImage(CGWindowID window, NSSize size, CGImageRef *image) {
    if (!CGPreflightScreenCaptureAccess())
        return NO;
    __block BOOL done = NO;
    __block CGImageRef captured = NULL;
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:YES
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent *content, NSError *error) {
                                   SCWindow *match = nil;
                                   if (!error)
                                       for (SCWindow *w in content.windows)
                                           if (w.windowID == window && w.owningApplication.processID == getpid()) {
                                               if (match) {
                                                   match = nil;
                                                   break;
                                               }
                                               match = w;
                                           }
                                   if (!match) {
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                         done = YES;
                                       });
                                       return;
                                   }
                                   SCContentFilter *filter =
                                       [[SCContentFilter alloc] initWithDesktopIndependentWindow:match];
                                   SCStreamConfiguration *config = [SCStreamConfiguration new];
                                   config.width = (size_t)size.width;
                                   config.height = (size_t)size.height;
                                   config.showsCursor = NO;
                                   config.ignoreShadowsSingleWindow = YES;
                                   config.ignoreGlobalClipSingleWindow = YES;
                                   [SCScreenshotManager
                                       captureImageWithFilter:filter
                                                configuration:config
                                            completionHandler:^(CGImageRef actual, NSError *failure) {
                                              id kept = (!failure && actual)
                                                            ? CFBridgingRelease(CGImageRetain(actual))
                                                            : nil;
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                if (!done && kept)
                                                    captured = CGImageRetain((__bridge CGImageRef)kept);
                                                done = YES;
                                              });
                                            }];
                                 }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:1.8];
    while (!done && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    done = YES;
    *image = captured;
    return captured != NULL;
}
static BOOL pictureAgrees(CGImageRef a, CGImageRef b, unsigned *maxDifference) {
    uint8_t left[10 * 10 * 4] = {0}, right[sizeof(left)] = {0};
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!srgb)
        return NO;
    BOOL ok = YES;
    *maxDifference = 0;
    for (int i = 0; i < 2; i++) {
        CGContextRef context =
            CGBitmapContextCreate(i ? right : left, 10, 10, 8, 40, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        if (!context) {
            ok = NO;
            break;
        }
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, 10, 10), i ? b : a);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(srgb);
    for (int i = 0; i < 400 && ok; i++) {
        if (i % 4 == 3) {
            if (left[i] != 255 || right[i] != 255)
                ok = NO;
        } else
            *maxDifference = MAX(*maxDifference, (unsigned)abs((int)left[i] - (int)right[i]));
    }
    return ok && *maxDifference <= 3;
}
@interface NCWallpaperPanel : NSPanel
@end
@implementation NCWallpaperPanel
- (BOOL)canBecomeKeyWindow {
    return NO;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end
static uint32_t realOrder(const NPRequest *a, const NPRequest *b, uint32_t patch, NCFrame frame, BOOL planned) {
    size_t cap = 8192;
    NSMutableData *storage = [NSMutableData dataWithLength:cap * sizeof(NCListed)];
    NCListed *list = storage.mutableBytes;
    uint32_t n = 0, above = 0, found = 0;
    NCDock dock = {0};
    if (np_corner_zorder(list, (uint32_t)cap, &n, &dock))
        return 0;
    for (uint32_t i = 0; i < n; i++) {
        NCListed w = list[i];
        if (w.window == a->window || w.window == b->window) {
            const NPRequest *r = w.window == a->window ? a : b;
            if (w.pid != r->pid || w.layer != 0 || w.alpha <= 0 || !CGRectIntersectsRect(cg(w.frame), cg(frame)))
                return 0;
            if (!above)
                above = w.window;
            found++;
        } else if (w.window != patch && w.layer >= 0 && w.alpha > 0 &&
                   CGRectIntersectsRect(cg(w.frame), cg(frame))) {
            if (w.pid != dock.pid || w.layer != 20 || !dock.count)
                return 0;
            for (unsigned j = 0; j < dock.count; j++)
                if (CGRectIntersectsRect(cg(dock.bars[j]), cg(frame)))
                    return 0;
        }
    }
    return found == 2 && np_fixture_patch_order(list, n, a->window, b->window, patch, above, frame, planned)
               ? above
               : 0;
}
NSDictionary *nc_fixture_picture(const NPRequest *a, const NPRequest *b) {
    NSMutableDictionary *receipt = [@{
        @"status" : @"BLOCKED",
        @"actualLayer" : @NO,
        @"wallpaperWritten" : @NO,
        @"physicalDisplayPixelComparison" : @"NOT_RUN"
    } mutableCopy];
    CGImageRef wallpaper = NULL, crop = NULL, captured = NULL;
    CGImageSourceRef source = NULL;
    NCWallpaperPanel *panel = nil;
    @try {
        requirePatch(ncg_disposable() && NSThread.isMainThread, @"isolatedMainThreadRequired");
        uint32_t hid[13], latest[13];
        np_corner_inputs(hid);
        NCDisplay d = {0};
        uint32_t count = 0;
        requirePatch(!np_corner_displays(&d, 1, &count) && count == 1 && !memcmp(a->display, d.uuid, 16) &&
                         !memcmp(b->display, d.uuid, 16) && a->native_id == b->native_id &&
                         !memcmp(a->native_space, b->native_space, 16),
                     @"singleBoundDisplayRequired");
        NSScreen *screen = NSScreen.screens.firstObject;
        struct stat initial = {0}, latestFile = {0};
        NSString *reason = nil;
        NSURL *url = sealedWall(screen, &initial, &reason);
        requirePatch(url != nil, reason);
        receipt[@"source"] = @"readOnlySealedAppleSystemWallpaper";
        NSDictionary *options = [NSWorkspace.sharedWorkspace desktopImageOptionsForScreen:screen];
        NSNumber *scaling = options[NSWorkspaceDesktopImageScalingKey],
                 *clipping = options[NSWorkspaceDesktopImageAllowClippingKey];
        BOOL stretch = [scaling isEqual:@(NSImageScaleAxesIndependently)],
             fill = [scaling isEqual:@(NSImageScaleProportionallyUpOrDown)] && [clipping isEqual:@YES];
        requirePatch(stretch || fill, @"exactWallpaperPlacementNotExposed");
        NCSample sa = {}, sb = {};
        NCFrame frame = {};
        requirePatch(readWindow(a, &sa) && readWindow(b, &sb) &&
                         np_fixture_patch_bounds(sa.cg, sb.cg, d.frame, &frame),
                     @"confirmedSliverRectangleUnavailable");
        source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        requirePatch(source && CGImageSourceGetCount(source) == 1, @"dynamicOrUnreadableSystemAsset");
        NSDictionary *meta = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        requirePatch(!meta[(__bridge NSString *)kCGImagePropertyOrientation] ||
                         [meta[(__bridge NSString *)kCGImagePropertyOrientation] isEqual:@1],
                     @"rotatedSystemWallpaper");
        wallpaper = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        requirePatch(wallpaper != NULL, @"requestedAppleWallpaperDecodeUnavailable");
        double iw = CGImageGetWidth(wallpaper), ih = CGImageGetHeight(wallpaper), sx = d.frame.w / iw,
               sy = d.frame.h / ih;
        if (fill)
            sx = sy = MAX(sx, sy);
        CGRect sourceRect =
            CGRectMake((frame.x - d.frame.x - (d.frame.w - iw * sx) / 2) / sx,
                       (frame.y - d.frame.y - (d.frame.h - ih * sy) / 2) / sy, frame.w / sx, frame.h / sy);
        requirePatch(CGRectContainsRect(CGRectMake(0, 0, iw, ih), sourceRect), @"wallpaperCropOutOfBounds");
        crop = CGImageCreateWithImageInRect(wallpaper, CGRectIntegral(sourceRect));
        requirePatch(crop != NULL, @"couldNotCropAppleAsset");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSRect f = NSMakeRect(NSMinX(screen.frame) + frame.x - d.frame.x,
                              NSMaxY(screen.frame) - (frame.y - d.frame.y) - frame.h, frame.w, frame.h);
        panel = [[NCWallpaperPanel alloc]
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
        NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, frame.w, frame.h)];
        view.imageScaling = NSImageScaleAxesIndependently;
        view.image = [[NSImage alloc] initWithCGImage:crop size:NSMakeSize(frame.w, frame.h)];
        panel.contentView = view;
        uint32_t number = (uint32_t)panel.windowNumber;
        uint32_t above = realOrder(a, b, number, frame, YES);
        np_corner_inputs(latest);
        requirePatch(above && !memcmp(hid, latest, sizeof(hid)) && !np_corner_secure_input(),
                     @"preorderOrHumanInputChanged");
        [panel orderWindow:NSWindowAbove relativeTo:above];
        [panel displayIfNeeded];
        [NSApp updateWindows];
        for (unsigned i = 0; i < 2; i++) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.06]];
            requirePatch(realOrder(a, b, number, frame, NO) && readWindow(a, &sa) && readWindow(b, &sb) &&
                             panel.ignoresMouseEvents && !panel.isKeyWindow,
                         @"independentZOrderDidNotConfirmExactClickThroughPanel");
        }
        receipt[@"actualLayer"] = @YES;
        receipt[@"verifiedParkedCount"] = @2;
        receipt[@"zOrderReadbacks"] = @2;
        receipt[@"patchFrame"] = @[ @(frame.x), @(frame.y), @(frame.w), @(frame.h) ];
        receipt[@"window"] = @(number);
        requirePatch(isolatedImage(number, NSMakeSize(frame.w, frame.h), &captured),
                     @"isolatedPatchWindowCaptureUnavailable");
        unsigned max = 0;
        BOOL match = pictureAgrees(crop, captured, &max);
        receipt[@"sampledOnlyOwnPatchWindow"] = @YES;
        receipt[@"maximumSRGBDifference"] = @(max);
        np_corner_inputs(latest);
        requirePatch(match && !memcmp(hid, latest, sizeof(hid)) && sealedWall(screen, &latestFile, &reason) &&
                         sameFile(initial, latestFile) &&
                         [options isEqual:[NSWorkspace.sharedWorkspace desktopImageOptionsForScreen:screen]] &&
                         realOrder(a, b, number, frame, NO),
                     @"patchPixelsWallpaperOrFinalOrderingUnconfirmed");
        receipt[@"status"] = @"PASS";
        receipt[@"scope"] = @"isolatedWindowPixelsAndTwoIndependentZOrderReads";
    } @catch (NSException *e) {
        receipt[@"reason"] = [e.name isEqual:@"patch"] ? e.reason : @"unexpectedPatchException";
    } @finally {
        [panel orderOut:nil];
        [panel close];
        if (captured)
            CGImageRelease(captured);
        if (crop)
            CGImageRelease(crop);
        if (wallpaper)
            CGImageRelease(wallpaper);
        if (source)
            CFRelease(source);
    }
    return receipt;
}
