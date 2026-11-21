// Native SDK calls only; no model state, input synthesis, graphics capture, or preference writes.
// Window read/write sequence adapted from stage-manager (see LICENSE-MIT) and Nearpane's exact window readers.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <libproc.h>
#import <math.h>
#import <unistd.h>
#import "macos.h"
#import "mouse_event.h"
#define NP_CORNER_WITNESS_IMPL 1
#import "gesture_witness.h"
#import "scope_binding.h"

enum {
    OK = 0,
    NO_AX = 1,
    LOST_PROCESS = 2,
    NO_WINDOW = 3,
    AX_SCOPE = 4,
    CG_SCOPE = 5,
    FRAME_MISMATCH = 6,
    MINIMIZED = 7,
    SECURE = 8,
    DISPLAY_CHANGED = 9,
    NATIVE_SPACE = 10,
    SYSTEM_OWNS = 11,
    NO_DOCK = 12,
    CAPACITY = 13,
    NO_ZORDER = 14,
    NEW_INTENT = 15,
    SETTER = 16,
    CHANGED_FRAME = 17,
    BUTTON_HELD = 18,
    NO_LISTEN = 19
};
static NCFrame frame(CGRect r) { return (NCFrame){r.origin.x, r.origin.y, r.size.width, r.size.height}; }
static BOOL valid(NCFrame f) {
    return isfinite(f.x) && isfinite(f.y) && isfinite(f.w) && isfinite(f.h) && f.w > 0 && f.h > 0 &&
           isfinite(f.x + f.w) && isfinite(f.y + f.h);
}
static BOOL same(NCFrame a, NCFrame b) {
    return valid(a) && valid(b) && fabs(a.x - b.x) <= 0.75 && fabs(a.y - b.y) <= 0.75 && fabs(a.w - b.w) <= 0.75 &&
           fabs(a.h - b.h) <= 0.75;
}
static uint64_t birth(pid_t p) {
    struct proc_bsdinfo i = {0};
    return p > 1 && proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &i, sizeof i) == sizeof i && i.pbi_pid == (uint32_t)p &&
                   i.pbi_uid == getuid()
               ? i.pbi_start_tvsec * 1000000ULL + i.pbi_start_tvusec
               : 0;
}
int np_corner_signed_fingerprint(int32_t pid, uint64_t expected, uint8_t digest[32]) {
    @autoreleasepool {
        if (!expected || birth(pid) != expected)
            return 0;
        SecCodeRef code = NULL;
        CFDictionaryRef info = NULL;
        OSStatus err = SecCodeCopyGuestWithAttributes(
            NULL,
            (__bridge CFDictionaryRef)
                @{(__bridge NSString *)kSecGuestAttributePid : @(pid)},
            0, &code);
        if (!err)
            err = SecCodeCheckValidity(code, kSecCSStrictValidate, NULL);
        if (!err)
            err = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
        NSData *__attribute__((objc_precise_lifetime)) h =
            info ? [(__bridge NSDictionary *)info objectForKey:(__bridge NSString *)kSecCodeInfoUnique] : nil;
        int ok =
            !err && [h isKindOfClass:NSData.class] && (h.length == 20 || h.length == 32) && birth(pid) == expected;
        if (ok) {
            memset(digest, 0, 32);
            memcpy(digest, h.bytes, h.length);
        }
        if (info)
            CFRelease(info);
        if (code)
            CFRelease(code);
        return ok;
    }
}
static id ax(AXUIElementRef e, CFStringRef key) {
    CFTypeRef v = NULL;
    return e && AXUIElementCopyAttributeValue(e, key, &v) == kAXErrorSuccess ? CFBridgingRelease(v) : nil;
}
static BOOL owned(AXUIElementRef e, pid_t p) {
    pid_t actual = 0;
    return e && AXUIElementGetPid(e, &actual) == kAXErrorSuccess && actual == p;
}
static BOOL pointSize(AXUIElementRef e, NCFrame *out) {
    id p = ax(e, kAXPositionAttribute), s = ax(e, kAXSizeAttribute);
    CGPoint origin;
    CGSize size;
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID() ||
        !AXValueGetValue((__bridge AXValueRef)p, kAXValueTypeCGPoint, &origin) ||
        !AXValueGetValue((__bridge AXValueRef)s, kAXValueTypeCGSize, &size))
        return NO;
    *out = frame((CGRect){origin, size});
    return valid(*out);
}
static BOOL uuidEqual(NSString *s, const uint8_t expected[16]) {
    if (![s isKindOfClass:NSString.class])
        return NO;
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
    uuid_t b;
    if (!u)
        return NO;
    [u getUUIDBytes:b];
    return memcmp(b, expected, 16) == 0;
}
static BOOL sessionAvailable(void) {
    NSDictionary *s = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [s[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] &&
           [s[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES] &&
           [s[(__bridge NSString *)kCGSessionUserIDKey] isEqual:@(getuid())] &&
           ![s[@"CGSSessionScreenIsLocked"] boolValue];
}
void np_corner_inputs(uint32_t counters[13]) {
    const CGEventType e[] = {kCGEventLeftMouseDown,    kCGEventRightMouseDown,   kCGEventOtherMouseDown,
                             kCGEventKeyDown,          kCGEventScrollWheel,      kCGEventKeyUp,
                             kCGEventFlagsChanged,     kCGEventLeftMouseUp,      kCGEventRightMouseUp,
                             kCGEventOtherMouseUp,     kCGEventLeftMouseDragged, kCGEventRightMouseDragged,
                             kCGEventOtherMouseDragged};
    for (int n = 0; n < 13; n++)
        counters[n] = CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, e[n]);
}
int np_corner_secure_input(void) { return IsSecureEventInputEnabled() != 0; }
static BOOL mouseButtonHeld(void) {
    // A stationary held button has no new counter event. AX must not move a window
    // underneath an in-flight gesture, including during Guardian recovery.
    for (CGMouseButton button = 0; button < 32; button++)
        if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, button) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) return YES;
    return NO;
}
uint32_t np_corner_input_access(void) {
    if (!AXIsProcessTrusted() || !CGPreflightPostEventAccess())
        return NO_AX;
    if (!CGPreflightListenEventAccess()) return NO_LISTEN;
    if (np_corner_secure_input()) return SECURE;
    return mouseButtonHeld() ? BUTTON_HELD : OK;
}
uint32_t np_corner_displays(NCDisplay *rows, uint32_t capacity, uint32_t *count) {
    @autoreleasepool {
        uint32_t n = 0;
        *count = 0;
        if (!rows || !sessionAvailable() || CGGetActiveDisplayList(0, NULL, &n) != kCGErrorSuccess || !n ||
            n > capacity)
            return DISPLAY_CHANGED;
        NSArray<NSScreen *> *screens = NSScreen.screens;
        if (screens.count != n)
            return DISPLAY_CHANGED;
        for (NSScreen *s in screens) {
            NSNumber *d = s.deviceDescription[@"NSScreenNumber"];
            if (!d || CGDisplayIsInMirrorSet(d.unsignedIntValue) || !CGDisplayIsActive(d.unsignedIntValue))
                return DISPLAY_CHANGED;
            CGRect cg = CGDisplayBounds(d.unsignedIntValue), full = s.frame, v = s.visibleFrame;
            if (!CGRectContainsRect(full, v) || fabs(full.size.width - cg.size.width) > .5 ||
                fabs(full.size.height - cg.size.height) > .5)
                return DISPLAY_CHANGED;
            NCDisplay *row = rows + (*count)++;
            row->frame = frame(cg);
            row->visible = (NCFrame){cg.origin.x + NSMinX(v) - NSMinX(full),
                                     cg.origin.y + NSMaxY(full) - NSMaxY(v), NSWidth(v), NSHeight(v)};
            if (!valid(row->visible) || !valid(row->frame))
                return DISPLAY_CHANGED;
            CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d.unsignedIntValue);
            if (!u)
                return DISPLAY_CHANGED;
            CFUUIDBytes bytes = CFUUIDGetUUIDBytes(u);
            memcpy(row->uuid, &bytes, 16);
            CFRelease(u);
        }
        return OK;
    }
}

