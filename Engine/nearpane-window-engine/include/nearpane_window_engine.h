#ifndef NEARPANE_WINDOW_ENGINE_H
#define NEARPANE_WINDOW_ENGINE_H
#include <stdint.h>
#include <stdbool.h>
#include "nearpane_host_scope.h"
#include "nearpane_guardian_observation.h"
#include "nearpane_spaces_installed_fixture.h"
#ifdef __cplusplus
extern "C" {
#endif
/* All buffers are caller-owned, copied synchronously and never retained. Initialize
 * size/version before every call. Coordinates are global Quartz points, y down.
 * Process birth is Unix microseconds from proc_bsdinfo. IDs use UUID network bytes.
 * Each command concerns one journaled window. 32 outstanding tickets per handle. */
enum { NP_ENGINE_ABI = 1, NP_CORNER = 1, NP_SPACES = 2 };
enum { NP_PROBE = 1, NP_READBACK, NP_HIDE, NP_SHOW, NP_RESTORE, NP_HEALTH, NP_TRIAL,
       NP_LAUNCH, NP_CLEAN_LAUNCH, NP_CORNER_PARK_ACCESS, NP_CORNER_DISPLAY_MATERIAL,
       NP_CORNER_RETIREMENT_SURFACE };
/* DISPLAY_MATERIAL returns the complete shadow footprint, native ID and the
 * verified source in detail. It cannot acquire visibility, input or window rights. */
enum { NP_CORNER_MATERIAL_SEALED_FILE = 49, NP_CORNER_MATERIAL_WALLPAPER_SURFACE = 50 };
/* RETIREMENT_SURFACE also checks the proposed corner against the current desktop,
 * other panels and the real Dock before preparing pixels. Neither call moves a window. */
enum { NP_CORNER_SITE_UNAVAILABLE = 51, NP_CORNER_SITE_DESKTOP = 52,
       NP_CORNER_SITE_OVERLAY = 53, NP_CORNER_SITE_DOCK = 54 };
/* Read-only eligibility of the calling Host. No window, tap or write authority. */
enum { NP_CORNER_MISSING_AX = 1, NP_CORNER_MISSING_LISTEN = 19,
       NP_CORNER_MISSING_POST = 20, NP_CORNER_MISSING_CAPTURE = 21 };
enum { NP_PASS = 0, NP_FAIL, NP_UNKNOWN, NP_UNSUPPORTED, NP_TIMEOUT, NP_CANCELLED };
enum { NP_VISIBLE = 1, NP_HIDDEN = 2, NP_AX_VALID = 4, NP_CG_VALID = 8,
       NP_INPUT_SAFE = 16, NP_MEMBERSHIP_VALID = 32, NP_HEALTHY = 64, NP_OWNED = 128,
       NP_PROBE_RESTORED = 256, NP_PROBE_CLOSED = 512, NP_PROBE_SPACE_DESTROYED = 1024,
       /* Retained Corner postimage only. Never authorizes product activity or input isolation. */
       NP_CORNER_RECOVERY_FRAME = 2048 };
/* Transport status is separate from the observed result. */
enum { NP_OK = 0, NP_INVALID = 1, NP_INCOMPATIBLE = 2, NP_CLOSED = 3, NP_BUSY = 4,
       NP_PENDING = 5, NP_NO_TICKET = 6, NP_INTERNAL = 7 };
enum { NP_HOST = 0, NP_ISOLATED_FIXTURE = 1 };
enum { NP_TRIAL_CLASSIC = 1u << 16 };
typedef struct { double x, y, width, height; } NPRect;
typedef struct { int32_t pid; uint32_t reserved; uint64_t birth; } NPProcess;
typedef struct {
    uint32_t size, version, mode, process_count;
    NPProcess processes[2];
} NPConfig;
typedef struct {
    uint32_t size, version, backend, operation, flags, timeout_ms;
    uint8_t intent[16], group[16], display[16], native_space[16], member[16], lifetime[16], generation[16];
    int32_t pid; uint32_t window;
    uint64_t birth, native_id, epoch;
    NPRect frame, target;
} NPRequest;
typedef struct {
    uint32_t size, version, status, flags, detail, owned;
    uint64_t native_id, epoch, elapsed_ns;
    uint8_t intent[16];
    NPRect frame;
} NPReceipt;
/* Nonzero opaque handles and tickets never alias a previous instance. Poll once
 * for a terminal receipt, including cancellation. Revoke invalidates the epoch
 * before the next OS side effect. A dispatched Corner hide may stay pending for
 * up to 500 ms after cancellation is observed or its deadline expires to measure
 * a recovery-only postimage. It cannot report successful isolation after revocation.
 * A revoked qualified handle may restore its prior
 * ownership or clean up its launch canary. New hide/show/launch work requires
 * release and a fresh qualified handle. Destroy refuses pending tickets/owned windows. */
uint32_t np_engine_version(void);
uint32_t np_engine_create(const NPConfig *, uint64_t *handle);
/* acquisition for exactly one reviewed backend; evidence points to 16 UUID bytes. */
uint32_t np_engine_create_qualified(uint32_t backend, const uint8_t *evidence, uint64_t *handle);
bool np_engine_evidence_is_reviewed(uint32_t backend, const uint8_t *evidence);
uint32_t np_engine_epoch(uint64_t handle, uint64_t *epoch);
uint32_t np_engine_submit(uint64_t handle, const NPRequest *, uint64_t *ticket);
/* The Host supplies its acknowledged Guardian child for this exact HIDE intent. */
uint32_t np_engine_submit_guarded_corner_hide(uint64_t handle, const NPRequest *, int32_t guardian_pid,
                                            uint64_t guardian_birth, uint64_t *ticket);
/* Qualified original Corner handle only. OK permanently excludes this never-accepted HIDE intent.
   An accepted ticket (including a consumed timeout/unknown), duplicate or closed handle cannot attest absence. */
uint32_t np_engine_fence_unsubmitted_corner_hide(uint64_t handle, const NPRequest *);
uint32_t np_engine_poll(uint64_t handle, uint64_t ticket, NPReceipt *receipt);
uint32_t np_engine_cancel(uint64_t handle, uint64_t ticket);
uint32_t np_engine_revoke(uint64_t handle);
uint32_t np_engine_destroy(uint64_t handle);
#ifdef __cplusplus
}
#endif
#endif
