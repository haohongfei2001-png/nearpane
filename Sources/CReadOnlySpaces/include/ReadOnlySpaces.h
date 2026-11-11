#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// Only the disposable reader executable links this shim. Both successful copies transfer ownership.
int NPReadOnlySpacesOpen(void);
CFArrayRef _Nullable NPReadInventory(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPReadWindowSpaces(uint32_t window) CF_RETURNS_RETAINED;

// Window-number read witnessed in P4.7.3; unavailable on unverified OS builds.
uint32_t NPReadAXWindowNumber(CFTypeRef _Nonnull element);

// 1 only for an available, empty WindowServer list scoped to this exact number.
int NPWindowNumberConfirmedAbsent(uint32_t window);
