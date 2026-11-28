#import "scope_binding.h"
#import "patch_site.h"
#include <assert.h>
static void sidebarAndDesktopSite(void) {
    CGRect area = CGRectMake(1384, 780, 86, 176);
    NCListed row = {71382, 100, {1230, 33, 240, 923}, 1, 3};
    CGWindowLevel icons = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
    NCDock dock = {.pid = 101, .count = 1, .bars = {{0, 100, 72, 650}}};
    assert(nc_site_layer(&row, area, icons, &dock, true, true) == 0);
    assert(nc_site_layer(&row, area, icons, &dock, false, true) == NP_CORNER_SITE_OVERLAY);
    row.layer = icons; row.frame = (NCFrame){0, 0, 1470, 956};
    assert(nc_site_layer(&row, area, icons, &dock, false, false) == NP_CORNER_SITE_DESKTOP);
    row.frame = (NCFrame){1384, 780, 10, 8};
    assert(nc_site_layer(&row, area, icons, &dock, false, false) == 0);
    assert(nc_site_layer(&row, area, icons, &dock, false, true) == NP_CORNER_SITE_DESKTOP);
    row.frame = (NCFrame){0, 0, 1470, 956}; row.layer = 20; row.pid = dock.pid;
    assert(nc_site_layer(&row, area, icons, &dock, false, false) == 0);
    dock.bars[0] = (NCFrame){1360, 780, 110, 176};
    assert(nc_site_layer(&row, area, icons, &dock, false, false) == NP_CORNER_SITE_DOCK);
}
int main(void) {
    @autoreleasepool {
        sidebarAndDesktopSite();
        NSString *display = @"12345678-1234-1234-1234-123456789012",
                 *space = @"12345678-1234-1234-1234-123456789013";
        NSMutableDictionary *row = [@{
            @"Display Identifier" : @"Main",
            @"Current Space" : @{@"id64" : @91},
            @"Spaces" : @[
                @{@"id64" : @91,
                  @"type" : @0,
                  @"uuid" : space}
            ]
        } mutableCopy];
        NSMutableDictionary *f = [NSMutableDictionary dictionary];
        assert([nc_bound_scope(row, display, YES, 91, f)[@"display"] isEqual:display]);
        assert(!nc_bound_scope(row, display, NO, 91, f));
        assert(!nc_bound_scope(row, display, YES, 0, f));
        assert(!nc_bound_scope(row, display, YES, 92, f));
        row[@"Spaces"] = @[ @{@"id64" : @91, @"type" : @0} ];
        assert(!nc_bound_scope(row, display, YES, 91, f));
        assert([f[@"reason"] isEqual:@"currentOrdinaryUUIDUnavailableOrContradictory"]);
        row[@"Current Space"] = @{@"ManagedSpaceID" : @91, @"uuid" : space};
        assert([nc_bound_scope(row, display, YES, 91, f)[@"space"] isEqual:space]);
        row[@"Current Space"] = @{@"id64" : @91, @"ManagedSpaceID" : @92, @"uuid" : space};
        assert(!nc_bound_scope(row, display, YES, 91, f));
        row[@"Current Space"] = @{@"id64" : @91, @"uuid" : space};
        row[@"Spaces"] = @[ @{@"id64" : @91, @"type" : @4, @"uuid" : space} ];
        assert(!nc_bound_scope(row, display, YES, 91, f));
        row[@"Spaces"] = @[ @{@"id64" : @91, @"type" : @0, @"uuid" : display} ];
        assert(!nc_bound_scope(row, display, YES, 91, f));
        row[@"Spaces"] =
            @[ @{@"id64" : @91,
                 @"type" : @0,
                 @"uuid" : space},
               @{@"id64" : @91,
                 @"type" : @0,
                 @"uuid" : space} ];
        assert(!nc_bound_scope(row, display, YES, 91, f));
    }
    return 0;
}
