// clang builds this executable separately. Only the mock class is instantiated.
#import <Foundation/Foundation.h>
#import "NativeSpaceActions.h"
#import "PreparedWindowMove.h"

static NSUInteger creates, deliveries, releases;
static uint64_t destination;
static __weak NSArray<NSNumber *> *observedWindows;

@interface FixtureOperation : NSObject
@end
@implementation FixtureOperation
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)space {
    self = [super init];
    if (self) { creates++; destination=space; observedWindows=windows; }
    return self;
}
- (void)performWithWMBridgeDelegate { deliveries++; }
- (void)dealloc { releases++; }
@end
@interface InvalidBridge : NSObject
@end
@implementation InvalidBridge
- (instancetype)initWithWindows:(NSArray *)wins spaceID:(uint32_t)space { return [super init]; }
- (BOOL)performWithWMBridgeDelegate { return NO; }
@end

int main(void) { @autoreleasepool {
    const uint32_t window = UINT32_MAX - 5;
    const uint64_t space = ((uint64_t)1 << 45) + 7;
    NPBridgedMoveABI live = NPInstalledMoveABI();
    NPBridgedMoveABI wrong = NPInspectMoveClass(InvalidBridge.class);
    NPBridgedMoveABI absent = NPInspectMoveClass(Nil);
    NPPreparedWindowMove *context;
    @autoreleasepool { context = [[NPPreparedWindowMove alloc] initWithClass:FixtureOperation.class window:window space:space]; }
    BOOL valid = context && creates == 1 && observedWindows.count == 1 &&
        [observedWindows.firstObject isEqual:@(window)] && ![observedWindows isKindOfClass:NSMutableArray.class] &&
        destination == space && !wrong.initializerMatches && !wrong.submissionMatches && !absent.hasClass;
    valid = valid && [context submitOnce] && ![context submitOnce] && deliveries == 1 && releases == 0;
    context = nil;
    valid = valid && releases == 1 &&
        ![[NPPreparedWindowMove alloc] initWithClass:InvalidBridge.class window:window space:space] &&
        ![[NPPreparedWindowMove alloc] initWithClass:FixtureOperation.class window:0 space:space] &&
        ![[NPPreparedWindowMove alloc] initWithClass:FixtureOperation.class window:window space:0] &&
        creates == 1 && !NPMoveAvailable() && !NPRequestMove(0, 0);
    NSDictionary *result = @{
        @"status": valid ? @"PASS" : @"FAIL", @"scope":@"mock operation plus installed runtime metadata",
        @"installedABI":@{@"class":@(live.hasClass),@"initializer":@(live.initializerMatches),@"perform":@(live.submissionMatches)},
        @"fixtureAllocations":@(creates),@"fixturePerformCalls":@(deliveries),@"fixtureReleasedAfterReadback":@(releases),
        @"productionAvailable":@(NPMoveAvailable()),@"systemOperationAllocations":@0,@"systemMoveRequests":@0,
        @"independentPhysicalWindowMembership":@"NOT_RUN"
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout); puts("");
    return valid ? 0 : 1;
} }
