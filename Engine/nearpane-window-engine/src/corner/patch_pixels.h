#pragma once
#import <AppKit/AppKit.h>

static inline NSData *cornerRGBA(CGImageRef image, size_t w, size_t h) {
    if (!image || !w || !h || w > 32768 || h > 32768 || w * h > 1048576 ||
        CGImageGetWidth(image) != w || CGImageGetHeight(image) != h) return nil;
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!color) return nil;
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, color,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (!context) return nil;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    return pixels;
}

// No resampling, flipping, alpha blending or partial matches. One sRGB code
// value is the rounding allowance when the compositor converts a color space.
static inline BOOL cornerPixelsMatch(CGImageRef expected, CGImageRef observed) {
    if (!expected || !observed) return NO;
    size_t w = CGImageGetWidth(expected), h = CGImageGetHeight(expected);
    NSData *left = cornerRGBA(expected, w, h), *right = cornerRGBA(observed, w, h);
    if (!left || !right) return NO;
    const uint8_t *a = left.bytes, *b = right.bytes;
    for (size_t i = 0; i < left.length; i += 4) {
        if (a[i + 3] != 255 || b[i + 3] != 255) return NO;
        for (size_t c = 0; c < 3; c++) if (abs(a[i + c] - b[i + c]) > 1) return NO;
    }
    return YES;
}

static inline BOOL stillIsOpaque(CGImageRef image, size_t w, size_t h) {
    if (!image || !w || !h || w > 32768 || h > 32768 || w * h > 1048576 ||
        CGImageGetWidth(image) != w || CGImageGetHeight(image) != h) return NO;
    NSMutableData *alpha = [NSMutableData dataWithLength:w * h];
    CGContextRef context = CGBitmapContextCreate(alpha.mutableBytes, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) return NO;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    const uint8_t *pixels = alpha.bytes;
    for (size_t i = 0; i < alpha.length; i++) if (pixels[i] != 255) return NO;
    return YES;
}
