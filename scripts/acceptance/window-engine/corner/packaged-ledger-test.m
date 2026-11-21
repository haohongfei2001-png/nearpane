// Exercises the shipping ledger parser in a newly created disposable directory, without a
// native application, WindowServer, signing identity, real profile or AX call.
#define main ncg_unused_product_main
#import "guardian/main.m"
#undef main
#include <assert.h>
static uint8_t accepted[16];
bool np_engine_evidence_is_reviewed(uint32_t backend, const uint8_t *evidence) {
    return backend == NP_CORNER && !memcmp(accepted, evidence, 16);
}
static void put(NSString *dir, NSString *name, id json) {
    NSData *b = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    assert(b);
    assert([b writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]);
}
static NSString *newID(uint8_t bytes[16]) {
    NSUUID *u = NSUUID.UUID;
    [u getUUIDBytes:bytes];
    return u.UUIDString;
}
static void inspectEnvelopeChecks(void) {
    NSMutableDictionary *request = [@{
        @"schema" : @1, @"challenge" : NSUUID.UUID.UUIDString, @"issued" : @100, @"hostPID" : @32,
        @"hostBirth" : @41, @"hostHash" : @"originalHost", @"childPID" : @48, @"childBirth" : @51,
        @"childHash" : @"originalGuardian", @"window" : @{@"pid" : @61, @"birth" : @71, @"number" : @81},
        @"fixtureHash" : [@"0" stringByPaddingToLength:40 withString:@"0" startingAtIndex:0], @"executable" : @"/test-fixture"
    } mutableCopy];
    assert(diagnosticEnvelope(request, 112));
    assert(!diagnosticEnvelope(request, 99));
    assert(!diagnosticEnvelope(request, UINT64_C(6000000101)));
    request[@"phase"] = @"prepare";
    assert(!diagnosticEnvelope(request, 112));
    [request removeObjectForKey:@"phase"];
    request[@"display"] = NSUUID.UUID.UUIDString;
    assert(!diagnosticEnvelope(request, 112));
    request[@"space"] = NSUUID.UUID.UUIDString;
    request[@"nativeID"] = @1;
    assert(diagnosticEnvelope(request, 112));
    NSDictionary *window = request[@"window"];
    request[@"window"] = @{@"pid" : @61, @"birth" : @71, @"number" : @(UINT64_C(4294967297))};
    assert(!diagnosticEnvelope(request, 112));
    request[@"window"] = @{@"pid" : @61, @"birth" : @71, @"number" : @YES};
    assert(!diagnosticEnvelope(request, 112));
    request[@"window"] = window;
    request[@"nativeID"] = @(-1);
    assert(!diagnosticEnvelope(request, 112));
}
int main(void) {
    @autoreleasepool {
        inspectEnvelopeChecks();
        char scratch[] = "/private/tmp/nearpane-guardian-ledger.XXXXXXXX";
        assert(mkdtemp(scratch));
        NSString *base = [NSFileManager.defaultManager stringWithFileSystemRepresentation:scratch
                                                                                   length:strlen(scratch)];
        NSString *root = [base stringByAppendingPathComponent:@"Nearpane Alpha Profiles"],
                 *gen = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *profile =
            [root stringByAppendingPathComponent:[NSString stringWithFormat:@"generations/%@/Nearpane", gen]];
        NSString *journal = @"stage-visibility-v1.json";
        Session s = {
            .dir = -1, .ledger = -1, .kqueue = -1, .profile = -1, .root = -1, .writer = -1, .serializer = -1};
        NPRequest *r = &s.pre.lease;
        NSString *intent = newID(r->intent), *group = newID(r->group), *member = newID(r->member),
                 *generation = newID(r->generation), *life = newID(r->lifetime), *screen = newID(r->display),
                 *space = newID(r->native_space), *evidence = newID(accepted);
        NSString *jobs = [profile stringByAppendingPathComponent:@".corner-guardians"],
                 *job = [jobs stringByAppendingPathComponent:intent.lowercaseString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:job
                                       withIntermediateDirectories:YES
                                                        attributes:@{
                                                            NSFilePosixPermissions : @0700
                                                        }
                                                             error:NULL]);
        int hostlock = open([root stringByAppendingPathComponent:@"writer.lock"].fileSystemRepresentation,
                            O_CREAT | O_EXCL | O_RDWR, 0600);
        assert(hostlock >= 0 && flock(hostlock, LOCK_EX | LOCK_NB) == 0);
        put(root, @"profile-index.json", @{@"format" : @1, @"active" : gen, @"imports" : @{}});
        assert(productOpen(&s, job));
        r->pid = 377;
        r->window = 409;
        r->birth = 48435;
        r->native_id = 4;
        r->frame = (NPRect){50, 100, 300, 170};
        s.sealed.result.frame = (NPRect){1199, 820, 300, 170};
        NSDictionary *win =
                         @{@"pid" : @377,
                           @"number" : @409,
                           @"birth" : @48435},
                     *src =
                         @{@"x" : @50,
                           @"y" : @100,
                           @"width" : @300,
                           @"height" : @170},
                     *park =
                         @{@"x" : @1199,
                           @"y" : @820,
                           @"width" : @300,
                           @"height" : @170};
        NSDictionary *visible = @{@"window" : win, @"lifetime" : life, @"visibility" : @"visible", @"frame" : src},
                     *parked = @{@"window" : win, @"lifetime" : life, @"visibility" : @"parked", @"frame" : park};
        NSDictionary *owner = @{
            @"backend" : @"corner",
            @"generation" : generation,
            @"evidence" : evidence,
            @"environment" : @{@"sipEnabled" : @YES, @"hostCDHash" : @"signed-host"}
        };
        s.hostHash = @"signed-host";
        s.stamp = owner;
        NSDictionary *scope = @{@"display" : screen, @"nativeSpace" : space};
        NSDictionary *directory = @{
            @"version" : @2,
            @"displays" : @[ @{
                @"id" : screen,
                @"groups" : @[ @{
                    @"id" : group,
                    @"nativeSpace" : space,
                    @"members" : @[ @{@"id" : member, @"windowHint" : win} ]
                } ]
            } ]
        };
        put(profile, @"stage-groups-v2.json", directory);
        NSMutableDictionary *entry =
            [@{@"intent" : intent,
               @"action" : @{@"hide" : @{}},
               @"before" : visible} mutableCopy];
        NSMutableDictionary *pending = [@{
            @"owner" : owner,
            @"scope" : scope,
            @"generation" : generation,
            @"nativeID" : @4,
            @"entries" : @[ entry ]
        } mutableCopy];
        NSMutableDictionary *ledger =
            [@{@"version" : @1,
               @"owner" : owner,
               @"pending" : pending,
               @"owned" : @[]} mutableCopy];
        put(profile, journal, ledger);
        assert(productJournal(&s, NO, NO));
        assert(!productJournal(&s, YES, NO));
        s.pre.lease.birth++;
        assert(!productJournal(&s, NO, NO));
        s.pre.lease.birth--;
        s.pre.lease.generation[0] ^= 1;
        assert(!productJournal(&s, NO, NO));
        s.pre.lease.generation[0] ^= 1;
        accepted[0] ^= 1;
        assert(!productJournal(&s, NO, NO));
        accepted[0] ^= 1;
        entry[@"after"] = parked;
        NSDictionary *owned = @{
            @"group" : group,
            @"member" : member,
            @"nativeID" : @4,
            @"owner" : owner,
            @"scope" : scope,
            @"original" : visible,
            @"hidden" : parked
        };
        ledger[@"owned"] = @[ owned ];
        put(profile, journal, ledger);
        assert(productJournal(&s, YES, NO));
        assert(!productJournal(&s, YES, YES));
        assert(!ledgerAfterRemovingOnlyThisMember(ledger, r));
        [ledger removeObjectForKey:@"pending"];
        put(profile, journal, ledger);
        assert(productJournal(&s, YES, NO));
        NSDictionary *other = @{@"hidden" : @{@"window" : @{@"pid" : @377, @"birth" : @48435, @"number" : @410}}};
        NSMutableDictionary *multiple = [ledger mutableCopy];
        multiple[@"owned"] = @[ other, owned ];
        multiple[@"untouched"] = @"original";
        NSDictionary *new = ledgerAfterRemovingOnlyThisMember(multiple, r);
        assert([new[@"owned"] isEqual:@[ other ]] && [new[@"owner"] isEqual:owner] &&
               [new[@"untouched"] isEqual:@"original"]);
        multiple[@"owned"] = @[ owned, owned ];
        assert(!ledgerAfterRemovingOnlyThisMember(multiple, r));
        multiple[@"owned"] = @[ other ];
        assert(!ledgerAfterRemovingOnlyThisMember(multiple, r));
        ledger[@"releases"] = @[ @{@"owned" : owned, @"intent" : NSUUID.UUID.UUIDString} ];
        put(profile, journal, ledger);
        assert(!productJournal(&s, YES, NO));
        [ledger removeObjectForKey:@"releases"];
        ledger[@"owned"] = @[];
        put(profile, journal, ledger);
        assert(productJournal(&s, YES, YES));
        assert(!productJournal(&s, YES, NO));
        put(
            root, @"profile-index.json",
            @{@"format" : @1,
              @"active" : NSUUID.UUID.UUIDString.lowercaseString,
              @"imports" : @{}});
        assert(!productJournal(&s, YES, YES));
        CFRelease(s.profileID);
        close(s.profile);
        close(s.root);
        close(s.writer);
        close(s.serializer);
        close(hostlock);
        assert([NSFileManager.defaultManager removeItemAtPath:base error:NULL]);
    }
    return 0;
}
