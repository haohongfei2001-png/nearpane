#import "scope_binding.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
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
