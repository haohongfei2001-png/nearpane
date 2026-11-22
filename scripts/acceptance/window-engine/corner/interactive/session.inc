#import "admission.h"
#import "evidence.h"
#import "scope_binding.h"
#import <poll.h>

static NSArray<NSWindow *> *owned;
static NSArray<NSNumber *> *numbers;
static NSArray<NSString *> *lifetimes;
static NPInputWitness *active;
static NSDictionary *prior;
static NSMutableSet<NSUUID *> *used;
static BOOL invalidated;
static NSDictionary *scope;
static NSString *displayToken;

static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
// Reuse the same direct per-display getter as the Corner contract, from this process's own connection.
// It sees a Space number only. No third-party window catalogue or content is read.
static BOOL stillOnLease(NSDictionary *expected, NSString *token) {
    typedef int32_t (*GetConnection)(void);
    static GetConnection read;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL | RTLD_LAZY);
        if (lib) read = (GetConnection)dlsym(lib,"SLSMainConnectionID");
    });
    int32_t connection = read ? read() : 0;
    return connection > 0 && sameUUID(nc_single_main_uuid(1).UUIDString,expected[@"displayUUID"]) &&
        [expected[@"nativeID"] unsignedLongLongValue] == nc_direct_home(connection,token) && read() == connection;
}
static NSArray *windowsSnapshot(void) {
    NSMutableArray *rows = [NSMutableArray array];
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    for (NSUInteger i = 0; i < owned.count; i++) {
        NSWindow *w = owned[i];
        NSRect f = w.frame;
        NSRect c = [w convertRectToScreen:[w.contentView convertRect:w.contentView.bounds toView:nil]];
        [rows addObject:@{@"role":i == 0 ? @"target" : @"sibling", @"window":numbers[i], @"lifetime":lifetimes[i],
            @"sameOriginal":@( (BOOL)(w.windowNumber == numbers[i].intValue)), @"visible":@(w.isVisible),
            @"onActiveSpace":@(w.isOnActiveSpace), @"minimized":@(w.isMiniaturized), @"key":@(w.isKeyWindow),
            @"main":@(w.isMainWindow), @"firstResponderIsContent":@( (BOOL)(w.firstResponder == w.contentView)),
            @"acceptsMouse":@( (BOOL)!w.ignoresMouseEvents), @"alpha":@(w.alphaValue),
            @"contentFrame":@[@(NSMinX(c)), @(top - NSMaxY(c)), @(NSWidth(c)), @(NSHeight(c))],
            @"frame":@[@(NSMinX(f)), @(top - NSMaxY(f)), @(NSWidth(f)), @(NSHeight(f))]}];
    }
    return rows;
}
static BOOL sameWindows(void) {
    return !invalidated && owned.count == 2 && numbers.count == 2 && [numbers[0] intValue] > 0 &&
           [numbers[1] intValue] > 0 && ![numbers[0] isEqual:numbers[1]] &&
           owned[0].windowNumber == [numbers[0] intValue] && owned[1].windowNumber == [numbers[1] intValue];
}
static void observe(NSEvent *event, NSWindow *window, NPReceiver stream) {
    if (!active || !window || [owned indexOfObjectIdenticalTo:window] == NSNotFound) return;
    unsigned slot = (unsigned)[owned indexOfObjectIdenticalTo:window];
    NPInputPhase phase;
    switch (event.type) {
        case NSEventTypeLeftMouseDown: phase = NPDown; break;
        case NSEventTypeLeftMouseDragged: phase = NPDrag; break;
        case NSEventTypeLeftMouseUp: phase = NPUp; break;
        case NSEventTypeKeyDown: phase = NPKeyDown; break;
        case NSEventTypeKeyUp: phase = NPKeyUp; break;
        default: active.interrupted = YES; return;
    }
    CGEventRef cg = event.CGEvent;
    if (!cg || !sameWindows() || event.window != window || event.windowNumber != [numbers[slot] intValue] ||
        event.timestamp < active.started || event.timestamp > active.deadline) {
        active.interrupted = YES; return;
    }
    if ((phase == NPDown || phase == NPDrag || phase == NPUp) &&
        !NSPointInRect([window.contentView convertPoint:event.locationInWindow fromView:nil],window.contentView.bounds)) {
        active.interrupted = YES; return;
    }
    pid_t from = (pid_t)CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID);
    uint64_t tag = (uint64_t)CGEventGetIntegerValueField(cg, kCGEventSourceUserData);
    // Only the signed peer's exact outstanding marker may ever cause characters to be read.
    BOOL matches = NO;
    if (phase == NPKeyDown && active.keyboard && tag == active.tag && from == active.source && now() <= active.deadline) {
        matches = !event.isARepeat && window.isKeyWindow && window.firstResponder == window.contentView &&
                  [event.characters isEqual:active.marker];
    }
    [active receive:phase from:from tag:tag slot:slot stream:stream now:now() markerMatches:matches];
}
@interface NPInteractiveView : NSView
@end
@implementation NPInteractiveView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)e { observe(e,self.window,NPContent); }
- (void)mouseDragged:(NSEvent *)e { observe(e,self.window,NPContent); }
- (void)mouseUp:(NSEvent *)e { observe(e,self.window,NPContent); }
- (void)keyDown:(NSEvent *)e { observe(e,self.window,NPContent); }
- (void)keyUp:(NSEvent *)e { observe(e,self.window,NPContent); }
@end

