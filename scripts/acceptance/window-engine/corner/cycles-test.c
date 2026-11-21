#include "cycles.h"
#include <assert.h>
int main(void) {
    NCCycles c = {0};
    assert(!nc_cycle_accept(&c, 0, 2, true));
    assert(!nc_cycle_accept(&c, 0, 1, false));
    for (unsigned stage = 0; stage < 3; stage++) {
        for (unsigned lap = 0; lap < nc_cycle_limit(stage); lap++) {
            assert(c.gate == stage && c.lap[stage] == lap && c.edge == 0);
            assert(nc_cycle_accept(&c, 0, 1, true));
            assert(!nc_cycle_accept(&c, 0, 1, true));
            assert(!nc_cycle_accept(&c, 1, 2, false));
            assert(c.gate == stage && c.lap[stage] == lap);
            assert(nc_cycle_accept(&c, 1, 2, true));
            assert(c.gate == stage && c.lap[stage] == lap);
            assert(nc_cycle_accept(&c, 2, 0, true));
        }
    }
    assert(c.gate == 3 && c.lap[0] == 1 && c.lap[1] == 10 && c.lap[2] == 50);
    assert(!nc_cycle_accept(&c, 0, 1, true));
    return 0;
}
