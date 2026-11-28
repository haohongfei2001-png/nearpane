#pragma once
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "guardian/identity.h"
#import "patch_pixels.h"
#import "wallpaper_identity.h"

typedef struct {
    CGWindowID number;
    pid_t pid;
    uint64_t birth;
    CGRect frame;
} NCSceneWindow;

// The observer can include its own surfaces. Only the disposable fixture build can
// also include its direct children which match both signed kit identities on disk.
static BOOL sceneSubject(NCSceneWindow s, NSString *kit) {
    pid_t parent = 0;
    if (!s.number || !s.birth || ncg_birth(s.pid, &parent) != s.birth) return NO;
    if (s.pid == getpid()) return !kit;
#if defined(NP_CORNER_FIXTURE)
    return kit && ncg_disposable() && parent == getpid() && ncg_fixture_hash(s.pid, kit) != nil;
#else
    return NO;
#endif
}

static SCWindow *sceneWindow(SCShareableContent *list, CGWindowID number, pid_t pid, CGRect frame) {
    SCWindow *found = nil;
    for (SCWindow *w in list.windows) {
        if (w.windowID != number) continue;
        if (found || w.owningApplication.processID != pid || !CGRectEqualToRect(w.frame, frame))
            return nil;
        found = w;
    }
    return found;
}

static BOOL sceneListed(CGWindowID number, pid_t pid, CGRect frame) {
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,number));
    NSDictionary *w = rows.count==1 ? rows.firstObject : nil;
    CGRect bounds;
    return [w[(id)kCGWindowNumber] isEqual:@(number)] && [w[(id)kCGWindowOwnerPID] isEqual:@(pid)] &&
        [w[(id)kCGWindowIsOnscreen] boolValue] && [w[(id)kCGWindowAlpha] doubleValue]>0 &&
        [w[(id)kCGWindowBounds] isKindOfClass:NSDictionary.class] &&
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&bounds) &&
        CGRectEqualToRect(frame,bounds);
}

// One actual display composite. Never request the entire screen or an exclusion list.
// No frame leaves the observer process.
static void sceneCapture(SCDisplay *display, CGRect region, NSArray<SCWindow *> *windows,
                         void (^finish)(NSData *, size_t, size_t)) API_AVAILABLE(macos(14.2));
static void sceneCapture(SCDisplay *display, CGRect region, NSArray<SCWindow *> *windows,
                         void (^finish)(NSData *, size_t, size_t)) {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display includingWindows:windows];
    filter.includeMenuBar = NO;
    CGFloat scale = filter.pointPixelScale, w = region.size.width * scale, h = region.size.height * scale;
    if (!(windows.count >= 1 && windows.count <= 4 && scale >= 1 && scale <= 4 &&
          w > 0 && h > 0 && w == floor(w) && h == floor(h) && w*h <= 1048576)) { finish(nil,0,0); return; }
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.sourceRect = CGRectOffset(region, -display.frame.origin.x, -display.frame.origin.y);
    config.destinationRect = CGRectMake(0,0,w,h);
    config.width = (size_t)w;
    config.height = (size_t)h;
    config.showsCursor = NO;
    config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    config.preservesAspectRatio = NO;
    config.scalesToFit = YES;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError *error) {
        finish(error ? nil : cornerRGBA(image, (size_t)w, (size_t)h), (size_t)w, (size_t)h);
    }];
}

static NSDictionary *sceneCounts(NSData *start, NSData *end, NSData *covered, NSData *bare) {
    if (!start.length || start.length != end.length || start.length != covered.length || start.length != bare.length)
        return @{@"status":@"UNKNOWN", @"reason":@"missingNativePixels"};
    const uint8_t *a = start.bytes, *b = end.bytes, *c = covered.bytes, *u = bare.bytes;
    NSUInteger changing = 0, different = 0, positive = 0, transparent = 0;
    for (NSUInteger i = 0; i < start.length; i += 4) {
        int movement = 0, mismatch = 0, contrast = 0;
        for (unsigned k = 0; k < 3; k++) {
            movement = MAX(movement, abs(a[i+k]-b[i+k]));
            mismatch = MAX(mismatch, MAX(abs(c[i+k]-a[i+k]), abs(c[i+k]-b[i+k])));
            contrast = MAX(contrast, MIN(abs(u[i+k]-a[i+k]), abs(u[i+k]-b[i+k])));
        }
        changing += movement > 1;
        different += mismatch > 1;
        positive += contrast >= 16;
        transparent += a[i+3] != 255 || b[i+3] != 255 || c[i+3] != 255 || u[i+3] != 255;
    }
    NSString *status = (transparent || changing || positive < 16) ? @"UNKNOWN" : (different ? @"FAIL" : @"PASS");
    return @{@"status":status, @"comparedPixels":@(start.length/4), @"nonopaquePixels":@(transparent),
             @"changedReferencePixels":@(changing), @"differentWithSheet":@(different), @"strongContrastWithoutSheet":@(positive)};
}

