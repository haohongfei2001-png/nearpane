// One ordinary owned window. No event injection, external actions, IPC or document access.
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <unistd.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *nonce=[NSString stringWithUTF8String:argv[1]];
        if (![[NSUUID alloc] initWithUUIDString:nonce]) return 2;
        pid_t parent=getppid();
        NSString *root=[@"/private/tmp/nearpane-apple-merge." stringByAppendingString:nonce];
        NSString *bundle=[root stringByAppendingPathComponent:@"Nearpane.app"];
        char path[PROC_PIDPATHINFO_MAXSIZE]={0};
        if (parent<=1 || !proc_pidpath(parent,path,sizeof(path)) ||
            ![[NSString stringWithUTF8String:path] isEqual:[bundle stringByAppendingPathComponent:@"Contents/MacOS/NearpaneHost"]]) return 2;
        NSBundle *own=NSBundle.mainBundle;
        NSString *id_=own.bundleIdentifier;
        NSDictionary *ids=@{@"com.holdsnow.stageworkset-merge-fixture.a":@"A",
                            @"com.holdsnow.stageworkset-merge-fixture.b":@"B",
                            @"com.holdsnow.stageworkset-merge-fixture.c":@"C"};
        NSString *letter=ids[id_];
        if (!letter || ([letter isEqual:@"C"] && ![[own objectForInfoDictionaryKey:@"NearpaneNativeFocusCycle"] boolValue])) return 2;
        NSString *relative=[NSString stringWithFormat:@"Contents/Helpers/Merge %@.app",letter];
        if (![[own objectForInfoDictionaryKey:@"NearpaneNativeMergeNonce"] isEqual:nonce] ||
            ![own.bundlePath isEqual:[bundle stringByAppendingPathComponent:relative]]) return 2;
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,290)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.title=[@"Nearpane fixture " stringByAppendingString:letter];window.releasedWhenClosed=NO;
        NSTextField *field=[NSTextField textFieldWithString:letter];
        field.frame=NSMakeRect(40,110,360,32); [window.contentView addSubview:field];
        [window center]; [window orderBack:nil];
        id focus=[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification
            object:app queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (getppid()==parent) [window makeKeyAndOrderFront:nil];
            }];
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:115];
        [NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) {
            if (getppid()!=parent || end.timeIntervalSinceNow<=0) {
                [window close]; [app terminate:nil];
            }
        }];
        [app run]; [NSNotificationCenter.defaultCenter removeObserver:focus]; return 0;
    }
}
