#include "ReadOnlySpaces.h"
CFDictionaryRef _Nullable NPContractMemberReport(CFArrayRef _Nonnull spaceIDs, int hostPID) CF_RETURNS_RETAINED;

CFArrayRef NPContractPublicWindowNumbers(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable NPContractOnscreenWindowNumbers(void) CF_RETURNS_RETAINED;
#ifdef NP_PRODUCT_CORNER_MATERIAL
CFDictionaryRef _Nonnull NPObserveProductCornerMaterial(CFStringRef _Nonnull nonce) CF_RETURNS_RETAINED;
#endif
