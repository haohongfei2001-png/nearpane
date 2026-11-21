#pragma once
#import <AppKit/AppKit.h>
#import "macos.h"

typedef struct {
    NCMember member;
    NCFrame frame;
} NCParkedPatchMember;
// Private to the linked Corner engine. No entry point changes a third-party window.
bool np_corner_patch_bounds(const NCFrame *, uint32_t count, NCFrame display, NCFrame *out);
bool np_corner_patch_order(const NCListed *, uint32_t length, const uint32_t *, uint32_t count, uint32_t panel,
                           uint32_t above, NCFrame, bool planned);
uint32_t np_corner_patch_visible(const uint32_t *ids, uint32_t count, const uint8_t display[16], NCFrame frame);
void *np_corner_patch_session(void);
void np_corner_patch_publish(void *session, const NCParkedPatchMember *members, uint32_t count);
void np_corner_patch_end(void *session);