static BOOL openTwo(NSString *displayUUID) {
    [NSApplication sharedApplication];
    if (![NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]) return NO;
    [NSApp finishLaunching];
    NSScreen *screen = NSScreen.screens.firstObject;
    NSNumber *n = screen.deviceDescription[@"NSScreenNumber"];
    if (NSScreen.screens.count != 1 || !n) return NO;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(n.unsignedIntValue);
    NSString *display = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL,uuid)) : nil;
    if (uuid) CFRelease(uuid);
    if (!sameUUID(display,displayUUID)) return NO;
    NSRect v = screen.visibleFrame;
    CGFloat w = MIN(264, floor((NSWidth(v) - 60) / 2)), h = MIN(180, NSHeight(v) - 120);
    if (w < 124 || h < 92) return NO;
    NSMutableArray *made = [NSMutableArray array], *ids = [NSMutableArray array];
    for (unsigned i = 0; i < 2; i++) {
        NSRect f = NSMakeRect(NSMinX(v) + 20 + i*(w + 12), NSMaxY(v) - 60 - h, w, h);
        NSView *view = [[NPInteractiveView alloc] initWithFrame:NSMakeRect(0,0,w,h)];
        NSWindow *win = ordinaryFixtureWindow(f, view, i ? @"Nearpane interactive sibling" : @"Nearpane interactive target",
                                               i ? NSColor.systemOrangeColor : NSColor.systemBlueColor);
        win.tabbingMode = NSWindowTabbingModeDisallowed;
        [made addObject:win];
        [win makeFirstResponder:view];
        [win orderFront:nil];
        [ids addObject:@(win.windowNumber)];
    }
    owned = made.copy;
    numbers = ids.copy;
    lifetimes = @[ NSUUID.UUID.UUIDString.lowercaseString, NSUUID.UUID.UUIDString.lowercaseString ];
    return sameWindows();
}
static BOOL sendReply(int fd, NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length > 16000) return NO;
    NSMutableData *line = data.mutableCopy;
    [line appendBytes:"\n" length:1];
    size_t sent = 0;
    while (sent < line.length) {
        ssize_t n = send(fd, (const char *)line.bytes + sent, line.length - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        sent += (size_t)n;
    }
    return YES;
}
static BOOL save(int dir, const char *name, NSDictionary *row) {
    int f = openat(dir,name,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    if (f < 0) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:f closeOnDealloc:YES];
    return data && [handle writeData:data error:NULL] && [handle synchronizeAndReturnError:NULL] && [handle closeAndReturnError:NULL];
}
static BOOL exactKeys(NSDictionary *msg, NSArray *extra) {
    NSMutableSet *keys = [NSMutableSet setWithArray:@[@"challenge",@"seq",@"op"]];
    [keys addObjectsFromArray:extra];
    return [keys isEqual:[NSSet setWithArray:msg.allKeys]];
}
static BOOL headerOK(id msg, NSString *nonce, unsigned seq) {
    return [msg isKindOfClass:NSDictionary.class] && sameUUID(msg[@"challenge"],nonce) &&
           positiveInteger(msg[@"seq"]) && [msg[@"seq"] unsignedLongLongValue] == seq &&
           [msg[@"op"] isKindOfClass:NSString.class];
}