// All of these SkyLight calls are read-only. Look up the same ABI as Nearpane's existing
// CReadOnlySpaces catalogue. An absent reverse/forward reader disqualifies a window.
static BOOL memberSpace(const NCMember *member) {
    typedef int (*Main)(void);
    typedef CFArrayRef (*Inv)(int);
    typedef CFArrayRef (*Reverse)(int, int, CFArrayRef);
    typedef CFArrayRef (*Forward)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
    static Main mainID;
    static Inv inventory;
    static Reverse reverse;
    static Forward forward;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_LAZY);
      if (h) {
          mainID = (Main)dlsym(h, "SLSMainConnectionID");
          inventory = (Inv)dlsym(h, "SLSCopyManagedDisplaySpaces");
          reverse = (Reverse)dlsym(h, "SLSCopySpacesForWindows");
          forward = (Forward)dlsym(h, "SLSCopyWindowsWithOptionsAndTags");
      }
    });
    if (!mainID || !inventory || !reverse || !forward || member->native == 0)
        return NO;
    int c = mainID();
    if (c <= 0)
        return NO;
    NSString *physical = [[NSUUID alloc] initWithUUIDBytes:member->display].UUIDString;
    NSUInteger reads = 1;
    for (NSUInteger observed = 0; observed < reads; observed++) {
        NSArray *displays = CFBridgingRelease(inventory(c));
        if (![displays isKindOfClass:NSArray.class] || !displays.count || displays.count > 32)
            return NO;
        NSUInteger matches = 0;
        for (id obj in displays) {
            if (![obj isKindOfClass:NSDictionary.class])
                return NO;
            NSString *token = obj[@"Display Identifier"];
            BOOL alias = [token isEqual:@"Main"];
            if (!alias && !uuidEqual(token, member->display))
                continue;
            BOOL onlyMain = NO;
            if (alias) {
                onlyMain = [nc_single_main_uuid(displays.count).UUIDString isEqual:physical];
                reads = 2;
            }
            NSDictionary *bound = nc_bound_scope(obj, physical, onlyMain, nc_direct_home(c, token),
                                                 [NSMutableDictionary dictionary]);
            if (!bound || ![bound[@"native"] isEqual:@(member->native)] ||
                !uuidEqual(bound[@"space"], member->space))
                return NO;
            matches++;
        }
        if (matches != 1)
            return NO;
    }
    NSArray *ids = CFBridgingRelease(reverse(c, 7, (__bridge CFArrayRef) @[ @(member->window) ]));
    uint64_t a = 0, b = 0;
    NSArray *windows = CFBridgingRelease(forward(c, 0, (__bridge CFArrayRef) @[ @(member->native) ], 7, &a, &b));
    return [ids isEqual:@[ @(member->native) ]] && [windows isKindOfClass:NSArray.class] &&
           windows.count <= 8192 && [windows containsObject:@(member->window)];
}
static BOOL numberOf(AXUIElementRef e, uint32_t *number) {
    typedef AXError (*Number)(AXUIElementRef, CGWindowID *);
    static Number get;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      get = (Number)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    *number = 0;
    return get && get(e, number) == kAXErrorSuccess && *number > 0;
}
static id exactAX(const NCMember *m) {
    AXUIElementRef app = AXUIElementCreateApplication(m->pid);
    if (!app)
        return nil;
    AXUIElementSetMessagingTimeout(app, 0.12f);
    NSArray *list = ax(app, kAXWindowsAttribute);
    CFRelease(app);
    if (![list isKindOfClass:NSArray.class] || list.count > 256)
        return nil;
    id match = nil;
    for (id item in list) {
        AXUIElementRef e = (__bridge AXUIElementRef)item;
        if (CFGetTypeID((__bridge CFTypeRef)item) != AXUIElementGetTypeID() || !owned(e, m->pid))
            return nil;
        uint32_t n = 0;
        if (!numberOf(e, &n))
            return nil;
        if (n != m->window)
            continue;
        if (match)
            return nil;
        match = item;
    }
    return match;
}
static BOOL liveCG(const NCMember *m, NCSample *s) {
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, m->window));
    if (rows.count != 1)
        return NO;
    NSDictionary *row = rows.firstObject;
    if (![row[(__bridge NSString *)kCGWindowOwnerPID] isEqual:@(m->pid)] ||
        ![row[(__bridge NSString *)kCGWindowNumber] isEqual:@(m->window)] ||
        ![row[(__bridge NSString *)kCGWindowLayer] isEqual:@0])
        return NO;
    CGRect r;
    if (!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)row[(__bridge NSString *)kCGWindowBounds], &r))
        return NO;
    s->cg = frame(r);
    s->onscreen = [row[(__bridge NSString *)kCGWindowIsOnscreen] isEqual:@YES];
    return valid(s->cg);
}
static uint32_t readMember(const NCMember *m, id *window, NCSample *state) {
    if (!AXIsProcessTrusted())
        return NO_AX;
    if (m->pid <= 1 || !m->birth || !m->window || birth(m->pid) != m->birth)
        return LOST_PROCESS;
    if (!memberSpace(m))
        return NATIVE_SPACE;
    id found = exactAX(m);
    if (!found)
        return NO_WINDOW;
    AXUIElementRef e = (__bridge AXUIElementRef)found;
    AXUIElementSetMessagingTimeout(e, 0.12f);
    id role = ax(e, kAXRoleAttribute), sub = ax(e, kAXSubroleAttribute), mini = ax(e, kAXMinimizedAttribute);
    id full = ax(e, CFSTR("AXFullScreen")), modal = ax(e, kAXModalAttribute);
    NSArray *sheets = ax(e, CFSTR("AXSheets"));
    if (![role isEqual:(__bridge NSString *)kAXWindowRole] ||
        ![sub isEqual:(__bridge NSString *)kAXStandardWindowSubrole] || ![mini isKindOfClass:NSNumber.class] ||
        ![full isEqual:@NO] || [modal isEqual:@YES] || sheets.count != 0)
        return AX_SCOPE;
    state->minimized = [mini boolValue];
    if (state->minimized)
        return MINIMIZED;
    if (!pointSize(e, &state->ax))
        return AX_SCOPE;
    if (!liveCG(m, state) || !state->onscreen)
        return CG_SCOPE;
    if (!same(state->ax, state->cg))
        return FRAME_MISMATCH;
    if (birth(m->pid) != m->birth)
        return LOST_PROCESS;
    if (window)
        *window = found;
    return OK;
}
uint32_t np_corner_sample(const NCMember *m, NCSample *s) {
    @autoreleasepool {
        return readMember(m, NULL, s);
    }
}

