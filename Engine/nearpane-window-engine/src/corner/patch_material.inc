// Display-filtered corner still adapted from stage-manager's platform/capture.rs (see origins/corner.json).
// All window identity and pixels stay inside the process holding the screen-recording grant.
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Security/Security.h>
#import "scope_binding.h"
#import "../../include/nearpane_host_scope.h"

static BOOL stillOrdinaryHome(const NCMember *home) {
    if (!home || !home->native) return NO;
    NSUUID *physical = [[NSUUID alloc] initWithUUIDBytes:home->display];
    NSUUID *space = [[NSUUID alloc] initWithUUIDBytes:home->space];
    int32_t connection = 0, error = 0;
    NSArray *rows = CFBridgingRelease(np_host_scope_copy_managed(&connection, &error));
    if (error || !rows.count) return NO;
    NSUInteger matches = 0;
    for (NSDictionary *row in rows) {
        NSString *token = row[@"Display Identifier"];
        BOOL alias = [token isEqual:@"Main"] && [nc_single_main_uuid(rows.count) isEqual:physical];
        if (!alias && ![nc_uuid(token) isEqual:physical]) continue;
        uint64_t direct = np_host_scope_direct(connection, (__bridge CFStringRef)token, &error);
        NSDictionary *scope = nc_bound_scope(row, physical.UUIDString, alias, direct, nil);
        if (error || direct != home->native || ![scope[@"native"] isEqual:@(home->native)] ||
            ![nc_uuid(scope[@"space"]) isEqual:space]) return NO;
        matches++;
    }
    return matches == 1;
}

// Only a single Apple-signed wallpaper-agent surface exactly covering this physical screen qualifies.
static NSArray *stillWallpaperWindow(CGRect frame) {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.wallpaper.agent"];
    if (apps.count != 1) return nil;
    pid_t pid = apps.firstObject.processIdentifier;
    struct proc_bsdinfo bsd = {};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd) ||
        bsd.pbi_pid != (uint32_t)pid || bsd.pbi_uid != getuid()) return nil;
    static SecRequirementRef rule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.wallpaper.agent\""), 0, &rule); });
    SecCodeRef code = NULL;
    if (!rule || SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge id)kSecGuestAttributePid:@(pid)}, 0, &code) || !code) return nil;
    OSStatus signedApple = SecCodeCheckValidity(code, 0, rule);
    CFRelease(code);
    if (signedApple != errSecSuccess) return nil;
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSNumber *found = nil;
    for (NSDictionary *row in rows) {
        CGRect bounds;
        if (![row[(id)kCGWindowOwnerPID] isEqual:@(pid)] || !row[(id)kCGWindowLayer] ||
            [row[(id)kCGWindowLayer] intValue] > CGWindowLevelForKey(kCGDesktopWindowLevelKey) ||
            ![row[(id)kCGWindowIsOnscreen] boolValue] || ![row[(id)kCGWindowAlpha] isEqual:@1] ||
            ![row[(id)kCGWindowBounds] isKindOfClass:NSDictionary.class] ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds], &bounds) ||
            !CGRectEqualToRect(bounds, frame)) continue;
        NSNumber *window = row[(id)kCGWindowNumber];
        if (found || !window.unsignedIntValue) return nil;
        found = window;
    }
    return found ? @[ @(pid), @(bsd.pbi_start_tvsec * 1000000ULL + bsd.pbi_start_tvusec), found ] : nil;
}

// The positive window list and exact display-relative source rectangle exclude unrelated pixels.
static void captureCornerSurface(SCDisplay *screenSource, SCWindow *window, CGRect region,
                                 void (^completion)(CGImageRef, CGFloat)) API_AVAILABLE(macos(14.2));
static void captureCornerSurface(SCDisplay *screenSource, SCWindow *window, CGRect region,
                                 void (^completion)(CGImageRef, CGFloat)) {
    CGRect frame = screenSource.frame;
    if (!screenSource || !window || !CGRectContainsRect(frame, region) || CGRectIsEmpty(region)) {
        completion(NULL, 0); return;
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:screenSource includingWindows:@[window]];
    filter.includeMenuBar = NO;
    CGFloat scale = filter.pointPixelScale;
    CGFloat width = region.size.width * scale, height = region.size.height * scale;
    if (!(scale >= 1 && scale <= 4 && width == floor(width) && height == floor(height) && width * height <= 1048576)) {
        completion(NULL, 0); return;
    }
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.sourceRect = CGRectOffset(region, -frame.origin.x, -frame.origin.y);
    config.width = (size_t)width; config.height = (size_t)height;
    config.destinationRect = CGRectMake(0, 0, width, height);
    config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    config.showsCursor = NO; config.preservesAspectRatio = NO; config.scalesToFit = YES;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError *issue) {
        completion(!issue && stillIsOpaque(image, config.width, config.height) ? image : NULL, scale);
    }];
}