// The admission proof and local socket identify the same installed Host generation.
// Every window in any response was created above and retained by this process.
static NSDictionary *handle(NSDictionary *m, NSDictionary *peer, NSString *nonce, BOOL *stop) {
    NSString *op = m[@"op"];
    if ([op isEqual:@"open"] && !owned && exactKeys(m,@[@"displayUUID",@"spaceUUID",@"nativeID"])) {
        uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSDictionary *pre = readPreflight(nonce);
        if (!ordinaryHostPreflight(pre,peer,m,ns)) return nil;
        scope = @{@"displayUUID":m[@"displayUUID"],@"spaceUUID":m[@"spaceUUID"],@"nativeID":m[@"nativeID"]};
        NSArray *samples = pre[@"spaceScope"][@"samples"];
        displayToken = samples.lastObject[@"managedDisplayToken"];
        if (!stillOnLease(scope,displayToken) || !openTwo(m[@"displayUUID"]) || !stillOnLease(scope,displayToken)) return nil;
        return @{@"windows":windowsSnapshot(), @"regular":@( (BOOL)(NSApp.activationPolicy == NSApplicationActivationPolicyRegular))};
    }
    if (!sameWindows()) return nil;
    if ([op isEqual:@"close"] && exactKeys(m,@[])) { *stop = YES; return @{}; }
    if (!stillOnLease(scope,displayToken)) return nil;
    if ([op isEqual:@"sample"] && exactKeys(m,@[])) return @{@"windows":windowsSnapshot()};
    NSUUID *intent = [m[@"intent"] isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:m[@"intent"]] : nil;
    if (!intent) return nil;
    if ([op isEqual:@"arm"] && !active && ![used containsObject:intent] && used.count < 16 &&
        exactKeys(m,@[@"intent",@"kind",@"receiver"]) &&
        [@[@"mouse",@"key"] containsObject:m[@"kind"]] && [@[@"target",@"sibling"] containsObject:m[@"receiver"]]) {
        unsigned slot = [m[@"receiver"] isEqual:@"sibling"] ? 1 : 0;
        active = [[NPInputWitness alloc] initWithIntent:intent source:[peer[@"pid"] intValue] slot:slot
                                              keyboard:[m[@"kind"] isEqual:@"key"] now:now()];
        [used addObject:intent];
        prior = @{@"windows":windowsSnapshot(), @"uptime":@(now())};
        NSMutableDictionary *r = [@{@"intent":intent.UUIDString.lowercaseString,
            @"tagHex":[NSString stringWithFormat:@"%016llx",(unsigned long long)active.tag],
            @"deadlineUptime":@(active.deadline), @"before":prior} mutableCopy];
        if (active.keyboard) r[@"marker"] = active.marker;
        return r;
    }
    if ([op isEqual:@"finish"] && [active.intent isEqual:intent] && exactKeys(m,@[@"intent"])) {
        NSDictionary *r = @{@"delivery":[active resultAt:now()], @"before":prior,
                            @"after":@{@"windows":windowsSnapshot(), @"uptime":@(now())}};
        active = nil; prior = nil;
        return r;
    }
    return nil;
}

