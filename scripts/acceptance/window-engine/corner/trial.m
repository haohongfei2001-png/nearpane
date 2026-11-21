// Signed test controller. All OS input is admitted only in a disposable login and either
// over one of its two exact signed child process windows or the exposed strip of that same window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <libproc.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import "nearpane_window_engine.h"
#import "cycles.h"
#import "picture.h"
#import "scope_binding.h"
#import "guardian/protocol.h"
#import "guardian/identity.h"
#include <fcntl.h>
#include <poll.h>
#include <signal.h>

static NSString *output;
static BOOL crashMode;
static NSMutableDictionary *result;
static NSMutableArray<NSTask *> *children;
static FILE *logFile;
static uint64_t handle, epoch;
static void stop(NSString *status, NSString *reason) {
    @throw [NSException exceptionWithName:status reason:reason userInfo:nil];
}
static void require(BOOL ok, NSString *reason) {
    if (!ok)
        stop(@"BLOCKED", reason);
}
static void event(NSString *kind, NSDictionary *fields) {
    NSMutableDictionary *row = [fields mutableCopy];
    row[@"stage"] = kind;
    row[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];
    fwrite(data.bytes, 1, data.length, logFile);
    fputc('\n', logFile);
    fflush(logFile);
}
static void save(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    [data writeToFile:[output stringByAppendingPathComponent:crashMode ? @"crash-host.json" : @"result.json"]
           atomically:YES];
}
static void pauseFor(double seconds) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static NSArray *owners(void) {
    NSString *nonce = NSUUID.UUID.UUIDString;
    require([nonce writeToFile:[output stringByAppendingPathComponent:@"sample"]
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL],
            @"ownerChallengeWrite");
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2.0];
    do {
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *key in @[ @"a", @"b" ]) {
            NSData *raw = [NSData
                dataWithContentsOfFile:[output
                                           stringByAppendingPathComponent:[key stringByAppendingString:@".json"]]];
            id s = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
            if ([s[@"nonce"] isEqual:nonce])
                [found addObject:s];
        }
        if (found.count == 2)
            return found;
        pauseFor(.025);
    } while ([end timeIntervalSinceNow] > 0);
    stop(@"BLOCKED", @"independentOwnerChallengeTimedOut");
    return nil;
}
static NSArray *frameList(CGRect f) {
    return @[ @(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height) ];
}
static NPRect rect(NSArray *a) {
    return (NPRect){[a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]};
}
static NSArray *unpack(NPRect f) { return @[ @(f.x), @(f.y), @(f.width), @(f.height) ]; }
static BOOL closeFrame(NSArray *a, NSArray *b) {
    if (a.count != 4 || b.count != 4)
        return NO;
    for (int i = 0; i < 4; i++)
        if (fabs([a[i] doubleValue] - [b[i] doubleValue]) > .75)
            return NO;
    return YES;
}
static void uuid(NSString *s, uint8_t *out) {
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
    require(u != nil, @"sourceUUIDUnavailable");
    [u getUUIDBytes:out];
}
static NSArray *cgFrame(NSNumber *number, NSNumber *pid) {
    NSArray *a =
        CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, number.unsignedIntValue));
    if (a.count != 1)
        return nil;
    NSDictionary *w = a.firstObject;
    CGRect r;
    if (![w[(__bridge NSString *)kCGWindowOwnerPID] isEqual:pid] ||
        ![w[(__bridge NSString *)kCGWindowNumber] isEqual:number] ||
        !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(__bridge NSString *)kCGWindowBounds],
                                                &r))
        return nil;
    return frameList(r);
}
static NSDictionary *scope(void) {
    typedef int (*Main)(void);
    typedef CFArrayRef (*Copy)(int);
    void *library =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
    require(library != NULL, @"readOnlyNativeScopeUnavailable");
    Main conn = (Main)dlsym(library, "SLSMainConnectionID");
    Copy read = (Copy)dlsym(library, "SLSCopyManagedDisplaySpaces");
    require(conn && read, @"readOnlyNativeScopeGettersUnavailable");
    NSDictionary *first = nil;
    NSMutableArray *evidence = [NSMutableArray array];
    for (unsigned i = 0; i < 2; i++) {
        int c = conn();
        NSArray *rows = c > 0 ? CFBridgingRelease(read(c)) : nil;
        CGDirectDisplayID ids[2];
        uint32_t count = 0;
        CGError queried = CGGetActiveDisplayList(2, ids, &count);
        BOOL single = queried == kCGErrorSuccess && count == 1 && ids[0] == CGMainDisplayID() &&
                      !CGDisplayIsInMirrorSet(ids[0]) && NSScreen.screens.count == 1 &&
                      [NSScreen.screens[0].deviceDescription[@"NSScreenNumber"] isEqual:@(ids[0])];
        CFUUIDRef nativeUUID = single ? CGDisplayCreateUUIDFromDisplayID(ids[0]) : NULL;
        NSString *uuid = nativeUUID ? CFBridgingRelease(CFUUIDCreateString(NULL, nativeUUID)) : nil;
        if (nativeUUID)
            CFRelease(nativeUUID);
        NSMutableDictionary *facts = [@{
            @"read" : @(i + 1),
            @"connectionAvailable" : @(c > 0),
            @"cgDisplayCount" : @(count),
            @"appKitScreenCount" : @(NSScreen.screens.count),
            @"managedDisplayCount" : @([rows isKindOfClass:NSArray.class] ? rows.count : 0)
        } mutableCopy];
        NSDictionary *row =
            [rows isKindOfClass:NSArray.class] && rows.count == 1 && [rows[0] isKindOfClass:NSDictionary.class]
                ? rows[0]
                : @{};
        NSDictionary *bound =
            nc_bound_scope(row, uuid, single, nc_direct_home(c, row[@"Display Identifier"]), facts);
        [evidence addObject:facts];
        if (!i)
            first = bound;
        if (i == 0)
            pauseFor(.025);
        if (i == 1 && (!first || ![first isEqual:bound])) {
            event(@"nativeScopeRejected", @{@"reads" : evidence});
            result[@"nativeScopeReads"] = evidence;
            save();
            stop(@"BLOCKED", !bound ? facts[@"reason"] : @"twoIndependentScopeReadsDisagree");
        }
    }
    if (!result[@"nativeScopePreflight"]) {
        result[@"nativeScopePreflight"] = evidence;
        save();
    }
    return first;
}
static NPReceipt requestID(NPRequest r, uint32_t op, const uint8_t requested[16]) {
    r.operation = op;
    r.epoch = epoch;
    r.timeout_ms = 4000;
    if (requested)
        memcpy(r.intent, requested, 16);
    else
        [NSUUID.UUID getUUIDBytes:r.intent];
    uint64_t ticket = 0;
    NPReceipt receipt = {.size = sizeof(NPReceipt), .version = 1};
    require(np_engine_submit(handle, &r, &ticket) == NP_OK, @"productionABIRejectedFixtureRequest");
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:6];
    for (;;) {
        uint32_t poll = np_engine_poll(handle, ticket, &receipt);
        if (poll == NP_OK)
            break;
        require(poll == NP_PENDING && end.timeIntervalSinceNow > 0, @"receiptUnavailable");
        pauseFor(.008);
    }
    require(memcmp(receipt.intent, r.intent, 16) == 0 && receipt.epoch == r.epoch, @"uncorrelatedEngineReply");
    event(
        @"engine", @{
            @"operation" : @(op),
            @"window" : @(r.window),
            @"pid" : @(r.pid),
            @"status" : @(receipt.status),
            @"frame" : unpack(receipt.frame),
            @"detail" : @(receipt.detail),
            @"flags" : @(receipt.flags),
            @"owned" : @(receipt.owned),
            @"intent" : [[NSUUID alloc] initWithUUIDBytes:r.intent].UUIDString,
            @"elapsedNs" : @(receipt.elapsed_ns)
        });
    return receipt;
}
static NPReceipt request(NPRequest r, uint32_t op) { return requestID(r, op, NULL); }
static int dockTiles(void) {
    NSArray *d = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (d.count != 1)
        return -1;
    AXUIElementRef app = AXUIElementCreateApplication([d[0] processIdentifier]);
    AXUIElementSetMessagingTimeout(app, .18f);
    CFTypeRef raw = NULL;
    AXUIElementCopyAttributeValue(app, kAXChildrenAttribute, &raw);
    NSArray *children = CFBridgingRelease(raw);
    CFRelease(app);
    int lists = 0, minis = 0, applications = 0;
    for (id x in children) {
        AXUIElementRef e = (__bridge AXUIElementRef)x;
        CFTypeRef r = NULL;
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute, &r);
        if (![CFBridgingRelease(r) isEqual:(__bridge NSString *)kAXListRole])
            continue;
        lists++;
        CFTypeRef v = NULL;
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &v);
        NSArray *items = CFBridgingRelease(v);
        if (!items.count || items.count > 1024)
            return -1;
        for (id item in items) {
            CFTypeRef s = NULL;
            AXUIElementCopyAttributeValue((__bridge AXUIElementRef)item, kAXSubroleAttribute, &s);
            NSString *role = CFBridgingRelease(s);
            if (!role)
                return -1;
            if ([role isEqual:(__bridge NSString *)kAXMinimizedWindowDockItemSubrole])
                minis++;
            if ([role isEqual:(__bridge NSString *)kAXApplicationDockItemSubrole])
                applications++;
        }
    }
    return lists == 1 && applications ? minis : -1;
}
static BOOL exactAX(CGPoint at, NPRequest *r) {
    typedef AXError (*Get)(AXUIElementRef, CGWindowID *);
    static Get get;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      get = (Get)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    if (!get)
        return NO;
    AXUIElementRef sys = AXUIElementCreateSystemWide(), hit = NULL;
    AXUIElementSetMessagingTimeout(sys, .15f);
    AXError rc = AXUIElementCopyElementAtPosition(sys, at.x, at.y, &hit);
    CFRelease(sys);
    if (rc != kAXErrorSuccess || !hit)
        return NO;
    pid_t p = 0;
    AXUIElementGetPid(hit, &p);
    CGWindowID n = 0;
    if (p == r->pid) {
        get(hit, &n);
        if (!n) {
            CFTypeRef window = NULL;
            if (AXUIElementCopyAttributeValue(hit, kAXWindowAttribute, &window) == kAXErrorSuccess) {
                get((AXUIElementRef)window, &n);
                CFRelease(window);
            }
        }
    }
    CFRelease(hit);
    return p == r->pid && n == r->window;
}
static void gesture(CGPoint point, int index) {
    CGEventType phases[3][3] = {{kCGEventLeftMouseDown, kCGEventLeftMouseDragged, kCGEventLeftMouseUp},
                                {kCGEventRightMouseDown, kCGEventRightMouseDragged, kCGEventRightMouseUp},
                                {kCGEventOtherMouseDown, kCGEventOtherMouseDragged, kCGEventOtherMouseUp}};
    CGEventRef events[3] = {0};
    for (int i = 0; i < 3; i++) {
        events[i] = CGEventCreateMouseEvent(NULL, phases[index][i], point, (CGMouseButton)index);
        if (!events[i]) {
            for (int j = 0; j < i; j++)
                CFRelease(events[j]);
            stop(@"BLOCKED", @"entireMouseSequenceUnavailable");
        }
    }
    // Complete a released gesture even if focus changes after down.
    for (int i = 0; i < 3; i++) {
        CGEventSetIntegerValueField(events[i], kCGEventSourceUserData, 0x4e50434f);
        CGEventPost(kCGHIDEventTap, events[i]);
        CFRelease(events[i]);
        pauseFor(.014);
    }
}
static NSDictionary *window(NSArray *owners, NPRequest r) {
    for (NSDictionary *o in owners)
        if ([o[@"pid"] intValue] == r.pid && [o[@"birth"] unsignedLongLongValue] == r.birth)
            for (NSDictionary *w in o[@"rows"])
                if ([w[@"window"] unsignedIntValue] == r.window)
                    return w;
    return nil;
}
static BOOL noChange(NSArray *before, NSArray *after, uint32_t except, BOOL protectedFrame) {
    if (before.count != after.count)
        return NO;
    for (unsigned i = 0; i < before.count; i++) {
        NSDictionary *a = before[i], *b = after[i];
        if (![a[@"pid"] isEqual:b[@"pid"]] || ![a[@"birth"] isEqual:b[@"birth"]])
            return NO;
        NSArray *left = a[@"rows"], *right = b[@"rows"];
        if (left.count != right.count)
            return NO;
        for (unsigned j = 0; j < left.count; j++) {
            NSDictionary *l = left[j], *r = right[j];
            if (![l[@"window"] isEqual:r[@"window"]] || ![l[@"minimized"] isEqual:r[@"minimized"]] ||
                ![l[@"current"] isEqual:r[@"current"]])
                return NO;
            if ([l[@"window"] unsignedIntValue] == except) {
                if (protectedFrame &&
                    (!closeFrame(l[@"frame"], r[@"frame"]) || ![l[@"counts"] isEqual:r[@"counts"]]))
                    return NO;
            } else if (!closeFrame(l[@"frame"], r[@"frame"]) || ![l[@"counts"] isEqual:r[@"counts"]])
                return NO;
        }
    }
    return YES;
}
static BOOL positive(NPRequest reference, int cycle) {
    NSArray *before = owners();
    NSDictionary *w = window(before, reference);
    NPRect r = rect(w[@"frame"]);
    CGPoint at = {r.x + r.width / 2, r.y + r.height / 2};
    if (!exactAX(at, &reference))
        return NO;
    int button = cycle % 3;
    gesture(at, button);
    pauseFor(.12);
    NSArray *after = owners();
    NSArray *prev = w[@"counts"], *now = window(after, reference)[@"counts"];
    BOOL ok = noChange(before, after, reference.window, NO);
    for (int i = 0; i < 9; i++)
        ok &= ([now[i] integerValue] - [prev[i] integerValue] == (i / 3 == button ? 1 : 0));
    event(
        @"positiveReceiver", @{
            @"window" : @(reference.window),
            @"button" : @(button),
            @"prior" : prev,
            @"after" : now,
            @"pass" : @(ok)
        });
    return ok;
}
// The sliver point requires exact AX/PID/window readback. For its resize band AX can return
// the desktop. Allow that one point only when this is the unique layer-zero donor near it,
// in the same isolated login; any other non-desktop surface at that point blocks the input.
static BOOL dockClearAt(NSDictionary *row, CGPoint p) {
    if ([row[(__bridge NSString *)kCGWindowLayer] integerValue] != 20)
        return NO;
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (apps.count != 1)
        return NO;
    NSRunningApplication *app = apps[0];
    pid_t pid = app.processIdentifier;
    if (![row[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(pid)] ||
        ![app.executableURL.path isEqual:@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"])
        return NO;
    SecCodeRef code = NULL;
    SecRequirementRef req = NULL;
    OSStatus rc = SecCodeCopyGuestWithAttributes(
        NULL,
        (__bridge CFDictionaryRef)
            @{(__bridge NSString *)kSecGuestAttributePid : @(pid)},
        0, &code);
    if (rc == errSecSuccess)
        rc = SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.dock\""), 0, &req);
    if (rc == errSecSuccess)
        rc = SecCodeCheckValidity(code, 0, req);
    if (req)
        CFRelease(req);
    if (code)
        CFRelease(code);
    if (rc != errSecSuccess)
        return NO;
    AXUIElementRef root = AXUIElementCreateApplication(pid);
    CFTypeRef raw = NULL;
    AXUIElementSetMessagingTimeout(root, .12f);
    AXUIElementCopyAttributeValue(root, kAXChildrenAttribute, &raw);
    CFRelease(root);
    NSArray *children = CFBridgingRelease(raw);
    BOOL hasBar = NO;
    for (id item in children) {
        AXUIElementRef e = (__bridge AXUIElementRef)item;
        CFTypeRef role = NULL;
        pid_t owner = 0;
        if (AXUIElementGetPid(e, &owner) != kAXErrorSuccess || owner != pid ||
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute, &role) != kAXErrorSuccess)
            return NO;
        if (![CFBridgingRelease(role) isEqual:(__bridge NSString *)kAXListRole])
            continue;
        CFTypeRef x = NULL, y = NULL;
        CGPoint pos;
        CGSize size;
        AXUIElementCopyAttributeValue(e, kAXPositionAttribute, &x);
        AXUIElementCopyAttributeValue(e, kAXSizeAttribute, &y);
        BOOL ok = x && y && CFGetTypeID(x) == AXValueGetTypeID() && CFGetTypeID(y) == AXValueGetTypeID() &&
                  AXValueGetValue((AXValueRef)x, kAXValueTypeCGPoint, &pos) &&
                  AXValueGetValue((AXValueRef)y, kAXValueTypeCGSize, &size);
        if (x)
            CFRelease(x);
        if (y)
            CFRelease(y);
        if (!ok || size.width <= 0 || size.height <= 0 ||
            CGRectContainsPoint(CGRectInset((CGRect){pos, size}, -160, -160), p))
            return NO;
        hasBar = YES;
    }
    return hasBar;
}
static BOOL resizeAdmission(CGPoint p, const NPRequest rs[4], const BOOL parked[3]) {
    NSArray *list =
        CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    BOOL donor = NO;
    for (NSDictionary *w in list) {
        CGRect f;
        NSDictionary *bounds = w[(__bridge NSString *)kCGWindowBounds];
        if (!bounds || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &f))
            return NO;
        NSNumber *alpha = w[(__bridge NSString *)kCGWindowAlpha], *layer = w[(__bridge NSString *)kCGWindowLayer];
        if (!alpha || !layer)
            return NO;
        if (alpha.doubleValue == 0)
            continue;
        BOOL enrolled = NO;
        for (unsigned j = 0; j < 3; j++)
            if (parked[j] && [w[(__bridge NSString *)kCGWindowNumber] isEqual:@(rs[j].window)] &&
                [w[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(rs[j].pid)] && layer.integerValue == 0)
                enrolled = YES;
        if (enrolled && CGRectContainsPoint(CGRectInset(f, -4, -4), p)) {
            donor = YES;
            continue;
        }
        // Desktop and desktop icons are below the ordinary CG window layer. No other regular,
        // menu, overlay, panel, Dock proxy or window may receive this test point.
        if (layer.integerValue >= 0 && CGRectContainsPoint(CGRectInset(f, -4, -4), p) && !dockClearAt(w, p))
            return NO;
    }
    return donor;
}
static void change(NPRequest r, uint32_t operation, BOOL *owned) {
    NPReceipt change = request(r, operation);
    *owned = (change.flags & NP_OWNED) != 0;
    uint32_t expect = operation == NP_HIDE ? NP_HIDDEN | NP_INPUT_SAFE | NP_OWNED : NP_VISIBLE;
    if (change.status != NP_PASS || (change.flags & expect) != expect || (*owned != (operation == NP_HIDE)))
        stop(change.status == NP_FAIL ? @"FAIL" : @"UNKNOWN", @"engineDidNotConfirmVisibilityChange");
}
static void visibleGroup(unsigned active, const NPRequest rs[4], const BOOL parked[3], NSArray *base,
                         NSDictionary *native, int dock) {
    for (unsigned sample = 0; sample < 2; sample++) {
        NSArray *snapshot = owners();
        require([scope() isEqual:native] && dockTiles() == dock, @"originalScopeOrDockChanged");
        require([snapshot[1][@"rows"][2][@"minimized"] isEqual:@YES], @"originalMinimizedMemberChanged");
        for (unsigned i = 0; i < 4; i++) {
            BOOL dormant = i < 3 && i != active;
            if (i < 3 && parked[i] != dormant)
                stop(@"FAIL", @"logicalGroupOwnershipChanged");
            NPReceipt read = request(rs[i], NP_READBACK);
            uint32_t flags = NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID |
                             (dormant ? NP_HIDDEN | NP_OWNED | NP_INPUT_SAFE : NP_VISIBLE);
            NSDictionary *w = window(snapshot, rs[i]);
            NSArray *frame = w[@"frame"];
            if (!w || ![w[@"current"] isEqual:@YES] || ![w[@"minimized"] isEqual:@NO] || read.status != NP_PASS ||
                (read.flags & flags) != flags || !closeFrame(cgFrame(@(rs[i].window), @(rs[i].pid)), frame) ||
                !closeFrame(frame, unpack(read.frame)) ||
                (!dormant && !closeFrame(frame, window(base, rs[i])[@"frame"])))
                stop(@"UNKNOWN", @"independentGroupMemberGeometryOrOwnershipUnavailable");
        }
        event(
            @"groupReadback",
            @{@"active" : @(active),
              @"sample" : @(sample),
              @"owners" : snapshot,
              @"dockTiles" : @(dock)});
        if (!sample)
            pauseFor(.085);
    }
}
static void exerciseShield(unsigned stage, unsigned lap, unsigned active, NPRequest rs[4], BOOL parked[3],
                           NSDictionary *native) {
    NSArray *prior = owners();
    CGRect display = CGDisplayBounds(CGMainDisplayID());
    CGPoint inside = CGPointZero, border = CGPointZero;
    int target = -1;
    for (int i = 0; i < 3; i++) {
        if (!parked[i])
            continue;
        NPRect f = rect(window(prior, rs[i])[@"frame"]);
        CGRect slit = CGRectIntersection(display, CGRectMake(f.x, f.y, f.width, f.height));
        if (CGRectIsNull(slit) || CGRectIsEmpty(slit) || CGRectGetWidth(slit) > 8)
            continue;
        CGPoint at = {CGRectGetMidX(slit), CGRectGetMinY(slit) + MIN(4., slit.size.height / 2)};
        if (!exactAX(at, &rs[i]))
            continue;
        inside = at;
        border =
            CGPointMake(f.x > CGRectGetMidX(display) ? CGRectGetMinX(slit) - 3 : CGRectGetMaxX(slit) + 3, at.y);
        target = i;
        break;
    }
    require(target >= 0, @"frontmostParkedSliverNotBoundToEitherEnrolledMember");
    for (int point = 0; point < 2; point++) {
        CGPoint at = point ? border : inside;
        for (int b = 0; b < 3; b++) {
            NPReceipt health = request(rs[target], NP_HEALTH);
            require(health.status == NP_PASS && (health.flags & NP_INPUT_SAFE) && [scope() isEqual:native] &&
                        (point ? resizeAdmission(at, rs, parked) : exactAX(at, &rs[target])),
                    @"shieldOrExpectedReceiverChanged");
            gesture(at, b);
            pauseFor(.075);
            NSArray *after = owners();
            BOOL unchanged = noChange(prior, after, 0, YES);
            event(
                @"sliverMarker", @{
                    @"gate" : @(stage),
                    @"lap" : @(lap),
                    @"active" : @(active),
                    @"pointKind" : point ? @"resize-border" : @"sliver",
                    @"window" : @(rs[target].window),
                    @"button" : @(b),
                    @"point" : @[ @(at.x), @(at.y) ],
                    @"owners" : after,
                    @"noReceiverMarkers" : @(unchanged)
                });
            if (!unchanged)
                stop(@"FAIL", @"fixtureReceivedParkedMouseOrBystanderChanged");
        }
    }
    require(positive(rs[active], (int)(stage + lap + active)), @"visibleGroupWholeGestureUnconfirmed");
}
#include "crash-drill.inc"
static void trial(NSString *kit) {
    require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), @"fixtureAccessibilityOrPostEventUnavailable");
    NSDictionary *native = scope();
    for (NSString *key in @[ @"a", @"b" ]) {
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL
            fileURLWithPath:[kit stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"Fixture%@.app/Contents/MacOS/Owner", key]]];
        task.arguments = @[ output, key ];
        NSError *e = nil;
        require([task launchAndReturnError:&e], @"signedOwnerLaunch");
        [children addObject:task];
    }
    NSArray *base = owners();
    require([base[0][@"rows"] count] == 2 && [base[1][@"rows"] count] == 3,
            @"twoAppsThreeManagedBystanderAndMinimizedRequired");
    require([base[1][@"rows"][2][@"minimized"] boolValue], @"userMinimizedFixtureNotEstablished");
    int dock = dockTiles();
    require(dock >= 0, @"dockMinimizedTileCountUnavailable");
    result[@"baseline"] = base;
    result[@"dockBefore"] = @(dock);
    result[@"nativeScope"] = native;
    save();
    NPConfig cfg = {.size = sizeof(NPConfig), .version = 1, .mode = NP_ISOLATED_FIXTURE, .process_count = 2};
    for (int i = 0; i < 2; i++) {
        cfg.processes[i] = (NPProcess){[base[i][@"pid"] intValue], 0, [base[i][@"birth"] unsignedLongLongValue]};
        require(cfg.processes[i].pid == children[i].processIdentifier, @"childGenerationMismatch");
    }
    require(np_engine_create(&cfg, &handle) == NP_OK && np_engine_epoch(handle, &epoch) == NP_OK,
            @"signedABIEnrollmentRefused");
    NPRequest rs[4] = {0};
    for (unsigned i = 0; i < 4; i++) {
        unsigned owner = i < 2 ? 0 : 1, index = i < 2 ? i : i - 2;
        NPRequest *r = &rs[i];
        r->size = sizeof(*r);
        r->version = 1;
        r->backend = NP_CORNER;
        r->pid = cfg.processes[owner].pid;
        r->birth = cfg.processes[owner].birth;
        NSDictionary *w = base[owner][@"rows"][index];
        r->window = [w[@"window"] unsignedIntValue];
        r->frame = rect(w[@"frame"]);
        r->target = r->frame;
        r->native_id = [native[@"native"] unsignedLongLongValue];
        uuid(native[@"space"], r->native_space);
        uuid(native[@"display"], r->display);
        [NSUUID.UUID getUUIDBytes:r->member];
        [NSUUID.UUID getUUIDBytes:r->group];
        [NSUUID.UUID getUUIDBytes:r->lifetime];
        [NSUUID.UUID getUUIDBytes:r->generation];
        NPReceipt check = request(*r, NP_READBACK);
        require(check.status == NP_PASS &&
                    (check.flags & (NP_VISIBLE | NP_CG_VALID | NP_AX_VALID | NP_MEMBERSHIP_VALID)) ==
                        (NP_VISIBLE | NP_CG_VALID | NP_AX_VALID | NP_MEMBERSHIP_VALID) &&
                    closeFrame(w[@"frame"], unpack(check.frame)),
                @"initialWindowReadbackUnconfirmed");
    }
    if (crashMode) {
        crashHost(kit, rs[0]);
        return;
    }
    BOOL owned[3] = {NO, NO, NO};
    NCCycles cycle = {0};
    NSArray *keys = @[ @"single", @"ten", @"fifty" ];
    @try {
        change(rs[1], NP_HIDE, &owned[1]);
        change(rs[2], NP_HIDE, &owned[2]);
        visibleGroup(0, rs, owned, base, native, dock);
        require(positive(rs[3], 0), @"unmanagedBystanderWholeGestureUnconfirmed");
        while (cycle.gate < 3) {
            unsigned gate = cycle.gate, from = cycle.edge, to = (from + 1) % 3, lap = cycle.lap[gate] + 1;
            event(
                @"transitionStarted",
                @{@"gate" : keys[gate],
                  @"lap" : @(lap),
                  @"from" : @(from),
                  @"to" : @(to)});
            require([scope() isEqual:native], @"desktopOrDisplayChangedBeforeSwitch");
            NSArray *before = owners();
            change(rs[to], NP_SHOW, &owned[to]);
            NSArray *shown = owners();
            if (!noChange(before, shown, rs[to].window, NO))
                stop(@"FAIL", @"unselectedWindowChangedOnShow");
            change(rs[from], NP_HIDE, &owned[from]);
            NSArray *hidden = owners();
            if (!noChange(shown, hidden, rs[from].window, NO))
                stop(@"FAIL", @"unselectedWindowChangedOnHide");
            visibleGroup(to, rs, owned, base, native, dock);
            exerciseShield(nc_cycle_limit(gate), lap, to, rs, owned, native);
            require(nc_cycle_accept(&cycle, from, to, YES), @"unqualifiedStageOrder");
            event(
                @"transitionConfirmed",
                @{@"gate" : keys[gate],
                  @"lap" : @(lap),
                  @"from" : @(from),
                  @"to" : @(to)});
            result[keys[gate]] = @(cycle.lap[gate]);
            if (gate == 0 && cycle.gate == 1) {
                // Optional cosmetics are separately measured. They never shield events or qualify a backend.
                result[@"cornerPatch"] = nc_fixture_picture(&rs[1], &rs[2]);
            }
            save();
        }
        result[@"status"] = @"PASS";
        result[@"scope"] = @"isolatedSignedThreeGroupCirclesAndReceiverMarkers";
    } @finally {
        NSMutableArray *cleanup = [NSMutableArray array];
        for (int j = 2; j >= 0; j--) {
            if (!owned[j])
                continue;
            NPReceipt clean = request(rs[j], NP_RESTORE);
            NSArray *returned = owners();
            BOOL exact = clean.status == NP_PASS && !(clean.flags & NP_OWNED) && (clean.flags & NP_VISIBLE) &&
                         closeFrame(window(returned, rs[j])[@"frame"], unpack(rs[j].frame)) &&
                         closeFrame(cgFrame(@(rs[j].window), @(rs[j].pid)), unpack(rs[j].frame));
            [cleanup addObject:@{
                @"window" : @(rs[j].window),
                @"status" : @(clean.status),
                @"ownedCount" : @(clean.owned),
                @"originalVerified" : @(exact)
            }];
            if (!exact)
                result[@"status"] = @"UNKNOWN";
        }
        result[@"compensation"] = cleanup;
        result[@"engineClose"] = @(np_engine_destroy(handle));
        save();
    }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 && argc != 4)
            return 2;
        crashMode = argc == 4 && !strcmp(argv[3], "--crash-host");
        BOOL supervisor = argc == 4 && !strcmp(argv[3], "--verify-crash");
        BOOL scopeOnly = argc == 4 && !strcmp(argv[3], "--scope-only");
        if (argc == 4 && !crashMode && !supervisor && !scopeOnly)
            return 2;
        BOOL hosted = [NSUserName() isEqual:@"runner"] &&
                      [NSProcessInfo.processInfo.environment[@"GITHUB_ACTIONS"] isEqual:@"true"] &&
                      [NSProcessInfo.processInfo.environment[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"];
        BOOL isolated =
            [NSUserName() hasPrefix:@"nearpane-fixture-"] &&
            [NSProcessInfo.processInfo.environment[@"NP_DISPOSABLE_CORNER_LOGIN"] isEqual:NSUserName()];
        if (!hosted && !isolated && !scopeOnly)
            return 3;
        NSString *kit = @(argv[1]);
        output = @(argv[2]);
        NSString *file =
            [output stringByAppendingPathComponent:crashMode ? @"host-events.jsonl" : @"events.jsonl"];
        logFile = fopen(file.fileSystemRepresentation, "wx");
        if (!logFile)
            return 4;
        children = [NSMutableArray array];
        result = [@{
            @"schema" : @1,
            @"status" : @"BLOCKED",
            @"hosted" : @(hosted),
            @"officialInstalledHost" : @"NOT_RUN",
            @"single" : @0,
            @"ten" : @0,
            @"fifty" : @0,
            @"menuBarDockWallpaperNotificationInteractions" : @"NOT_RUN",
            @"processCrashAndRelaunch" : @"NOT_RUN",
            @"physicalMultiDisplay" : @"NOT_RUN",
            @"cornerPatch" : @{@"status" : @"NOT_RUN"},
            @"qualification" : @"UNQUALIFIED"
        } mutableCopy];
        save();
        @try {
            if (scopeOnly) {
                result[@"nativeScope"] = scope();
                result[@"status"] = @"PASS";
                result[@"scope"] = @"readOnlyNativeDesktopIdentity";
            } else if (supervisor)
                witnessCrash(kit);
            else
                trial(kit);
        } @catch (NSException *error) {
            result[@"status"] =
                [@[ @"FAIL", @"UNKNOWN", @"BLOCKED" ] containsObject:error.name] ? error.name : @"UNKNOWN";
            result[@"reason"] = [@[ @"FAIL", @"UNKNOWN", @"BLOCKED" ] containsObject:error.name]
                                    ? error.reason
                                    : @"unexpectedNativeException";
        } @finally {
            if (!scopeOnly)
                [@"" writeToFile:[output stringByAppendingPathComponent:@"stop"]
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:NULL];
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:4];
            for (NSTask *t in children) {
                while (t.running && until.timeIntervalSinceNow > 0)
                    pauseFor(.025);
            }
            BOOL gone = YES;
            for (NSTask *t in children)
                gone &= !t.running;
            if (supervisor) {
                NSDictionary *state = readJSON(@"crash-host.json");
                NSArray *prior = state[@"baseline"];
                for (NSDictionary *owner in prior) {
                    pid_t pid = [owner[@"pid"] intValue];
                    uint64_t birth = [owner[@"birth"] unsignedLongLongValue];
                    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
                    while (birth && ncg_birth(pid, NULL) == birth && deadline.timeIntervalSinceNow > 0)
                        pauseFor(.025);
                    if (!birth || ncg_birth(pid, NULL) == birth)
                        gone = NO;
                }
            }
            result[@"fixtureOwnersExited"] = @(gone);
            if (!gone)
                result[@"status"] = @"UNKNOWN";
            save();
            fclose(logFile);
        }
        return 0;
    }
}
