#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

// All events are built before the first post. No read/listen tap is registered.
bool NPSendAdjacentSwipe(bool right, bool reducedMotion, CGDirectDisplayID intendedDisplay);
bool NPMoveAvailable(void);
bool NPRequestMove(uint32_t window, uint64_t space);
