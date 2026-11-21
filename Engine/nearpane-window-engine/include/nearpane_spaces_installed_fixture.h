#ifndef NEARPANE_SPACES_INSTALLED_FIXTURE_H
#define NEARPANE_SPACES_INSTALLED_FIXTURE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Single installed-Host diagnostic. The challenge names the co-owned
 * rendezvous; no client can name a window, desktop, route or target executable.
 * ABI 1. */
typedef struct {
  uint32_t size, version, status, detail, phase, admission, refusal;
  uint32_t host_pid, fixture_pid, fixture_window, canary_window;
  uint64_t fixture_birth, home_id, canary_space, fixture_space;
  uint32_t before_proofs, parked_proofs, returned_proofs, final_proofs;
  uint32_t canary_created, canary_restored, canary_closed, canary_space_gone;
  uint32_t canary_creates, canary_hides, canary_shows, canary_destroys;
  uint32_t fixture_creates, fixture_hides, fixture_shows, fixture_destroys;
  uint32_t held_windows, held_spaces, outstanding_canary, safe_to_rollback;
  uint32_t before_onscreen, parked_onscreen, returned_onscreen;
  double original_frame[4];
} NPInstalledSpacesReceipt;
int32_t np_spaces_installed_fixture_cycle(const uint8_t challenge[16],
                                          NPInstalledSpacesReceipt *receipt);
#ifdef __cplusplus
}
#endif
#endif
