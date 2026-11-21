#import "NativeSpaceActions.h"
#import "PreparedWindowMove.h"
#import <ApplicationServices/ApplicationServices.h>
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

static Class installedMoveClass(void) {
    static Class operationClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY)) {
            operationClass = objc_lookUpClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        }
    });
    return operationClass;
}

NPBridgedMoveABI NPInstalledMoveABI(void) {
    return NPInspectMoveClass(installedMoveClass());
}

bool NPMoveAvailable(void) {
    // No build has qualified both the P0 switch and P1 single-window round trips.
    return false;
}

static BOOL contextAllowed(Class cls) {
#if defined(NP_MOVE_ABI_FIXTURE)
    // The offline executable owns the mock class and both implementations. Reject an
    // installed system class (including a subclass) even in the fixture build.
    if (!cls) return NO;
    Class systemClass = installedMoveClass();
    for (Class parent = cls; parent; parent = class_getSuperclass(parent)) {
        if (parent == systemClass) return NO;
    }
    Dl_info owner, fixture, initializer, submission;
    Method init = validatedMethod(cls, @selector(initWithWindows:spaceID:), "@32@0:8@16Q24");
    Method perform = validatedMethod(cls, NSSelectorFromString(@"performWithWMBridgeDelegate"), "v16@0:8");
    return init && perform && dladdr((__bridge const void *)cls, &owner) &&
           dladdr((const void *)&NPInspectMoveClass, &fixture) && owner.dli_fbase == fixture.dli_fbase &&
           dladdr((const void *)method_getImplementation(init), &initializer) && initializer.dli_fbase == fixture.dli_fbase &&
           dladdr((const void *)method_getImplementation(perform), &submission) && submission.dli_fbase == fixture.dli_fbase;
#else
    return NPMoveAvailable() && cls && cls == installedMoveClass();
#endif
}

#if defined(NP_MOVE_ABI_FIXTURE)
static NPMoveFixtureCounts calls;
NPMoveFixtureCounts NPMoveObservedCalls(void) { return calls; }
#endif

@implementation NPPreparedWindowMove {
    id _operation;
    NSArray<NSNumber *> *_windows;
    BOOL _submitted;
}

- (instancetype)initWithClass:(Class)cls window:(uint32_t)window space:(uint64_t)space {
    self = [super init];
    if (!self) return nil;
    NPBridgedMoveABI abi = NPInspectMoveClass(cls);
    if (window && space && contextAllowed(cls) && abi.initializerMatches && abi.submissionMatches) {
        _windows = [[NSArray alloc] initWithObjects:@(window), nil];
#if defined(NP_MOVE_ABI_FIXTURE)
        if (cls == installedMoveClass()) calls.systemAllocations++;
#endif
        _operation = [(id<NPBridgedMoveInitializer>)[cls alloc] initWithWindows:_windows spaceID:space];
        if (_operation && object_getClass(_operation) == cls) return self;
    }
#if !__has_feature(objc_arc)
    [self release];
#endif
    return nil;
}

- (NPWindowMoveSubmission)submitOnce {
    @synchronized (self) {
        SEL selector = NSSelectorFromString(@"performWithWMBridgeDelegate");
        Method method = validatedMethod(object_getClass(_operation), selector, "v16@0:8");
        if (_submitted || !method || !contextAllowed(object_getClass(_operation))) return NPMoveNotIssued;
        _submitted = YES;
#if defined(NP_MOVE_ABI_FIXTURE)
        if (object_getClass(_operation) == installedMoveClass()) calls.systemSubmissions++;
#endif
        @try {
            ((void (*)(id, SEL))method_getImplementation(method))(_operation, selector);
            return NPMoveSubmitted;
        } @catch (NSException *exception) {
            // The invocation began. Its void result or exception supplies no membership evidence.
            return NPMoveSubmissionUncertain;
        }
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

CFTypeRef NPCreateWindowMove(uint32_t window, uint64_t space) {
    if (!NPMoveAvailable() || !window || !space || !AXIsProcessTrusted()) return NULL;
    NPPreparedWindowMove *context = [[NPPreparedWindowMove alloc] initWithClass:installedMoveClass()
                                                                         window:window space:space];
#if __has_feature(objc_arc)
    return (__bridge_retained CFTypeRef)context;
#else
    return (CFTypeRef)context;
#endif
}

NPWindowMoveSubmission NPSubmitWindowMove(CFTypeRef context) {
    if (!NPMoveAvailable() || !context || !AXIsProcessTrusted()) return NPMoveNotIssued;
    id operation = (__bridge id)context;
    return object_getClass(operation) == NPPreparedWindowMove.class ? [operation submitOnce] : NPMoveNotIssued;
}
