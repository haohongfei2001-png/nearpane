// A stage opens only after its predecessor's complete, independently witnessed laps.
#include <stdbool.h>
typedef struct {
    unsigned gate, edge, lap[3];
} NCCycles;
static inline unsigned nc_cycle_limit(unsigned gate) {
    return gate == 0 ? 1 : gate == 1 ? 10 : gate == 2 ? 50 : 0;
}
static inline bool nc_cycle_accept(NCCycles *cycle, unsigned from, unsigned to, bool witnessed) {
    if (!witnessed || cycle->gate >= 3 || cycle->edge != from || (from + 1) % 3 != to)
        return false;
    cycle->edge = to;
    if (!to && ++cycle->lap[cycle->gate] == nc_cycle_limit(cycle->gate))
        ++cycle->gate;
    return true;
}
