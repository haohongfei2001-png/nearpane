// Isolated signed helper. Its only setter restores one pre-retained ordinary window after
// the authenticated writer's kernel exit. Cold recovery from a serialized PID is impossible.
#import "identity.h"
#import "exit-watch.h"
#import "peer-watch.h"
#include "protocol.h"
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/time.h>

typedef struct {
    NCGuardianEntry pre, sealed;
    NCMember member;
    NCDisplay display;
    void *held;
    int dir, ledger, kqueue;
#ifndef NP_CORNER_FIXTURE
    int profile, root, writer, serializer;
    BOOL serializedRecovery;
    void *profileID;
    __unsafe_unretained NSString *hostHash;
    __unsafe_unretained NSData *hostDigest;
    uint8_t preparedTransaction[16];
    __unsafe_unretained NSDictionary *stamp;
    uint32_t takeoverInput[13];
#endif
    NCRecoveryFacts facts;
    BOOL takeoverChecked;
    __unsafe_unretained NSData *hash;
    __unsafe_unretained NSString *kit;
} Session;
static NCFrame convert(NPRect r) { return (NCFrame){r.x, r.y, r.width, r.height}; }
static BOOL closeFrame(NCFrame a, NCFrame b) {
    return a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0 && fabs(a.x - b.x) <= .75 && fabs(a.y - b.y) <= .75 &&
           fabs(a.w - b.w) <= .75 && fabs(a.h - b.h) <= .75;
}
static BOOL fileOK(int fd, BOOL dir) {
    struct stat st;
    return fstat(fd, &st) == 0 && st.st_uid == getuid() &&
           (dir ? S_ISDIR(st.st_mode) && (st.st_mode & 0777) == 0700
                : S_ISREG(st.st_mode) && st.st_nlink == 1 && (st.st_mode & 0777) == 0600);
}
static BOOL readPacket(int fd, void *raw, size_t length) {
    size_t n = 0;
    double end = NSProcessInfo.processInfo.systemUptime + 8.;
    while (n < length) {
        int time = (int)((end - NSProcessInfo.processInfo.systemUptime) * 1000);
        if (time <= 0)
            return NO;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int ready = poll(&p, 1, time);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0)
            return NO;
        ssize_t got = read(fd, (char *)raw + n, length - n);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0)
            return NO;
        n += (size_t)got;
    }
    return YES;
}
#ifndef NP_CORNER_FIXTURE
static BOOL displayIs(Session *s);
static BOOL stable(Session *s, NCFrame frame);
#include "packaged.h"
#include "inspect.h"
#endif
static BOOL journal(Session *s, BOOL sealed) {
#ifndef NP_CORNER_FIXTURE
    return productJournal(s, sealed, NO);
#else
    struct stat st, same;
    NCGuardianEntry p, q;
    size_t len = sizeof(p);
    if (!fileOK(s->ledger, NO) || fstat(s->ledger, &st) ||
        fstatat(s->dir, "guardian-ledger.bin", &same, AT_SYMLINK_NOFOLLOW) || same.st_ino != st.st_ino ||
        same.st_dev != st.st_dev || st.st_size != (off_t)(len * (sealed ? 2 : 1)) ||
        pread(s->ledger, &p, len, 0) != (ssize_t)len || memcmp(&p, &s->pre, len))
        return NO;
    return !sealed || (pread(s->ledger, &q, len, (off_t)len) == (ssize_t)len && !memcmp(&q, &s->sealed, len));
#endif
}
static BOOL displayIs(Session *s) {
    NCDisplay d = {0};
    uint32_t count = 0;
    return np_corner_displays(&d, 1, &count) == 0 && count == 1 && !memcmp(d.uuid, s->display.uuid, 16) &&
           closeFrame(d.frame, s->display.frame) && closeFrame(d.visible, s->display.visible);
}
static BOOL stable(Session *s, NCFrame frame) {
    NCSample sample = {0};
    return np_corner_same_window(&s->member, s->held) && !np_corner_sample(&s->member, &sample) &&
           !sample.minimized && sample.onscreen && closeFrame(sample.ax, frame) && closeFrame(sample.cg, frame);
}
#ifdef NP_CORNER_FIXTURE
static BOOL originalReleaseWitness(Session *s) {
    return getppid() == s->pre.host && ncg_birth(getppid(), NULL) == s->pre.host_birth &&
           [s->hash isEqual:ncg_fixture_hash(s->member.pid,s->kit)] && journal(s,YES) &&
           displayIs(s) && stable(s,convert(s->pre.lease.frame));
}
#else
static BOOL originalReleaseWitness(Session *s) {
    uint8_t digest[32] = {0};
    return getppid() == s->pre.host && ncg_birth(getppid(), NULL) == s->pre.host_birth &&
           np_corner_signed_fingerprint(s->member.pid, s->member.birth, digest) &&
           [s->hash isEqual:[NSData dataWithBytes:digest length:sizeof(digest)]] && displayIs(s) &&
           productJournal(s, YES, YES) && stable(s, convert(s->pre.lease.frame));
}
#endif
static uint32_t authorize(void *ptr) {
    Session *s = ptr;
    s->takeoverChecked = YES;
    s->facts.guardian_own_ax = AXIsProcessTrusted();
    uint32_t hid[13];
    np_corner_inputs(hid);
    s->facts.parent_generation_gone = ncg_birth(s->pre.host, NULL) != s->pre.host_birth;
    s->facts.journal_exact = journal(s, YES);
    s->facts.lifetime_exact = np_corner_same_window(&s->member, s->held);
    s->facts.frame_exact = stable(s, convert(s->sealed.result.frame));
    s->facts.original_display = displayIs(s);
#ifdef NP_CORNER_FIXTURE
    s->facts.inputs_unchanged = !memcmp(hid, s->sealed.hid, sizeof(hid));
    s->facts.current_signature = [s->hash isEqual:ncg_fixture_hash(s->member.pid, s->kit)];
#else
    s->facts.inputs_unchanged = !memcmp(hid, s->takeoverInput, sizeof(hid));
    uint8_t digest[32] = {0};
    s->facts.current_signature = np_corner_signed_fingerprint(s->member.pid, s->member.birth, digest) &&
                                 [s->hash isEqual:[NSData dataWithBytes:digest length:sizeof(digest)]];
#endif
    s->facts.no_secure_input = !np_corner_secure_input();
    return ncg_may_restore(s->facts);
}
static void need(BOOL yes, NSString *why) {
    if (!yes)
        @throw [NSException exceptionWithName:@"guard" reason:why userInfo:nil];
}
static void run(Session *s, NSMutableDictionary *receipt, NSString *kit, NSString *folder) {
    s->kit = kit;
#ifdef NP_CORNER_FIXTURE
    need(ncg_disposable() && [ncg_hash(getpid(), [kit stringByAppendingPathComponent:@"guardian"],
                                       @"com.holdsnow.nearpane.engine-guardian.fixture") length] > 0,
         @"unsignedOrNonisolatedGuardian");
    s->dir = open(folder.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    s->ledger = openat(s->dir, "guardian-ledger.bin", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    need(fileOK(s->dir, YES) && fileOK(s->ledger, NO), @"privateHostJournalUnavailable");
    need(readPacket(STDIN_FILENO, &s->pre, sizeof(s->pre)) && journal(s, NO), @"preparePipeAndJournalDiffer");
#else
    (void)kit;
    NSData *__attribute__((objc_precise_lifetime)) parentDigest = signedProduct(getppid(), hostExe, @"com.holdsnow.nearpane.alpha");
    need(parentDigest.length &&
             signedProduct(getpid(), guardianExe, @"com.holdsnow.nearpane.alpha.corner-guardian").length,
         @"signedCanonicalHostAndNestedGuardianRequired");
    NSMutableString *__attribute__((objc_precise_lifetime)) hash = [NSMutableString string];
    for (NSUInteger i = 0; i < parentDigest.length; i++)
        [hash appendFormat:@"%02x", ((const uint8_t *)parentDigest.bytes)[i]];
    s->hostHash = hash;
    s->hostDigest = parentDigest;
    s->dir = open(folder.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    need(fileOK(s->dir, YES) && productOpen(s, folder), @"activeLockedHostProfileUnavailable");
    need(productPrepare(s, productMessage(), folder), @"pendingQualifiedProductHideNotInHostJournal");
    NSDictionary *initialWAL = productFile(s->profile, "stage-visibility-v1.json");
    NSDictionary *__attribute__((objc_precise_lifetime)) stamp = [initialWAL[@"owner"] copy];
    (void)decodeUUID(initialWAL[@"pending"][@"intent"], s->preparedTransaction);
    s->stamp = stamp;
    need(stamp && journal(s, NO), @"hostOwnerStampChangedBeforeRetention");
#endif
    NPRequest r = s->pre.lease;
    need(s->pre.version == 1 && s->pre.phase == NCG_PREPARE && s->pre.host == getppid() &&
             s->pre.host_birth != 0 && s->pre.host_birth == ncg_birth(getppid(), NULL) && r.size == sizeof(r) &&
             r.version == 1 && !r.flags && r.backend == NP_CORNER && r.operation == NP_HIDE && r.epoch &&
             r.pid > 1 && r.window && r.birth && r.native_id && closeFrame(convert(r.frame), convert(r.target)),
         @"prepareOwnerOrRequestChanged");
    uint8_t zero[16] = {0};
    for (NSValue *v in @[
             [NSValue valueWithPointer:r.intent], [NSValue valueWithPointer:r.member],
             [NSValue valueWithPointer:r.generation], [NSValue valueWithPointer:r.lifetime],
             [NSValue valueWithPointer:r.group], [NSValue valueWithPointer:r.display],
             [NSValue valueWithPointer:r.native_space]
         ])
        need(memcmp(v.pointerValue, zero, 16) != 0, @"incompleteHostLease");
#ifdef NP_CORNER_FIXTURE
    NSData *host = ncg_hash(getppid(), [kit stringByAppendingPathComponent:@"controller"],
                            @"com.holdsnow.nearpane.engine-fixture");
    pid_t parent = 0;
    NSData *__attribute__((objc_precise_lifetime)) owner = ncg_fixture_hash(r.pid, kit);
    s->hash = owner;
    need(host.length && owner.length && ncg_birth(r.pid, &parent) == r.birth && parent == getppid(),
         @"unregisteredFixtureOrHostSignature");
#else
    uint8_t digest[32];
    need(np_corner_signed_fingerprint(r.pid, r.birth, digest), @"enrolledApplicationSigningIdentityUnavailable");
    NSData *__attribute__((objc_precise_lifetime)) owner = [NSData dataWithBytes:digest length:sizeof(digest)];
    s->hash = owner;
#endif
    s->kqueue = ncg_watch_exit(s->pre.host, s->pre.host_birth);
    need(s->kqueue >= 0 && getppid() == s->pre.host && s->pre.host_birth == ncg_birth(s->pre.host, NULL),
         @"cannotWatchOriginalHostExit");
    s->member = (NCMember){.pid = r.pid, .window = r.window, .birth = r.birth, .native = r.native_id};
    memcpy(s->member.space, r.native_space, 16);
    memcpy(s->member.display, r.display, 16);
    uint32_t n = 0;
    need(!np_corner_displays(&s->display, 1, &n) && n == 1 && !memcmp(s->display.uuid, r.display, 16),
         @"originalDisplayUnconfirmed");
    receipt[@"guardianOwnAccessibilityAtPrepare"] = @(AXIsProcessTrusted());
    need([receipt[@"guardianOwnAccessibilityAtPrepare"] isEqual:@YES], @"guardianIndependentAccessibilityUnavailable");
    s->held = np_corner_retain_window(&s->member);
    need(s->held && stable(s, convert(r.frame)), @"originalAXReferenceOrFrameNotConfirmed");
    s->facts.retained_before_park = true;
    s->facts.unspent = true;
    need(write(STDOUT_FILENO, "R", 1) == 1, @"prepareAckUnavailable");
    BOOL afterCommittedEOF = NO;
#ifdef NP_CORNER_FIXTURE
    need(readPacket(STDIN_FILENO, &s->sealed, sizeof(s->sealed)) && ncg_correlates(&s->pre, &s->sealed) &&
             journal(s, YES),
         @"committedPostimageOrIntentMissing");
#else
    need(ncg_wait_for_host_message(STDIN_FILENO), @"hostClosedBeforeSealOrWithdrawal");
    NSDictionary *message = productMessage();
    if ([message[@"phase"] isEqual:@"withdrawUnsubmitted"]) {
        need(withdrawalMessage(s, message), @"withdrawalIntentOrEpochChanged");
        NSDictionary *wal = withdrawableJournal(s);
        need(withdrawalWitness(s, wal), @"originalPreparedWindowOrWALUnavailable");
        usleep(25000);
        need(withdrawalWitness(s, wal), @"secondOriginalPreparedWindowOrWALUnavailable");
        receipt[@"withdrawal"] = @{
            @"intent": [[NSUUID alloc] initWithUUIDBytes:r.intent].UUIDString,
            @"transaction": wal[@"pending"][@"intent"], @"epoch": @(r.epoch),
            @"group": [[NSUUID alloc] initWithUUIDBytes:r.group].UUIDString,
            @"member": [[NSUUID alloc] initWithUUIDBytes:r.member].UUIDString,
            @"generation": [[NSUUID alloc] initWithUUIDBytes:r.generation].UUIDString,
            @"lifetime": [[NSUUID alloc] initWithUUIDBytes:r.lifetime].UUIDString,
            @"display": [[NSUUID alloc] initWithUUIDBytes:r.display].UUIDString,
            @"space": [[NSUUID alloc] initWithUUIDBytes:r.native_space].UUIDString,
            @"native": @(r.native_id), @"pid": @(r.pid), @"birth": @(r.birth), @"window": @(r.window),
            @"frame": @[@(r.frame.x), @(r.frame.y), @(r.frame.width), @(r.frame.height)],
            @"hostPID": @(s->pre.host), @"hostBirth": @(s->pre.host_birth),
            @"guardianBirth": @(ncg_birth(getpid(), NULL)), @"originalReadbacks": @2
        };
        receipt[@"status"] = @"WITHDRAWN_BEFORE_SUBMISSION";
        return;
    }
    if ([message[@"phase"] isEqual:@"observePark"]) {
        need(productParkReceipt(s, message, NO) && displayIs(s) && stable(s, convert(s->sealed.result.frame)),
             @"originalEnginePostimageUnavailable");
        NPReceipt original = s->sealed.result;
        need(write(STDOUT_FILENO, "O", 1) == 1, @"enginePostimageAckUnavailable");
        receipt[@"enginePostimageWitnessed"] = @YES;
        int next = ncg_next_host_packet(STDIN_FILENO);
        need(next >= 0, @"hostConfirmationChannelUnavailable");
        if (next == 0) {
            // The exact signed Host supplied the engine result while alive. The coordinator
            // must also have independently verified it and committed this member to its WAL.
            need(productJournal(s, YES, NO), @"hostExitedBeforeIndependentOwnershipCommit");
            afterCommittedEOF = YES;
        } else {
            need(productSeal(s, productMessage()) && ncg_same_park_receipt(&original, &s->sealed.result),
                 @"confirmationDiffersFromOriginalEngineReceipt");
        }
    } else {
        need(productSeal(s, message), @"independentCommittedProductOwnershipUnavailable");
    }
#endif
    NCFrame parked = convert(s->sealed.result.frame);
    CGRect d = CGRectMake(s->display.frame.x, s->display.frame.y, s->display.frame.w, s->display.frame.h);
    CGRect slit = CGRectIntersection(d, CGRectMake(parked.x, parked.y, parked.w, parked.h));
    need(!CGRectIsEmpty(slit) && CGRectGetWidth(slit) <= 8 && !closeFrame(parked, convert(r.frame)) &&
             closeFrame((NCFrame){r.frame.x, r.frame.y, parked.w, parked.h}, convert(r.frame)) &&
             stable(s, parked) && displayIs(s),
         @"liveParkedPostimageUnavailable");
    usleep(25000);
    need(stable(s, parked) && journal(s, YES),
         @"secondParkedPostimageUnavailable");
    if (afterCommittedEOF || getppid() != s->pre.host || ncg_birth(s->pre.host, NULL) != s->pre.host_birth) {
        s->facts.kernel_parent_exit = ncg_saw_exit(s->kqueue, s->pre.host, s->pre.host_birth, 2000);
        need(s->facts.kernel_parent_exit, @"originalHostChangedDuringPostimage");
    }
    s->facts.parked_confirmed = true;
    receipt[@"trustedHostPID"] = @(s->pre.host);
    receipt[@"trustedHostBirth"] = @(s->pre.host_birth);
    receipt[@"window"] = @(r.window);
    receipt[@"pid"] = @(r.pid);
    receipt[@"birth"] = @(r.birth);
    receipt[@"intent"] = [[NSUUID alloc] initWithUUIDBytes:r.intent].UUIDString;
    receipt[@"preimage"] = @[ @(r.frame.x), @(r.frame.y), @(r.frame.width), @(r.frame.height) ];
    receipt[@"postimage"] = @[ @(parked.x), @(parked.y), @(parked.w), @(parked.h) ];
    NCGSealAck ack = afterCommittedEOF ? NCG_ACK_CLOSED : ncg_ack_committed_park(STDOUT_FILENO);
    need(ack != NCG_ACK_ERROR, @"sealAckUnavailable");
    receipt[@"sealAckDelivered"] = @(ack == NCG_ACK_SENT);
    receipt[@"ownershipCommittedBeforeHostEOF"] = @(afterCommittedEOF);
    struct pollfd p = {.fd = STDIN_FILENO, .events = POLLIN};
    char extra;
#ifdef NP_CORNER_FIXTURE
    need(poll(&p, 1, 30000) > 0, @"originalWriterPipeStillOpen");
#else
    int polled;
    do {
        polled = poll(&p, 1, -1);
    } while (polled < 0 && errno == EINTR);
    need(polled > 0, @"signedHostPipeUnavailable");
#endif
    ssize_t got = read(STDIN_FILENO, &extra, 1);
    if (got == 1 && extra == 'D') {
        need(originalReleaseWitness(s), @"journalAndReleasedOriginalNotConfirmed");
        receipt[@"liveReleaseOriginalFrameReadbacks"] = @1;
        usleep(25000);
        need(originalReleaseWitness(s), @"secondReleasedOriginalNotConfirmed");
        receipt[@"liveReleaseOriginalFrameReadbacks"] = @2;
        receipt[@"status"] = @"PASS";
        receipt[@"reason"] = @"liveHostReleasedRestoredOwnership";
        return;
    }
    need(got == 0, @"unexpectedHostCommand");
#ifndef NP_CORNER_FIXTURE
    np_corner_inputs(s->takeoverInput);
    if (ack == NCG_ACK_CLOSED || s->facts.kernel_parent_exit)
        need(!memcmp(s->takeoverInput, s->sealed.hid, sizeof(s->takeoverInput)), @"inputChangedDuringSealHandoff");
#endif
    s->facts.eof = true;
    if (!s->facts.kernel_parent_exit)
        s->facts.kernel_parent_exit = ncg_saw_exit(s->kqueue, s->pre.host, s->pre.host_birth, 2000);
    need(s->facts.kernel_parent_exit, @"kernelDidNotConfirmOriginalHostExit");
#ifndef NP_CORNER_FIXTURE
    // Never race a newly launched Host. This lock is also the CAS boundary for checking the active generation.
    need(flock(s->writer, LOCK_SH | LOCK_NB) == 0 && activeProfile(s), @"newHostOwnsProfile");
    // Multiple Guardians may keep out a new Host. Only one may execute its single-window restore at a time.
    double deadline = NSProcessInfo.processInfo.systemUptime + 3;
    int locked;
    do {
        locked = flock(s->serializer, LOCK_EX | LOCK_NB);
        if (locked && errno == EWOULDBLOCK)
            usleep(15000);
        else
            break;
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    need(locked == 0, @"otherRecoveryWriterDidNotQuiesce");
    s->serializedRecovery = YES;
    receipt[@"exclusiveHostWriterExcluded"] = @YES;
    receipt[@"serializedRecoveryWriter"] = @YES;
    usleep(25000);
#endif
    need(authorize(s), @"restoreFactsIncomplete");
    uint32_t issued = 0;
    uint32_t why = np_corner_position(&s->member, s->held, parked, convert(r.frame), NC_RESTORE, authorize, s, &issued);
    s->facts.unspent = false;
    receipt[@"issued"] = @(issued);
    receipt[@"setterResult"] = @(why);
    need(issued == 1, @"lastMomentLeaseRejected");
    unsigned consecutive = 0;
    for (unsigned i = 0; i < 30 && consecutive < 2; i++) {
        if (displayIs(s) && stable(s, convert(r.frame)))
            consecutive++;
        else
            consecutive = 0;
        if (consecutive < 2)
            usleep(25000);
    }
    receipt[@"originalFrameReadbacks"] = @(consecutive);
    need(consecutive == 2, @"originalGeometryUnconfirmedAfterSingleSetter");
    receipt[@"status"] = @"PASS";
    receipt[@"reason"] = @"retainedWindowRestoredAfterKernelExitAndEOF";
#ifndef NP_CORNER_FIXTURE
    receipt[@"physicalRestoration"] = @"PASS";
    receipt[@"durableOwnership"] = settleCommitted(s);
    if (![receipt[@"durableOwnership"] isEqual:@"exactCommittedOwnershipRemoved"])
        receipt[@"status"] = @"UNKNOWN";
#endif
}
// The parent cannot settle a pending entry from a pipe byte preceding durable evidence.
static BOOL publishReceipt(int dir, NSDictionary *receipt, int reply) {
    if (dir < 0 || !fileOK(dir, YES)) return NO;
    int fd = openat(dir, "guardian-receipt.json", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:NULL];
    BOOL durable = data.length && write(fd, data.bytes, data.length) == (ssize_t)data.length && fsync(fd) == 0;
    close(fd);
    if (!durable || fsync(dir)) return NO;
    char ack;
    if ([receipt[@"status"] isEqual:@"WITHDRAWN_BEFORE_SUBMISSION"]) ack = 'W';
    else if ([receipt[@"status"] isEqual:@"PASS"] && [receipt[@"reason"] isEqual:@"liveHostReleasedRestoredOwnership"] &&
             [receipt[@"liveReleaseOriginalFrameReadbacks"] isEqual:@2]) ack = 'D';
    else return YES;
    ssize_t count;
    do { count = write(reply, &ack, 1); } while (count < 0 && errno == EINTR);
    return count == 1;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return 2;
#ifndef NP_CORNER_FIXTURE
        if (argc == 2 && !strcmp(argv[1], "--inspect-registered-fixture"))
            return inspectRegisteredFixture(NO, nil);
        if (argc == 2 && !strcmp(argv[1], "--inspect-fixture-after-host-exit"))
            return inspectRegisteredFixture(YES, nil);
#endif
#ifdef NP_INTERNAL_SURVIVAL
        // This development executable cannot own, park, or restore windows.
        if (argc == 3 && !strcmp(argv[1], "--inspect-survival-principal")) {
            NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:@(argv[2])];
            if (nonce) return inspectRegisteredFixture(YES, nonce);
        }
        return 2;
#endif
        if (argc != 3)
            return 2;
#ifdef NP_CORNER_FIXTURE
        if (!ncg_disposable())
            return 2;
#else
        if (strcmp(argv[1], "--watch"))
            return 2;
#endif
        Session s = {.dir = -1, .ledger = -1, .kqueue = -1};
#ifndef NP_CORNER_FIXTURE
        s.profile = s.root = s.writer = s.serializer = -1;
#endif
        NSMutableDictionary *r = [@{@"schema" : @1, @"status" : @"UNKNOWN", @"issued" : @0} mutableCopy];
        @try {
            run(&s, r, @(argv[1]), @(argv[2]));
        } @catch (NSException *e) {
            r[@"reason"] = [e.name isEqual:@"guard"] ? e.reason : @"unexpectedException";
        }
        r[@"normalWindowWriter"] = @"originalHostOnly";
        r[@"guardianPID"] = @(getpid());
        r[@"guardianOwnAccessibilityBeforeWrite"] = s.takeoverChecked ? @(s.facts.guardian_own_ax) : NSNull.null;
        r[@"retainedBeforePark"] = @(s.facts.retained_before_park);
        r[@"committedPostimage"] = @(s.facts.parked_confirmed);
        r[@"originalPipeEOF"] = @(s.facts.eof);
        r[@"kernelHostExit"] = @(s.facts.kernel_parent_exit);
        r[@"originalHostGone"] = @(s.facts.parent_generation_gone);
        r[@"journalExact"] = @(s.facts.journal_exact);
        r[@"sameRetainedWindow"] = @(s.facts.lifetime_exact);
        r[@"postimageExactBeforeWrite"] = @(s.facts.frame_exact);
        r[@"sameDisplay"] = @(s.facts.original_display);
        r[@"unchangedInput"] = @(s.facts.inputs_unchanged);
        r[@"processSignatureRechecked"] = @(s.facts.current_signature);
        if (s.held)
            np_corner_release_window(s.held);
        if (s.ledger >= 0)
            close(s.ledger);
        if (s.kqueue >= 0)
            close(s.kqueue);
        BOOL published = publishReceipt(s.dir, r, STDOUT_FILENO);
        if (s.dir >= 0)
            close(s.dir);
#ifndef NP_CORNER_FIXTURE
        if (s.profile >= 0)
            close(s.profile);
        if (s.root >= 0)
            close(s.root);
        if (s.writer >= 0)
            close(s.writer);
        if (s.serializer >= 0)
            close(s.serializer);
        if (s.profileID)
            CFRelease(s.profileID);
#endif
        if (!published) return 4;
        return [r[@"status"] isEqual:@"PASS"] || [r[@"status"] isEqual:@"WITHDRAWN_BEFORE_SUBMISSION"] ? 0 : 3;
    }
}
