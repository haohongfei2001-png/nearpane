// Independent read-only cleanup evidence for the disposable secondary desktop.
// clang -fobjc-arc -I Sources/CReadOnlySpaces/include scripts/acceptance/secondary-occupancy.m Sources/CReadOnlySpaces/ReadOnlySpaces.c -framework Foundation -framework CoreGraphics -framework ColorSync -o /tmp/nearpane-secondary-occupancy
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#import <unistd.h>
#import "ReadOnlySpaces.h"

static void need(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"Refusal" reason:message userInfo:nil];
}

static NSNumber *integer(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFNumberGetTypeID()
        || CFNumberIsFloatType((__bridge CFNumberRef)value)) return nil;
    return value;
}

static NSString *spaceID(id value) {
    NSNumber *n = integer(value);
    need(n && [n compare:@0] == NSOrderedDescending, @"invalid record number");
    return n.stringValue;
}

static NSString *displayUUID(CGDirectDisplayID d) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
    need(u != NULL, @"missing display UUID");
    NSString *s = CFBridgingRelease(CFUUIDCreateString(NULL, u));
    CFRelease(u);
    return s;
}

static NSDictionary *inventory(NSString *primary, NSString *secondary) {
    CGDirectDisplayID ids[3]; uint32_t count = 0;
    need(CGGetActiveDisplayList(3, ids, &count) == kCGErrorSuccess && count == 2 &&
         [displayUUID(CGMainDisplayID()) isEqual:primary] &&
         [(@[displayUUID(ids[0]),displayUUID(ids[1])]) containsObject:secondary] &&
         ![primary isEqual:secondary], @"display roles or active display count changed");
    NSArray *scopes = CFBridgingRelease(NPReadInventory());
    need(scopes.count == 2, @"two scopes required");
    NSMutableDictionary *state = [NSMutableDictionary new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSDictionary *scope in scopes) {
        NSString *d = scope[@"Display Identifier"];
        need(([d isEqual:primary] || [d isEqual:secondary]) && !state[d], @"unknown or duplicate scope");
        NSString *current = spaceID(scope[@"Current Space"][@"id64"]);
        NSMutableArray *order = [NSMutableArray new], *types = [NSMutableArray new];
        for (NSDictionary *row in scope[@"Spaces"]) {
            NSString *sid = spaceID(row[@"id64"]);
            NSNumber *type = integer(row[@"type"]);
            need(type && ![seen containsObject:sid], @"unknown type or duplicate Space number");
            [seen addObject:sid]; [order addObject:sid]; [types addObject:type];
        }
        need([order containsObject:current], @"current not in scope");
        state[d] = @{@"current":current, @"order":order, @"types":types};
    }
    return state;
}

static NSSet *windowNumbers(CGWindowListOption option) {
    CFArrayRef list = CGWindowListCreate(option, kCGNullWindowID);
    need(list != NULL, @"Quartz number list unavailable");
    NSMutableSet *numbers = [NSMutableSet new];
    @try {
        CFIndex count = CFArrayGetCount(list);
        need(count > 0 && count <= 8192, @"empty or unbounded Quartz window inventory");
        for (CFIndex i = 0; i < count; ++i) {
            uintptr_t raw = (uintptr_t)CFArrayGetValueAtIndex(list, i);
            need(raw && raw <= UINT32_MAX && ![numbers containsObject:@(raw)], @"unexpected Quartz number encoding");
            [numbers addObject:@(raw)];
        }
    } @finally { CFRelease(list); }
    return numbers;
}