static int serve(NSString *nonce) {
    NSString *root = [@"/private/tmp/nearpane-membership." stringByAppendingString:nonce];
    NSString *binary = [root stringByAppendingPathComponent:@"Interactive Windows.app/Contents/MacOS/InteractiveWindows"];
    int dir = privateDirectory(root);
    uint64_t birth = processBirth(getpid());
    SecCodeRef self = NULL;
    if (dir < 0 || !birth || !kernelExecutable(getpid(),binary) || ![NSBundle.mainBundle.bundleIdentifier isEqual:fixtureID] ||
        SecCodeCopySelf(0,&self)) { if (dir >= 0) close(dir); return 2; }
    NSString *digest = codeHash(self,fixtureID);
    CFRelease(self);
    if (!digest) { close(dir); return 2; }
    NSString *path = [root stringByAppendingPathComponent:@"interactive.sock"];
    int listener = socket(AF_UNIX,SOCK_STREAM,0);
    struct sockaddr_un addr = {.sun_family=AF_UNIX};
    if (listener < 0 || strlcpy(addr.sun_path,path.fileSystemRepresentation,sizeof(addr.sun_path)) >= sizeof(addr.sun_path)) {
        if (listener >= 0) close(listener);
        close(dir); return 2;
    }
    addr.sun_len = SUN_LEN(&addr);
    mode_t mask = umask(0077);
    BOOL bound = !bind(listener,(struct sockaddr *)&addr,addr.sun_len);
    umask(mask);
    if (!bound || listen(listener,1)) { if (bound) unlinkat(dir,"interactive.sock",0); close(listener); close(dir); return 2; }
    double started = now(), limit = started + 75;
    NSDictionary *owner = @{@"pid":@(getpid()), @"birth":@(birth), @"cdhash":digest, @"identifier":fixtureID};
    NSDictionary *fixed = @{@"schema":@1,@"challenge":nonce,@"owner":owner,@"startedUptime":@(started),@"deadlineUptime":@(limit)};
    BOOL ready = save(dir,"interactive-ready.json",fixed);
    struct pollfd pollFD = {.fd=listener,.events=POLLIN};
    int connection = -1;
    if (ready && poll(&pollFD,1,12000) == 1 && (pollFD.revents & POLLIN)) connection = accept(listener,NULL,NULL);
    close(listener);
    unlinkat(dir,"interactive.sock",0);
    NSDictionary *peer = connection >= 0 ? authenticatedHost(connection) : nil;
    int yes = 1;
    struct timeval shortWrite = {.tv_sec=0,.tv_usec=150000};
    if (peer && (setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes)) ||
                 setsockopt(connection,SOL_SOCKET,SO_SNDTIMEO,&shortWrite,sizeof(shortWrite)))) peer = nil;
    NSString *end = ready ? (peer ? @"deadline" : @"noAuthenticatedHost") : @"ownerReceiptUnavailable";
    unsigned seq = 1;
    used = [NSMutableSet set];
    NSMutableData *buf = [NSMutableData data];
    id spaceObserver = nil, displayObserver = nil, closeObserver = nil, monitor = nil;
    BOOL closeRequested = NO;
    while (peer && !closeRequested && seq <= 128 && now() < limit) {
        @autoreleasepool {
            if (owned) {
                NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.008]
                                                   inMode:NSDefaultRunLoopMode dequeue:YES];
                if (e) [NSApp sendEvent:e];
                [NSApp updateWindows];
                if (!sameWindows()) { end = @"windowDisplayOrSpaceChanged"; break; }
            }
            struct pollfd pending = {.fd=connection,.events=POLLIN};
            int polled = poll(&pending,1,owned ? 0 : 10);
            if (polled < 0 && errno == EINTR) continue;
            if (!polled) continue;
            if (polled < 0 || !(pending.revents & POLLIN)) { end = @"hostDisconnected"; break; }
            char bytes[1200];
            ssize_t got = recv(connection,bytes,sizeof(bytes),MSG_DONTWAIT);
            if (!got) { end = @"hostDisconnected"; break; }
            if (got < 0) { if (errno == EAGAIN || errno == EINTR) continue; end = @"readFailed"; break; }
            [buf appendBytes:bytes length:(NSUInteger)got];
            if (buf.length > 2048) { end = @"oversizedMessage"; break; }
            const char *newline = memchr(buf.bytes,'\n',buf.length);
            if (!newline) continue;
            if (newline != (const char *)buf.bytes + buf.length - 1) { end = @"overlappingMessages"; break; }
            id m = [NSJSONSerialization JSONObjectWithData:buf options:0 error:NULL];
            [buf setLength:0];
            if (!headerOK(m,nonce,seq) || ![peer isEqual:authenticatedHost(connection)]) { end = @"invalidHeaderOrPeer"; break; }
            BOOL first = !owned;
            NSDictionary *reply = handle(m,peer,nonce,&closeRequested);
            if (!reply) { end = @"admissionOrCommandRefused"; break; }
            if (first && owned) {
                closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil
                    queue:nil usingBlock:^(NSNotification *n){ if ([owned indexOfObjectIdenticalTo:n.object] != NSNotFound) invalidated = YES; }];
                displayObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil queue:nil usingBlock:^(NSNotification *n){ (void)n; invalidated = YES; }];
                spaceObserver = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil queue:nil usingBlock:^(NSNotification *n){ (void)n; invalidated = YES; }];
                NSEventMask watched = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                    NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
                monitor = [NSEvent addLocalMonitorForEventsMatchingMask:watched handler:^NSEvent *(NSEvent *e) {
                    observe(e,e.window,NPQueue); return e;
                }];
                if (!monitor || !closeObserver || !spaceObserver || !displayObserver) { end = @"observationUnavailable"; break; }
            }
            if (closeRequested) { end = @"hostClosed"; break; }
            NSMutableDictionary *r = fixed.mutableCopy;
            [r addEntriesFromDictionary:reply];
            r[@"scope"] = scope;
            r[@"seq"] = @(seq++); r[@"op"] = m[@"op"]; r[@"uptime"] = @(now()); r[@"host"] = peer;
            if (!sendReply(connection,r)) { end = @"hostDisconnected"; break; }
        }
    }
    if (spaceObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:spaceObserver];
    if (closeObserver) [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
    if (displayObserver) [NSNotificationCenter.defaultCenter removeObserver:displayObserver];
    if (monitor) [NSEvent removeMonitor:monitor];
    NSDictionary *unfinished = nil;
    if (active) {
        active.interrupted = YES;
        unfinished = @{@"before":prior, @"delivery":[active resultAt:now()]};
    }
    NSArray *beforeClose = owned ? windowsSnapshot() : @[];
    BOOL locallyClosed = YES;
    for (NSWindow *w in owned) { [w close]; locallyClosed &= !w.visible; }
    NSMutableDictionary *last = fixed.mutableCopy;
    [last addEntriesFromDictionary:@{@"seq":@(seq),@"op":@"close",@"reason":end,@"uptime":@(now()),
        @"beforeClose":beforeClose,@"ownWindowsCreated":@(owned.count),@"ownWindowsClosed":@(locallyClosed),
        @"physicalInput":@"NOT_ASSESSED",@"systemRemoval":@"REQUIRES_INDEPENDENT_READBACK"}];
    if (peer) last[@"host"] = peer;
    if (unfinished) last[@"unfinished"] = unfinished;
    BOOL durable = save(dir,"interactive-closed.json",last);
    if (closeRequested && durable) sendReply(connection,last);
    if (connection >= 0) close(connection);
    close(dir);
    return closeRequested && durable && locallyClosed ? 0 : 3;
}

#import "self-test.inc"
int main(int argc,const char **argv) {
    @autoreleasepool {
        // This path never initializes NSApplication or looks up any other application.
        if (argc == 2 && !strcmp(argv[1],"--self-test")) return offlineTests();
        if (argc != 3 || strcmp(argv[1],"--interactive-fixture") || !getuid() || getuid() != geteuid()) return 2;
        NSUUID *id = [[NSUUID alloc] initWithUUIDString:@(argv[2])];
        if (!id || ![id.UUIDString.lowercaseString isEqual:@(argv[2])]) return 2;
        return serve(id.UUIDString.lowercaseString);
    }
}
