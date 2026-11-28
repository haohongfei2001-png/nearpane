#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// PID-directed Apple Events only. Never launches or activates an application.
/// Each response is bounded JSON. Errors are returned in { errorCode, error }.
FOUNDATION_EXPORT NSData *LTPReadPlayer(int32_t pid, BOOL spotify, BOOL includeArtwork);
/// accepted=true means delivery only; Swift must verify the resulting player state.
FOUNDATION_EXPORT NSData *LTPCommandPlayer(int32_t pid, BOOL spotify, NSString *command, double positionSeconds);
FOUNDATION_EXPORT void LTPReleasePlayers(void);
/// Kernel process start time; zero means identity could not be established.
FOUNDATION_EXPORT uint64_t LTPProcessStartMicros(int32_t pid);
FOUNDATION_EXPORT NSString *LTPSystemBuild(void);
NS_ASSUME_NONNULL_END
