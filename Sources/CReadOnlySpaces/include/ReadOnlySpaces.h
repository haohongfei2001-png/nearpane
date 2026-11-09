#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// Only the disposable reader executable links this shim. Both successful copies transfer ownership.
int NPReadOnlySpacesOpen(void);
CFArrayRef _Nullable NPReadInventory(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPReadWindowSpaces(uint32_t window) CF_RETURNS_RETAINED;