static NSDictionary *sample(NSString *primary, NSString *secondary, NSString *primaryCurrent, NSString *source, NSString *target) {
    NSDictionary *scopes = inventory(primary, secondary);
    need([scopes[primary][@"current"] isEqual:primaryCurrent] && [scopes[secondary][@"current"] isEqual:source],
         @"primary or secondary current changed");
    NSArray *order = scopes[secondary][@"order"], *types = scopes[secondary][@"types"];
    NSUInteger a = [order indexOfObject:source];
    need(a != NSNotFound && [types[a] isEqual:@0], @"source is not ordinary");
    if (target) {
        NSUInteger b = [order indexOfObject:target];
        need(b != NSNotFound && [types[b] isEqual:@0] && labs((long)b-(long)a) == 1,
             @"target not an inactive adjacent ordinary secondary record");
    }
    NSMutableSet *scopeRecords = [NSMutableSet setWithArray:scopes[primary][@"order"]];
    [scopeRecords addObjectsFromArray:order];
    NSSet *all = windowNumbers(kCGWindowListOptionAll);
    NSSet *nonDesktop = windowNumbers(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements);
    need([nonDesktop isSubsetOfSet:all], @"Quartz window inventory changed");
    NSMutableDictionary *memberships = [NSMutableDictionary new];
    NSUInteger unknown = 0, unknownNonDesktop = 0, targetCount = 0, sharedTarget = 0, targetNonDesktop = 0, multi = 0;
    for (NSNumber *wid in all) {
        NSArray *values = CFBridgingRelease(NPReadWindowSpaces(wid.unsignedIntValue));
        NSMutableSet *members = [NSMutableSet new];
        BOOL complete = values.count > 0 && values.count <= scopeRecords.count;
        for (id n in values) {
            NSNumber *valid = integer(n);
            NSString *sid = valid.stringValue;
            if (!valid || ![scopeRecords containsObject:sid] || [members containsObject:sid]) { complete = NO; break; }
            [members addObject:sid];
        }
        if (!complete) {
            ++unknown;
            if ([nonDesktop containsObject:wid]) ++unknownNonDesktop;
            memberships[wid] = NSNull.null;
        } else {
            memberships[wid] = members;
            if (members.count > 1) ++multi;
            if (target && [members containsObject:target]) {
                ++targetCount;
                if ([nonDesktop containsObject:wid]) ++targetNonDesktop;
                if (members.count > 1) ++sharedTarget;
            }
        }
    }
    need([windowNumbers(kCGWindowListOptionAll) isEqual:all] &&
         [windowNumbers(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements) isEqual:nonDesktop] &&
         [inventory(primary, secondary) isEqual:scopes], @"window or Space inventory changed during read");
    NSDictionary *counts = @{@"allWindowCount":@(all.count), @"nonDesktopElementCount":@(nonDesktop.count),
                             @"unknownMembershipCount":@(unknown), @"unknownNonDesktopCount":@(unknownNonDesktop),
                             @"multiSpaceCount":@(multi), @"targetCount":target ? @(targetCount) : NSNull.null,
                             @"sharedTargetCount":target ? @(sharedTarget) : NSNull.null, @"targetNonDesktopCount":target ? @(targetNonDesktop) : NSNull.null,
                             @"knownMembershipNonDesktopCount":@(nonDesktop.count - unknownNonDesktop)};
    return @{@"counts":counts, @"scopes":scopes, @"memberships":memberships, @"nonDesktop":nonDesktop};
}

static void emit(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
}

int main(int argc, const char **argv) { @autoreleasepool {
    @try {
        need(argc == 5 || argc == 6, @"usage: secondary-occupancy PRIMARY_UUID SECONDARY_UUID PRIMARY_CURRENT SOURCE_A [ADDED_B]");
        NSString *p = @(argv[1]), *s = @(argv[2]), *pc = @(argv[3]), *a = @(argv[4]), *b = argc == 6 ? @(argv[5]) : nil;
        need(NPReadOnlySpacesOpen() == 1, @"unsupported OS build or Reader path unavailable");
        NSDictionary *first = sample(p,s,pc,a,b);
        usleep(300000);
        NSDictionary *second = sample(p,s,pc,a,b);
        need([first isEqual:second], @"consecutive window membership or scope maps differ");
        NSDictionary *c = second[@"counts"];
        BOOL complete = [c[@"unknownMembershipCount"] unsignedIntegerValue] == 0;
        BOOL clear = b && complete && [c[@"targetCount"] unsignedIntegerValue] == 0;
        NSMutableDictionary *r = [c mutableCopy];
        [r addEntriesFromDictionary:@{@"primary":p, @"secondary":s, @"primaryCurrent":pc, @"source":a,
             @"target":b ?: NSNull.null, @"scopeSamples":@2, @"membershipComplete":@(complete),
             @"occupancy":b ? (clear ? @"OBSERVED_EMPTY" : @"REFUSED") : (complete ? @"BASELINE_COMPLETE" : @"BASELINE_INCOMPLETE"),
             @"ordinaryUserWindowCount":NSNull.null, @"deletionAuthorized":@NO}];
        emit(r);
        return (b ? clear : complete) ? 0 : 2;
    } @catch (NSException *error) {
        emit(@{@"occupancy":@"REFUSED", @"reason":error.reason ?: @"invalid evidence", @"deletionAuthorized":@NO});
        return 2;
    }
}}
