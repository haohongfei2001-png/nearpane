// Hermetic: decode our own PNG and inspect in-memory Quartz events. Never create a panel, tap or HID post.
#import "patch_crop.h"
#define NP_CORNER_WITNESS_IMPL 1
#import "gesture_witness.h"
#include <assert.h>
static void input(void) {
    const uint64_t nonce = 1337, stale = 7331;
    NCGestureRead read = {};
    assert(np_corner_witness_begin(nonce) && !np_corner_witness_begin(stale));
    assert(!np_corner_witness_end(stale, &read));
    CGEventType phases[] = {kCGEventLeftMouseDown, kCGEventLeftMouseDragged, kCGEventLeftMouseUp};
    for (uint32_t i = 0; i < 3; i++) {
        for (unsigned sample = 0; sample < 3; sample++) {
            CGEventRef ev = CGEventCreateMouseEvent(NULL, phases[i], CGPointMake(9 + i, 13), kCGMouseButtonLeft);
            assert(ev);
            CGEventSetIntegerValueField(ev, kCGEventSourceUserData, sample == 0 ? stale : nonce);
            CGEventSetIntegerValueField(ev, kCGEventSourceUnixProcessID, sample == 1 ? getpid()+1 : getpid());
            recordGesture(phases[i], ev, sample == 2);
            CFRelease(ev);
        }
    }
    assert(np_corner_witness_end(nonce, &read) && read.count == 3);
    for (unsigned i = 0; i < 3; i++)
        assert(read.phases[i].type == phases[i] && read.phases[i].dropped && read.phases[i].point.x == 9 + i);
    assert(!np_corner_witness_end(nonce, &read));
}
static void pixels(NSString *path) {
    uint8_t rgba[4 * 8 * 4];
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 8; x++) {
            uint8_t *pixel = &rgba[(y * 8 + x) * 4];
            pixel[0] = x * 23;
            pixel[1] = y * 47;
            pixel[2] = 37;
            pixel[3] = 255;
        }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba, 8, 4, 8, 32, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef out =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    assert(out);
    CGImageDestinationAddImage(out, image, NULL);
    assert(CGImageDestinationFinalize(out));
    CFRelease(out);
    NCFrame display = {-8, 20, 8, 4};
    NSDictionary *stretch = @{NSWorkspaceDesktopImageScalingKey : @(NSImageScaleAxesIndependently)};
    CGImageRef crop = cropWallpaper(url, stretch, display, (NCFrame){-2, 22, 1, 1});
    assert(crop && CGImageGetWidth(crop) == 1 && CGImageGetHeight(crop) == 1);
    uint8_t actual[4] = {};
    CGContextRef check = CGBitmapContextCreate(actual, 1, 1, 8, 4, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(check, CGRectMake(0, 0, 1, 1), crop);
    assert(!memcmp(actual, &rgba[(2 * 8 + 6) * 4], 4));
    assert(!cropWallpaper(url, stretch, display, (NCFrame){7, 21, 1, 1}));
    assert(!cropWallpaper(url, @{}, display, (NCFrame){-2, 22, 1, 1}));
    BOOL fill = NO;
    CGImageSourceRef admitted = drawableWallpaper(url, stretch, &fill);
    assert(admitted && !fill);
    CFRelease(admitted);
    assert(!drawableWallpaper(url, @{}, &fill));
    NSURL *animated = [url URLByAppendingPathExtension:@"gif"];
    CGImageDestinationRef multi = CGImageDestinationCreateWithURL((__bridge CFURLRef)animated,
                                                                 CFSTR("com.compuserve.gif"), 2, NULL);
    assert(multi);
    CGImageDestinationAddImage(multi, image, NULL);
    CGImageDestinationAddImage(multi, image, NULL);
    assert(CGImageDestinationFinalize(multi));
    CFRelease(multi);
    assert(!drawableWallpaper(animated, stretch, &fill));
    assert(!cropWallpaper(animated, stretch, display, (NCFrame){-2,22,1,1}));
    assert([[NSFileManager defaultManager] removeItemAtURL:animated error:NULL]);
    CGImageRelease(crop);
    CGImageRelease(image);
    CGContextRelease(check);
    CGContextRelease(context);
    CGColorSpaceRelease(srgb);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        input();
        pixels(@(argv[1]));
        puts("{\"scope\":\"offscreenOwnPNGAndUnpostedQuartzEvents\",\"status\":\"PASS\",\"systemInputPosted\":"
             "0,\"windowsOrdered\":0}");
    }
}
