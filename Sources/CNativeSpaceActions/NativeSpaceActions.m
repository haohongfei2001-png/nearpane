#import "NativeSpaceActions.h"
#import "PreparedWindowMove.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@protocol NPBridgedMoveInitializer
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)space;
@end

static Method validatedMethod(Class cls, SEL selector, const char *encoding) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && strcmp(actual, encoding) == 0 ? method : NULL;
}

NPBridgedMoveABI NPInspectMoveClass(Class cls) {
    return (NPBridgedMoveABI){
        .hasClass = cls != Nil,
        .initializerMatches = validatedMethod(cls, @selector(initWithWindows:spaceID:), "@32@0:8@16Q24") != NULL,
        .submissionMatches = validatedMethod(cls, NSSelectorFromString(@"performWithWMBridgeDelegate"), "v16@0:8") != NULL,
    };
}

NPBridgedMoveABI NPInstalledMoveABI(void) {
    static Class operationClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY)) {
            operationClass = objc_lookUpClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        }
    });
    return NPInspectMoveClass(operationClass);
}

@implementation NPPreparedWindowMove {
    id _operation;
    NSArray<NSNumber *> *_windows;
    BOOL _submitted;
}

- (instancetype)initWithClass:(Class)cls window:(uint32_t)window space:(uint64_t)space {
    self = [super init];
    if (!self) return nil;
    NPBridgedMoveABI abi = NPInspectMoveClass(cls);
    if (window && space && abi.initializerMatches && abi.submissionMatches) {
        _windows = [[NSArray alloc] initWithObjects:@(window), nil];
        _operation = [(id<NPBridgedMoveInitializer>)[cls alloc] initWithWindows:_windows spaceID:space];
        if (_operation && object_getClass(_operation) == cls) return self;
    }
#if !__has_feature(objc_arc)
    [self release];
#endif
    return nil;
}

- (BOOL)submitOnce {
    @synchronized (self) {
        SEL selector = NSSelectorFromString(@"performWithWMBridgeDelegate");
        Method method = validatedMethod(object_getClass(_operation), selector, "v16@0:8");
        if (_submitted || !method) return NO;
        _submitted = YES;
        ((void (*)(id, SEL))method_getImplementation(method))(_operation, selector);
        // The method returns void. Delivery alone cannot confirm window membership.
        return YES;
    }
}

#if !__has_feature(objc_arc)
- (void)dealloc {
    [_operation release];
    [_windows release];
    [super dealloc];
}
#endif
@end

bool NPMoveAvailable(void) {
    // No build has qualified the P0 and P1 installed round-trip gates.
    return false;
}

bool NPRequestMove(uint32_t window, uint64_t space) {
    // Prepare the backend in isolation, without enrolling a system window.
    return false;
}
