#pragma once
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "macos.h"

// Preflight and rendering must agree on the same source. ImageIO metadata does not decode any pixels.
static CGImageSourceRef drawableWallpaper(NSURL *url, NSDictionary *options, BOOL *fill) CF_RETURNS_RETAINED;
static CGImageSourceRef drawableWallpaper(NSURL *url, NSDictionary *options, BOOL *fill) {
    *fill = [options[NSWorkspaceDesktopImageScalingKey] isEqual:@(NSImageScaleProportionallyUpOrDown)] &&
            [options[NSWorkspaceDesktopImageAllowClippingKey] isEqual:@YES];
    if (!url || (!*fill && ![options[NSWorkspaceDesktopImageScalingKey] isEqual:@(NSImageScaleAxesIndependently)]))
        return NULL;
    NSDictionary *metadataOnly = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)metadataOnly);
    if (!source) return NULL;
    NSDictionary *meta = nil;
    if (CGImageSourceGetCount(source) == 1)
        meta = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)metadataOnly));
    double width = [meta[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [meta[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    NSNumber *orientation = meta[(__bridge NSString *)kCGImagePropertyOrientation];
    if (width > 0 && height > 0 && width * height <= 42000000 && (!orientation || [orientation isEqual:@1]))
        return source;
    CFRelease(source);
    return NULL;
}

static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display,
                                NCFrame frame) CF_RETURNS_RETAINED;
static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display, NCFrame frame) {
    BOOL fill = NO;
    CGImageSourceRef source = drawableWallpaper(url, options, &fill);
    if (!source) return NULL;
    CGImageRef crop = NULL, image = NULL;
    @try {
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

