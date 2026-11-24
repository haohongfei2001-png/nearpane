// Exercise the production AppKit publication lifetime without opening a window or installing a tap.
#import "patch_sheet.h"
#import "nearpane_window_engine.h"
#include <assert.h>

@interface NSObject (NCSurfaceTest)
- (void)interrupt:(uint32_t)reason packet:(NSData *)packet;
@end

static void record(const void *context, uint32_t reason) {
    uint32_t *result = (uint32_t *)context;
    result[0]++;
    result[1] = reason;
}

void np_test_surface_interruption(void) {
    @autoreleasepool {
        uint32_t result[2] = {};
        void *material = np_corner_patch_material();
        void *handle = np_corner_patch_session(material, result, record);
        NSObject *session = (__bridge NSObject *)handle;
        NCParkedPatchMember member = {.member = {.window = 7}};
        np_corner_patch_publish(handle, &member, 1);
        NSData *old = [session valueForKey:@"latest"];
        member.member.window = 8;
        np_corner_patch_publish(handle, &member, 1);
        NSData *current = [session valueForKey:@"latest"];
        assert(old && current && old != current);
        [session interrupt:NP_CORNER_SITE_DOCK packet:old];
        assert(result[0] == 0);

        // An equal roster after an observation gap gets a fresh packet, even when
        // the main loop has not had the opportunity to expire the previous one.
        [session setValue:@0 forKey:@"validUntil"];
        np_corner_patch_publish(handle, &member, 1);
        NSData *renewed = [session valueForKey:@"latest"];
        assert(renewed && renewed != current);
        [session interrupt:NP_CORNER_PICTURE_CHANGED packet:current];
        assert(result[0] == 0);

        [session interrupt:NP_CORNER_SITE_OVERLAY packet:renewed];
        assert(result[0] == 1 && result[1] == NP_CORNER_SITE_OVERLAY);
        np_corner_patch_publish(handle, &member, 1);
        [session interrupt:NP_CORNER_SITE_DESKTOP packet:renewed];
        assert(result[0] == 1 && !np_corner_patch_verified(handle, &member));
        np_corner_patch_end(handle);
        [session interrupt:NP_CORNER_SITE_DOCK packet:renewed];
        assert(result[0] == 1);
        np_corner_patch_material_end(material);
    }
}
