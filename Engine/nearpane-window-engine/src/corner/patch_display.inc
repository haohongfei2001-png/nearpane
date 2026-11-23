// Only the local click-through panel and the Apple-signed wallpaper surface may be sampled.
// A comparison returns a verdict to the owner; the pixels never leave the capturing process.
static NSScreen *cornerScreen(const NCMember *home) {
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID d = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(d);
        if (!uuid) continue;
        CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
        CFRelease(uuid);
        if (!memcmp(&bytes, home->display, 16) && CGDisplayIsActive(d) && !CGDisplayIsInMirrorSet(d))
            return screen;
    }
    return nil;
}

static NSRect cornerPanelFrame(NSScreen *screen, CGRect display, CGRect area) {
    return NSMakeRect(NSMinX(screen.frame) + area.origin.x - display.origin.x,
                      NSMaxY(screen.frame) - (area.origin.y - display.origin.y) - area.size.height,
                      area.size.width, area.size.height);
}

NSPanel *np_corner_material_panel(void *material, const NCMember *home, NCFrame footprint) {
    if (!material || !home || !NSThread.isMainThread) return nil;
    NSScreen *screen = cornerScreen(home);
    NSData *key = [NSData dataWithBytes:home->display length:16];
    NSDictionary *store = (__bridge NSDictionary *)material;
    NCCornerStill *still = store[key];
    CGRect area = patchRect(footprint);
    if (!screen || ![still sourceCurrent:screen home:home] || ![still readyFor:area] ||
        ![stillWallpaperWindow(still.displayFrame) isEqual:still.wallpaper]) return nil;
    CGImageRef crop = [still copyCrop:area];
    if (!crop) return nil;
    NCWallpaperPanel *panel = patchPanel(cornerPanelFrame(screen, still.displayFrame, area), crop);
    CGImageRelease(crop);
    return panel;
}

void np_corner_compare_panel(NSPanel *panel, NCMember home, NCFrame footprint,
                             void (^completion)(NCCornerPicture)) {
    if (!completion) return;
    if (!NSThread.isMainThread || ![panel isMemberOfClass:NCWallpaperPanel.class] || !CGPreflightScreenCaptureAccess()) {
        completion(NCCornerPictureUnavailable); return;
    }
    if (@available(macOS 14.2, *)) {
        NSScreen *screen = cornerScreen(&home);
        CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGRect frame = CGDisplayBounds(display), area = patchRect(footprint);
        NSInteger number = panel.windowNumber;
        if (!screen || number <= 0 || number > UINT32_MAX || CGRectIsEmpty(area) ||
            !CGRectEqualToRect(area, CGRectIntegral(area)) || !CGRectContainsRect(frame, area) ||
            area.size.width > 128 || area.size.width * area.size.height > 1048576 ||
            (CGRectGetMinX(area) != CGRectGetMinX(frame) && CGRectGetMaxX(area) != CGRectGetMaxX(frame))) {
            completion(NCCornerPictureUnavailable); return;
        }
        NSArray *owner = stillWallpaperWindow(frame);
        NSRect panelFrame = cornerPanelFrame(screen, frame, area);
        BOOL (^valid)(void) = ^BOOL {
            return owner && panel.windowNumber == number && panel.visible && panel.onActiveSpace &&
                !panel.keyWindow && !panel.mainWindow && panel.ignoresMouseEvents &&
                NSEqualRects(panel.frame, panelFrame) && CGPreflightScreenCaptureAccess() &&
                CGDisplayIsActive(display) && !CGDisplayIsInMirrorSet(display) &&
                CGRectEqualToRect(CGDisplayBounds(display), frame) && stillOrdinaryHome(&home) &&
                [stillWallpaperWindow(frame) isEqual:owner];
        };
        if (!valid()) { completion(NCCornerPictureUnavailable); return; }
        NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
        void (^finish)(NCCornerPicture) = ^(NCCornerPicture result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL fresh = NSProcessInfo.processInfo.systemUptime - began < 1.5;
                completion(fresh && valid() ? result : NCCornerPictureUnavailable);
            });
        };
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
            completionHandler:^(SCShareableContent *content, NSError *error) {
            SCWindow *sheet = nil, *wallpaper = nil;
            SCDisplay *surface = nil;
            for (SCDisplay *d in content.displays)
                if (d.displayID == display && CGRectEqualToRect(d.frame, frame)) surface = d;
            for (SCWindow *w in content.windows) {
                if (w.windowID == (CGWindowID)number && w.owningApplication.processID == getpid() &&
                    CGRectEqualToRect(w.frame, area)) sheet = w;
                if (w.windowID == [owner[2] unsignedIntValue] && w.owningApplication.processID == [owner[0] intValue] &&
                    CGRectEqualToRect(w.frame, frame)) wallpaper = w;
            }
            if (error || !surface || !sheet || !wallpaper) { finish(NCCornerPictureUnavailable); return; }
            // Both samples describe the same instant as closely as the compositor permits.
            // Each completion writes its own slot; the dispatch group orders the final read.
            dispatch_group_t frames = dispatch_group_create();
            __block id reference = nil, drawn = nil;
            __block CGFloat referenceScale = 0, drawnScale = 0;
            dispatch_group_enter(frames);
            captureCornerSurface(surface, wallpaper, area, ^(CGImageRef image, CGFloat scale) {
                reference = (__bridge id)image;
                referenceScale = scale;
                dispatch_group_leave(frames);
            });
            dispatch_group_enter(frames);
            captureCornerSurface(surface, sheet, area, ^(CGImageRef image, CGFloat scale) {
                drawn = (__bridge id)image;
                drawnScale = scale;
                dispatch_group_leave(frames);
            });
            dispatch_group_notify(frames, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (!reference || !drawn || referenceScale != drawnScale) { finish(NCCornerPictureUnavailable); return; }
                finish(cornerPixelsMatch((__bridge CGImageRef)reference, (__bridge CGImageRef)drawn) ?
                    NCCornerPictureMatch : NCCornerPictureDifferent);
            });
        }];
        return;
    }
    completion(NCCornerPictureUnavailable);
}
