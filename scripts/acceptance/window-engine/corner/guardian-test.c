#include "guardian/protocol.h"
#include <assert.h>
int main(void) {
    NCRecoveryFacts f = {.retained_before_park = true, .parked_confirmed = true, .eof = true,
                         .kernel_parent_exit = true, .parent_generation_gone = true, .journal_exact = true,
                         .lifetime_exact = true, .frame_exact = true, .original_display = true,
                         .inputs_unchanged = true, .current_signature = true, .no_secure_input = true,
                         .unspent = true, .guardian_own_ax = true};
    assert(ncg_may_restore(f));
#define MISSING(x)                                                                                                \
    do {                                                                                                          \
        f.x = false;                                                                                              \
        assert(!ncg_may_restore(f));                                                                              \
        f.x = true;                                                                                               \
    } while (0)
    MISSING(retained_before_park);
    MISSING(parked_confirmed);
    MISSING(eof);
    MISSING(kernel_parent_exit);
    MISSING(parent_generation_gone);
    MISSING(journal_exact);
    MISSING(lifetime_exact);
    MISSING(frame_exact);
    MISSING(original_display);
    MISSING(inputs_unchanged);
    MISSING(current_signature);
    MISSING(no_secure_input);
    MISSING(unspent);
    MISSING(guardian_own_ax);
    NCGuardianEntry p = {.version = 1, .phase = NCG_PREPARE, .host = 45, .host_birth = 543}, s = p;
    p.lease.intent[0] = 1;
    p.lease.epoch = 5;
    p.lease.native_id = 9;
    s = p;
    s.phase = NCG_CONFIRMED;
    s.result = (NPReceipt){.size = sizeof(NPReceipt),
                           .version = 1,
                           .status = NP_PASS,
                           .epoch = 5,
                           .native_id = 9,
                           .flags = NP_HIDDEN | NP_AX_VALID | NP_CG_VALID | NP_INPUT_SAFE | NP_MEMBERSHIP_VALID |
                                    NP_OWNED};
    memcpy(s.result.intent, p.lease.intent, 16);
    assert(ncg_correlates(&p, &s));
    s.result.intent[1] = 2;
    assert(!ncg_correlates(&p, &s));
    s.result.intent[1] = 0;
    s.lease.generation[2] = 8;
    assert(!ncg_correlates(&p, &s));
    s.lease.generation[2] = 0;
    s.lease.lifetime[0] = 4;
    assert(!ncg_correlates(&p, &s));
    s.lease.lifetime[0] = 0;
    s.hid[12] = 5;
    assert(!ncg_correlates(&p, &s));
    s.hid[12] = 0;
    s.result.flags &= ~NP_INPUT_SAFE;
    assert(!ncg_correlates(&p, &s));
}
