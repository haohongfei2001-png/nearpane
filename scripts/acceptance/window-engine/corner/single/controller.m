#import "lease.h"
#import "macos.h"
#import "nearpane_window_engine.h"
#import "scope_binding.h"
#import <CommonCrypto/CommonDigest.h>
#include <signal.h>
#include <sys/sysctl.h>

static NSMutableDictionary *report;

static uint32_t baseline[14];
static uint8_t salt[16];
static NSString *originalFocus, *expectedControllerHash, *expectedWindowHash;
static NSString *codeHash(pid_t pid, BOOL child) {
    NSData *hash = singleCode(pid, child);
    if (!hash)
        return nil;
    NSMutableString *v = [NSMutableString string];
    const uint8_t *bytes = hash.bytes;
    for (NSUInteger i = 0; i < hash.length; i++)
        [v appendFormat:@"%02x", bytes[i]];
    return v;
}
static NSDictionary *originalHome;
static uint64_t handle, epoch;
static BOOL attempted = NO, aborted = NO;
static void pauseFor(double sec) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:sec]];
}
static void need(BOOL ok, NSString *why) {
    if (!ok)
        @throw [NSException exceptionWithName:@"stop" reason:why userInfo:nil];
}
static void row(NSString *event, NSDictionary *v) {
    NSMutableDictionary *m = [v mutableCopy];
    m[@"event"] = event;
    m[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    singleWrite(STDOUT_FILENO, m);
}
static NSString *front(void) {
    NSRunningApplication *running = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t pid = running.processIdentifier, axpid = 0;
    uint64_t b = ncg_birth(pid, NULL);
    CGWindowID n = 0;
    if (!b || pid == getpid() || !AXIsProcessTrusted())
        return nil;
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    CFTypeRef app = NULL, win = NULL;
    BOOL ok = sys && AXUIElementSetMessagingTimeout(sys, .1f) == kAXErrorSuccess &&
              AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, &app) == kAXErrorSuccess && app &&
              CFGetTypeID(app) == AXUIElementGetTypeID() &&
              AXUIElementGetPid((AXUIElementRef)app, &axpid) == kAXErrorSuccess && axpid == pid &&
              AXUIElementSetMessagingTimeout((AXUIElementRef)app, .1f) == kAXErrorSuccess;
    if (ok) {
        AXError rc = AXUIElementCopyAttributeValue((AXUIElementRef)app, kAXFocusedWindowAttribute, &win);
        if (rc == kAXErrorNoValue && !win)
            n = 0;
        else {
            typedef AXError (*N)(AXUIElementRef, CGWindowID *);
            N number = (N)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
            ok = rc == kAXErrorSuccess && win && CFGetTypeID(win) == AXUIElementGetTypeID() && number &&
                 AXUIElementGetPid((AXUIElementRef)win, &axpid) == kAXErrorSuccess && axpid == pid &&
                 number((AXUIElementRef)win, &n) == kAXErrorSuccess && n > 0;
        }
    }
    if (sys)
        CFRelease(sys);
    if (app)
        CFRelease(app);
    if (win)
        CFRelease(win);
    if (!ok || !n || ncg_birth(pid, NULL) != b ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != pid)
        return nil;
    uint8_t facts[32], digest[CC_SHA256_DIGEST_LENGTH];
    memcpy(facts, salt, 16);
    memcpy(facts + 16, &pid, 4);
    memcpy(facts + 20, &b, 8);
    memcpy(facts + 28, &n, 4);
    CC_SHA256(facts, sizeof(facts), digest);
    NSMutableString *h = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(digest); i++)
        [h appendFormat:@"%02x", digest[i]];
    return h;
}
static NSDictionary *home(NSMutableDictionary *facts) {
    NCDisplay d = {0};
    uint32_t n = 0;
    BOOL actual = !np_corner_displays(&d, 1, &n) && n == 1;
    uint32_t a = 0;
    CGDirectDisplayID id = 0;
    BOOL main = actual && CGGetActiveDisplayList(1, &id, &a) == kCGErrorSuccess && a == 1 &&
                id == CGMainDisplayID() && !CGDisplayIsInMirrorSet(id);
    typedef int (*Conn)(void);
    typedef CFArrayRef (*Inv)(int);
    void *l = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    Conn conn = l ? (Conn)dlsym(l, "SLSMainConnectionID") : NULL;
    Inv copy = l ? (Inv)dlsym(l, "SLSCopyManagedDisplaySpaces") : NULL;
    int c = conn ? conn() : 0;
    NSArray *rows = c > 0 && copy ? CFBridgingRelease(copy(c)) : nil;
    NSDictionary *m =
        [rows isKindOfClass:NSArray.class] && rows.count == 1 && [rows[0] isKindOfClass:NSDictionary.class]
            ? rows[0]
            : @{};
    facts[@"activePhysicalCount"] = @(n);
    facts[@"managedDisplayCount"] = @([rows isKindOfClass:NSArray.class] ? rows.count : 0);
    NSDictionary *bound = nc_bound_scope(m, actual ? [[NSUUID alloc] initWithUUIDBytes:d.uuid].UUIDString : nil,
                                         main, nc_direct_home(c, m[@"Display Identifier"]), facts);
    if (l)
        dlclose(l);
    return bound;
}
static NSString *stage(void) {
    id x = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"), CFSTR("com.apple.WindowManager")));
    if (x) {
        if (CFGetTypeID((__bridge CFTypeRef)x) != CFBooleanGetTypeID())
            return @"UNKNOWN";
        return [x boolValue] ? @"ON" : @"OFF";
    }
    for (NSString *h in
         @[ (__bridge NSString *)kCFPreferencesCurrentHost, (__bridge NSString *)kCFPreferencesAnyHost ]) {
        id domain = CFBridgingRelease(CFPreferencesCopyMultiple(
            NULL, CFSTR("com.apple.WindowManager"), kCFPreferencesCurrentUser, (__bridge CFStringRef)h));
        if (![domain isKindOfClass:NSDictionary.class])
            return @"UNKNOWN";
    }
    return @"OFF";
}
static void hid(uint32_t out[14]) {
    np_corner_inputs(out);
    out[13] = CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventMouseMoved);
}
static NSDictionary *scopeReading(void);
static BOOL unchanged(void) {
    uint32_t curr[14];
    hid(curr);
    return !memcmp(curr, baseline, sizeof(curr)) && !np_corner_secure_input() && [stage() isEqual:@"OFF"] &&
           [scopeReading()[@"scope"] isEqual:originalHome] && [front() isEqual:originalFocus];
}
static NSDictionary *readLine(int fd) {
    char bytes[2200];
    size_t used = 0;
    double end = NSProcessInfo.processInfo.systemUptime + 1.8;
    while (NSProcessInfo.processInfo.systemUptime < end && used < sizeof(bytes)) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 0) <= 0) {
            pauseFor(.008);
            continue;
        }
        ssize_t got = read(fd, bytes + used, sizeof(bytes) - used);
        if (got <= 0)
            return nil;
        used += (size_t)got;
        if (bytes[used - 1] == '\n') {
            id obj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:used]
                                                     options:0
                                                       error:NULL];
            return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        }
    }
    return nil;
}
static NSDictionary *owner(int send, int receive, unsigned *seq) {
    need(write(send, "Q", 1) == 1, @"ownFixtureChannelClosed");
    NSDictionary *r = readLine(receive);
    BOOL valid = r && [r[@"sequence"] unsignedIntValue] == ++*seq && singleInvisible(r);
    if (!valid) {
        NSArray *keys = @[
            @"sequence", @"window", @"pid", @"birth", @"alpha", @"clickThrough", @"opaque", @"canKey", @"canMain",
            @"key", @"main", @"activeApp", @"onActiveSpace", @"ordered", @"panel", @"shadow", @"mini"
        ];
        NSMutableDictionary *facts = [NSMutableDictionary dictionary];
        for (NSString *key in keys)
            if ([r[key] isKindOfClass:NSNumber.class])
                facts[key] = r[key];
        facts[@"hasReply"] = @(r != nil);
        row(@"fixturePropertiesNotConfirmed", facts);
    }
    need(valid, @"ordinaryChildNotProvenFullyInvisibleAndNoninteractive");
    return r;
}
static NSArray *coreFrame(uint32_t number, pid_t pid, BOOL listed) {
    if (listed) {
        // Only the numeric on-screen roster is needed; retrieve dictionaries solely for our one window.
        CFArrayRef ids = CGWindowListCreate(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!ids)
            return nil;
        unsigned exact = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(ids); i++)
            if ((uintptr_t)CFArrayGetValueAtIndex(ids, i) == number)
                exact++;
        CFRelease(ids);
        if (exact != 1)
            return nil;
    }
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, number));
    NSArray *found = nil;
    for (NSDictionary *r in rows)
        if ([r[(__bridge NSString *)kCGWindowNumber] isEqual:@(number)]) {
            CGRect f;
            if (found || ![r[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(pid)] ||
                ![r[(__bridge NSString *)kCGWindowLayer] isEqual:@0] ||
                ![r[(__bridge NSString *)kCGWindowAlpha] isEqual:@0] ||
                ![r[(__bridge NSString *)kCGWindowIsOnscreen] isEqual:@YES] ||
                !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)r[(__bridge NSString *)kCGWindowBounds], &f))
                return nil;
            found = @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ];
        }
    return found;
}
static NPReceipt op(NPRequest r, uint32_t operation, BOOL cancelIfChanged) {
    r.operation = operation;
    r.epoch = epoch;
    r.timeout_ms = 1500;
    [NSUUID.UUID getUUIDBytes:r.intent];
    uint64_t ticket = 0;
    NPReceipt out = {.size = sizeof(out), .version = 1};
    need(!cancelIfChanged || unchanged(), @"newInputFocusOrDesktopBeforeEngineRequest");
    need(np_engine_submit(handle, &r, &ticket) == NP_OK, @"signedEngineRejectedThisLease");
    if (operation == NP_HIDE || operation == NP_RESTORE) {
        attempted = YES;
        report[operation == NP_HIDE ? @"parkSubmitted" : @"restoreSubmitted"] = @YES;
        row(@"submitted", @{@"operation" : @(operation), @"ownWindow" : @(r.window)});
    }
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
    double next = NSProcessInfo.processInfo.systemUptime + .025;
    for (;;) {
        uint32_t rc = np_engine_poll(handle, ticket, &out);
        if (rc == NP_OK)
            break;
        need(rc == NP_PENDING && end.timeIntervalSinceNow > 0, @"engineDeliveryUnknown");
        if (cancelIfChanged && NSProcessInfo.processInfo.systemUptime >= next) {
            next = NSProcessInfo.processInfo.systemUptime + .05;
            if (!aborted && !unchanged()) {
                aborted = YES;
                np_engine_cancel(handle, ticket);
            }
        }
        pauseFor(.006);
    }
    need(out.epoch == epoch && !memcmp(out.intent, r.intent, 16), @"engineReceiptIdentityChanged");
    row(
        @"engine", @{
            @"operation" : @(operation),
            @"status" : @(out.status),
            @"flags" : @(out.flags),
            @"detail" : @(out.detail),
            @"owned" : @(out.owned),
            @"actualFrame" : @[ @(out.frame.x), @(out.frame.y), @(out.frame.width), @(out.frame.height) ]
        });
    return out;
}
static NSArray *observed(NPRequest r, int send, int recv, unsigned *seq, NSArray *wanted, NSString *phase) {
    NSDictionary *w = owner(send, recv, seq);
    NSArray *f = w[@"frame"], *cg = coreFrame(r.window, r.pid, NO), *onscreen = coreFrame(r.window, r.pid, YES);
    NCMember member = {.pid = r.pid, .window = r.window, .birth = r.birth, .native = r.native_id};
    memcpy(member.display, r.display, 16);
    memcpy(member.space, r.native_space, 16);
    NCSample evidence = {0};
    unsigned rc = np_corner_sample(&member, &evidence);
    NSArray *ax = @[ @(evidence.ax.x), @(evidence.ax.y), @(evidence.ax.w), @(evidence.ax.h) ];
    BOOL identity =
        [w[@"pid"] isEqual:@(r.pid)] && [w[@"birth"] isEqual:@(r.birth)] && [w[@"window"] isEqual:@(r.window)];
    BOOL correct = identity && !rc && evidence.onscreen && !evidence.minimized && singleNear(cg, f) &&
                   singleNear(onscreen, f) && singleNear(ax, f) && (!wanted || singleNear(f, wanted));
    row(
        @"ownedWindow", @{
            @"phase" : phase,
            @"window" : @(r.window),
            @"ownerVersion" : w[@"sequence"],
            @"ownerFrame" : f ?: @[],
            @"zeroAlphaCGFrame" : cg ?: @[],
            @"listedWithZeroAlpha" : @(onscreen != nil),
            @"axScopeResult" : @(rc),
            @"standardAXFrame" : rc ? @[] : ax,
            @"exactOwnedWindow" : @(correct)
        });
    need(correct, @"zeroAlphaOrdinaryWindowNotIndependentlyOnscreenOrAXStandard");
    return f;
}
static NSDictionary *scopeReading(void) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    NSDictionary *bound = home(facts);
    // A physical lease always requires WindowServer's separate per-display current query, including UUID displays.
    if (!bound || ![facts[@"directWindowServerHome"] isEqual:bound[@"native"]])
        bound = nil;
    return @{@"scope" : bound ?: @{}, @"facts" : facts};
}
static BOOL preflight(void) {
    NSMutableArray *blocks = [NSMutableArray array];
    NSString *actualHash = codeHash(getpid(), NO);
    BOOL selfSigned = actualHash && [actualHash isEqual:expectedControllerHash];
    // LaunchServices starts our separate LSUIElement under launchd. A terminal child is ineligible.
    BOOL independent = getppid() == 1;
    typedef pid_t (*ResponsiblePID)(pid_t);
    ResponsiblePID responsible = (ResponsiblePID)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    pid_t responsiblePID = responsible ? responsible(getpid()) : -1;
    BOOL ownsResponsibility = responsiblePID == getpid();
    BOOL ax = AXIsProcessTrusted(), post = CGPreflightPostEventAccess(), listen = CGPreflightListenEventAccess();
    BOOL console = getuid() != 0 && geteuid() == getuid();
    CFDictionaryRef dict = CGSessionCopyCurrentDictionary();
    if (dict) {
        NSDictionary *s = CFBridgingRelease(dict);
        console = console && [s[(__bridge NSString *)kCGSessionUserIDKey] isEqual:@(getuid())] &&
                  [s[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] &&
                  [s[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES];
    } else
        console = NO;
    BOOL secure = np_corner_secure_input() != 0;
    BOOL mayReadPrivateFocusIdentity = selfSigned && independent && ownsResponsibility && console && ax;
    NSString *wm = stage(), *focus = mayReadPrivateFocusIdentity ? front() : nil;
    hid(baseline);
    NSDictionary *first = scopeReading();
    row(@"scope1", first);
    pauseFor(.12);
    uint32_t again[14];
    hid(again);
    NSString *f2 = mayReadPrivateFocusIdentity ? front() : nil;
    NSDictionary *last = scopeReading();
    row(@"scope2", last);
    BOOL hidStable = !memcmp(baseline, again, sizeof(again)), focusStable = focus && [focus isEqual:f2];
    originalFocus = focus;
    originalHome = first[@"scope"];
    BOOL stable = originalHome.count && [originalHome isEqual:last[@"scope"]];
    if (!selfSigned)
        [blocks addObject:@"controllerDynamicAndStaticSignatureMismatch"];
    if (!independent)
        [blocks addObject:@"controllerNotIndependentlyLaunchedByLaunchServices"];
    if (!ownsResponsibility)
        [blocks addObject:@"separateControllerIsNotItsOwnResponsibilitySubject"];
    if (!console)
        [blocks addObject:@"notActiveLocalConsoleUser"];
    if (!ax)
        [blocks addObject:@"separateControllerAccessibilityNotAlreadyGranted"];
    if (!post)
        [blocks addObject:@"separateControllerEventFilteringAccessNotAlreadyGranted"];
    if (secure || np_corner_secure_input())
        [blocks addObject:@"secureInputActive"];
    if (![wm isEqual:@"OFF"] || ![wm isEqual:stage()])
        [blocks addObject:@"stageManagerNotConfirmedOff"];
    if (!hidStable)
        [blocks addObject:@"physicalInputChanged"];
    if (!focusStable)
        [blocks addObject:@"externalExactFocusNotConfirmedTwice"];
    if (!stable)
        [blocks addObject:@"singleActiveOrdinaryDisplayAndSpaceNotConfirmedTwice"];
    row(
        @"preflight", @{
            @"signed" : @(selfSigned),
            @"controllerCDHash" : actualHash ?: [NSNull null],
            @"launchdParent" : @(independent),
            @"ownResponsibilitySubject" : @(ownsResponsibility),
            @"console" : @(console),
            @"accessibilityAlreadyGranted" : @(ax),
            @"postEventAlreadyGranted" : @(post),
            @"listenEventAlreadyGranted" : @(listen),
            @"secureInput" : @(secure),
            @"stage" : wm,
            @"stableFocus" : @(focusStable),
            @"saltedFocusedWindow1" : focus ?: [NSNull null],
            @"saltedFocusedWindow2" : f2 ?: [NSNull null],
            @"stableHID14" : @(hidStable),
            @"stablePhysicalScope" : @(stable),
            @"blockingReasons" : blocks
        });
    report[@"blockingReasons"] = blocks;
    report[@"preflightPassed"] = @(blocks.count == 0);
    return blocks.count == 0;
}
static BOOL selfTest(void) {
    NSArray *f = @[ @1, @2, @100, @80 ];
    return singleNear(f, @[ @1.75, @2, @100, @80 ]) && !singleNear(f, @[ @1.76, @2, @100, @80 ]) &&
           !singleNear(f, @[ @1, @2, @0, @1 ]) && !singleInvisible(@{});
}
static NSArray *box(NPRect r) { return @[ @(r.x), @(r.y), @(r.width), @(r.height) ]; }
static NPRect asRect(NSArray *f) {
    return (NPRect){[f[0] doubleValue], [f[1] doubleValue], [f[2] doubleValue], [f[3] doubleValue]};
}
static void requireRead(NPReceipt v, unsigned flags, NPRequest r, NSArray *f) {
    need(!aborted && v.status == NP_PASS && (v.flags & flags) == flags && v.native_id == r.native_id &&
             v.owned == ((flags & NP_OWNED) ? 1 : 0) && singleNear(box(v.frame), f),
         @"engineWindowOrFootprintNotConfirmed");
}
static void readTwice(NPRequest r, int send, int recv, unsigned *seq, NSArray *frame, NSString *phase,
                      unsigned flags) {
    for (unsigned i = 0; i < 2; i++) {
        if (i)
            pauseFor(.07);
        requireRead(op(r, NP_READBACK, YES), flags, r, frame);
        observed(r, send, recv, seq, frame, phase);
        need(unchanged(), @"inputFocusOrDesktopChangedDuringIndependentReadback");
    }
}
static BOOL completelyClosed(CGWindowID number, pid_t pid, uint64_t birth) {
    if (ncg_birth(pid, NULL) == birth)
        return NO;
    if (!number)
        return YES;
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, number));
    if (![rows isKindOfClass:NSArray.class]) {
        CFArrayRef ids = CGWindowListCreate(kCGWindowListOptionAll, kCGNullWindowID);
        if (!ids)
            return NO;
        BOOL absent = YES;
        for (CFIndex i = 0; i < CFArrayGetCount(ids); i++)
            if ((uintptr_t)CFArrayGetValueAtIndex(ids, i) == number)
                absent = NO;
        CFRelease(ids);
        return absent;
    }
    for (NSDictionary *w in rows)
        if ([w[(__bridge NSString *)kCGWindowNumber] isEqual:@(number)] &&
            [w[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(pid)])
            return NO;
    return YES;
}
static void runGeometry(void) {
    NSTask *child = [NSTask new];
    NSPipe *to = [NSPipe pipe], *from = [NSPipe pipe];
    int tx = to.fileHandleForWriting.fileDescriptor, rx = from.fileHandleForReading.fileDescriptor;
    fcntl(tx, F_SETNOSIGPIPE, 1);
    pid_t pid = 0;
    uint64_t birth = 0;
    CGWindowID win = 0;
    unsigned seq = 0;
    @try {
        need(unchanged(), @"newHumanInputBeforeChildLaunch");
        child.executableURL = [NSURL fileURLWithPath:singlePath(YES)];
        child.arguments = @[ @"--one-window" ];
        child.standardInput = to;
        child.standardOutput = from;
        child.standardError = NSFileHandle.fileHandleWithNullDevice;
        need([child launchAndReturnError:nil], @"signedChildLaunchFailed");
        pid = child.processIdentifier;
        NSDictionary *ready = readLine(rx);
        pid_t parent = 0;
        birth = ncg_birth(pid, &parent);
        NSString *windowHash = codeHash(pid, YES);
        need(parent == getpid() && birth && [ready[@"phase"] isEqual:@"ready"] && [ready[@"pid"] isEqual:@(pid)] &&
                 [ready[@"birth"] isEqual:@(birth)] && windowHash && [windowHash isEqual:expectedWindowHash],
             @"directChildSignatureOrBirthNotConfirmed");
        row(
            @"fixtureIdentity",
            @{@"windowCDHash" : windowHash,
              @"directChild" : @YES,
              @"pid" : @(pid),
              @"birth" : @(birth)});
        need(unchanged(), @"newHumanInputBeforeWindowCreation");
        need(write(tx, "C", 1) == 1, @"ownerCreateChannelClosed");
        report[@"windowRequested"] = @YES;
        NSDictionary *start = owner(tx, rx, &seq);
        NSArray *original = start[@"frame"];
        win = [start[@"window"] unsignedIntValue];
        need(win > 0 && [start[@"pid"] isEqual:@(pid)] && [start[@"birth"] isEqual:@(birth)] &&
                 singleSize(original),
             @"invalidOriginalOwnedWindow");
        NPRequest r = {.size = sizeof(r),
                       .version = NP_ENGINE_ABI,
                       .backend = NP_CORNER,
                       .pid = pid,
                       .birth = birth,
                       .window = win,
                       .native_id = [originalHome[@"native"] unsignedLongLongValue]};
        [NSUUID.UUID getUUIDBytes:r.group];
        [NSUUID.UUID getUUIDBytes:r.member];
        [NSUUID.UUID getUUIDBytes:r.lifetime];
        [NSUUID.UUID getUUIDBytes:r.generation];
        [[[NSUUID alloc] initWithUUIDString:originalHome[@"display"]] getUUIDBytes:r.display];
        [[[NSUUID alloc] initWithUUIDString:originalHome[@"space"]] getUUIDBytes:r.native_space];
        r.frame = asRect(original);
        r.target = r.frame;
        observed(r, tx, rx, &seq, original, @"admission");
        NPConfig config = {.size = sizeof(config),
                           .version = NP_ENGINE_ABI,
                           .mode = NP_ISOLATED_FIXTURE,
                           .process_count = 1,
                           .processes = {{.pid = pid, .birth = birth}}};
        need(np_engine_create(&config, &handle) == NP_OK && np_engine_epoch(handle, &epoch) == NP_OK && epoch > 0,
             @"couldNotBindSignedChildEngine");
        unsigned real = NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID;
        readTwice(r, tx, rx, &seq, original, @"original", real | NP_VISIBLE);
        NPReceipt health = op(r, NP_HEALTH, YES);
        need(!aborted && health.status == NP_PASS &&
                 (health.flags & (NP_HEALTHY | NP_INPUT_SAFE)) == (NP_HEALTHY | NP_INPUT_SAFE),
             @"emptyRecipientEventTapNotConfirmedHealthy");
        NPReceipt hidden = op(r, NP_HIDE, YES);
        NSArray *park = box(hidden.frame);
        requireRead(hidden, real | NP_HIDDEN | NP_OWNED | NP_INPUT_SAFE, r, park);
        CGRect display = CGDisplayBounds(CGMainDisplayID()),
               actual = CGRectMake(hidden.frame.x, hidden.frame.y, hidden.frame.width, hidden.frame.height);
        CGRect slit = CGRectIntersection(actual, display);
        need(!CGRectIsNull(slit) && !CGRectIsEmpty(slit) && slit.size.width <= 8.0 && !singleNear(park, original) &&
                 fabs(hidden.frame.width - r.frame.width) <= .75 &&
                 fabs(hidden.frame.height - r.frame.height) <= .75,
             @"parkGeometryDidNotPhysicallyMoveToSliver");
        readTwice(r, tx, rx, &seq, park, @"parked", real | NP_HIDDEN | NP_OWNED | NP_INPUT_SAFE);
        row(@"parkConfirmed", @{@"original" : original, @"parked" : park, @"sliverWidth" : @(slit.size.width)});
        requireRead(op(r, NP_RESTORE, YES), real | NP_VISIBLE, r, original);
        readTwice(r, tx, rx, &seq, original, @"restored", real | NP_VISIBLE);
        report[@"originalGeometryRestored"] = @YES;
    } @finally {
        if (handle) {
            uint32_t rc = np_engine_destroy(handle);
            report[@"engineClose"] = @(rc);
            if (rc == NP_OK)
                handle = 0;
        }
        if (pid > 1) {
            if (child.running)
                write(tx, "X", 1);
            [to.fileHandleForWriting closeFile];
            double until = NSProcessInfo.processInfo.systemUptime + 2;
            while (child.running && NSProcessInfo.processInfo.systemUptime < until)
                pauseFor(.015);
            report[@"fixtureExited"] = @(!child.running);
            report[@"ownedWindowGone"] = @(!child.running && birth && completelyClosed(win, pid, birth));
        }
        uint32_t last[14];
        hid(last);
        report[@"originalHIDUnchanged"] = @(!memcmp(baseline, last, sizeof(last)));
        NSString *focus = front();
        NSDictionary *scope = scopeReading()[@"scope"];
        pauseFor(.06);
        report[@"externalExactFocusPreserved"] =
            @(originalFocus && [originalFocus isEqual:focus] && [focus isEqual:front()]);
        report[@"originalDisplaySpacePreserved"] =
            @(originalHome.count && [originalHome isEqual:scope] && [scope isEqual:scopeReading()[@"scope"]]);
    }
    need([report[@"engineClose"] isEqual:@0] && [report[@"fixtureExited"] isEqual:@YES] &&
             [report[@"ownedWindowGone"] isEqual:@YES] && [report[@"externalExactFocusPreserved"] isEqual:@YES] &&
             [report[@"originalDisplaySpacePreserved"] isEqual:@YES] &&
             [report[@"originalHIDUnchanged"] isEqual:@YES],
         @"restorationOrFinalIndependentStateNotConfirmed");
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--self-test"))
            return selfTest() ? 0 : 1;
        BOOL execute = argc == 4 && !strcmp(argv[1], "run");
        if (!execute && (argc != 4 || strcmp(argv[1], "preflight")))
            return 2;
        expectedControllerHash = [NSString stringWithUTF8String:argv[2]];
        expectedWindowHash = [NSString stringWithUTF8String:argv[3]];
        fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1);
        [NSUUID.UUID getUUIDBytes:salt];
        report = [@{
            @"status" : @"UNKNOWN",
            @"mode" : execute ? @"run" : @"preflight",
            @"scope" : execute ? @"oneTransparentOrdinaryWindowGeometry" : @"noPromptPermissionAndPhysicalScope",
            @"windowRequested" : @NO,
            @"parkSubmitted" : @NO,
            @"restoreSubmitted" : @NO,
            @"originalGeometryRestored" : @NO,
            @"qualification" : @"UNQUALIFIED",
            @"fullCycle" : @"NOT_RUN",
            @"pixelsAndClickShield" : @"NOT_MEASURED",
            @"globalEventsPosted" : @0,
            @"preferenceWrites" : @0,
            @"thirdPartyWindowWrites" : @0
        } mutableCopy];
        @try {
            need(preflight(), @"preflightNotAdmitted");
            if (execute)
                runGeometry();
            report[@"status"] = @"PASS";
        } @catch (NSException *e) {
            report[@"status"] = attempted ? @"UNKNOWN" : @"BLOCKED";
            report[@"reason"] = [e.name isEqual:@"stop"] ? e.reason : @"unexpectedControllerException";
        }
        row(@"terminal", report);
        return 0;
    }
}
