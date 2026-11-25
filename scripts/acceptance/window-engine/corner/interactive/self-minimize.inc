// Opt-in signed fixture only. The caller creates a private nonce directory and
// passes a pair of anonymous pipes. Only this fixture's second NSWindow is ever
// miniaturized. EOF, timeout or an interrupted observation still returns it.
#import <signal.h>
static int miniReceiptDir = -1;
static BOOL miniMessage(NSString *nonce, NSString *phase, NSDictionary *facts) {
    NSMutableDictionary *m = [facts mutableCopy]; m[@"nonce"] = nonce; m[@"phase"] = phase;
    m[@"uptimeNanoseconds"] = @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    NSString *name = [NSString stringWithFormat:@"owner-%@.json",phase];
    if (!save(miniReceiptDir,name.UTF8String,m)) return NO;
    NSData *d = [NSJSONSerialization dataWithJSONObject:m options:0 error:NULL];
    return d && d.length < 4096 && fwrite(d.bytes,1,d.length,stdout) == d.length && fputc('\n',stdout) != EOF && fflush(stdout) == 0;
}
static void miniPump(void) {
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.015]
                                      inMode:NSDefaultRunLoopMode dequeue:YES];
    if (e) [NSApp sendEvent:e];
    [NSApp updateWindows];
}
static BOOL miniWait(NSString *nonce, NSString *command, BOOL (^safe)(void)) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",nonce,command];
    NSData *expected = [line dataUsingEncoding:NSUTF8StringEncoding];
    char buf[128] = {0}; size_t used = 0;
    double end = now() + 7;
    while (now() < end && safe() && used < expected.length && expected.length < sizeof buf) {
        struct pollfd fd = {STDIN_FILENO,POLLIN,0}; int pollResult = poll(&fd,1,0);
        if (pollResult < 0 || (fd.revents & (POLLHUP | POLLERR | POLLNVAL))) return NO;
        if (fd.revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO,buf + used,expected.length - used);
            if (n < 1) return NO;
            used += (size_t)n;
        } else miniPump();
    }
    return used == expected.length && !memcmp(buf,expected.bytes,used) && safe();
}
static int selfMinimize(NSString *nonce) {
    struct stat inStat, outStat;
    if (bystander || !getuid() || getuid() != geteuid() || ![NSBundle.mainBundle.bundleIdentifier isEqual:fixtureID] ||
        fstat(STDIN_FILENO,&inStat) || fstat(STDOUT_FILENO,&outStat) || !S_ISFIFO(inStat.st_mode) || !S_ISFIFO(outStat.st_mode)) return 2;
    int dir = privateDirectory([@"/private/tmp/nearpane-mini." stringByAppendingString:nonce]);
    if (dir < 0) return 2;
    int claim = openat(dir,"consumed",O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0600);
    if (claim < 0) { close(dir); return 2; }
    miniReceiptDir=dir;
    close(claim); signal(SIGPIPE,SIG_IGN);
    SecCodeRef me=NULL; SecCodeCopySelf(kSecCSDefaultFlags,&me); NSString *hash=codeHash(me,fixtureID); if (me) CFRelease(me);
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; uint64_t birth = processBirth(front);
    if (!hash || front <= 1 || front == getpid() || !birth) return 2;
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching];
    __block BOOL focusChanged = NO;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:nil usingBlock:^(__unused NSNotification *n){ focusChanged = YES; }];
    BOOL (^safe)(void) = ^BOOL { return !focusChanged && !NSApp.isActive && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == front && processBirth(front) == birth; };
    NSWindow *one=nil, *two=nil; BOOL attempted=NO, miniSeen=NO, restored=NO, ok=NO;
    @try {
        if (!safe() || NSScreen.screens.count != 1 || !miniMessage(nonce,@"process",@{@"pid":@(getpid()),@"birth":@(processBirth(getpid())),@"cdhash":hash}) || !miniWait(nonce,@"open",safe)) return 3;
        NSRect visible=NSScreen.screens.firstObject.visibleFrame;
        if (NSWidth(visible)<600 || NSHeight(visible)<300) return 3;
        NSRect a=NSMakeRect(NSMinX(visible)+18,NSMinY(visible)+18,198,105), b=NSOffsetRect(a,220,0);
        one=ordinaryFixtureWindow(a,[NSView new],@"Nearpane minimize sibling",NSColor.systemBlueColor);
        two=ordinaryFixtureWindow(b,[NSView new],@"Nearpane minimize target",NSColor.systemOrangeColor);
        for (NSWindow *w in @[one,two]) { w.restorable=NO; w.ignoresMouseEvents=YES; w.tabbingMode=NSWindowTabbingModeDisallowed; [w orderBack:nil]; }
        NSInteger first=one.windowNumber, second=two.windowNumber; NSRect fa=one.frame, fb=two.frame;
        BOOL (^baseline)(void) = ^BOOL { return safe() && first>0 && second>0 && first!=second && one.windowNumber==first && two.windowNumber==second &&
            one.visible && !one.miniaturized && !one.keyWindow && !two.keyWindow && one.onActiveSpace && NSEqualRects(fa,one.frame); };
        if (!baseline() || !two.visible || two.miniaturized || !two.onActiveSpace || !miniMessage(nonce,@"windows",@{@"sibling":@(first),@"target":@(second)}) || !miniWait(nonce,@"mini",baseline)) return 3;
        attempted=YES; [two miniaturize:nil];
        double end=now()+2; while(now()<end && !two.miniaturized && baseline()) miniPump();
        miniSeen=two.miniaturized && baseline();
        if (!miniSeen || !miniMessage(nonce,@"minimized",@{@"target":@(second),@"siblingNormal":@YES}) || !miniWait(nonce,@"restore",baseline)) return 4;
        [two deminiaturize:nil]; end=now()+2; while(now()<end && (two.miniaturized || !two.visible) && baseline()) miniPump();
        restored=baseline() && !two.miniaturized && two.visible && two.onActiveSpace && NSEqualRects(fb,two.frame);
        if (!restored || !miniMessage(nonce,@"restored",@{@"target":@(second),@"siblingNormal":@YES,@"geometryRestored":@YES}) || !miniWait(nonce,@"close",baseline)) return 5;
        ok=YES;
    } @finally {
        if (attempted && two.miniaturized) { [two deminiaturize:nil]; double end=now()+2; while (now()<end && two.miniaturized) miniPump(); }
        BOOL originalFocus = safe(); [two close]; [one close];
        [NSNotificationCenter.defaultCenter removeObserver:token];
        miniMessage(nonce,@"closed",@{@"targetRestoredBeforeClose":@(attempted && !two.miniaturized),@"ownWindowsClosed":@(!one.visible && !two.visible),
            @"originalForegroundUnchanged":@(originalFocus && safe()),@"scopeCompleted":@(ok),@"miniSeen":@(miniSeen),@"restoreVerified":@(restored)});
    }
    return ok ? 0 : 6;
}
