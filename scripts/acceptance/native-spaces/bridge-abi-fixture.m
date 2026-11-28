// Standalone ARC fixture. Only classes defined in this executable may be constructed or called.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "PreparedWindowMove.h"

static NSUInteger initialized, deliveries, released;
static uint64_t receivedSpace;
static __weak NSArray<NSNumber *> *receivedWindows;
static __weak id receivedOperation;

@interface EnrolledOperation : NSObject
@end
@implementation EnrolledOperation
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)space {
    self = [super init];
    if (self) {
        initialized++;
        receivedSpace = space;
        receivedWindows = windows;
        receivedOperation = self;
    }
    return self;
}
- (void)performWithWMBridgeDelegate { deliveries++; }
- (void)dealloc { released++; }
@end

@interface WrongSpaceWidth : NSObject @end
@implementation WrongSpaceWidth
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint32_t)space { return [super init]; }
- (void)performWithWMBridgeDelegate {}
@end
@interface WrongReturn : NSObject @end
@implementation WrongReturn
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint64_t)space { return [super init]; }
- (BOOL)performWithWMBridgeDelegate { return YES; }
@end
@interface MissingSelector : NSObject @end
@implementation MissingSelector
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint64_t)space { return [super init]; }
- (void)performWithWMBridgeDelegate:(id)unexpectedArgument {}
@end
@interface FailedInitialization : EnrolledOperation @end
@implementation FailedInitialization
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint64_t)space { return nil; }
@end
@interface SubstitutedOperation : EnrolledOperation @end
@implementation SubstitutedOperation
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint64_t)space {
    return (id)[[NSObject alloc] init];
}
@end
@interface ThrowingOperation : EnrolledOperation @end
@implementation ThrowingOperation
- (void)performWithWMBridgeDelegate {
    deliveries++;
    @throw [NSException exceptionWithName:@"MockOnly" reason:nil userInfo:nil];
}
@end

static NSUInteger submitConcurrently(NPPreparedWindowMove *context) {
    __block atomic_uint winners = 0;
    dispatch_apply(12, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
        if ([context submitOnce] == NPMoveSubmitted) atomic_fetch_add(&winners, 1);
    });
    return atomic_load(&winners);
}

static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys
                                                      error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    puts("");
}

int main(void) { @autoreleasepool {
    const uint32_t number = UINT32_MAX - 5;
    const uint64_t space = ((uint64_t)1 << 45) + 7;
    NPBridgedMoveABI live = NPInstalledMoveABI(); // runtime metadata only
    Class installed = objc_lookUpClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    Method init = class_getInstanceMethod(installed, NSSelectorFromString(@"initWithWindows:spaceID:"));
    Method perform = class_getInstanceMethod(installed, NSSelectorFromString(@"performWithWMBridgeDelegate"));
    NSMutableDictionary *checks = [NSMutableDictionary new];
    checks[@"productionClosed"] = @(!NPMoveAvailable() && !NPCreateWindowMove(number, space) &&
                                      NPSubmitWindowMove((__bridge CFTypeRef)NSNull.null) == NPMoveNotIssued);
    NPBridgedMoveABI absent = NPInspectMoveClass(Nil);
    NPBridgedMoveABI narrow = NPInspectMoveClass(WrongSpaceWidth.class);
    NPBridgedMoveABI result = NPInspectMoveClass(WrongReturn.class);
    NPBridgedMoveABI missing = NPInspectMoveClass(MissingSelector.class);
    checks[@"missingClass"] = @(!absent.hasClass && !absent.initializerMatches && !absent.submissionMatches);
    checks[@"initializerWidth"] = @(!narrow.initializerMatches && narrow.submissionMatches);
    checks[@"submissionReturnAndArity"] = @(result.initializerMatches && !result.submissionMatches &&
                                            missing.initializerMatches && !missing.submissionMatches);
    BOOL refused = YES;
    for (Class cls in @[WrongSpaceWidth.class, WrongReturn.class, MissingSelector.class,
                        FailedInitialization.class, SubstitutedOperation.class]) {
        refused &= ![[NPPreparedWindowMove alloc] initWithClass:cls window:number space:space];
    }
    checks[@"invalidABIInitializationOrSubstitution"] = @(refused && initialized == 0 && deliveries == 0);
    checks[@"zeroArguments"] = @(![[NPPreparedWindowMove alloc] initWithClass:EnrolledOperation.class window:0 space:space] &&
                                  ![[NPPreparedWindowMove alloc] initWithClass:EnrolledOperation.class window:number space:0]);

    NSUInteger beforeRelease = released;
    NPPreparedWindowMove *context;
    @autoreleasepool {
        context = [[NPPreparedWindowMove alloc] initWithClass:EnrolledOperation.class window:number space:space];
    }
    checks[@"immutableSingleUInt32WindowAndUInt64Space"] = @(context && receivedWindows.count == 1 &&
        ![receivedWindows isKindOfClass:NSMutableArray.class] && [receivedWindows.firstObject isEqual:@(number)] &&
        receivedSpace == space);
    checks[@"concurrentAndDuplicateCalls"] = @(submitConcurrently(context) == 1 && deliveries == 1 &&
                                                [context submitOnce] == NPMoveNotIssued);
    @autoreleasepool {
        checks[@"operationAndWindowArrayOwnedAfterInvocation"] = @(receivedWindows.count == 1 && receivedOperation != nil &&
                                                     released == beforeRelease);
    }
    context = nil;
    checks[@"operationAndArrayReleasedAfterTerminal"] = @(!receivedOperation && !receivedWindows && released == beforeRelease + 1);
    context = [[NPPreparedWindowMove alloc] initWithClass:ThrowingOperation.class window:number space:space];
    checks[@"exceptionAfterInvocationIsUnknownAndNeverReplayed"] = @(context && [context submitOnce] == NPMoveSubmissionUncertain &&
        [context submitOnce] == NPMoveNotIssued && deliveries == 2);
    context = nil;

    NPMoveFixtureCounts calls = NPMoveObservedCalls();
    checks[@"systemOperationNeverConstructedOrInvoked"] = @(calls.systemAllocations == 0 && calls.systemSubmissions == 0);
    for (NSString *name in checks.allKeys) checks[name] = @([checks[name] boolValue]);
    BOOL passed = ![checks.allValues containsObject:@NO];
    emit(@{@"status": passed ? @"PASS" : @"FAIL", @"checks": checks,
           @"installedMetadata": @{@"classPresent":@(live.hasClass), @"initializerMatches":@(live.initializerMatches),
                                   @"submissionMatches":@(live.submissionMatches),
                                   @"initializerEncoding":init ? @(method_getTypeEncoding(init)) : NSNull.null,
                                   @"submissionEncoding":perform ? @(method_getTypeEncoding(perform)) : NSNull.null},
           @"fixtureSuccessfulInitializations":@(initialized), @"fixtureInvocationCount":@(deliveries),
           @"systemOperationAllocations":@(calls.systemAllocations), @"systemMoveRequests":@(calls.systemSubmissions),
           @"physicalMoveRoundTrip":@"NOT_RUN"});
    return passed ? 0 : 1;
} }
