// Private, same-build handoff. A journal record alone never confers authority.
#pragma once
#include "../macos.h"
#include "nearpane_window_engine.h"
#include <stdbool.h>
#include <string.h>
enum { NCG_PREPARE = 1, NCG_CONFIRMED = 2 };
typedef struct {
    uint32_t version, phase;
    int32_t host;
    uint32_t reserved;
    uint64_t host_birth;
    NPRequest lease;
    NPReceipt result;
    uint32_t hid[13];
} NCGuardianEntry;
static inline bool ncg_correlates(const NCGuardianEntry *prepared, const NCGuardianEntry *sealed) {
    const NPReceipt *r = &sealed->result;
    const unsigned flags = NP_HIDDEN | NP_AX_VALID | NP_CG_VALID | NP_INPUT_SAFE | NP_MEMBERSHIP_VALID | NP_OWNED;
    return prepared->version == 1 && sealed->version == 1 && prepared->phase == NCG_PREPARE &&
           sealed->phase == NCG_CONFIRMED && prepared->host == sealed->host &&
           prepared->host_birth == sealed->host_birth &&
           !memcmp(&prepared->lease, &sealed->lease, sizeof(prepared->lease)) &&
           !memcmp(prepared->hid, sealed->hid, sizeof(prepared->hid)) && r->size == sizeof(*r) &&
           r->version == 1 && r->status == NP_PASS && r->epoch == prepared->lease.epoch &&
           r->native_id == prepared->lease.native_id && (r->flags & flags) == flags &&
           !memcmp(r->intent, prepared->lease.intent, 16);
}
typedef struct {
    bool retained_before_park, parked_confirmed, eof, kernel_parent_exit, parent_generation_gone;
    bool journal_exact, lifetime_exact, frame_exact, original_display, inputs_unchanged;
    bool current_signature, no_secure_input, unspent, guardian_own_ax;
} NCRecoveryFacts;
static inline bool ncg_may_restore(NCRecoveryFacts f) {
    return f.retained_before_park && f.parked_confirmed && f.eof && f.kernel_parent_exit &&
           f.parent_generation_gone && f.journal_exact && f.lifetime_exact && f.frame_exact &&
           f.original_display && f.inputs_unchanged && f.current_signature && f.no_secure_input && f.unspent &&
           f.guardian_own_ax;
}