// The Dock's actual AX list bounds distinguish its click-through, display-sized CG surface from the bar.
// No names, Dock items, window titles, screenshots, or document attributes are requested.
static BOOL appleDock(pid_t pid) {
    char executable[PROC_PIDPATHINFO_MAXSIZE];
    if (!proc_pidpath(pid, executable, sizeof executable) ||
        strcmp(executable, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
        return NO;
    SecCodeRef code = NULL;
    SecRequirementRef req = NULL;
    OSStatus err = SecCodeCopyGuestWithAttributes(
        NULL,
        (__bridge CFDictionaryRef)
            @{(__bridge NSString *)kSecGuestAttributePid : @(pid)},
        0, &code);
    if (err == errSecSuccess)
        err = SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.dock\""), 0, &req);
    if (err == errSecSuccess)
        err = SecCodeCheckValidity(code, 0, req);
    if (req)
        CFRelease(req);
    if (code)
        CFRelease(code);
    return err == errSecSuccess;
}
static uint32_t dockAndOwnership(NCDock *out) {
    if (!sessionAvailable())
        return SYSTEM_OWNS;
    if (np_corner_secure_input())
        return SECURE;
    id pref =
        CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"), CFSTR("com.apple.WindowManager")));
    if (pref) {
        if (CFGetTypeID((__bridge CFTypeRef)pref) != CFBooleanGetTypeID() || ![pref isEqual:@NO])
            return SYSTEM_OWNS;
    } else {
        // Same factory-off rule as NearpaneCore.StageManagerPreference: both underlying
        // domains must actually be readable before an absent key means off.
        for (NSString *host in
             @[ (__bridge NSString *)kCFPreferencesCurrentHost, (__bridge NSString *)kCFPreferencesAnyHost ]) {
            id domain = CFBridgingRelease(CFPreferencesCopyMultiple(
                NULL, CFSTR("com.apple.WindowManager"), kCFPreferencesCurrentUser, (__bridge CFStringRef)host));
            if (![domain isKindOfClass:NSDictionary.class])
                return SYSTEM_OWNS;
        }
    }
    NSArray<NSRunningApplication *> *docks =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (docks.count != 1)
        return NO_DOCK;
    pid_t pid = docks[0].processIdentifier;
    uint64_t generation = birth(pid);
    if (!generation || !appleDock(pid))
        return NO_DOCK;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app)
        return NO_DOCK;
    AXUIElementSetMessagingTimeout(app, 0.12f);
    NSArray *children = ax(app, kAXChildrenAttribute);
    NCDock dock = {.pid = pid};
    BOOL ordinary = [children isKindOfClass:NSArray.class] && children.count > 0 && children.count <= 16;
    for (id child in children) {
        if (!ordinary)
            break;
        AXUIElementRef e = (__bridge AXUIElementRef)child;
        if (CFGetTypeID((__bridge CFTypeRef)child) != AXUIElementGetTypeID() || !owned(e, pid)) {
            ordinary = NO;
            break;
        }
        NSString *role = ax(e, kAXRoleAttribute);
        if ([ax(e, kAXIdentifierAttribute) isEqual:@"mc"] || ![role isKindOfClass:NSString.class]) {
            ordinary = NO;
            break;
        }
        if ([role isEqual:(__bridge NSString *)kAXListRole]) {
            if (dock.count >= 16 || !pointSize(e, dock.bars + dock.count)) {
                ordinary = NO;
                break;
            }
            dock.count++;
        }
    }
    NSArray *again = ax(app, kAXChildrenAttribute);
    CFRelease(app);
    if (!ordinary || !dock.count || ![again isEqual:children] || birth(pid) != generation)
        return NO_DOCK;
    *out = dock;
    return OK;
}
// Read only our own AppKit windows' explicitly declared input behavior, on their owner thread.
// If a live surface in the protected zone cannot be classified, the WM worker refuses the snapshot.
static NSDictionary *ownInput(void) {
    if (!NSApp)
        return @{};
    __block NSMutableDictionary *map = nil;
    void (^read)(void) = ^{
      NSMutableDictionary *found = [NSMutableDictionary dictionary];
      for (NSWindow *w in NSApp.windows)
          if (w.windowNumber > 0)
              found[@(w.windowNumber)] = @(w.ignoresMouseEvents);
      map = found;
    };
    if (NSThread.isMainThread)
        read();
    else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
          read();
          dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 80000000)))
            return nil;
    }
    return map;
}
uint32_t np_corner_zorder(NCListed *list, uint32_t capacity, uint32_t *count, NCDock *dock) {
    @autoreleasepool {
        *count = 0;
        uint32_t why = dockAndOwnership(dock);
        if (why)
            return why;
        NSArray *rows =
            CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
        if (![rows isKindOfClass:NSArray.class] || !rows.count || rows.count > capacity)
            return NO_ZORDER;
        NSDictionary *own = nil;
        for (NSDictionary *r in rows) {
            NSNumber *n = r[(__bridge NSString *)kCGWindowNumber],
                     *pid = r[(__bridge NSString *)kCGWindowOwnerPID],
                     *layer = r[(__bridge NSString *)kCGWindowLayer],
                     *alpha = r[(__bridge NSString *)kCGWindowAlpha];
            CGRect bounds;
            if (!n || !pid || !layer || !alpha || n.unsignedIntValue == 0 || pid.intValue <= 0 ||
                !isfinite(alpha.doubleValue) || alpha.doubleValue < 0 || alpha.doubleValue > 1 ||
                !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)r[(__bridge NSString *)kCGWindowBounds], &bounds))
                return NO_ZORDER;
            NCFrame f = frame(bounds);
            if (!valid(f))
                return NO_ZORDER;
            // Positive iff our own NSWindow currently reports ignoresMouseEvents. A normal Host
            // surface remains a possible recipient; metadata-only unknowns are never labeled transparent.
            double opacity = alpha.doubleValue;
            if (pid.intValue == getpid() && opacity > 0) {
                if (!own)
                    own = ownInput();
                if ([own[n] isEqual:@YES])
                    opacity = 0;
                else if (![own[n] isEqual:@NO])
                    return NO_ZORDER;
            }
            list[(*count)++] = (NCListed){n.unsignedIntValue, pid.intValue, f, opacity, layer.longLongValue};
        }
        return OK;
    }
}
uint32_t np_corner_position(const NCMember *m, void *retained, NCFrame before, NCFrame desired, NCGuard allow,
                            void *context, uint32_t *issued) {
    @autoreleasepool {
        *issued = 0;
        if (!valid(desired) || !same((NCFrame){before.x, before.y, desired.w, desired.h}, before))
            return CHANGED_FRAME;
        NCDock dock = {0};
        uint32_t why = dockAndOwnership(&dock);
        if (why)
            return why;
        NCSample s = {0};
        id window = nil;
        why = readMember(m, &window, &s);
        if (why)
            return why;
        if (!retained || !CFEqual(retained, (__bridge CFTypeRef)window))
            return NO_WINDOW;
        if (!same(s.cg, before))
            return CHANGED_FRAME;
        AXUIElementRef e = (__bridge AXUIElementRef)window;
        Boolean writable = false;
        if (AXUIElementIsAttributeSettable(e, kAXPositionAttribute, &writable) != kAXErrorSuccess || !writable)
            return AX_SCOPE;
        CGPoint p = {desired.x, desired.y};
        AXValueRef value = AXValueCreate(kAXValueTypeCGPoint, &p);
        if (!value)
            return SETTER;
        if (!allow(context)) {
            CFRelease(value);
            return NEW_INTENT;
        }
        if (mouseButtonHeld()) {
            CFRelease(value);
            return BUTTON_HELD;
        }
        *issued = 1;
        AXError err = AXUIElementSetAttributeValue(e, kAXPositionAttribute, value);
        CFRelease(value);
        return err == kAXErrorSuccess ? OK : SETTER;
    }
}

