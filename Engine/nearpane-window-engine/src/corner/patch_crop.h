#pragma once
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "macos.h"

static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display,
                                NCFrame frame) CF_RETURNS_RETAINED;
static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display, NCFrame frame) {
    BOOL stretch = [options[NSWorkspaceDesktopImageScalingKey] isEqual:@(NSImageScaleAxesIndependently)];
    BOOL fill = [options[NSWorkspaceDesktopImageScalingKey] isEqual:@(NSImageScaleProportionallyUpOrDown)] &&
                [options[NSWorkspaceDesktopImageAllowClippingKey] isEqual:@YES];
    if (!stretch && !fill)
        return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source)
        return NULL;
    CGImageRef crop = NULL, image = NULL;
    @try {
        if (CGImageSourceGetCount(source) != 1)
            return NULL;
        NSDictionary *meta = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSNumber *w = meta[(__bridge NSString *)kCGImagePropertyPixelWidth],
                 *h = meta[(__bridge NSString *)kCGImagePropertyPixelHeight],
                 *orientation = meta[(__bridge NSString *)kCGImagePropertyOrientation];
        if (!w || !h || !w.unsignedLongLongValue || !h.unsignedLongLongValue ||
            w.doubleValue * h.doubleValue > 42000000 || (orientation && ![orientation isEqual:@1]))
            return NULL;
        NSDictionary *decode = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES};
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)decode);
        if (!image)
            return NULL;
        double iw = CGImageGetWidth(image), ih = CGImageGetHeight(image), sx = display.w / iw,
               sy = display.h / ih;
        if (fill)
            sx = sy = MAX(sx, sy);
        CGRect area =
            CGRectMake((frame.x - display.x - (display.w - iw * sx) / 2) / sx,
                       (frame.y - display.y - (display.h - ih * sy) / 2) / sy, frame.w / sx, frame.h / sy);
        if (CGRectContainsRect(CGRectMake(0, 0, iw, ih), area))
            crop = CGImageCreateWithImageInRect(image, CGRectIntegral(area));
    } @finally {
        if (image)
            CGImageRelease(image);
        CFRelease(source);
    }
    return crop;
}

