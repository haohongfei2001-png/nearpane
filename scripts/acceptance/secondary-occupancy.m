// Independent read-only cleanup evidence for the disposable secondary desktop.
// clang -fobjc-arc -I Sources/CReadOnlySpaces/include scripts/acceptance/secondary-occupancy.m Sources/CReadOnlySpaces/ReadOnlySpaces.c -framework Foundation -framework CoreGraphics -framework ColorSync -o /tmp/nearpane-secondary-occupancy
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#import <unistd.h>
#import <dlfcn.h>
#import <libproc.h>
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
    need(CGGetActiveDisplayList(3, ids, &count) == kCGErrorSuccess && count > 0 && count <= 2,
         @"unsupported active display count");
    NSMutableSet *active = [NSMutableSet new];
    for (uint32_t index = 0; index < count; index++) {
        need(!CGDisplayIsInMirrorSet(ids[index]), @"mirrored display");
        [active addObject:displayUUID(ids[index])];
    }
    need(active.count == count && [active containsObject:secondary], @"display UUID no longer active");
    if (primary) need(count == 2 && [displayUUID(CGMainDisplayID()) isEqual:primary] &&
                      ![primary isEqual:secondary], @"protected display changed");
    NSArray *scopes = CFBridgingRelease(NPReadInventory());
    need(scopes.count == count, @"physical displays and scope inventory differ");
    NSMutableDictionary *state = [NSMutableDictionary new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSDictionary *scope in scopes) {
        NSString *d = scope[@"Display Identifier"];
        need([active containsObject:d] && !state[d], @"unknown or duplicate scope");
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

// Read-only lab ABI used by Hammerspoon's windowsForSpace (libspaces.m). Never
// resolved unless the existing NPReadOnlySpacesOpen() admits this exact OS build.
// Option 7 includes minimized and offscreen windows; option 2 provides a subset check.
static NSSet<NSNumber *> *windowsInSpace(NSString *sid, uint32_t options) {
    typedef CFArrayRef (*CopyWindows)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
    static CopyWindows copyWindows;
    static int connection;
    if (!copyWindows) {
        void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
        need(lib != NULL, @"Space reader unavailable");
        int (*connect)(void) = dlsym(lib, "SLSMainConnectionID");
        copyWindows = dlsym(lib, "SLSCopyWindowsWithOptionsAndTags");
        need(copyWindows && connect, @"per-Space read unavailable");
        connection = connect();
    }
    need(connection > 0, @"WindowServer connection unavailable");
    uint64_t setTags = 0, clearTags = 0;
    NSArray *request = @[@(strtoull(sid.UTF8String, NULL, 10))];
    NSArray *found = CFBridgingRelease(copyWindows(connection, 0, (__bridge CFArrayRef)request, options, &setTags, &clearTags));
    need([found isKindOfClass:NSArray.class] && found.count <= 8192, @"missing or invalid per-Space read");
    NSMutableSet *items = [NSMutableSet new];
    for (id raw in found) {
        NSNumber *wid = integer(raw);
        need(wid && [wid compare:@0] == NSOrderedDescending && wid.unsignedLongLongValue <= UINT32_MAX &&
             ![items containsObject:wid], @"invalid per-Space window number");
        [items addObject:wid];
    }
    return items;
}

static NSDictionary *classifyTargetWindows(NSSet *targetIDs, NSSet *all, NSSet *nonDesktop,
                                           NSArray *order, NSDictionary *reverse, NSDictionary *membership) {
    NSMutableSet *desktop = [NSMutableSet new], *shared = [NSMutableSet new], *blocking = [NSMutableSet new];
    for (NSNumber *wid in targetIDs) {
        // Exemption is positive in both public lists. Absence alone does not classify a window.
        if ([all containsObject:wid] && ![nonDesktop containsObject:wid]) {
            [desktop addObject:wid];
            continue;
        }
        // Every Space of this secondary has the same window in both directions.
        // The window already resides in A; it does not need to be moved there.
        BOOL onEverySecondary = [all containsObject:wid] && [nonDesktop containsObject:wid] &&
                                 [[NSSet setWithArray:order] isSubsetOfSet:membership[wid] ?: [NSSet set]];
        for (NSString *sid in order) onEverySecondary &= [reverse[sid] containsObject:wid];
        [(onEverySecondary ? shared : blocking) addObject:wid];
    }
    return @{@"desktop":desktop, @"shared":shared, @"blocking":blocking};
}

// Quartz can describe an inactive or suppressed window by its exact numeric ID even when
// kCGWindowListOptionIncludingWindow does not enumerate it. Keep owner metadata in memory.
static NSDictionary *exactWindowOwner(NSNumber *number) {
    const void *id = (const void *)(uintptr_t)number.unsignedIntValue;
    CFArrayRef ids = CFArrayCreate(NULL, &id, 1, NULL);
    if (!ids) return nil;
    NSArray *rows = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(ids));
    CFRelease(ids);
    if (rows.count != 1 || ![rows[0][(__bridge NSString *)kCGWindowNumber] isEqual:number]) return nil;
    pid_t owner = [rows[0][(__bridge NSString *)kCGWindowOwnerPID] intValue];
    struct proc_bsdinfo info = {0};
    if (owner <= 0 || proc_pidinfo(owner, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return nil;
    return @{@"pid":@(owner), @"birthSeconds":@(info.pbi_start_tvsec), @"birthUsec":@(info.pbi_start_tvusec)};
}

static BOOL verifiedOnAllDesktopRecords(NSSet *records, NSNumber *number, NSDictionary *membership, NSDictionary *reverse) {
    if (!records.count || ![records isSubsetOfSet:membership[number] ?: [NSSet set]]) return NO;
    for (NSString *sid in records) if (![reverse[sid] containsObject:number]) return NO;
    return YES;
}

// Return only the facts relevant to an enrolled A witness and to B. Transient objects
// on other displays or outside both queries do not decide whether removing B moves a window.
static NSDictionary *scopedSample(NSString *p, NSString *s, NSString *pc, NSString *a, NSString *b,
                                  pid_t pid, NSNumber *anchor) {
    NSDictionary *scopes = inventory(p, s);
    NSArray *order = scopes[s][@"order"], *types = scopes[s][@"types"];
    NSUInteger ai = [order indexOfObject:a], bi = b ? [order indexOfObject:b] : NSNotFound;
    need((!p || [scopes[p][@"current"] isEqual:pc]) && [scopes[s][@"current"] isEqual:a] &&
         ai != NSNotFound && [types[ai] isEqual:@0], @"enrolled primary current and ordinary secondary source required");
    if (b) need(bi != NSNotFound && [types[bi] isEqual:@0] && labs((long)ai - (long)bi) == 1,
                @"target must be a distinct inactive adjacent ordinary desktop");

    struct proc_bsdinfo process = {0};
    if (anchor) {
        need(pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) == sizeof(process)
             && process.pbi_uid == getuid(), @"missing witness process identity");
        NSArray *record = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, anchor.unsignedIntValue));
        need(record.count == 1 && [record[0][(__bridge NSString *)kCGWindowNumber] isEqual:anchor] &&
             [record[0][(__bridge NSString *)kCGWindowOwnerPID] intValue] == pid &&
             [record[0][(__bridge NSString *)kCGWindowLayer] isEqual:@0], @"enrolled ordinary witness owner/number changed");
    }
    NSSet *all = windowNumbers(kCGWindowListOptionAll);
    NSSet *nonDesktop = windowNumbers(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements);
    if (anchor) need([nonDesktop containsObject:anchor] && [all containsObject:anchor], @"A witness missing in Quartz");
    NSMutableSet *sids = [NSMutableSet new];
    for (NSDictionary *scope in scopes.allValues) [sids addObjectsFromArray:scope[@"order"]];
    NSMutableDictionary<NSString *,NSSet *> *reverse = [NSMutableDictionary new];
    for (NSString *sid in sids) {
        NSSet *items = windowsInSpace(sid, 7);
        need([windowsInSpace(sid, 2) isSubsetOfSet:items], @"inconsistent per-Space coverage");
        if (anchor) need([items containsObject:anchor] == [a isEqual:sid], @"A witness not exclusively in A in per-Space read");
        reverse[sid] = items;
    }
    NSMutableSet *targetIDs = b ? [reverse[b] mutableCopy] : [NSMutableSet new];
    NSMutableDictionary *membership = [NSMutableDictionary new];
    NSMutableSet *inspect = [all mutableCopy];
    if (!p) [inspect unionSet:targetIDs];
    for (NSNumber *wid in inspect) {
        NSArray *raw = CFBridgingRelease(NPReadWindowSpaces(wid.unsignedIntValue));
        if (![raw isKindOfClass:NSArray.class]) continue;
        NSMutableSet *set = [NSMutableSet new];
        for (id row in raw) {
            NSString *sid = spaceID(row);
            [set addObject:sid];
        }
        if ([anchor isEqual:wid]) need([set isEqual:[NSSet setWithObject:a]], @"A witness forward membership mismatch");
        if (b && [set containsObject:b]) [targetIDs addObject:wid];
        if ([targetIDs containsObject:wid] || [anchor isEqual:wid]) membership[wid] = set;
    }
    if (anchor) need([membership[anchor] isEqual:[NSSet setWithObject:a]], @"A witness forward read unavailable");
    NSDictionary *classified = classifyTargetWindows(targetIDs, all, nonDesktop, order, reverse, membership);
    NSMutableDictionary *verifiedOwners = [NSMutableDictionary new];
    if (!p && b) {
        // Existing B is still required to have zero shared non-desktop objects. Only a
        // caller with its own creation receipt may use the no-relocation verdict for B.
        NSMutableSet *blocking = [classified[@"blocking"] mutableCopy];
        NSMutableSet *shared = [classified[@"shared"] mutableCopy];
        NSMutableSet *other = [blocking mutableCopy];
        [other unionSet:shared];
        NSSet *records = [NSSet setWithArray:order];
        for (NSNumber *number in other) {
            NSDictionary *owner = exactWindowOwner(number);
            if (owner && verifiedOnAllDesktopRecords(records, number, membership, reverse)) {
                verifiedOwners[number] = owner;
                [shared addObject:number];
                [blocking removeObject:number];
            } else {
                [blocking addObject:number];
                [shared removeObject:number];
            }
        }
        classified = @{@"desktop":classified[@"desktop"], @"blocking":blocking, @"shared":shared};
    }
    need([inventory(p,s) isEqual:scopes], @"desktop arrangement changed during occupancy observation");
    NSMutableDictionary *sample = [classified mutableCopy];
    sample[@"scopes"] = scopes;
    sample[@"corroboratedOwners"] = verifiedOwners;
    sample[@"pidStartSeconds"] = @(process.pbi_start_tvsec);
    sample[@"pidStartUsec"] = @(process.pbi_start_tvusec);
    return sample;
}

