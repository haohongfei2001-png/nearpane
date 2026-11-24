// Compiled only into the opt-in signed internal package. The regular fixture places its own
// window 24 points sideways, wholly on-screen. Only the return uses the product AX primitive.
#import <sys/sysctl.h>
typedef struct {
    Session window;
    NCFrame original, displaced;
    pid_t parent, front;
    uint64_t parentBirth, frontBirth;
    AXUIElementRef focus;
    uint32_t hid[13], motion;
    BOOL exited, unspent;
    __unsafe_unretained NSDictionary *prepared;
} VisibleReturn;

static uint32_t mouseMotion(void) {
    return CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventMouseMoved);
}
static BOOL visibleContinuity(VisibleReturn *t) {
    uint32_t hid[13];
    np_corner_inputs(hid);
    if (memcmp(hid, t->hid, sizeof(hid)) || mouseMotion() != t->motion || np_corner_secure_input() ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != t->front ||
        ncg_birth(t->front, NULL) != t->frontBirth || !displayIs(&t->window))
        return NO;
    AXUIElementRef current = cornerFocusedWindow(t->front);
    BOOL same = current && CFEqual(t->focus, current);
    if (current)
        CFRelease(current);
    return same;
}
static uint32_t authorizeVisibleReturn(void *ptr) {
    VisibleReturn *t = ptr;
    uint8_t digest[32];
    return t->exited && t->unspent && AXIsProcessTrusted() && ncg_birth(t->parent, NULL) != t->parentBirth &&
           diagnosticResponsible() == getpid() && visibleContinuity(t) &&
           [productFile(t->window.dir, "guardian-prepared.json") isEqual:t->prepared] &&
           np_corner_signed_fingerprint(t->window.member.pid, t->window.member.birth, digest) &&
           [t->window.hash isEqual:[NSData dataWithBytes:digest length:sizeof(digest)]] &&
           stable(&t->window, t->displaced);
}
static BOOL visibleTargetSystem(void) {
    char build[64] = {0};
    size_t size = sizeof(build);
    int (*readSIP)(uint32_t *) = dlsym(RTLD_DEFAULT, "csr_get_active_config");
    uint32_t bits = UINT32_MAX;
#if defined(__arm64__)
    return !sysctlbyname("kern.osversion", build, &size, NULL, 0) && !strcmp(build, "26A428") && readSIP &&
           !readSIP(&bits) && !bits;
#else
    (void)build;
    (void)size;
    (void)readSIP;
    (void)bits;
    return NO;
#endif
}
static NSArray *fixtureFrame(NCFrame r) { return @[ @(r.x), @(r.y), @(r.w), @(r.h) ]; }
static int recoverVisibleFixture(NSDictionary *m, const NPGuardianFixtureObservation *pre, pid_t parent,
                                 uint64_t parentBirth, pid_t responsible) {
    if (!m[@"display"] || !m[@"space"] || !m[@"nativeID"] || !survivalProof(pre))
        return 3;
    VisibleReturn t = {
        .window = {.dir = -1, .kqueue = -1}, .parent = parent, .parentBirth = parentBirth, .unspent = YES};
    Session *s = &t.window;
    NSDictionary *w = m[@"window"];
    s->member = (NCMember){.pid = [w[@"pid"] intValue],
                           .birth = [w[@"birth"] unsignedLongLongValue],
                           .window = [w[@"number"] unsignedIntValue],
                           .native = [m[@"nativeID"] unsignedLongLongValue]};
    NSString *nonce = [m[@"challenge"] lowercaseString];
    NSString *root = [@"/private/tmp/nearpane-membership." stringByAppendingString:nonce];
    NSString *path =
        [root stringByAppendingPathComponent:@"Membership Window.app/Contents/MacOS/MembershipWindow"];
    NSMutableDictionary *receipt = [@{
        @"schema" : @1,
        @"scope" : @"visibleFixtureGeometryAcrossHostExit",
        @"challenge" : m[@"challenge"],
        @"hostPID" : @(parent),
        @"hostBirth" : @(parentBirth),
        @"hostHash" : m[@"hostHash"],
        @"childPID" : m[@"childPID"],
        @"childBirth" : m[@"childBirth"],
        @"childHash" : m[@"childHash"],
        @"window" : w,
        @"fixtureHash" : m[@"fixtureHash"],
        @"nativeID" : m[@"nativeID"],
        @"display" : m[@"display"],
        @"space" : m[@"space"],
        @"scopeSpaceWrites" : @0,
        @"issued" : @0,
        @"parked" : @NO,
        @"status" : @"UNKNOWN"
    } mutableCopy];
    BOOL armed = NO;
    @try {
        char canonical[PATH_MAX];
        need(visibleTargetSystem() && survivalProof(pre) && [path isEqual:m[@"executable"]] &&
                 realpath(path.fileSystemRepresentation, canonical) && [path isEqual:@(canonical)] &&
                 (responsible == parent || responsible == getpid()) &&
                 decodeUUID(m[@"display"], s->member.display) && decodeUUID(m[@"space"], s->member.space),
             @"targetSystemOrSignedFixtureScopeUnavailable");
        s->dir = open(root.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        need(s->dir >= 0 && fileOK(s->dir, YES), @"privateFixtureRootUnavailable");
        NSData *__attribute__((objc_precise_lifetime)) digest =
            signedProduct(s->member.pid, path, @"com.holdsnow.nearpane.engine-fixture.a");
        uint8_t ownerDigest[32];
        need(digest.length && [diagnosticHash(digest) isEqual:m[@"fixtureHash"]] &&
                 np_corner_signed_fingerprint(s->member.pid, s->member.birth, ownerDigest),
             @"unconfirmedFixtureImage");
        NSData *__attribute__((objc_precise_lifetime)) owner = [NSData dataWithBytes:ownerDigest
                                                                              length:sizeof(ownerDigest)];
        s->hash = owner;
        NPGuardianRect r = pre->second.cg;
        t.original = (NCFrame){r.x, r.y, r.width, r.height};
        t.displaced = (NCFrame){r.x + 24, r.y, r.width, r.height};
        need(captureDisplays(s, s->member.display, t.original) && s->displayCount == 1 &&
                 CGRectContainsRect(displayRect(s->display.visible), displayRect(t.original)) &&
                 CGRectContainsRect(displayRect(s->display.visible), displayRect(t.displaced)),
             @"ordinaryVisibleGeometryUnavailable");
        t.front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        t.frontBirth = ncg_birth(t.front, NULL);
        need(t.front > 1 && t.front != s->member.pid && t.front != parent && t.frontBirth,
             @"ordinaryForegroundUnavailable");
        t.focus = cornerFocusedWindow(t.front);
        np_corner_inputs(t.hid);
        t.motion = mouseMotion();
        s->kqueue = ncg_watch_exit(parent, parentBirth);
        s->held = np_corner_retain_window(&s->member);
        need(t.focus && s->kqueue >= 0 && getppid() == parent && ncg_birth(parent, NULL) == parentBirth &&
                 s->held && stable(s, t.original) && visibleContinuity(&t),
             @"originalNotRetained");
        receipt[@"original"] = fixtureFrame(t.original);
        receipt[@"displaced"] = fixtureFrame(t.displaced);
        receipt[@"frontPID"] = @(t.front);
        receipt[@"frontBirth"] = @(t.frontBirth);
        NSDictionary *__attribute__((objc_precise_lifetime)) responsibility = @{
            @"schema" : @1,
            @"scope" : @"restoreOneVisibleSignedFixture",
            @"challenge" : m[@"challenge"],
            @"hostPID" : @(parent),
            @"hostBirth" : @(parentBirth),
            @"guardianPID" : @(getpid()),
            @"guardianBirth" : m[@"childBirth"],
            @"hostHash" : m[@"hostHash"],
            @"guardianHash" : m[@"childHash"],
            @"fixtureHash" : m[@"fixtureHash"],
            @"window" : w,
            @"original" : receipt[@"original"],
            @"displaced" : receipt[@"displaced"],
            @"nativeID" : m[@"nativeID"],
            @"display" : m[@"display"],
            @"space" : m[@"space"]
        };
        t.prepared = responsibility;
        need(persistJobRecord(s->dir, NCPrepared, responsibility), @"durableVisibleResponsibilityUnavailable");
        unsigned reads = 0;
        for (unsigned i = 0; i < 35 && reads < 2; i++) {
            need(visibleContinuity(&t) && getppid() == parent && ncg_birth(parent, NULL) == parentBirth,
                 @"userOrParentChangedBeforeDisplacement");
            NSDictionary *displacement = productFile(s->dir, "owner-displaced.json");
            BOOL ownerObserved = [displacement[@"pid"] isEqual:w[@"pid"]] &&
                                 [displacement[@"window"] isEqual:w[@"number"]] &&
                                 [displacement[@"frame"] isEqual:receipt[@"displaced"]];
            reads = ownerObserved && stable(s, t.displaced) ? reads + 1 : 0;
            if (reads < 2)
                usleep(20000);
        }
        receipt[@"displacedReads"] = @(reads);
        need(reads == 2 && write(STDOUT_FILENO, "ARMED\n", 6) == 6, @"visibleDisplacementUnconfirmed");
        armed = YES;
        t.exited = ncg_saw_exit(s->kqueue, parent, parentBirth, 8000);
        receipt[@"kernelExit"] = @(t.exited);
        struct pollfd pipeState = {.fd = STDIN_FILENO, .events = POLLIN};
        char byte;
        BOOL eof = t.exited && poll(&pipeState, 1, 250) > 0 && read(STDIN_FILENO, &byte, 1) == 0;
        receipt[@"originalPipeEOF"] = @(eof);
        receipt[@"responsibleAfter"] = @(diagnosticResponsible());
        need(eof && authorizeVisibleReturn(&t), @"postExitOwnershipOrForegroundChanged");
        uint32_t issued = 0;
        uint32_t code = np_corner_position(&s->member, s->held, t.displaced, t.original, NC_RESTORE,
                                           authorizeVisibleReturn, &t, &issued);
        t.unspent = NO;
        receipt[@"issued"] = @(issued);
        receipt[@"setterCode"] = @(code);
        need(issued == 1, @"guardedReturnWasNotIssued");
        reads = 0;
        for (unsigned i = 0; i < 25 && reads < 2; i++) {
            reads = stable(s, t.original) && visibleContinuity(&t) ? reads + 1 : 0;
            if (reads < 2)
                usleep(20000);
        }
        need(reads == 2, @"originalGeometryOrFocusNotRestored");
        NPGuardianFixtureObservation post = {.size = sizeof(post), .version = 1};
        int sampled = ncg_observe_retained(s->member.pid, s->member.birth, s->member.window,
                                           (__bridge CFStringRef)path, (__bridge CFStringRef)m[@"fixtureHash"],
                                           s->member.native, (__bridge CFStringRef)m[@"display"],
                                           (__bridge CFStringRef)m[@"space"], s->held, &post);
        receipt[@"sampleCode"] = @(sampled);
        receipt[@"postReads"] = @[ survivalRead(&post.first), survivalRead(&post.second) ];
        need(sampled == 0 && survivalProof(&post) && [survivalFrame(post.first.cg) isEqual:receipt[@"original"]] &&
                 [survivalFrame(post.second.cg) isEqual:receipt[@"original"]] && visibleContinuity(&t),
             @"finalOriginalWitnessIncomplete");
        receipt[@"status"] = @"PASS";
    } @catch (NSException *failure) {
        receipt[@"reason"] = failure.reason ?: @"visibleReturnIncomplete";
    }
    if (s->held)
        np_corner_release_window(s->held);
    if (t.focus)
        CFRelease(t.focus);
    if (s->kqueue >= 0)
        close(s->kqueue);
    BOOL saved = s->dir >= 0 && persistJobRecord(s->dir, NCFinal, receipt);
    if (s->dir >= 0)
        close(s->dir);
    if (!armed)
        (void)write(STDOUT_FILENO, "REFUSED\n", 8);
    return saved ? 0 : 4;
}
