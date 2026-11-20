#import <Foundation/Foundation.h>
#import "NativeSpaceActions.h"

typedef struct {
    BOOL hasClass;
    BOOL initializerMatches;
    BOOL submissionMatches;
} NPBridgedMoveABI;

// Examining methods never allocates an operation or submits a move.
NPBridgedMoveABI NPInspectMoveClass(Class operationClass);
NPBridgedMoveABI NPInstalledMoveABI(void);

// Internal preparation for the independently gated membership transaction.
// Its owner must keep this context alive until terminal WindowServer readback.
@interface NPPreparedWindowMove : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithClass:(Class)operationClass window:(uint32_t)window space:(uint64_t)space;
- (NPWindowMoveSubmission)submitOnce;
@end

#if defined(NP_MOVE_ABI_FIXTURE)
// Instrument only the two operation-call boundaries in the standalone test build.
typedef struct { NSUInteger systemAllocations, systemSubmissions; } NPMoveFixtureCounts;
NPMoveFixtureCounts NPMoveObservedCalls(void);
#endif
