// Exercises the shipping ledger parser in a newly created disposable directory, without a
// native application, WindowServer, signing identity, real profile or AX call.
#define main ncg_unused_product_main
#define np_corner_inputs deterministic_test_inputs
#import "guardian/main.m"
#undef main
#undef np_corner_inputs
#include "guardian/measurement.h"
#include <assert.h>
void deterministic_test_inputs(uint32_t counters[13]) { memset(counters, 0, 13 * sizeof(*counters)); }
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
static void displayScopeChecks(void) {
    Session s = {.displayCount = 2};
    s.displays[0] = (NCDisplay){.uuid={1}, .frame={-100, 0, 100, 100}, .visible={-100, 5, 100, 95}};
    s.displays[1] = (NCDisplay){.uuid={2}, .frame={0, 0, 100, 100}, .visible={0, 5, 100, 95}};
    NCDisplay current[2]; memcpy(current, s.displays, sizeof(current));
    assert(sameDisplays(s.displays, 2, current, 2));
    assert(!sameDisplays(s.displays, 2, current, 1));
    assert(frameOnScopedDisplay(&s, (NCFrame){-40, 10, 40, 30}, current[0].uuid));
    assert(!frameOnScopedDisplay(&s, (NCFrame){-38, 10, 40, 30}, current[0].uuid));
    assert(!frameOnScopedDisplay(&s, (NCFrame){100, 20, 40, 30}, current[1].uuid));
    current[1].visible.x += 1;
    assert(!sameDisplays(s.displays, 2, current, 2));
    current[1] = s.displays[1]; current[1].uuid[0] = 3;
    assert(!sameDisplays(s.displays, 2, current, 2));
}
static void expectPrepareRefusal(Session *s, NSDictionary *wal, NSString *reason) {
    int reply[2];
    assert(pipe(reply) == 0 && fcntl(reply[0], F_SETFL, O_NONBLOCK) == 0);
    @try {
        acknowledgePreparedRecovery(s, wal, reply[1]);
        assert(0 && "an unverified focus released a park");
    } @catch (NSException *exception) {
        assert([exception.reason isEqual:reason]);
    }
    char byte;
    assert(read(reply[0], &byte, 1) == -1 && errno == EAGAIN);
    assert(!productFile(s->dir, "guardian-prepared.json"));
    close(reply[0]);
    close(reply[1]);
}
static void selectedWorksetFocusChecks(int jobFD) {
    Session s = {.dir = jobFD, .member = {.pid = 377, .window = 409, .birth = 48435},
                 .preparedFrontPID = 377, .preparedFrontBirth = 48435, .preparedFocusNumber = 410};
    NSDictionary *sibling = @{@"pending": @{@"preferred": @{@"pid": @377, @"birth": @48435, @"number": @410}}};
    assert(focusMatchesSelection(&s, sibling));
    expectPrepareRefusal(&s, @{}, @"guardianFocusDoesNotMatchSelectedWorksetWindow");
    expectPrepareRefusal(&s, sibling, @"selectedFocusOrInputChangedBeforePrepare");
    assert(np_corner_drawn_window_number(NULL, s.preparedFrontPID) == 0);
    s.preparedFocusNumber = 409;
    expectPrepareRefusal(&s, @{@"pending": @{@"preferred": @{@"pid": @377, @"birth": @48435, @"number": @409}}},
                         @"guardianFocusDoesNotMatchSelectedWorksetWindow");
    s.preparedFocusNumber = 411;
    expectPrepareRefusal(&s, sibling, @"guardianFocusDoesNotMatchSelectedWorksetWindow");
    s.preparedFocusNumber = 410;
    s.preparedFrontBirth++;
    expectPrepareRefusal(&s, sibling, @"guardianFocusDoesNotMatchSelectedWorksetWindow");
    s.preparedFrontPID = 378;
    assert(focusMatchesSelection(&s, @{@"pending": @{@"preferred": @{@"pid": @378, @"birth": @48436, @"number": @410}}}));
    puts("{\"scope\":\"guardianPrepareFocus\",\"refusedCases\":5,\"prepareAckBytes\":0,\"preparedRecords\":0,\"windowWrites\":0}");
}
static void inverseHideJournalChecks(Session *s, NSString *profile, NSString *name, NSDictionary *baseline,
                                     NSDictionary *owned) {
    Session copy = *s;
    NPRequest *r = &copy.pre.lease;
    NSString *undo = [[NSUUID alloc] initWithUUIDBytes:r->intent].UUIDString;
    NSDictionary *visible = owned[@"original"], *parked = owned[@"hidden"];
    NSDictionary *sibling = @{@"pid": @(r->pid), @"birth": @(r->birth), @"number": @(r->window + 1)};
    NSMutableDictionary *e = [@{@"intent": NSUUID.UUID.UUIDString, @"undoIntent": undo, @"action": @{@"show": @{}},
        @"before": parked, @"undoBefore": visible, @"group": owned[@"group"], @"member": owned[@"member"]} mutableCopy];
    NSMutableDictionary *p = [baseline[@"pending"] mutableCopy];
    NSMutableDictionary *l = [baseline mutableCopy];
    [p addEntriesFromDictionary:@{@"entries": @[e], @"verifiedDirectoryCommit": @NO,
        @"target": owned[@"group"], @"originalFocus": sibling, @"preferred": visible[@"window"],
        @"ownedBefore": @[owned], @"before": @[parked]}];
    l[@"pending"] = p;
    l[@"owned"] = @[];
    copy.member.window = r->window;
    copy.preparedFrontPID = r->pid;
    copy.preparedFrontBirth = r->birth;
    copy.preparedFocusNumber = r->window + 1;
    put(profile, name, l);
    NSString *job = [profile stringByAppendingPathComponent:undo];
    NSMutableDictionary *request = [@{@"phase": @"prepare", @"epoch": @1, @"intent": undo,
        @"group": owned[@"group"], @"member": owned[@"member"], @"lifetime": visible[@"lifetime"],
        @"generation": p[@"generation"], @"display": p[@"scope"][@"display"], @"space": p[@"scope"][@"nativeSpace"],
        @"native": p[@"nativeID"], @"pid": @(r->pid), @"birth": @(r->birth), @"number": @(r->window),
        @"frame": visible[@"frame"]} mutableCopy];
    assert(!productPrepare(&copy, request, job));
    request[@"expectedPark"] = visible[@"frame"];
    assert(!productPrepare(&copy, request, job));
    request[@"expectedPark"] = parked[@"frame"];
    assert(productPrepare(&copy, request, job));
    assert(decodeUUID(e[@"intent"], copy.preparedShowIntent));
    assert([originalProof(&copy, l)[@"sourceShowIntent"] isEqual:e[@"intent"]]);
    assert(withdrawableJournal(&copy) && pendingFrameJournal(&copy) && focusMatchesSelection(&copy, l));
    assert(!productJournal(&copy, YES, NO));
    copy.preparedFocusNumber = r->window;
    assert(!focusMatchesSelection(&copy, l));
    copy.preparedFocusNumber = r->window + 1;
    NSDictionary *original = [e copy];
    for (NSDictionary *change in @[@{@"undoIntent": NSUUID.UUID.UUIDString}, @{@"intent": NSUUID.UUID.UUIDString}, @{@"intent": undo},
                                   @{@"intent": p[@"intent"]}, @{@"undoBefore": parked}, @{@"before": visible},
                                   @{@"group": NSUUID.UUID.UUIDString}, @{@"member": NSUUID.UUID.UUIDString},
                                   @{@"action": @{@"focus": @{}}}, @{@"after": visible}]) {
        [e addEntriesFromDictionary:change];
        put(profile, name, l);
        assert(!preparedHideJournal(&copy));
        [e setDictionary:original];
    }
    for (NSDictionary *change in @[@{@"ownedBefore": @[]}, @{@"ownedBefore": @[owned, owned]},
                                   @{@"before": @[visible]}, @{@"target": NSUUID.UUID.UUIDString},
                                   @{@"entries": @[e, original]}, @{@"verifiedDirectoryCommit": @YES}]) {
        NSString *key = [change.allKeys firstObject];
        id value = p[key];
        p[key] = change[key];
        put(profile, name, l);
        assert(!preparedHideJournal(&copy));
        p[key] = value;
    }
    [e removeObjectForKey:@"undoBefore"];
    put(profile, name, l);
    assert(!preparedHideJournal(&copy));
    e[@"undoBefore"] = visible;
    e[@"guardianPending"] = @YES;
    l[@"owned"] = @[owned];
    put(profile, name, l);
    assert(productJournal(&copy, YES, NO) && !preparedHideJournal(&copy));
    copy.sealed.result.frame.x += 2;
    assert(!productJournal(&copy, YES, NO));
    put(profile, name, baseline);
    assert(!productPrepare(&copy, request, job));
    puts("{\"scope\":\"inverseShowHideWAL\",\"originalFocusOnly\":true,\"requiresPriorOwnership\":true,"
         "\"requiresBothWindowImages\":true,\"changedParkRejected\":true,\"windowWrites\":0}");
}
static void inverseShowReleaseChecks(Session *s, NSString *profile, NSString *name, NSDictionary *baseline,
                                     NSDictionary *owned) {
    NSMutableDictionary *p = [baseline[@"pending"] mutableCopy], *l = [baseline mutableCopy];
    NSMutableDictionary *e = [[p[@"entries"] lastObject] mutableCopy];
    [e removeObjectForKey:@"after"];
    [e addEntriesFromDictionary:@{@"group": owned[@"group"], @"member": owned[@"member"], @"undoIntent": NSUUID.UUID.UUIDString,
        @"undoBefore": owned[@"hidden"], @"guardianPending": @YES}];
    p[@"entries"] = @[e];
    p[@"verifiedDirectoryCommit"] = @NO;
    l[@"pending"] = p;
    l[@"owned"] = @[];
    put(profile, name, l);
    assert(productJournal(s, YES, YES));
    l[@"owned"] = @[owned];
    put(profile, name, l);
    assert(!productJournal(s, YES, YES));
    l[@"owned"] = @[];
    NSDictionary *valid = [e copy];
    for (NSDictionary *change in @[@{@"undoIntent": e[@"intent"]}, @{@"undoIntent": p[@"intent"]},
                                   @{@"action": @{@"show": @{}}}, @{@"after": owned[@"original"]},
                                   @{@"member": NSUUID.UUID.UUIDString}, @{@"undoBefore": owned[@"original"]},
                                   @{@"guardianPending": @NO}]) {
        [e addEntriesFromDictionary:change];
        put(profile, name, l);
        assert(!productJournal(s, YES, YES));
        [e setDictionary:valid];
    }
    [e removeObjectForKey:@"undoBefore"];
    put(profile, name, l);
    assert(!productJournal(s, YES, YES));
    put(profile, name, baseline);
    puts("{\"scope\":\"inverseHideShowReleaseWAL\",\"ownedOrAmbiguousReleaseRejected\":true,\"windowWrites\":0}");
}
int main(void) {
    @autoreleasepool {
        displayScopeChecks();
        inspectEnvelopeChecks();
        char scratch[] = "/private/tmp/nearpane-guardian-ledger.XXXXXXXX";
        assert(mkdtemp(scratch));
        NSString *base = [NSFileManager.defaultManager stringWithFileSystemRepresentation:scratch
                                                                                   length:strlen(scratch)];
        NSString *root = [base stringByAppendingPathComponent:@"Nearpane Alpha Profiles"],
                 *gen = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *profile =
            [root stringByAppendingPathComponent:[NSString stringWithFormat:@"generations/%@/Nearpane", gen]];
        NSString *ledgerFile = @"stage-visibility-v1.json";
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
        r->backend = NP_CORNER;
        r->operation = NP_HIDE;
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
            @"intent" : newID(s.preparedTransaction),
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
        put(profile, ledgerFile, ledger);
        assert(productJournal(&s, NO, NO));
        assert(!productJournal(&s, YES, NO));
        int replies[2];
        assert(pipe(replies) == 0 && fcntl(replies[0], F_SETFL, O_NONBLOCK) == 0);
        NSDictionary *withdrawn = @{@"status": @"WITHDRAWN_BEFORE_SUBMISSION", @"issued": @0};
        int jobFD = open(job.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        assert(jobFD >= 0);
        selectedWorksetFocusChecks(jobFD);
        char reply;
        NSDictionary *prepared = @{@"schema": @1, @"status": @"PREPARED", @"guardianPID": @(getpid())};
        assert(persistJobRecord(jobFD, NCPrepared, prepared));
        assert([productFile(jobFD, "guardian-prepared.json") isEqual:prepared]);
        assert(!persistJobRecord(jobFD, NCPrepared, @{@"status": @"OTHER"}));
        assert([productFile(jobFD, "guardian-prepared.json") isEqual:prepared]);
        assert(!productFile(jobFD, "guardian-receipt.json"));
        assert(!publishReceipt(-1, withdrawn, replies[1]));
        assert(!publishReceipt(-1, @{@"status": @"PASS"}, replies[1]));
        assert(read(replies[0], &reply, 1) == -1 && errno == EAGAIN);
        assert(publishReceipt(jobFD, withdrawn, replies[1]));
        assert(read(replies[0], &reply, 1) == 1 && reply == 'W');
        assert([productFile(jobFD, "guardian-receipt.json") isEqual:withdrawn]);
        assert(!publishReceipt(jobFD, withdrawn, replies[1]));
        assert(read(replies[0], &reply, 1) == -1 && errno == EAGAIN);
        NSDictionary *released = @{@"status": @"PASS", @"reason": @"liveHostReleasedRestoredOwnership",
                                   @"liveReleaseOriginalFrameReadbacks": @2};
        assert(!publishReceipt(jobFD, released, replies[1]));
        assert(read(replies[0], &reply, 1) == -1 && errno == EAGAIN);
        assert(mkdirat(jobFD, "released", 0700) == 0);
        int releasedFD = openat(jobFD, "released", O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        assert(publishReceipt(releasedFD, released, replies[1]));
        assert(read(replies[0], &reply, 1) == 1 && reply == 'D');
        assert([productFile(releasedFD, "guardian-receipt.json") isEqual:released]);
        close(releasedFD);
        assert(mkdirat(jobFD, "lost-reply", 0700) == 0);
        int noReply = openat(jobFD, "lost-reply", O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        assert(noReply >= 0 && fcntl(replies[1], F_SETNOSIGPIPE, 1) == 0);
        close(replies[0]);
        assert(!publishReceipt(noReply, released, replies[1]) && errno == EPIPE);
        assert([productFile(noReply, "guardian-receipt.json") isEqual:released]);
        printf("{\"scope\":\"guardianReleasePublication\",\"ackDelivered\":false,\"originalRecordDurable\":true,\"windowWrites\":0}\n");
        close(noReply);
        close(jobFD);
        close(replies[1]);
        // Real shipping WAL reader, disposable files only. Witness/AX are deliberately not simulated.
        assert(withdrawableJournal(&s));
        r->epoch = 1;
        assert(withdrawalMessage(&s, @{@"phase": @"withdrawUnsubmitted", @"intent": intent, @"epoch": @1}));
        assert(!withdrawalMessage(&s, @{@"phase": @"confirm", @"intent": intent, @"epoch": @1}));
        assert(!withdrawalMessage(&s, @{@"phase": @"withdrawUnsubmitted", @"intent": intent, @"epoch": @2}));
        assert(!withdrawalMessage(&s, @{@"phase": @"withdrawUnsubmitted", @"intent": NSUUID.UUID.UUIDString, @"epoch": @1}));
        assert(!withdrawalWitness(&s, ledger));  // no previously retained real window
        for (NSString *key in @[@"after", @"guardianPending", @"undoIntent"]) {
            entry[key] = [key isEqual:@"after"] ? parked : (id)@YES;
            put(profile, ledgerFile, ledger);
            assert(!withdrawableJournal(&s));
            [entry removeObjectForKey:key];
        }
        NSString *transaction = pending[@"intent"];
        pending[@"intent"] = NSUUID.UUID.UUIDString;
        put(profile, ledgerFile, ledger);
        assert(!withdrawableJournal(&s));
        pending[@"intent"] = transaction;
        pending[@"entries"] = @[entry, @{@"intent": NSUUID.UUID.UUIDString}];
        put(profile, ledgerFile, ledger);
        assert(!withdrawableJournal(&s));
        pending[@"entries"] = @[entry];
        put(profile, ledgerFile, ledger);
        s.pre.lease.birth++;
        assert(!productJournal(&s, NO, NO));
        s.pre.lease.birth--;
        s.pre.lease.generation[0] ^= 1;
        assert(!productJournal(&s, NO, NO));
        s.pre.lease.generation[0] ^= 1;
        accepted[0] ^= 1;
        assert(!productJournal(&s, NO, NO));
        accepted[0] ^= 1;
        s.pre.version = 1;
        s.pre.phase = NCG_PREPARE;
        NSMutableDictionary *motion = [@{@"phase": @"observePark", @"intent": intent, @"epoch": @1,
            @"native": @4, @"owned": @1, @"flags": @190, @"status": @0, @"frame": park} mutableCopy];
        NSMutableDictionary *measured = [motion mutableCopy];
        measured[@"phase"] = @"observeRecoveryFrame";
        measured[@"status"] = @(NP_UNKNOWN);
        const unsigned frameFlags = NP_OWNED | NP_MEMBERSHIP_VALID | NP_AX_VALID | NP_CG_VALID | NP_CORNER_RECOVERY_FRAME;
        measured[@"flags"] = @(frameFlags);
        assert(!productParkReceipt(&s, measured, NO)); // Legacy or different member.
        entry[@"group"] = group;
        entry[@"member"] = member;
        put(profile, ledgerFile, ledger);
        assert(productParkReceipt(&s, measured, NO) && !productSeal(&s, measured));
        NSMutableDictionary *early = [measured mutableCopy];
        early[@"phase"] = @"workerMeasuredPark";
        early[@"window"] = @{@"pid": @(r->pid), @"birth": @(r->birth), @"number": @(r->window)};
        assert(productParkReceipt(&s, early, NO) && !productSeal(&s, early));
        early[@"window"] = @{@"pid": @(r->pid), @"birth": @(r->birth), @"number": @(r->window + 1)};
        assert(!productParkReceipt(&s, early, NO));
        // Exercise the shipping writer and reader on an anonymous pipe. Close all Host
        // writers before the Guardian reads. A complete frame survives EOF; an incomplete
        // second packet cannot be confused with the loss of the writer between packets.
        int conduit[2];
        assert(pipe(conduit) == 0);
        assert(np_corner_copy_measurement_writer(conduit[0]) < 0 && np_corner_copy_measurement_writer(conduit[1]) < 0);
        assert(fcntl(conduit[1], F_SETFL, O_NONBLOCK) == 0 && fcntl(conduit[1], F_SETNOSIGPIPE, 1) == 0);
        int copy = np_corner_copy_measurement_writer(conduit[1]);
        assert(copy >= 0);
        NPRect landing;
        assert(productFrame(park, &landing));
        assert(np_corner_send_measurement(copy, r, landing, 1));
        close(copy);
        close(conduit[1]);
        assert(ncg_next_host_packet(conduit[0]) == 1);
        NSDictionary *wire = productMessageFrom(conduit[0]);
        assert(ncg_next_host_packet(conduit[0]) == 0 && productParkReceipt(&s, wire, NO));
        close(conduit[0]);
        NPReceipt workerPosition = s.sealed.result;
        assert(!productSeal(&s, wire) && followsWorkerMeasurement(motion, &workerPosition));
        assert(followsWorkerMeasurement(measured, &workerPosition) && !followsWorkerMeasurement(wire, &workerPosition));
        workerPosition.frame.x += 1;
        assert(!followsWorkerMeasurement(motion, &workerPosition));
        assert(pipe(conduit) == 0);
        assert(write(conduit[1], "x", 1) == 1);
        close(conduit[1]);
        assert(ncg_next_host_packet(conduit[0]) == 1 && !productMessageFrom(conduit[0]));
        close(conduit[0]);
        assert(pipe(conduit) == 0);
        assert(fcntl(conduit[1], F_SETFL, O_NONBLOCK) == 0 && fcntl(conduit[1], F_SETNOSIGPIPE, 1) == 0);
        close(conduit[0]);
        assert(!np_corner_send_measurement(conduit[1], r, landing, 1));
        close(conduit[1]);
        printf("{\"scope\":\"workerMeasuredPark\",\"bufferedAfterClose\":true,\"earlySeal\":false,"
               "\"changedFrameAccepted\":false,\"partialPacketAccepted\":false,\"windowWrites\":0}\n");
        assert(!productJournal(&s, YES, NO));
        for (NSNumber *invalid in @[@(frameFlags | NP_INPUT_SAFE), @(frameFlags | NP_HIDDEN), @(frameFlags & ~NP_CG_VALID),
                                     @(UINT64_C(0x100000000) + frameFlags)]) {
            measured[@"flags"] = invalid;
            assert(!productParkReceipt(&s, measured, NO));
        }
        measured[@"flags"] = @(frameFlags);
        measured[@"status"] = @(NP_PASS);
        assert(!productParkReceipt(&s, measured, NO));
        measured[@"status"] = @(NP_UNKNOWN);
        assert(productParkReceipt(&s, measured, NO));
        assert(mkdirat(s.profile, "recovery-frame-test", 0700) == 0);
        s.dir = openat(s.profile, "recovery-frame-test", O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        assert(s.dir >= 0 && !recoveryFrameRecord(&s));
        NSDictionary *bound = @{@"schema": @1, @"status": @"PREPARED", @"guardianPID": @(getpid()),
                                @"original": originalProof(&s, ledger)};
        assert(persistJobRecord(s.dir, NCPrepared, bound));
        NSDictionary *measuredRecord = recoveryFrameRecord(&s);
        assert(measuredRecord && persistJobRecord(s.dir, NCRecoveryFrame, measuredRecord));
        assert(!persistJobRecord(s.dir, NCRecoveryFrame, measuredRecord));
        s.recoveryOnly = s.recoveryFramePublished = YES;
        assert(journal(&s, YES));
        pending[@"verifiedDirectoryCommit"] = @NO;
        put(profile, ledgerFile, ledger);
        assert([returnedMeasuredJournal(&s) isEqual:ledger]);
        NSString *undo = NSUUID.UUID.UUIDString;
        assert(!measuredReturnIntent(&s, undo));
        entry[@"measuredReturnIntent"] = undo;
        put(profile, ledgerFile, ledger);
        assert(measuredReturnIntent(&s, undo) && !withdrawableJournal(&s));
        assert(!measuredReturnIntent(&s, NSUUID.UUID.UUIDString));
        assert(!originalAfterArmedHostExit(&s, undo));
        for (NSString *invalid in @[entry[@"intent"], pending[@"intent"], @"invalid"]) {
            entry[@"measuredReturnIntent"] = invalid;
            put(profile, ledgerFile, ledger);
            assert(!pendingFrameJournal(&s) && !measuredReturnIntent(&s, invalid));
        }
        [entry removeObjectForKey:@"measuredReturnIntent"];
        put(profile, ledgerFile, ledger);
        printf("{\"scope\":\"liveMeasuredReturn\",\"exactUndoRequired\":true,\"aliasedIntentRejected\":true,"
               "\"withdrawAfterArmingRejected\":true,\"exitWithoutKernelRejected\":true,\"windowWrites\":0}\n");
        assert([settleRestoredOwnership(&s, 2, 1) isEqual:@"ownershipRetained"]); // No kernel exit.
        pending[@"verifiedDirectoryCommit"] = @YES;
        put(profile, ledgerFile, ledger);
        assert(!returnedMeasuredJournal(&s));
        pending[@"verifiedDirectoryCommit"] = @NO;
        put(profile, ledgerFile, ledger);
        assert([productFile(s.profile, ledgerFile.UTF8String) isEqual:ledger]);
        printf("{\"scope\":\"returnedMeasuredPrimitive\",\"pendingIntentRecognized\":true,\"directoryCommitRejected\":true,"
               "\"withoutKernelExitRejected\":true,\"guardianChangedProductWAL\":false,\"windowWrites\":0}\n");
        entry[@"member"] = NSUUID.UUID.UUIDString;
        put(profile, ledgerFile, ledger);
        assert(!journal(&s, YES));
        assert(!returnedMeasuredJournal(&s));
        entry[@"member"] = member;
        put(profile, ledgerFile, ledger);
        s.sealed.result.frame.x += 1;
        assert(!journal(&s, YES));
        s.recoveryOnly = s.recoveryFramePublished = NO;
        close(s.dir);
        s.dir = -1;
        motion[@"flags"] = @191;
        assert(!productParkReceipt(&s, motion, NO));
        motion[@"flags"] = @190;
        assert(productParkReceipt(&s, motion, NO));
        assert(!productJournal(&s, YES, NO)); // A received engine packet alone cannot authorize an orphan restore.
        NPReceipt observedBeforeCommit = s.sealed.result;
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
        inverseHideJournalChecks(&s, profile, ledgerFile, ledger, owned);
        inverseShowReleaseChecks(&s, profile, ledgerFile, ledger, owned);
        ledger[@"owned"] = @[ owned ];
        put(profile, ledgerFile, ledger);
        assert(productJournal(&s, YES, NO));
        motion[@"phase"] = @"confirm";
        motion[@"verified"] = park;
        assert(productSeal(&s, motion) && ncg_same_park_receipt(&observedBeforeCommit, &s.sealed.result));
        observedBeforeCommit.frame.x += 1;
        assert(!ncg_same_park_receipt(&observedBeforeCommit, &s.sealed.result));
        observedBeforeCommit = s.sealed.result;
        observedBeforeCommit.native_id++;
        assert(!ncg_same_park_receipt(&observedBeforeCommit, &s.sealed.result));
        motion[@"verified"] = src;
        assert(!productSeal(&s, motion));
        motion[@"verified"] = park;
        assert(productSeal(&s, motion));
        assert(!withdrawableJournal(&s));
        assert(!productJournal(&s, YES, YES));
        assert(!ledgerAfterRemovingOnlyThisMember(ledger, r));
        [ledger removeObjectForKey:@"pending"];
        put(profile, ledgerFile, ledger);
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
        put(profile, ledgerFile, ledger);
        assert(!productJournal(&s, YES, NO));
        [ledger removeObjectForKey:@"releases"];
        ledger[@"owned"] = @[];
        put(profile, ledgerFile, ledger);
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
