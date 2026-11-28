// Guardian-internal. The AX reference belongs to this process and never crosses IPC or the Swift ABI.
#pragma once
#import "../../../include/nearpane_guardian_observation.h"
int32_t ncg_observe_retained(int32_t pid, uint64_t start, uint32_t window, CFStringRef executable,
                             CFStringRef cdhash, uint64_t native, CFStringRef display, CFStringRef space,
                             CFTypeRef original, NPGuardianFixtureObservation *out);
