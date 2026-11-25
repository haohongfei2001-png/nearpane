// Ordinary test documents in a process separate from the Nearpane controller.
// The command channel can address only these newly created windows.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <libproc.h>
#import <unistd.h>

static NSString *directory, *nonce;
static NSMutableArray<NSWindow *> *documents;
static NSMutableArray<NSTextField *> *fields;
static NSInteger commandSequence;
static NSInteger pendingFocus = -1, lastFocusSequence;
static double focusDeadline;
static BOOL lastActivationAccepted;
static void completeRequestedFocus(void) {
    if(pendingFocus<0)return;
    if(NSProcessInfo.processInfo.systemUptime>focusDeadline){pendingFocus=-1;return;}
    if(!NSApp.isActive)return;
    NSWindow *window=documents[(NSUInteger)pendingFocus];
    [window makeKeyAndOrderFront:nil];[window makeFirstResponder:fields[(NSUInteger)pendingFocus]];
    if(window.isKeyWindow)pendingFocus=-1;
}
static uint64_t birth(void) {
    struct proc_bsdinfo p={0};
    return proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p)
        ? p.pbi_start_tvsec*1000000+p.pbi_start_tvusec : 0;
}
static void writeState(void) {
    NSMutableArray *rows=[NSMutableArray array];
    for (NSUInteger i=0;i<documents.count;i++) {
        NSWindow *w=documents[i]; NSRect f=w.frame;
        [rows addObject:@{@"index":@(i),@"number":@(w.windowNumber),@"visible":@(w.isVisible),
            @"miniaturized":@(w.isMiniaturized),@"key":@(w.isKeyWindow),@"fullScreen":@((w.styleMask&NSWindowStyleMaskFullScreen)!=0),
            @"frame":@[@(f.origin.x),@(f.origin.y),@(f.size.width),@(f.size.height)],
            @"text":fields[i].stringValue}];
    }
    NSDictionary *state=@{@"schema":@1,@"nonce":nonce,@"pid":@(getpid()),@"birth":@(birth()),
        @"bundle":NSBundle.mainBundle.bundleIdentifier?:@"",@"commandSequence":@(commandSequence),@"windows":rows,
        @"applicationActive":@(NSApp.isActive),@"lastFocusSequence":@(lastFocusSequence),
        @"focusActivationAccepted":@(lastActivationAccepted)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:NULL];
    [data writeToFile:[directory stringByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:NULL];
}
static void command(void) {
    NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]];
    NSDictionary *request=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"nonce"] isEqual:nonce] ||
        [request[@"sequence"] integerValue]<=commandSequence) return;
    NSInteger index=[request[@"index"] integerValue]; NSString *action=request[@"action"];
    if (index<0 || (NSUInteger)index>=documents.count || ![action isKindOfClass:NSString.class]) return;
    NSWindow *w=documents[(NSUInteger)index];
    pendingFocus=-1;
    if ([action isEqual:@"focus"]) {
        // This nonce-bound command explicitly requests foreground ownership of
        // our own fixture. Options 0 cannot displace the currently active app.
        lastFocusSequence=[request[@"sequence"] integerValue];pendingFocus=index;
        focusDeadline=NSProcessInfo.processInfo.systemUptime+2.5;
        lastActivationAccepted=[NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        completeRequestedFocus();
    } else if ([action isEqual:@"minimize"]) {
        // This is the actual AppKit action of the yellow title-bar button, not orderOut.
        [[w standardWindowButton:NSWindowMiniaturizeButton] performClick:nil];
    } else if ([action isEqual:@"restore"]) {
        [w deminiaturize:nil];
    } else if ([action isEqual:@"fullscreen"]) {
        [w toggleFullScreen:nil];
    } else if ([action isEqual:@"close"]) {
        [w close];
    } else if ([action isEqual:@"quit"]) {
        for (NSWindow *document in documents) [document close];
        commandSequence=[request[@"sequence"] integerValue]; writeState(); [NSApp terminate:nil]; return;
    } else { return; }
    commandSequence=[request[@"sequence"] integerValue]; writeState();
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=5) return 2;
        directory=@(argv[1]);nonce=@(argv[2]);NSInteger count=[@(argv[3]) integerValue], offset=[@(argv[4]) integerValue];
        if (![[NSUUID alloc] initWithUUIDString:nonce] || count<1 || count>2 || !birth()) return 2;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow.allowsAutomaticWindowTabbing=NO;
        // AppKit supplies the real Full Screen / Tile menu for a normal Window menu.
        // The acceptance helper discovers that system menu instead of inventing one.
        NSMenu *mainMenu=[NSMenu new], *applicationMenu=[NSMenu new], *windowMenu=[[NSMenu alloc] initWithTitle:@"Window"];
        NSMenuItem *applicationItem=[NSMenuItem new], *windowItem=[NSMenuItem new];
        applicationItem.submenu=applicationMenu;windowItem.submenu=windowMenu;
        [applicationMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
        [mainMenu addItem:applicationItem];[mainMenu addItem:windowItem];NSApp.mainMenu=mainMenu;NSApp.windowsMenu=windowMenu;
        [NSApp finishLaunching];
        documents=[NSMutableArray array];fields=[NSMutableArray array];
        for(NSInteger i=0;i<count;i++) {
            NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(120+offset+i*280,180,250,170)
                styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed=NO;w.tabbingMode=NSWindowTabbingModeDisallowed;
            w.title=[NSString stringWithFormat:@"Nearpane Fixture %@ %@ %ld",nonce.lowercaseString,NSBundle.mainBundle.bundleIdentifier,(long)i];
            w.collectionBehavior=NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorFullScreenPrimary|NSWindowCollectionBehaviorFullScreenAllowsTiling;
            w.contentView.wantsLayer=YES;
            w.contentView.layer.backgroundColor=(i==0?(offset==0?NSColor.systemRedColor:NSColor.systemGreenColor):NSColor.systemBlueColor).CGColor;
            NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(12,70,226,26)];
            field.stringValue=[NSString stringWithFormat:@"Fixture %ld / ready",(long)i];
            NSTextField *marker=[NSTextField wrappingLabelWithString:w.title];
            marker.frame=NSMakeRect(12,112,226,40);marker.font=[NSFont systemFontOfSize:8];
            [marker setAccessibilityIdentifier:[NSString stringWithFormat:@"nearpane-split-marker-%@-%@",nonce.lowercaseString,i==0?@"a":@"b"]];
            [w.contentView addSubview:marker];
            [w.contentView addSubview:field]; [documents addObject:w];[fields addObject:field];[w orderFront:nil];
        }
        [CATransaction flush]; writeState();
        double deadline=NSProcessInfo.processInfo.systemUptime+600;
        NSTimer *timer=[NSTimer timerWithTimeInterval:.04 repeats:YES block:^(NSTimer *t){
            command();completeRequestedFocus();writeState();
            if(NSProcessInfo.processInfo.systemUptime>=deadline){for(NSWindow *w in documents)[w close];[t invalidate];[NSApp terminate:nil];}
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];[NSApp run];[timer invalidate];
        return 0;
    }
}
