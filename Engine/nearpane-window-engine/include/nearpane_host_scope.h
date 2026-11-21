#ifndef NEARPANE_HOST_SCOPE_H
#define NEARPANE_HOST_SCOPE_H
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Metadata-only diagnostics. A copied collection belongs to the caller. Each getter
 * rechecks the existing WindowServer connection. Zero hits is distinct from an error. */
enum {
    NP_SCOPE_OK = 0,
    NP_SCOPE_NO_SYMBOL = 1,
    NP_SCOPE_CONNECTION = 2,
    NP_SCOPE_ARGUMENT = 3,
    NP_SCOPE_NO_REPLY = 4,
    NP_SCOPE_SHAPE = 5
};
CFArrayRef _Nullable np_host_scope_copy_managed(int32_t *_Nonnull connection,
                                                int32_t *_Nonnull error) CF_RETURNS_RETAINED;
uint64_t np_host_scope_direct(int32_t connection, CFStringRef _Nonnull display, int32_t *_Nonnull error);
CFArrayRef _Nullable np_host_scope_reverse(int32_t connection, uint32_t window,
                                           int32_t *_Nonnull error) CF_RETURNS_RETAINED;
int32_t np_host_scope_forward_hits(int32_t connection, uint64_t space, uint32_t window,
                                   int32_t *_Nonnull error);
#ifdef __cplusplus
}
#endif
#endif
#endif