typedef struct {
    void *context;
    NCDecide decide;
    NCTapHealth health;
} NCCallback;
static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *raw) {
    (void)proxy;
    NCCallback *tap = raw;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        tap->health(tap->context, type == kCGEventTapDisabledByTimeout ? 3 : 4);
        return event;
    }
    if (!event)
        return event;
    BOOL dropped = nc_mouse_decision(type, event, tap->context, tap->decide) != 0;
    recordGesture(type, event, dropped);
    return dropped ? NULL : event;
}
void np_corner_tap_run(void *context, NCDecide decide, NCTapControl control, NCTapHealth health) {
    @autoreleasepool {
        const CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                                 CGEventMaskBit(kCGEventLeftMouseDragged) |
                                 CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                                 CGEventMaskBit(kCGEventRightMouseDragged) |
                                 CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) |
                                 CGEventMaskBit(kCGEventOtherMouseDragged);
        NCCallback cb = {context, decide, health};
        CFMachPortRef port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                              mask, tapCallback, &cb);
        if (!port) {
            health(context, 2);
            return;
        }
        CGEventTapEnable(port, false);
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, port, 0);
        if (!src) {
            health(context, 2);
            CFMachPortInvalidate(port);
            CFRelease(port);
            return;
        }
        CFRunLoopRef loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(loop, src, kCFRunLoopCommonModes);
        BOOL wasOn = NO, secure = NO;
        for (;;) {
            uint32_t cfg = control(context);
            BOOL held = (cfg & 2) != 0, stop = (cfg & 4) != 0, wanted = (cfg & 1) != 0;
            if (stop && !held)
                break;
            if (np_corner_secure_input()) {
                if (!secure)
                    health(context, 4);
                secure = YES;
            } else
                secure = NO;
            BOOL on = !secure && (held || (!stop && wanted));
            if (on != wasOn) {
                CGEventTapEnable(port, on);
                wasOn = on;
            }
            BOOL actual = CGEventTapIsEnabled(port);
            if (on && !actual)
                health(context, 3);
            else
                health(context, actual ? 1 : 0);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.012, true);
            if (stop && secure)
                break; // forced disable broke a gesture; its failure remains in the receipt.
        }
        CGEventTapEnable(port, false);
        CFRunLoopRemoveSource(loop, src, kCFRunLoopCommonModes);
        CFMachPortInvalidate(port);
        CFRelease(src);
        CFRelease(port);
        health(context, 0);
    }
}
void *np_corner_retain_window(const NCMember *m) {
    @autoreleasepool {
        if (!m || birth(m->pid) != m->birth)
            return NULL;
        id w = exactAX(m);
        return w ? (void *)CFBridgingRetain(w) : NULL;
    }
}
void np_corner_release_window(void *retained) {
    if (retained)
        CFRelease(retained);
}
int np_corner_same_window(const NCMember *m, void *retained) {
    @autoreleasepool {
        if (!retained || birth(m->pid) != m->birth)
            return 0;
        id w = exactAX(m);
        return w && CFEqual(retained, (__bridge CFTypeRef)w);
    }
}

#include "host_scope.inc"
#include "guardian/observe.inc"
