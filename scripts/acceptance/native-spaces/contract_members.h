#include "ReadOnlySpaces.h"
CFDictionaryRef _Nullable NPContractMemberReport(CFArrayRef _Nonnull spaceIDs, int hostPID) CF_RETURNS_RETAINED;

CFArrayRef NPContractPublicWindowNumbers(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPContractOnscreenWindowNumbers(void) CF_RETURNS_RETAINED;
#ifdef NP_PRODUCT_CORNER_MATERIAL
CFDictionaryRef _Nonnull NPObserveProductCornerMaterial(CFStringRef _Nonnull nonce) CF_RETURNS_RETAINED;
CFDictionaryRef _Nonnull NPObserveProductCornerPanel(CFStringRef _Nonnull nonce, bool occlusion) CF_RETURNS_RETAINED;
bool NPCornerObserverMatchesHome(CFStringRef _Nonnull display, CFStringRef _Nonnull space, uint64_t native);
#endif
