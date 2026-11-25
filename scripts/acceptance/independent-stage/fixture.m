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
            @"miniaturized":@(w.isMiniaturized),@"key":@(w.isKeyWindow),
            @"frame":@[@(f.origin.x),@(f.origin.y),@(f.size.width),@(f.size.height)],
            @"text":fields[i].stringValue}];
    }
    NSDictionary *state=@{@"schema":@1,@"nonce":nonce,@"pid":@(getpid()),@"birth":@(birth()),
        @"bundle":NSBundle.mainBundle.bundleIdentifier?:@"",@"commandSequence":@(commandSequence),@"windows":rows};
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
    if ([action isEqual:@"focus"]) {
        [NSApp activateIgnoringOtherApps:YES]; [w makeKeyAndOrderFront:nil]; [w makeFirstResponder:fields[(NSUInteger)index]];
    } else if ([action isEqual:@"minimize"]) {
        // This is the actual AppKit action of the yellow title-bar button, not orderOut.
        [[w standardWindowButton:NSWindowMiniaturizeButton] performClick:nil];
    } else if ([action isEqual:@"restore"]) {
        [w deminiaturize:nil];
    } else if ([action isEqual:@"close"]) {
        [w close];
    } else if ([action isEqual:@"quit"]) {
        for (NSWindow *document in documents) [document close];
        commandSequence=[request[@"sequence"] integerValue]; writeState(); [NSApp stop:nil]; return;
    } else { return; }
    commandSequence=[request[@"sequence"] integerValue]; writeState();
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=5) return 2;
        directory=@(argv[1]);nonce=@(argv[2]);NSInteger count=[@(argv[3]) integerValue], offset=[@(argv[4]) integerValue];
        if (![NSUUID.alloc initWithUUIDString:nonce] || count<1 || count>2 || !birth()) return 2;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
        documents=[NSMutableArray array];fields=[NSMutableArray array];
        for(NSInteger i=0;i<count;i++) {
            NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(120+offset+i*280,180,250,170)
                styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed=NO;w.title=[NSString stringWithFormat:@"Nearpane Fixture %@ %ld",NSBundle.mainBundle.bundleIdentifier,(long)i];
            w.collectionBehavior=NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorFullScreenPrimary;
            w.contentView.wantsLayer=YES;
            w.contentView.layer.backgroundColor=(i==0?(offset==0?NSColor.systemRedColor:NSColor.systemGreenColor):NSColor.systemBlueColor).CGColor;
            NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(12,70,226,26)];
            field.stringValue=[NSString stringWithFormat:@"Fixture %ld / ready",(long)i];
            [w.contentView addSubview:field]; [documents addObject:w];[fields addObject:field];[w orderFront:nil];
        }
        [CATransaction flush]; writeState();
        double deadline=NSProcessInfo.processInfo.systemUptime+240;
        NSTimer *timer=[NSTimer timerWithTimeInterval:.04 repeats:YES block:^(NSTimer *t){
            command();writeState();
            if(NSProcessInfo.processInfo.systemUptime>=deadline){for(NSWindow *w in documents)[w close];[t invalidate];[NSApp stop:nil];}
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];[NSApp run];[timer invalidate];
        return 0;
    }
}
