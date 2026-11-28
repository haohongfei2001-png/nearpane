#ifndef NEARPANE_APPLE_MERGE_H
#define NEARPANE_APPLE_MERGE_H
#include "nearpane_apple_stage.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint32_t size, version;
    uint64_t sample_time_ns; /* must match the committed mirror sample */
    NPAppleRect visible_frame; /* usable display bounds; same global CG coordinates */
    uint32_t source_count, destination_count;
    const uint32_t *source, *destination; /* complete current and strip groups */
} NPAppleMergeRequest;
typedef struct {
    uint32_t size, version;
    uint32_t window, twin;
    int32_t manager_pid;
    uint32_t reserved;
    double x, y;
} NPAppleMergePoint;
/* Pure observation. UNAVAILABLE includes covered, hidden and AX-unconfirmed strip items.
 * OK describes one point only in this snapshot. The caller must re-check WindowManager's
 * exact topmost twin and the AX strip item at that point immediately before use. */
uint32_t np_apple_merge_point_v1(uint64_t handle, const NPAppleMergeRequest *request, NPAppleMergePoint *point);
#ifdef __cplusplus
}
#endif
#endif
