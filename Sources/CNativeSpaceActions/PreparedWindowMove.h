#import <Foundation/Foundation.h>

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
- (BOOL)submitOnce;
@end
