#ifndef NEARPANE_APPLE_STAGE_H
#define NEARPANE_APPLE_STAGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define NP_APPLE_MIRROR_ABI 1u
enum { NP_APPLE_MIRROR_OK=0, NP_APPLE_MIRROR_INVALID=1, NP_APPLE_MIRROR_CLOSED=2,
       NP_APPLE_MIRROR_SCOPE_CHANGED=3, NP_APPLE_MIRROR_CAPACITY=4,
       NP_APPLE_MIRROR_UNAVAILABLE=5, NP_APPLE_MIRROR_STALE=6, NP_APPLE_MIRROR_INTERNAL=7 };
enum { NP_APPLE_CURRENT=1, NP_APPLE_STRIP=2, NP_APPLE_REMEMBERED=3 };
enum { NP_APPLE_MAX_LISTED=8192, NP_APPLE_MAX_MANAGED=1024, NP_APPLE_MAX_AX_MEMBERS=2048 };

typedef struct { double x, y, width, height; } NPAppleRect;
typedef struct {
    uint32_t size, version;
    uint8_t display_uuid[16];
    uint64_t native_space_id;
} NPAppleMirrorScope;
/* Complete CG order, front to back. Unmanaged rows between two listed windows matter. */
typedef struct {
    uint32_t window;
    int32_t pid, layer;
    uint32_t onscreen;
    NPAppleRect frame;
} NPAppleListedWindow;
/* One row per AXWindowsIDs member, same item and frame for a strip item's members. */
typedef struct { uint32_t item, window; NPAppleRect frame; } NPAppleAXMember;
typedef struct {
    uint32_t size, version;
    NPAppleMirrorScope scope;
    uint64_t sample_time_ns; /* Monotonic within the handle. */
    NPAppleRect display_frame;
    int32_t manager_pid;
    uint32_t ax_available, transition_began;
    uint32_t listed_count, managed_count, ax_count;
    const NPAppleListedWindow *listed;
    const uint32_t *managed; /* Alive windows witnessed in this physical display + native Space. */
    const NPAppleAXMember *ax_members;
} NPAppleMirrorInput;
/* Ordinals apply only to this snapshot. Current is 0, then strip items, then remembered. */
typedef struct {
    uint32_t ordinal, role, window, confirmed_by_ax;
    NPAppleRect group_frame;
} NPAppleMirrorMember;
typedef struct {
    uint32_t size, version, member_count, settled, disagreement, trusted_ax;
    int32_t strip_shown; /* -1 unknown, 0 off the left edge, 1 shown */
} NPAppleMirrorResult;

/* Create one immutable session per physical display UUID and ordinary native Space.
 * Initialize size/version in scope, input, and result to sizeof(record) and ABI 1.
 * Handles are process-local, internally serialized, and owned by the caller.
 * Destroy on display/Space/lifetime replacement. A handle cannot be reopened. */
uint32_t np_apple_mirror_create(const NPAppleMirrorScope *scope, uint64_t *handle);
uint32_t np_apple_mirror_destroy(uint64_t handle);
/* Call with member_capacity >= managed_count for a single pass. On CAPACITY,
 * member_count is the exact required length; the sample was not committed.
 * Pointers must be aligned, live for this call, with non-overlapping input and
 * writable output regions. Null is accepted for zero-length arrays.
 * A trusted AX reading remains valid across a blank poll within the same
 * stationary scene. Resetting ax_available, a transition or process change
 * invalidates it. REMEMBERED rows carry historical group geometry only. */
uint32_t np_apple_mirror_read_v1(uint64_t handle, const NPAppleMirrorInput *input,
    NPAppleMirrorMember *members, uint32_t member_capacity, NPAppleMirrorResult *result);

#ifdef __cplusplus
}
#endif
#include "nearpane_apple_merge.h"
#endif