// Instance ownership belongs to a single NCPatchSession. Accessed on the AppKit main queue.
@interface NCCornerStill : NSObject
@property(nonatomic) NCMember home;
@property(nonatomic) CGDirectDisplayID display;
@property(nonatomic) CGRect displayFrame, region;
@property(nonatomic, strong) NSArray *wallpaper;
@property(nonatomic, strong) id pixels;
@property(nonatomic) CGFloat scale;
@property(nonatomic) NSTimeInterval started, sampled;
@property(nonatomic) BOOL pending;
@end

@implementation NCCornerStill
- (BOOL)sourceCurrent:(NSScreen *)screen home:(const NCMember *)home {
    return home->native == _home.native && !memcmp(home->space, _home.space, 16) && !memcmp(home->display, _home.display, 16) &&
        CGPreflightScreenCaptureAccess() && [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == _display &&
        CGDisplayIsActive(_display) && !CGDisplayIsInMirrorSet(_display) && CGRectEqualToRect(CGDisplayBounds(_display), _displayFrame) &&
        stillOrdinaryHome(home);
}
- (BOOL)readyFor:(CGRect)rect {
    return _pixels && NSProcessInfo.processInfo.systemUptime - _sampled < 10 && CGRectContainsRect(_region, rect);
}
- (void)refresh:(NSScreen *)screen completion:(void (^)(BOOL))completion API_AVAILABLE(macos(14.2)) {
    if (_pending || ![self sourceCurrent:screen home:&_home]) { completion(NO); return; }
    NSArray *owner = stillWallpaperWindow(_displayFrame);
    if (!owner || (_wallpaper && ![_wallpaper isEqual:owner])) { _pixels = nil; completion(NO); return; }
    _wallpaper = owner;
    _pending = YES;
    _started = NSProcessInfo.processInfo.systemUptime;
    CGRect frame = _displayFrame, region = _region;
    CGDirectDisplayID displayID = _display;
    id previous = _pixels;
    CGFloat previousScale = _scale;
    void (^finish)(id, CGFloat) = ^(id image, CGFloat scale) {
        // Repainting an identical surface would discard the independent WindowServer
        // proof shared by already parked group members. Compare native pixels off-main.
        BOOL unchanged = image && previous && previousScale == scale &&
            cornerPixelsMatch((__bridge CGImageRef)previous, (__bridge CGImageRef)image);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL valid = image && NSProcessInfo.processInfo.systemUptime - self.started < 3 &&
                [self sourceCurrent:screen home:&self->_home] && [stillWallpaperWindow(frame) isEqual:owner];
            self.pending = NO;
            self.pixels = valid ? (unchanged && self.pixels == previous ? previous : image) : nil;
            if (valid) {
                self.scale = scale;
                NSTimeInterval sampled = NSProcessInfo.processInfo.systemUptime;
                self.sampled = sampled;
                __weak NCCornerStill *weak = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    NCCornerStill *still = weak;
                    if (still && still.sampled == sampled) still.pixels = nil;
                });
            }
            completion(valid);
        });
    };
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
        SCDisplay *screenSource = nil;
        SCWindow *window = nil;
        if (!error) {
            for (SCDisplay *d in content.displays) if (d.displayID == displayID && CGRectEqualToRect(d.frame, frame)) screenSource = d;
            for (SCWindow *w in content.windows) if (w.windowID == [owner[2] unsignedIntValue] && w.owningApplication.processID == [owner[0] intValue] &&
                    CGRectEqualToRect(w.frame, frame)) window = w;
        }
        if (!screenSource || !window) { finish(nil, 0); return; }
        captureCornerSurface(screenSource, window, region, ^(CGImageRef image, CGFloat scale) {
            finish((__bridge id)image, scale);
        });
    }];
}
- (CGImageRef)copyCrop:(CGRect)rect CF_RETURNS_RETAINED {
    if (![self readyFor:rect]) return NULL;
    CGRect px = CGRectApplyAffineTransform(CGRectOffset(rect, -_region.origin.x, -_region.origin.y), CGAffineTransformMakeScale(_scale, _scale));
    if (!CGRectEqualToRect(px, CGRectIntegral(px))) return NULL;
    return CGImageCreateWithImageInRect((__bridge CGImageRef)_pixels, px);
}
@end
