/* Fixed-width private Rust/C boundary. No AppKit or Objective-C reference leaves this file. */
#ifndef NP_SPACES_PLATFORM_H
#define NP_SPACES_PLATFORM_H
#include <stdint.h>
typedef struct { uint8_t display[16], uuid[16]; uint64_t id; int32_t kind; uint32_t current; } NPStageDesktop;
typedef struct { uint32_t number; int32_t pid; uint64_t birth; uint32_t onboard; uint32_t layer_zero; double rect[4]; } NPStageWindow;
int32_t np_stage_symbols(void);
int32_t np_stage_sip_enabled(void);
uint64_t np_stage_hosted_self_birth(void);
int32_t np_stage_target_build(void);
/* Runtime support for a candidate, not qualification of a particular OS/SIP combination. */
int32_t np_stage_candidate_supported(void);
int32_t np_stage_connection(void);
int32_t np_stage_desktops(int32_t connection, NPStageDesktop *out, uint32_t capacity);
int32_t np_stage_all_spaces(int32_t connection, uint64_t *out, uint32_t capacity);
int32_t np_stage_checked_inventory(int32_t connection, uint64_t *out, uint32_t capacity);
int32_t np_stage_membership(int32_t connection, uint32_t number, uint64_t *out, uint32_t capacity);
int32_t np_stage_occupants(int32_t connection, uint64_t space, uint64_t *out, uint32_t capacity);
/* Optional read-only diagnostics, not a qualification of a numeric private Space type. */
int32_t np_stage_space_type(int32_t connection, uint64_t space, int32_t *out);
int32_t np_stage_window(uint32_t number, NPStageWindow *out);
int32_t np_stage_create(int32_t connection, uint64_t *created);
int32_t np_stage_destroy(int32_t connection, uint64_t space);
int32_t np_stage_move(int32_t connection, uint32_t route, uint32_t number, uint64_t space, uint32_t mask);
void *np_stage_bind(uint32_t number, int32_t pid, uint64_t birth);
int32_t np_stage_check_bound(void *handle,uint32_t number,int32_t pid,uint64_t birth,uint32_t on_screen);
int32_t np_stage_check_bound_minimized(void *handle,uint32_t number,int32_t pid,uint64_t birth,uint32_t on_screen);
// Read-only status: 1 is a complete original binding, -25204 is only absent AX
// transport evidence, and 0 rejects every other failure. Writer checks stay Boolean.
int32_t np_stage_check_bound_status(void *handle,uint32_t number,int32_t pid,uint64_t birth,uint32_t on_screen,uint32_t allow_minimized);
// Only for a retained original standard window established by a visible readback.
int32_t np_stage_adopt_minimized(void *handle,uint32_t number,int32_t pid,uint64_t birth);
// 0/1 are positive Boolean reads. -25204 preserves AXCannotComplete;
// other missing/invalid observations return -1 and never imply false.
int32_t np_stage_is_minimized(void *handle);
int32_t np_stage_set_minimized(void *handle,uint32_t number,int32_t pid,uint64_t birth,uint32_t minimized);
void np_stage_release(void *handle);
typedef struct { uint32_t number; int32_t pid; uint64_t birth; uint32_t opened, registered, absent, focus_same, close_issued; } NPStageCanary;
typedef int32_t (*NPStageGuard)(void *);
typedef void (*NPStageFree)(void *);
void *np_stage_launch_token(void);
void *np_stage_launch_candidate_token(void);
int32_t np_stage_launch_call(void *handle,uint32_t op,void *auth,NPStageGuard guard,NPStageFree release,NPStageCanary *out);
#endif
