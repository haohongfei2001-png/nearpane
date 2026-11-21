// Exercise the linked Engine's production readers. This observer owns no Host,
// panel or window. Stable display and desktop UUIDs stay inside this process.
#import <Foundation/Foundation.h>
#import "platform.h"

static NSNumber *alias(const uint8_t bytes[16], NSMutableDictionary *aliases) {
    NSData *key = [NSData dataWithBytes:bytes length:16];
    if (!aliases[key]) aliases[key] = @(aliases.count + 1);
    return aliases[key];
}

int main(void) {
    @autoreleasepool {
        NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
        NSMutableArray *reads = [NSMutableArray array];
        int connection = np_stage_connection();
        BOOL valid = connection > 0;
        for (int index = 0; index < 2; index++) {
            NPStageDesktop desktops[512];
            uint64_t spaces[1024], checked[1024];
            double start = NSProcessInfo.processInfo.systemUptime;
            int n = np_stage_desktops(connection, desktops, 512);
            int count = np_stage_all_spaces(connection, spaces, 1024);
            int checkedCount = np_stage_checked_inventory(connection, checked, 1024);
            NSMutableArray *managed = [NSMutableArray array], *all = [NSMutableArray array];
            for (int j = 0; j < count; j++) [all addObject:@(spaces[j])];
            for (int j = 0; j < n; j++) {
                NPStageDesktop d = desktops[j];
                valid = valid && [all containsObject:@(d.id)];
                [managed addObject:@{@"displayAlias":alias(d.display, aliases), @"spaceAlias":alias(d.uuid, aliases),
                                     @"id":@(d.id), @"kind":@(d.kind), @"current":@(d.current)}];
            }
            [all sortUsingSelector:@selector(compare:)];
            valid = valid && np_stage_connection() == connection && n > 0 && count > 0 && count == checkedCount;
            for (int j = 0; valid && j < checkedCount; j++) valid = [all[j] isEqual:@(checked[j])];
            [reads addObject:@{@"startedUptime":@(start), @"endedUptime":@(NSProcessInfo.processInfo.systemUptime),
                               @"managedReturn":@(n), @"allSpacesReturn":@(count), @"checkedReturn":@(checkedCount),
                               @"distinctIDs":@([NSSet setWithArray:all].count), @"managed":managed, @"all":all}];
            if (!index) [NSThread sleepForTimeInterval:0.12];
        }
        valid = valid && [reads[0][@"all"] isEqual:reads[1][@"all"]] && [reads[0][@"managed"] isEqual:reads[1][@"managed"]];
        NSDictionary *result = @{@"scope":@"linkedEngineInventoryOutsideHost", @"status":valid ? @"PASS" : @"UNKNOWN",
            @"targetBuildAndSIP":@(np_stage_target_build()), @"samples":reads, @"windowWrites":@0, @"spaceWrites":@0,
            @"formalHostCanary":@"NOT_RUN", @"missionControlUI":@"NOT_RUN", @"productionQualified":@NO};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length) return 3;
        puts("");
        return valid ? 0 : 2;
    }
}