// Runs on AppKit's main thread. Async work retains only value copies. The caller verifies
// actual window order, foreground, HID and native membership again after this read.
static NSDictionary *readCornerScene(CGDirectDisplayID displayID, CGRect area, CGWindowID panel,
                                     const NCSceneWindow *targets, NSUInteger count, NSString *kit) {
    NSDictionary *(^unknown)(NSString *) = ^(NSString *reason) { return @{@"status":@"UNKNOWN", @"reason":reason}; };
    if (!NSThread.isMainThread || !CGPreflightScreenCaptureAccess() || !targets || !panel ||
        !count || count > 2 || !CGDisplayIsActive(displayID) || CGDisplayIsInMirrorSet(displayID)) return unknown(@"invalidPrincipalOrDisplay");
    CGRect screen = CGDisplayBounds(displayID);
    if (CGRectIsEmpty(area) || !CGRectEqualToRect(area, CGRectIntegral(area)) || !CGRectContainsRect(screen, area) ||
        area.size.width > 128 || area.size.width * area.size.height > 1048576 ||
        (CGRectGetMinX(area) != CGRectGetMinX(screen) && CGRectGetMaxX(area) != CGRectGetMaxX(screen))) return unknown(@"invalidCornerFootprint");
    NSArray *owner = stillWallpaperWindow(screen);
    if (!owner || !sceneListed(panel,getpid(),area)) return unknown(@"wallpaperOrSheetMissingFromWindowServer");
    for (NSUInteger i = 0; i < count; i++) {
        if (!sceneSubject(targets[i], kit) || !CGRectIntersectsRect(area, targets[i].frame) ||
            targets[i].number == panel || targets[i].number == [owner[2] unsignedIntValue] ||
            (i && targets[i].number == targets[0].number) ||
            !sceneListed(targets[i].number,targets[i].pid,targets[i].frame)) return unknown(@"registeredSurfaceMissingFromWindowServer");
    }
    if (@available(macOS 14.2, *)) {
        NSData *members = [NSData dataWithBytes:targets length:count*sizeof(*targets)];
        NSTimeInterval limit = NSProcessInfo.processInfo.systemUptime + 5;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block NSDictionary *measurement = nil;
        void (^finish)(NSDictionary *) = ^(NSDictionary *row) {
            measurement = row;
            dispatch_semaphore_signal(ready);
        };
        // A fully covered window may be absent from the shareable on-screen subset.
        // WindowServer itself must list each exact bound identity before and after.
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
            completionHandler:^(SCShareableContent *list, NSError *error) {
            SCDisplay *display = nil;
            for (SCDisplay *candidate in list.displays) if (candidate.displayID == displayID && CGRectEqualToRect(candidate.frame, screen)) {
                if (display) { finish(unknown(@"duplicateDisplay")); return; }
                display = candidate;
            }
            SCWindow *wall = sceneWindow(list,[owner[2] unsignedIntValue],[owner[0] intValue],screen);
            SCWindow *sheet = sceneWindow(list,panel,getpid(),area);
            if (!display || !wall || !sheet || error) {
                finish(@{@"status":@"UNKNOWN",@"reason":@"missingCaptureDescriptor",@"display":@(display!=nil),
                         @"wallpaper":@(wall!=nil),@"sheet":@(sheet!=nil),@"error":@(error.code)}); return;
            }
            NSMutableArray *bareList = [NSMutableArray arrayWithObject:wall];
            const NCSceneWindow *bound = members.bytes;
            for (NSUInteger i = 0; i < count; i++) {
                SCWindow *target = sceneWindow(list,bound[i].number,bound[i].pid,bound[i].frame);
                if (!target || !sceneSubject(bound[i], kit)) { finish(unknown(@"registeredDescriptorUnavailable")); return; }
                [bareList addObject:target];
            }
            NSArray *bare = [bareList copy], *covered = [bare arrayByAddingObject:sheet];
            sceneCapture(display, area, @[wall], ^(NSData *start, size_t w, size_t h) {
                if (!start || NSProcessInfo.processInfo.systemUptime >= limit) { finish(unknown(@"firstWallpaperCaptureUnavailable")); return; }
                dispatch_group_t images = dispatch_group_create();
                __block NSData *with = nil, *without = nil;
                dispatch_group_enter(images);
                sceneCapture(display,area,covered,^(NSData *data, size_t x, size_t y) {
                    if (x==w && y==h) with=data;
                    dispatch_group_leave(images);
                });
                dispatch_group_enter(images);
                sceneCapture(display,area,bare,^(NSData *data, size_t x, size_t y) {
                    if (x==w && y==h) without=data;
                    dispatch_group_leave(images);
                });
                dispatch_group_notify(images, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                    if (!with || !without || NSProcessInfo.processInfo.systemUptime >= limit) {
                        finish(@{@"status":@"UNKNOWN",@"reason":@"compositeCaptureUnavailable",@"withSheet":@(with!=nil),
                                 @"withoutSheet":@(without!=nil)}); return;
                    }
                    sceneCapture(display,area,@[wall],^(NSData *end, size_t x, size_t y) {
                        finish(x==w && y==h ? sceneCounts(start,end,with,without) : unknown(@"lastWallpaperCaptureUnavailable"));
                    });
                });
            });
        }];
        BOOL arrived = NO;
        while (NSProcessInfo.processInfo.systemUptime < limit) {
            if (!dispatch_semaphore_wait(ready,DISPATCH_TIME_NOW)) { arrived = YES; break; }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.015]];
        }
        // The screenshot callbacks can finish while the caller is already executing a
        // main-queue block. A queued main-queue completion cannot be awaited from it.
        if (!arrived) return unknown(@"scopedCaptureTimedOut");
        if (!CGPreflightScreenCaptureAccess() || !CGDisplayIsActive(displayID) || CGDisplayIsInMirrorSet(displayID) ||
            !CGRectEqualToRect(screen,CGDisplayBounds(displayID)) || ![stillWallpaperWindow(screen) isEqual:owner] ||
            !sceneListed(panel,getpid(),area)) return unknown(@"sourceChanged");
        for (NSUInteger i=0; i<count; i++)
            if (!sceneSubject(targets[i],kit) || !sceneListed(targets[i].number,targets[i].pid,targets[i].frame))
                return unknown(@"registeredSurfaceChanged");
        return measurement;
    }
    return unknown(@"screenCaptureKitVersionUnavailable");
}
