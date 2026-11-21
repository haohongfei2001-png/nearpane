// Decode only native numbers, the declared category, and UUIDs. A missing ordinary UUID is never synthesized.
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
static inline NSNumber *nc_integer(id n) {
    if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID() ||
        !strchr("csilqCSILQ", *[n objCType]) || [n longLongValue] < 0)
        return nil;
    return n;
}
static inline NSNumber *nc_space_number(NSDictionary *row) {
    id a = nc_integer(row[@"id64"]), b = nc_integer(row[@"ManagedSpaceID"]);
    if ((row[@"id64"] && !a) || (row[@"ManagedSpaceID"] && !b) || (a && b && ![a isEqual:b]))
        return nil;
    NSNumber *n = a ?: b;
    return n.unsignedLongLongValue > 0 ? n : nil;
}
static inline NSUUID *nc_uuid(id value) {
    if (![value isKindOfClass:NSString.class])
        return nil;
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:value];
    return [u.UUIDString isEqual:@"00000000-0000-0000-0000-000000000000"] ? nil : u;
}
static inline uint64_t nc_direct_home(int connection, NSString *token) {
    typedef uint64_t (*Read)(int, CFStringRef);
    static Read read;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *library =
          dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
      if (library)
          read = (Read)dlsym(library, "SLSManagedDisplayGetCurrentSpace");
    });
    return read && connection > 0 && ([token isEqual:@"Main"] || nc_uuid(token))
               ? read(connection, (__bridge CFStringRef)token)
               : 0;
}
static inline NSDictionary *nc_bound_scope(NSDictionary *row, NSString *physicalUUID, BOOL onlyMain,
                                           uint64_t direct, NSMutableDictionary *facts) {
    NSString *token = row[@"Display Identifier"];
    NSUUID *display = nc_uuid(physicalUUID), *rawDisplay = nc_uuid(token);
    BOOL alias = [token isEqual:@"Main"],
         displayMatch = display && ([display isEqual:rawDisplay] || (alias && onlyMain));
    NSDictionary *current = [row[@"Current Space"] isKindOfClass:NSDictionary.class] ? row[@"Current Space"] : @{};
    NSArray *records = [row[@"Spaces"] isKindOfClass:NSArray.class] ? row[@"Spaces"] : @[];
    NSNumber *home = nc_space_number(current);
    NSUInteger hits = 0, ordinary = 0, ordinaryUUIDs = 0;
    NSDictionary *matched = nil;
    for (id object in records) {
        if (![object isKindOfClass:NSDictionary.class])
            continue;
        if ([nc_integer(object[@"type"]) isEqual:@0]) {
            ordinary++;
            if (nc_uuid(object[@"uuid"]))
                ordinaryUUIDs++;
        }
        if (home && [nc_space_number(object) isEqual:home]) {
            hits++;
            matched = object;
        }
    }
    NSUUID *entry = nc_uuid(matched[@"uuid"]), *currentUUID = nc_uuid(current[@"uuid"]);
    NSNumber *type = nc_integer(matched[@"type"]), *currentType = nc_integer(current[@"type"]);
    [facts addEntriesFromDictionary:@{
        @"displayToken" : alias ? @"Main"
        : rawDisplay            ? @"uuid"
                                : @"missingOrOther",
        @"physicalDisplayUUID" : display.UUIDString ?: [NSNull null],
        @"singleCGMainDisplay" : @(onlyMain),
        @"currentID64" : nc_integer(current[@"id64"]) ?: [NSNull null],
        @"currentManagedID" : nc_integer(current[@"ManagedSpaceID"]) ?: [NSNull null],
        @"directWindowServerHome" : @(direct),
        @"currentUUID" : currentUUID.UUIDString ?: [NSNull null],
        @"matchedUUID" : entry.UUIDString ?: [NSNull null],
        @"currentType" : currentType ?: [NSNull null],
        @"matchedType" : type ?: [NSNull null],
        @"matchedRecords" : @(hits),
        @"ordinaryCount" : @(ordinary),
        @"ordinaryWithUUIDCount" : @(ordinaryUUIDs),
        @"recordCount" : @(records.count)
    }];
    NSString *why = nil;
    if (!displayMatch)
        why = @"managedAndPhysicalDisplayIdentityUnconfirmed";
    else if (!home)
        why = @"currentRecordIDUnavailableOrContradictory";
    else if (!records.count || records.count > 256 || hits != 1)
        why = @"currentRecordAbsentOrDuplicatedInRoster";
    else if (![type isEqual:@0] || (current[@"type"] && ![type isEqual:currentType]))
        why = @"currentRecordNotConfirmedOrdinary";
    else if ((!entry && !currentUUID) || (matched[@"uuid"] && !entry) || (current[@"uuid"] && !currentUUID) ||
             (entry && currentUUID && ![entry isEqual:currentUUID]))
        why = @"currentOrdinaryUUIDUnavailableOrContradictory";
    else if (direct && direct != home.unsignedLongLongValue)
        why = @"independentCurrentSpaceDisagrees";
    else if ((alias || !current[@"id64"] || !matched[@"id64"] || !entry) && !direct)
        why = @"independentCurrentSpaceUnavailable";
    facts[@"reason"] = why ?: @"confirmed";
    return why ? nil : @{
        @"native" : home,
        @"space" : (entry ?: currentUUID).UUIDString,
        @"display" : display.UUIDString
    };
}
