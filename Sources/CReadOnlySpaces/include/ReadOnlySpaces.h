#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGGeometry.h>
#include <stdint.h>

// The Host, ordinary-window controller and disposable readers share this read-only
// shim. arm64 Darwin 26-family symbol/shape reads do not grant engine write
// qualification; callers retain their independent TCC, process and AX identity checks.
int NPReadOnlySpacesOpen(void);
// Metadata-only inventory on that ABI family, including a runtime shape probe.
int NPProbeReadOnlyCatalog(void);
CFArrayRef _Nullable NPReadInventory(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPReadWindowSpaces(uint32_t window) CF_RETURNS_RETAINED;
// Physical witnesses include classic hidden Spaces (selector 15). The ordinary
// catalogue above keeps selector 7; neither view changes window membership.
CFArrayRef _Nullable NPReadWindowSpacesIncludingHidden(uint32_t window) CF_RETURNS_RETAINED;

// Read-only WindowServer member numbers for one already witnessed Space.
CFArrayRef _Nullable NPReadCatalogSpaceWindowNumbers(uint64_t space) CF_RETURNS_RETAINED;

// Pre-compositor logical rectangle for the read-only roster. No content or action authority.
// Returns zero outside the supported ABI family, for absent symbols or invalid bounds.
int NPReadCatalogLogicalBounds(uint32_t window, CGRect * _Nonnull bounds);

// Private read of an existing AX element on the supported ABI family. A positive
// number alone never replaces retained AX equality or the process-birth witness.
uint32_t NPReadAXWindowNumber(CFTypeRef _Nonnull element);

// Exact ID-only query including offscreen records: absent (0), present (1), unavailable (-1).
int NPReadWindowNumberPresence(uint32_t window);

// Anonymous pre-consent numbers only. No window dictionaries, titles or pixels.
int NPReadExistingWindowNumbers(uint32_t * _Nonnull out, int capacity);

// Preserve global z-order using IDs alone; fetch metadata only for the supplied windows.
CFArrayRef _Nullable NPReadVisibleWindowDescriptions(const uint32_t * _Nonnull windows, int count) CF_RETURNS_RETAINED;
