#import "NativeSpaceActions.h"
#import "event_serialize.h"
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <mach/mach_time.h>

// See Resources/Upstream/NativeSpaceActions for pins and licenses.
static CGEventRef swipeEvent(int phase, double progress, double velocity, CGPoint point) {
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGEventSetLocation(e, point);
    // The Dock gesture ABI carries its Mach timestamp in field 169.
    CGEventSetDoubleValueField(e, (CGEventField)169, (double)mach_absolute_time());
    CGEventSetIntegerValueField(e, (CGEventField)55, 30); // Dock control
    CGEventSetIntegerValueField(e, (CGEventField)110, 23); // Dock swipe
    CGEventSetIntegerValueField(e, (CGEventField)123, 1); // horizontal
    CGEventSetDoubleValueField(e, (CGEventField)124, progress);
    CGEventSetDoubleValueField(e, (CGEventField)125, 0.1);
    CGEventSetDoubleValueField(e, (CGEventField)129, velocity);
    CGEventSetIntegerValueField(e, (CGEventField)132, phase);
    CGEventSetIntegerValueField(e, (CGEventField)134, phase);
    CGEventSetDoubleValueField(e, (CGEventField)138, 3.0);
    CGEventRef result = iss_augment_dock_swipe_event(e);
    CFRelease(e);
    return result;
}

bool NPSendAdjacentSwipe(bool right, bool reducedMotion, CGDirectDisplayID intendedDisplay) {
    if (!CGPreflightPostEventAccess()) return false;
    CGEventRef source = CGEventCreate(NULL);
    if (!source) return false;
    CGPoint point = CGEventGetLocation(source);
    CFRelease(source);
    uint32_t count = 0;
    CGDirectDisplayID display = 0;
    if (CGGetDisplaysWithPoint(point, 1, &display, &count) != kCGErrorSuccess ||
        count != 1 || display != intendedDisplay || CGDisplayIsInMirrorSet(display)) return false;

    Boolean valid = false;
    Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                     kCFPreferencesAnyApplication, &valid);
    double sign = right ? -1.0 : 1.0;
    if (valid && !natural) sign = -sign;
    // The compositor owns the transition. Reduced motion uses ISS's short fling.
    const double smooth[] = {0.000016, 0.12, 0.31, 0.56, 0.74, 0.82};
    int length = reducedMotion ? 3 : 6;
    CGEventRef gestures[6] = {0}, companions[6] = {0};
    bool posted = false;
    for (int i = 0; i < length; i++) {
        int phase = i == 0 ? 1 : (i == length - 1 ? 4 : 2);
        double progress = reducedMotion ? 0.000016 : smooth[i];
        double velocity = phase == 4 ? (reducedMotion ? 9999.0 : 2.0) : 0;
        gestures[i] = swipeEvent(phase, sign * progress, sign * velocity, point);
        companions[i] = CGEventCreate(NULL);
        if (!gestures[i] || !companions[i]) goto cleanup;
        CGEventSetLocation(companions[i], point);
        CGEventSetIntegerValueField(companions[i], (CGEventField)55, 29);
    }
    for (int i = 0; i < length; i++) {
        if (i > 0 && !reducedMotion) usleep(16000);
        CGEventSetTimestamp(gestures[i], mach_absolute_time());
        CGEventSetTimestamp(companions[i], mach_absolute_time());
        CGEventPost(kCGSessionEventTap, gestures[i]);
        CGEventPost(kCGSessionEventTap, companions[i]);
    }
    posted = true;
cleanup:
    for (int i = 0; i < length; i++) {
        if (gestures[i]) CFRelease(gestures[i]);
        if (companions[i]) CFRelease(companions[i]);
    }
    return posted;
}

// macOS 27 branch of yabai's space_manager_move_window_to_space. The
// asynchronous submission has no completion result; the caller must read
// window membership back from WindowServer. Other branches are not linked.
typedef int64_t (*PerformMove)(void *);
static PerformMove performMove;
static Class moveClass;
bool NPMoveAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                             RTLD_LOCAL | RTLD_LAZY);
        if (!image) return;
        performMove = (PerformMove)dlsym(image, "SLSPerformAsynchronousBridgedWindowManagementOperation");
        moveClass = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    });
    return performMove && moveClass && [moveClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)];
}

bool NPRequestMove(uint32_t window, uint64_t space) {
    if (!window || !space || !NPMoveAvailable() || !AXIsProcessTrusted()) return false;
    SEL initializer = @selector(initWithWindows:spaceID:);
    id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([moveClass alloc], initializer,
                                                                @[@(window)], space);
    if (!operation) return false;
    (void)performMove((__bridge void *)operation);
#if !__has_feature(objc_arc)
    [operation release];
#endif
    return true;
}
