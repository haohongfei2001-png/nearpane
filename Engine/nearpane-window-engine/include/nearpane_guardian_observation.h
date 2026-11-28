#ifndef NEARPANE_GUARDIAN_OBSERVATION_H
#define NEARPANE_GUARDIAN_OBSERVATION_H
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    double x, y, width, height;
} NPGuardianRect;
typedef struct {
    uint64_t uptime_ns;
    uint32_t signature, kernel_generation, cg_owner, cg_onscreen, ax_trusted;
    uint32_t native_sample_attempted, native_sample_code, same_retained;
    NPGuardianRect cg, ax;
} NPGuardianFixtureRead;
typedef struct {
    uint32_t size, version, held_in_caller, released, same_geometry, signatures_closed;
    NPGuardianFixtureRead first, second;
} NPGuardianFixtureObservation;
/* Reports only the fixed signed ordinary acceptance owner. No AX/CF handle, command,
 * durable ownership, PID selection capability, or window setter crosses this ABI. */
int32_t np_guardian_observe_fixture(int32_t pid, uint64_t birth, uint32_t window,
                                    CFStringRef _Nonnull executable, CFStringRef _Nonnull cdhash,
                                    uint64_t native_id, CFStringRef _Nullable display,
                                    CFStringRef _Nullable space, NPGuardianFixtureObservation *_Nonnull out);
/* A successful open returns a caller-owned close-on-exec descriptor for the signed installed
 * Guardian child. Its first terminal observation is final. No window authority is transferred. */
enum { NP_GUARDIAN_IMAGE_LOST = 0, NP_GUARDIAN_IMAGE_LIVE = 1, NP_GUARDIAN_IMAGE_EXITED = 2,
       NP_GUARDIAN_IMAGE_UNAVAILABLE = 3 };
int32_t np_corner_open_guardian_peer(int32_t child, uint64_t birth);
int32_t np_corner_guardian_image_state(int32_t watch, int32_t child, uint64_t birth);
#ifdef __cplusplus
}
#endif
#endif
#endif
