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
        BOOL second=[id_ isEqual:@"com.holdsnow.stageworkset-merge-fixture.b"];
        if (!second && ![id_ isEqual:@"com.holdsnow.stageworkset-merge-fixture.a"]) return 2;
        if (![[own objectForInfoDictionaryKey:@"NearpaneNativeMergeNonce"] isEqual:nonce] ||
            ![own.bundlePath isEqual:[bundle stringByAppendingPathComponent: second ? @"Contents/Helpers/Merge B.app" : @"Contents/Helpers/Merge A.app"]]) return 2;
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,290)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.title=second?@"Nearpane fixture B":@"Nearpane fixture A";window.releasedWhenClosed=NO;
        NSTextField *field=[NSTextField textFieldWithString:second?@"B":@"A"];
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
