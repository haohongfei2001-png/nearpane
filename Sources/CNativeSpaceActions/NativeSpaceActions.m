#import "NativeSpaceActions.h"
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
