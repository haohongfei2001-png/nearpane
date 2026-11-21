// Private SDK shim. These layouts stay inside the Rust Corner backend.
#include <stdint.h>
typedef struct {
    double x, y, w, h;
} NCFrame;
typedef struct {
    uint8_t uuid[16];
    NCFrame frame, visible;
} NCDisplay;
typedef struct {
    int32_t pid;
    uint32_t window;
    uint64_t birth, native;
    uint8_t display[16], space[16];
} NCMember;
typedef struct {
    NCFrame ax, cg;
    uint32_t minimized, onscreen;
} NCSample;
typedef struct {
    uint32_t window;
    int32_t pid;
    NCFrame frame;
    double alpha;
    int64_t layer;
} NCListed;
typedef struct {
    int32_t pid;
    uint32_t count;
    NCFrame bars[16];
} NCDock;
typedef uint32_t (*NCGuard)(void *);
uint32_t np_corner_displays(NCDisplay *rows, uint32_t capacity, uint32_t *count);
uint32_t np_corner_zorder(NCListed *rows, uint32_t capacity, uint32_t *count, NCDock *dock);
uint32_t np_corner_sample(const NCMember *, NCSample *);
uint32_t np_corner_position(const NCMember *, void *retained, NCFrame before, NCFrame desired, NCGuard allow,
                            void *context, uint32_t *issued);
int np_corner_secure_input(void);
void np_corner_inputs(uint32_t counters[13]);
// Callback receives in-process event metadata only. No event pointer escapes into Rust.
// Control returns bit 0 wanted, bit 1 a swallowed gesture still held, bit 2 stop.
typedef int (*NCDecide)(void *, uint32_t, double, double, int64_t);
typedef uint32_t (*NCTapControl)(void *);
typedef void (*NCTapHealth)(void *, uint32_t);
void np_corner_tap_run(void *, NCDecide, NCTapControl, NCTapHealth);
void np_corner_release_window(void *retained);
void *np_corner_retain_window(const NCMember *member);
int np_corner_same_window(const NCMember *member, void *retained);

int np_corner_signed_fingerprint(int32_t pid, uint64_t birth, uint8_t digest[32]);