static void emit(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
}

int main(int argc, const char **argv) { @autoreleasepool {
    @try {
        BOOL candidate = argc > 1 && strcmp(argv[1], "--candidate-current") == 0;
        BOOL enrolled = argc > 1 && strcmp(argv[1], "--scoped-current") == 0;
        BOOL removal = argc > 1 && strcmp(argv[1], "--removal-current") == 0;
        if (candidate || enrolled || removal) {
            need((candidate && argc == 5) || (enrolled && (argc == 6 || argc == 7)) || (removal && argc == 7),
                 @"expected [PID WID] DISPLAY A [B]");
            need(NPReadOnlySpacesOpen() == 1, @"unsupported OS build or Reader unavailable");
            int offset = candidate ? 2 : 4;
            NSString *display = @(argv[offset]), *a = @(argv[offset + 1]), *b = argc > offset + 2 ? @(argv[offset + 2]) : nil;
            pid_t pid = 0;
            NSNumber *window = nil;
            if (!candidate) {
                long long owner = [@(argv[2]) longLongValue], number = [@(argv[3]) longLongValue];
                need(owner > 0 && owner <= INT32_MAX && number > 0 && number <= UINT32_MAX &&
                     [@(owner).stringValue isEqual:@(argv[2])] && [@(number).stringValue isEqual:@(argv[3])],
                     @"invalid enrolled process or window number");
                pid = (pid_t)owner;
                window = @(number);
            }
            NSDictionary *first = scopedSample(nil, display, nil, a, b, pid, window);
            usleep(220000);
            NSDictionary *second = scopedSample(nil, display, nil, a, b, pid, window);
            need([first isEqual:second], @"target occupancy, witness generation or arrangement changed");
            NSUInteger blocking = [second[@"blocking"] count], shared = [second[@"shared"] count];
            BOOL clear = blocking == 0 && (removal || shared == 0);
            NSString *result = !b ? @"SOURCE_WITNESSED" : (removal ? @"NO_RELOCATION_OBSERVED" : @"OBSERVED_EMPTY");
            emit(@{@"occupancy": clear ? result : @"REFUSED", @"display":display,
                   @"source":a, @"target":b ?: NSNull.null, @"scopeSamples":@2, @"scopeCount":@([second[@"scopes"] count]),
                   @"desktopElements":@([second[@"desktop"] count]), @"blockingWindows":@(blocking),
                   @"corroboratedShared":@(shared), @"sourcePID":@(pid), @"sourceWindow":window ?: NSNull.null,
                   @"systemInputs":@0, @"deletionAuthorized":@NO});
            return clear ? 0 : 2;
        }
        if (argc > 1 && strcmp(argv[1], "--scoped") == 0) {
            need(argc == 8 || argc == 9, @"expected --scoped A_PID A_WINDOW PRIMARY_UUID SECONDARY_UUID PRIMARY_CURRENT A [B]");
            need(NPReadOnlySpacesOpen() == 1, @"unsupported OS build or Reader unavailable");
            NSString *p = @(argv[4]), *s = @(argv[5]), *pc = @(argv[6]), *a = @(argv[7]), *b = argc == 9 ? @(argv[8]) : nil;
            long long pid = [@(argv[2]) longLongValue], wid = [@(argv[3]) longLongValue];
            need(pid > 0 && pid <= INT32_MAX && wid > 0 && wid <= UINT32_MAX &&
                 [@(pid).stringValue isEqual:@(argv[2])] && [@(wid).stringValue isEqual:@(argv[3])], @"invalid enrolled process or window number");
            NSDictionary *first = scopedSample(p,s,pc,a,b,(pid_t)pid,@(wid));
            usleep(200000);
            NSDictionary *second = scopedSample(p,s,pc,a,b,(pid_t)pid,@(wid));
            need([first isEqual:second], @"target occupancy, witness generation or arrangement changed");
            BOOL clear = [second[@"blocking"] count] == 0;
            emit(@{@"occupancy":b ? (clear ? @"NO_RELOCATION_OBSERVED" : @"REFUSED") : @"SOURCE_WITNESSED",
                   @"source":a, @"target":b ?: NSNull.null, @"primary":p, @"secondary":s, @"primaryCurrent":pc,
                   @"sourcePID":@(pid), @"sourceWindow":@(wid), @"sourceBirthSeconds":second[@"pidStartSeconds"],
                   @"sourceBirthMicroseconds":second[@"pidStartUsec"], @"scopeSamples":@2,
                   @"desktopElements":@([second[@"desktop"] count]), @"corroboratedShared":@([second[@"shared"] count]),
                   @"blockingWindows":@([second[@"blocking"] count]), @"deletionAuthorized":@NO,
                   @"sampledUptime":@(NSProcessInfo.processInfo.systemUptime)});
            return clear ? 0 : 2;
        }
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
