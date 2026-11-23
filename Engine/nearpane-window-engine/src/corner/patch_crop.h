#pragma once
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "macos.h"

typedef NS_ENUM(NSUInteger, NCWallpaperScale) { NCWallpaperStretch, NCWallpaperFill, NCWallpaperFit };
typedef struct { CGSize pixels; NCWallpaperScale scale; } NCWallpaperGeometry;

// NSWorkspace defaults to proportional scaling without clipping. The fill color outside the image
// is system-defined. A crop touching that area needs a separate witness of the actual material.
static BOOL wallpaperCropArea(NCWallpaperGeometry g, NCFrame display, NCFrame frame, CGRect *area) {
    CGRect requested = CGRectMake(frame.x, frame.y, frame.w, frame.h);
    CGRect screen = CGRectMake(display.x, display.y, display.w, display.h);
    if (g.pixels.width <= 0 || g.pixels.height <= 0 || CGRectIsEmpty(requested) ||
        CGRectIsEmpty(screen) || !CGRectContainsRect(screen, requested)) return NO;
    double sx = display.w / g.pixels.width, sy = display.h / g.pixels.height;
    if (g.scale == NCWallpaperFill) sx = sy = MAX(sx, sy);
    if (g.scale == NCWallpaperFit) sx = sy = MIN(sx, sy);
    CGRect pixels = CGRectMake(0, 0, g.pixels.width, g.pixels.height);
    CGRect mapped = CGRectMake((frame.x - display.x - (display.w - g.pixels.width * sx) / 2) / sx,
                               (frame.y - display.y - (display.h - g.pixels.height * sy) / 2) / sy,
                               frame.w / sx, frame.h / sy);
    if (!CGRectContainsRect(pixels, mapped)) return NO;
    *area = CGRectIntegral(mapped);
    return CGRectContainsRect(pixels, *area);
}

// Preflight and rendering must agree on the same source. ImageIO metadata does not decode any pixels.
static CGImageSourceRef drawableWallpaper(NSURL *url, NSDictionary *options, NCWallpaperGeometry *geometry) CF_RETURNS_RETAINED;
static CGImageSourceRef drawableWallpaper(NSURL *url, NSDictionary *options, NCWallpaperGeometry *geometry) {
    if (!url || !options) return NULL;
    id scaling = options[NSWorkspaceDesktopImageScalingKey], clip = options[NSWorkspaceDesktopImageAllowClippingKey];
    NCWallpaperScale mode;
    if ([scaling isEqual:@(NSImageScaleAxesIndependently)]) mode = NCWallpaperStretch;
    else if ((!scaling || [scaling isEqual:@(NSImageScaleProportionallyUpOrDown)]) &&
             (!clip || [clip isEqual:@NO] || [clip isEqual:@YES])) mode = [clip boolValue] ? NCWallpaperFill : NCWallpaperFit;
    else return NULL;
    NSDictionary *metadataOnly = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)metadataOnly);
    if (!source) return NULL;
    NSDictionary *meta = nil;
    if (CGImageSourceGetCount(source) == 1)
        meta = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)metadataOnly));
    double width = [meta[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [meta[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    NSNumber *orientation = meta[(__bridge NSString *)kCGImagePropertyOrientation];
    if (width > 0 && height > 0 && width * height <= 42000000 && (!orientation || [orientation isEqual:@1])) {
        *geometry = (NCWallpaperGeometry){CGSizeMake(width, height), mode};
        return source;
    }
    CFRelease(source);
    return NULL;
}

static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display,
                                NCFrame frame) CF_RETURNS_RETAINED;
static CGImageRef cropWallpaper(NSURL *url, NSDictionary *options, NCFrame display, NCFrame frame) {
    NCWallpaperGeometry geometry = {};
    CGImageSourceRef source = drawableWallpaper(url, options, &geometry);
    if (!source) return NULL;
    CGImageRef crop = NULL, image = NULL;
    @try {
        CGRect area;
        if (!wallpaperCropArea(geometry, display, frame, &area)) return NULL;
        NSDictionary *decode = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES};
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)decode);
        if (image && CGImageGetWidth(image) == geometry.pixels.width && CGImageGetHeight(image) == geometry.pixels.height)
            crop = CGImageCreateWithImageInRect(image, area);
    } @finally {
        if (image)
            CGImageRelease(image);
        CFRelease(source);
    }
    return crop;
}

