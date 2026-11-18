#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// The disposable readers and action helper link this shim. The Host does not.
// The existing entry point keeps the reviewed write/identity build gate.
int NPReadOnlySpacesOpen(void);
// Metadata-only inventory on the reviewed Darwin ABI family, after a runtime shape probe.
int NPProbeReadOnlyCatalog(void);
CFArrayRef _Nullable NPReadInventory(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPReadWindowSpaces(uint32_t window) CF_RETURNS_RETAINED;

// Window-number read witnessed in P4.7.3; unavailable on unverified OS builds.
uint32_t NPReadAXWindowNumber(CFTypeRef _Nonnull element);

// Exact ID-only query including offscreen records: absent (0), present (1), unavailable (-1).
int NPReadWindowNumberPresence(uint32_t window);

// Anonymous pre-consent numbers only. No window dictionaries, titles or pixels.
int NPReadExistingWindowNumbers(uint32_t * _Nonnull out, int capacity);

// Preserve global z-order using IDs alone; fetch metadata only for the supplied windows.
CFArrayRef _Nullable NPReadVisibleWindowDescriptions(const uint32_t * _Nonnull windows, int count) CF_RETURNS_RETAINED;
