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
void *np_corner_patch_material(void);
void np_corner_patch_material_end(void *material);
void *np_corner_patch_session(void *material);
void np_corner_patch_publish(void *session, const NCParkedPatchMember *members, uint32_t count);
bool np_corner_patch_verified(void *session, const NCParkedPatchMember *member);
bool np_corner_patch_source_available(const uint8_t display[16], NCFrame zone);
uint32_t np_corner_patch_prepare_source(void *material, const NCMember *home, NCFrame footprint, bool prepare);
void np_corner_patch_end(void *session);
