// Isolated signed helper. Its only setter restores one pre-retained ordinary window after
// the authenticated writer's kernel exit. Cold recovery from a serialized PID is impossible.
#import "identity.h"
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
    NCRecoveryFacts facts;
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
        if (poll(&p, 1, time) <= 0)
            return NO;
        ssize_t got = read(fd, (char *)raw + n, length - n);
        if (got <= 0)
            return NO;
        n += (size_t)got;
    }
    return YES;
}
static BOOL journal(Session *s, BOOL sealed) {
    struct stat st, same;
    NCGuardianEntry p, q;
    size_t len = sizeof(p);
    if (!fileOK(s->ledger, NO) || fstat(s->ledger, &st) ||
        fstatat(s->dir, "guardian-ledger.bin", &same, AT_SYMLINK_NOFOLLOW) || same.st_ino != st.st_ino ||
        same.st_dev != st.st_dev || st.st_size != (off_t)(len * (sealed ? 2 : 1)) ||
        pread(s->ledger, &p, len, 0) != (ssize_t)len || memcmp(&p, &s->pre, len))
        return NO;
    return !sealed || (pread(s->ledger, &q, len, (off_t)len) == (ssize_t)len && !memcmp(&q, &s->sealed, len));
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
static uint32_t authorize(void *ptr) {
    Session *s = ptr;
    uint32_t hid[13];
    np_corner_inputs(hid);
    s->facts.parent_generation_gone = ncg_birth(s->pre.host, NULL) != s->pre.host_birth;
    s->facts.journal_exact = journal(s, YES);
    s->facts.lifetime_exact = np_corner_same_window(&s->member, s->held);
    s->facts.frame_exact = stable(s, convert(s->sealed.result.frame));
    s->facts.original_display = displayIs(s);
    s->facts.inputs_unchanged = !memcmp(hid, s->sealed.hid, sizeof(hid));
    s->facts.current_signature = [s->hash isEqual:ncg_fixture_hash(s->member.pid, s->kit)];
    s->facts.no_secure_input = !np_corner_secure_input();
    return ncg_may_restore(s->facts);
}
static void need(BOOL yes, NSString *why) {
    if (!yes)
        @throw [NSException exceptionWithName:@"guard" reason:why userInfo:nil];
}
static void run(Session *s, NSMutableDictionary *receipt, NSString *kit, NSString *folder) {
    s->kit = kit;
    need(ncg_disposable() && [ncg_hash(getpid(), [kit stringByAppendingPathComponent:@"guardian"],
                                       @"com.holdsnow.nearpane.engine-guardian.fixture") length] > 0,
         @"unsignedOrNonisolatedGuardian");
    s->dir = open(folder.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    s->ledger = openat(s->dir, "guardian-ledger.bin", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    need(fileOK(s->dir, YES) && fileOK(s->ledger, NO), @"privateHostJournalUnavailable");
    need(readPacket(STDIN_FILENO, &s->pre, sizeof(s->pre)) && journal(s, NO), @"preparePipeAndJournalDiffer");
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
    NSData *host = ncg_hash(getppid(), [kit stringByAppendingPathComponent:@"controller"],
                            @"com.holdsnow.nearpane.engine-fixture");
    pid_t parent = 0;
    NSData *__attribute__((objc_precise_lifetime)) owner = ncg_fixture_hash(r.pid, kit);
    s->hash = owner;
    need(host.length && owner.length && ncg_birth(r.pid, &parent) == r.birth && parent == getppid(),
         @"unregisteredFixtureOrHostSignature");
    s->kqueue = kqueue();
    struct kevent change;
    EV_SET(&change, (uintptr_t)s->pre.host, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    need(s->kqueue >= 0 && kevent(s->kqueue, &change, 1, NULL, 0, NULL) == 0 &&
             s->pre.host_birth == ncg_birth(getppid(), NULL),
         @"cannotWatchOriginalHostExit");
    s->member = (NCMember){.pid = r.pid, .window = r.window, .birth = r.birth, .native = r.native_id};
    memcpy(s->member.space, r.native_space, 16);
    memcpy(s->member.display, r.display, 16);
    uint32_t n = 0;
    need(!np_corner_displays(&s->display, 1, &n) && n == 1 && !memcmp(s->display.uuid, r.display, 16),
         @"originalDisplayUnconfirmed");
    s->held = np_corner_retain_window(&s->member);
    need(s->held && stable(s, convert(r.frame)), @"originalAXReferenceOrFrameNotConfirmed");
    s->facts.retained_before_park = true;
    s->facts.unspent = true;
    need(write(STDOUT_FILENO, "R", 1) == 1, @"prepareAckUnavailable");
    need(readPacket(STDIN_FILENO, &s->sealed, sizeof(s->sealed)) && ncg_correlates(&s->pre, &s->sealed) &&
             journal(s, YES),
         @"committedPostimageOrIntentMissing");
    NCFrame parked = convert(s->sealed.result.frame);
    CGRect d = CGRectMake(s->display.frame.x, s->display.frame.y, s->display.frame.w, s->display.frame.h);
    CGRect slit = CGRectIntersection(d, CGRectMake(parked.x, parked.y, parked.w, parked.h));
    need(!CGRectIsEmpty(slit) && CGRectGetWidth(slit) <= 8 && !closeFrame(parked, convert(r.frame)) &&
             closeFrame((NCFrame){r.frame.x, r.frame.y, parked.w, parked.h}, convert(r.frame)) &&
             stable(s, parked) && displayIs(s),
         @"liveParkedPostimageUnavailable");
    usleep(25000);
    need(stable(s, parked) && journal(s, YES) && ncg_birth(getppid(), NULL) == s->pre.host_birth,
         @"secondParkedPostimageUnavailable");
    s->facts.parked_confirmed = true;
    receipt[@"trustedHostPID"] = @(s->pre.host);
    receipt[@"trustedHostBirth"] = @(s->pre.host_birth);
    receipt[@"window"] = @(r.window);
    receipt[@"pid"] = @(r.pid);
    receipt[@"birth"] = @(r.birth);
    receipt[@"intent"] = [[NSUUID alloc] initWithUUIDBytes:r.intent].UUIDString;
    receipt[@"preimage"] = @[ @(r.frame.x), @(r.frame.y), @(r.frame.width), @(r.frame.height) ];
    receipt[@"postimage"] = @[ @(parked.x), @(parked.y), @(parked.w), @(parked.h) ];
    need(write(STDOUT_FILENO, "P", 1) == 1, @"sealAckUnavailable");
    struct pollfd p = {.fd = STDIN_FILENO, .events = POLLIN};
    char extra;
    need(poll(&p, 1, 12000) > 0 && read(STDIN_FILENO, &extra, 1) == 0, @"originalWriterPipeStillOpen");
    s->facts.eof = true;
    struct kevent event;
    struct timespec wait = {2, 0};
    need(kevent(s->kqueue, NULL, 0, &event, 1, &wait) == 1 && event.filter == EVFILT_PROC &&
             event.ident == (uintptr_t)s->pre.host && (event.fflags & NOTE_EXIT) && !(event.flags & EV_ERROR),
         @"kernelDidNotConfirmOriginalHostExit");
    s->facts.kernel_parent_exit = true;
    for (unsigned i = 0; i < 100 && ncg_birth(s->pre.host, NULL) == s->pre.host_birth; i++)
        usleep(10000);
    need(authorize(s), @"restoreFactsIncomplete");
    uint32_t issued = 0;
    uint32_t why = np_corner_position(&s->member, s->held, parked, convert(r.frame), authorize, s, &issued);
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
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 || !ncg_disposable())
            return 2;
        Session s = {.dir = -1, .ledger = -1, .kqueue = -1};
        NSMutableDictionary *r = [@{@"schema" : @1, @"status" : @"UNKNOWN", @"issued" : @0} mutableCopy];
        @try {
            run(&s, r, @(argv[1]), @(argv[2]));
        } @catch (NSException *e) {
            r[@"reason"] = [e.name isEqual:@"guard"] ? e.reason : @"unexpectedException";
        }
        r[@"guardianPID"] = @(getpid());
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
        r[@"fixtureSignatureRechecked"] = @(s.facts.current_signature);
        if (s.held)
            np_corner_release_window(s.held);
        if (s.ledger >= 0)
            close(s.ledger);
        if (s.kqueue >= 0)
            close(s.kqueue);
        if (s.dir >= 0 && fileOK(s.dir, YES)) {
            int fd =
                openat(s.dir, "guardian-receipt.json", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
            NSData *data = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:NULL];
            if (fd >= 0) {
                BOOL ok = write(fd, data.bytes, data.length) == (ssize_t)data.length && fsync(fd) == 0;
                close(fd);
                if (!ok)
                    return 4;
            } else
                return 4;
        }
        if (s.dir >= 0)
            close(s.dir);
        return [r[@"status"] isEqual:@"PASS"] ? 0 : 3;
    }
}
