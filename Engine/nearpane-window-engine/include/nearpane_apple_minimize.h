#ifndef NEARPANE_APPLE_MINIMIZE_H
#define NEARPANE_APPLE_MINIMIZE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { int32_t pid; uint32_t window; uint64_t birth; } NPAppleMinimizeWindow;
enum { NP_APPLE_AX_MINIATURIZED = 1, NP_APPLE_AX_DEMINIATURIZED = 2, NP_APPLE_MINIMIZE_SNAPSHOT = 3 };
enum { NP_APPLE_MINIMIZE_UNKNOWN = 0, NP_APPLE_WINDOW_NORMAL = 1, NP_APPLE_WINDOW_MINIMIZED = 2 };
enum { NP_APPLE_MINIMIZE_OBSERVING = 1 };
enum { NP_APPLE_MINIMIZE_NO_CHANGE = 0, NP_APPLE_MINIMIZE_REFRESH_MINIMIZED = 1, NP_APPLE_MINIMIZE_REFRESH_RESTORED = 2 };
/* A change only requests a fresh read of Apple's arrangement. No input or AX write.
   birth is the registered process start in microseconds. */
uint32_t np_apple_native_minimize_change_v1(uint32_t event, NPAppleMinimizeWindow registered,
    NPAppleMinimizeWindow current, uint32_t previous, uint32_t observed, uint32_t scope);
#ifdef __cplusplus
}
#endif
#endif
