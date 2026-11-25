// Included by platform.m so the same Apple SDK shim and symbol policy serves both routes.
// Only this class can be a production launch probe. No caller supplies an NSWindow or CGWindowID.
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>

@interface NPSpacesLaunchPanel : NSPanel
@end
@implementation NPSpacesLaunchPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface NPSpacesLaunchToken : NSObject {
@public
    NPSpacesLaunchPanel *panel;
    uint32_t window, originalFocus;
    pid_t foreground;
    uint64_t foregroundBirth;
    BOOL prepared, opened, closed, closeIssued;
}
@end
@implementation NPSpacesLaunchToken
@end

static int launchTrace(NPSpacesLaunchToken *t,unsigned op,int result,const char *phase) {
    if (getenv("NP_SPACES_LAUNCH_TRACE")) {
        fprintf(stderr,"{\"event\":\"spacesLaunchPlatform\",\"phase\":\"%s\",\"operation\":%u,\"result\":%d,\"mainThread\":%d,\"appRunning\":%d,\"prepared\":%d,\"opened\":%d,\"window\":%u,\"closeIssued\":%d}\n",
            phase,op,result,NSThread.isMainThread,NSApp.isRunning,t->prepared,t->opened,t->window,t->closeIssued);
        fflush(stderr);
    }
    return result;
}

@interface NPSpacesMainCall : NSObject {
@public
    atomic_bool expired;
    NPStageCanary read;
    int result;
}
@end
@implementation NPSpacesMainCall
@end

static BOOL signedInstalledHost(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if (proc_pidpath(getpid(),path,sizeof(path))<=0 || strcmp(path,"/Applications/Nearpane.app/Contents/MacOS/NearpaneHost")) return NO;
    SecCodeRef code=NULL;SecRequirementRef req=NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags,&code)!=errSecSuccess) return NO;
    OSStatus rc=SecRequirementCreateWithString(CFSTR("anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
                                                kSecCSDefaultFlags,&req);
    if (rc==errSecSuccess) rc=SecCodeCheckValidity(code,kSecCSStrictValidate,req);
    if(req)CFRelease(req);CFRelease(code);return rc==errSecSuccess;
}
void *np_stage_launch_token(void) {
    if (!signedInstalledHost() || !np_stage_target_build()) return NULL;
    return (void *)CFBridgingRetain([NPSpacesLaunchToken new]);
}
void *np_stage_launch_candidate_token(void) {
    // An explicit candidate can run from its build directory and an independently
    // launched diagnostic app. It can create only this process's transparent panel;
    // the original signed-install probe remains unchanged for archived receipts.
    if (!np_stage_candidate_supported()) return NULL;
    return (void *)CFBridgingRetain([NPSpacesLaunchToken new]);
}
static BOOL readFocus(pid_t *pid,uint64_t *started,uint32_t *window) {
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t owner=front.processIdentifier; uint64_t generation=birth(owner); CGWindowID n=0;
    if (!generation) return NO;
    if (owner==getpid()) {
        NSWindow *key=NSApp.keyWindow;
        if(key && (key.windowNumber<=0 || key.windowNumber>UINT32_MAX)) return NO;
        n=key ? (CGWindowID)key.windowNumber : 0;
    } else {
        if(!AXIsProcessTrusted())return NO;
        AXUIElementRef system=AXUIElementCreateSystemWide();CFTypeRef app=NULL,focused=NULL;
        pid_t axOwner=0;BOOL valid=system && AXUIElementSetMessagingTimeout(system,.08f)==kAXErrorSuccess &&
            AXUIElementCopyAttributeValue(system,kAXFocusedApplicationAttribute,&app)==kAXErrorSuccess && app &&
            CFGetTypeID(app)==AXUIElementGetTypeID() && AXUIElementGetPid((AXUIElementRef)app,&axOwner)==kAXErrorSuccess && axOwner==owner &&
            AXUIElementSetMessagingTimeout((AXUIElementRef)app,.08f)==kAXErrorSuccess;
        if(valid) {
            AXError e=AXUIElementCopyAttributeValue((AXUIElementRef)app,kAXFocusedWindowAttribute,&focused);
            if(e==kAXErrorNoValue && !focused) n=0;
            else {
                AXNumber number=(AXNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
                valid=e==kAXErrorSuccess && focused && CFGetTypeID(focused)==AXUIElementGetTypeID() &&
                    number && number((AXUIElementRef)focused,&n)==kAXErrorSuccess && n>0;
            }
        }
        if(focused)CFRelease(focused);if(app)CFRelease(app);if(system)CFRelease(system);
        if(!valid)return NO;
    }
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=owner || birth(owner)!=generation) return NO;
    *pid=owner;*started=generation;*window=n;return YES;
}
static BOOL originalFocus(NPSpacesLaunchToken *t) {
    pid_t pid=0;uint64_t started=0;uint32_t number=0;
    return t->prepared && readFocus(&pid,&started,&number) && pid==t->foreground &&
        started==t->foregroundBirth && number==t->originalFocus;
}
static BOOL truePanel(NPSpacesLaunchToken *t) {
    NSWindow *p=t->panel;
    return p && t->window && [p isMemberOfClass:NPSpacesLaunchPanel.class] &&
        [NSApp windowWithWindowNumber:t->window]==p && p.windowNumber==t->window && !p.isKeyWindow && !p.isMainWindow &&
        !p.canBecomeKeyWindow && !p.canBecomeMainWindow && p.ignoresMouseEvents && !p.isOpaque && p.alphaValue==0;
}
static BOOL noRegisteredProbe(void) {
    for (NSWindow *w in NSApp.windows) if([w isKindOfClass:NPSpacesLaunchPanel.class])return NO;
    return YES;
}
static int panelCall(NPSpacesLaunchToken *t,unsigned op,NPSpacesMainCall *call,void *authorization,NPStageGuard guard) {
    BOOL (^allowed)(void)=^BOOL{ return !atomic_load(&call->expired) && guard && guard(authorization); };
    if (!NSApp || !NSThread.isMainThread || atomic_load(&call->expired))return launchTrace(t,op,0,"entry");
    if(op==0 && !t->prepared) {
        if(!noRegisteredProbe() || !readFocus(&t->foreground,&t->foregroundBirth,&t->originalFocus))return launchTrace(t,op,0,"prepare-focus");
        t->prepared=YES;
    }
    if(op==1) {
        if(!t->prepared || t->opened || t->closed || !noRegisteredProbe() || !originalFocus(t) || !allowed())return launchTrace(t,op,0,"open-precondition");
        NSScreen *screen=NSApp.mainWindow.screen ?: NSScreen.mainScreen;
        if(!screen)return launchTrace(t,op,0,"open-screen");
        // Transparent but inside a physical display so the original desktop is well defined.
        NSRect frame=NSMakeRect(NSMidX(screen.frame),NSMidY(screen.frame),4,4);
        t->panel=[[NPSpacesLaunchPanel alloc] initWithContentRect:frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        t->opened=YES;
        NPSpacesLaunchPanel *p=t->panel;
        p.releasedWhenClosed=NO;p.opaque=NO;p.backgroundColor=NSColor.clearColor;p.alphaValue=0;p.hasShadow=NO;
        p.ignoresMouseEvents=YES;p.hidesOnDeactivate=NO;p.excludedFromWindowsMenu=YES;p.level=NSNormalWindowLevel;
        p.animationBehavior=NSWindowAnimationBehaviorNone;p.collectionBehavior=NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorFullScreenNone;
        if(p.windowNumber>0 && p.windowNumber<=UINT32_MAX)t->window=(uint32_t)p.windowNumber;
        if(!allowed() || !originalFocus(t) || !allowed())return launchTrace(t,op,0,"open-before-order");
        [p orderFront:nil];
        if(p.windowNumber<=0 || p.windowNumber>UINT32_MAX)return launchTrace(t,op,0,"open-window-number");
        t->window=(uint32_t)p.windowNumber;
    } else if(op==3 && t->panel) {
        NSWindow *p=t->panel;
        if(![p isMemberOfClass:NPSpacesLaunchPanel.class] || p.isKeyWindow || p.isMainWindow ||
           (t->window && p.windowNumber!=t->window) || !allowed())return launchTrace(t,op,0,"close-precondition");
        t->closeIssued=YES;[p close];t->panel=nil;t->closed=YES;
    }
    BOOL absent=!t->panel && noRegisteredProbe();
    call->read=(NPStageCanary){.number=t->window,.pid=getpid(),.birth=birth(getpid()),
        .opened=t->opened,.registered=truePanel(t),.absent=absent,.focus_same=originalFocus(t),.close_issued=t->closeIssued};
    return launchTrace(t,op,1,"complete");
}
int32_t np_stage_launch_call(void *handle,uint32_t op,void *ctx,NPStageGuard guard,NPStageFree release,NPStageCanary *out) {
    if(!handle || !out || op>3 || ((op==1 || op==3) && (!guard || !ctx || !release))) {
        if(ctx && release)release(ctx);return 0;
    }
    NPSpacesLaunchToken *token=(__bridge NPSpacesLaunchToken *)handle;
    NPSpacesMainCall *call=[NPSpacesMainCall new];atomic_init(&call->expired,false);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    void (^perform)(void)=^{
        @autoreleasepool {
            @try {call->result=panelCall(token,op,call,ctx,guard);}
            @catch(NSException *e) {call->result=launchTrace(token,op,0,"exception");}
            @finally {if(ctx && release)release(ctx);dispatch_semaphore_signal(done);}
        }
    };
    if(NSThread.isMainThread)perform();else dispatch_async(dispatch_get_main_queue(),perform);
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC))!=0) {
        atomic_store(&call->expired,true);return launchTrace(token,op,0,"main-queue-timeout");
    }
    if(call->result)*out=call->read;
    return call->result;
}

#ifdef NP_BUILD_EXACT_CANARY_TOOL
// Present only in the separately signed diagnostic executable; never linked into the ordinary Rust archive.
#import <sys/stat.h>
NSDictionary *np_stage_development_checks(void) {
    NSString *identifier=@"com.holdsnow.nearpane.spaces-launch-canary";
    NSBundle *bundle=NSBundle.mainBundle;
    NSURL *folder=bundle.bundleURL.URLByDeletingLastPathComponent;
    char kit[PATH_MAX]={0},exec[PROC_PIDPATHINFO_MAXSIZE]={0},selfPath[PATH_MAX]={0},bundlePath[PATH_MAX]={0},tmp[PATH_MAX]={0};
    BOOL kitReal=realpath(folder.fileSystemRepresentation,kit)!=NULL;
    BOOL tmpReal=realpath("/private/tmp",tmp)!=NULL;
    NSString *kitName=kitReal?[NSString stringWithUTF8String:kit]:@"";
    NSString *expected=[kitName stringByAppendingPathComponent:@"Spaces Launch Canary.app/Contents/MacOS/Canary"];
    BOOL canonicalParent=kitReal && tmpReal && [kitName.stringByDeletingLastPathComponent isEqual:[NSString stringWithUTF8String:tmp]];
    BOOL prefix=[kitName.lastPathComponent hasPrefix:@"nearpane-spaces-canary."];
    struct stat st={0};BOOL isDirectory=kitReal && lstat(kit,&st)==0 && S_ISDIR(st.st_mode);
    BOOL owner=isDirectory && st.st_uid==getuid();
    BOOL mode=isDirectory && (st.st_mode&0777)==0700;
    BOOL identity=[bundle.bundleIdentifier isEqual:identifier];
    BOOL live=proc_pidpath(getpid(),exec,sizeof(exec))>0 && realpath(exec,selfPath)!=NULL;
    BOOL bundleReal=bundle.executableURL && realpath(bundle.executableURL.fileSystemRepresentation,bundlePath)!=NULL;
    BOOL matching=live && bundleReal && !strcmp(selfPath,bundlePath) && [expected isEqual:[NSString stringWithUTF8String:selfPath]];
    BOOL uid=(getuid()==geteuid() && getuid()!=0);
    BOOL target=np_stage_target_build()==1;
    BOOL ax=AXIsProcessTrusted();
    OSStatus reqStatus=errSecParam,selfStatus=errSecParam,guestStatus=errSecParam,selfValidity=errSecParam,guestValidity=errSecParam;
    SecRequirementRef req=NULL;SecCodeRef code=NULL,guest=NULL;
    reqStatus=SecRequirementCreateWithString(CFSTR("anchor apple generic and identifier \"com.holdsnow.nearpane.spaces-launch-canary\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),kSecCSDefaultFlags,&req);
    selfStatus=SecCodeCopySelf(kSecCSDefaultFlags,&code);
    NSDictionary *attrs=@{(__bridge NSString *)kSecGuestAttributePid:@(getpid())};
    guestStatus=SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)attrs,kSecCSDefaultFlags,&guest);
    if(reqStatus==errSecSuccess && code)selfValidity=SecCodeCheckValidity(code,kSecCSStrictValidate,req);
    if(reqStatus==errSecSuccess && guest)guestValidity=SecCodeCheckValidity(guest,kSecCSStrictValidate,req);
    BOOL equivalent=code && guest && CFEqual(code,guest);
    if(code)CFRelease(code);if(guest)CFRelease(guest);if(req)CFRelease(req);
    BOOL signedSelf=selfStatus==errSecSuccess && selfValidity==errSecSuccess;
    BOOL signedGuest=guestStatus==errSecSuccess && guestValidity==errSecSuccess;
    BOOL accepted=identity && canonicalParent && prefix && owner && mode && matching && uid && target && signedSelf && signedGuest;
    return @{@"event":@"developmentIdentityPreflight",@"systemWrites":@0,@"targetOSBuildAndSIP":@(target),
        @"sipEnabled":@(np_stage_sip_enabled()),@"expectedBundleIdentifier":@(identity),@"nonrootSameUID":@(uid),
        @"kitHasPOSIXRealpath":@(kitReal),@"tmpHasPOSIXRealpath":@(tmpReal),@"canonicalPrivateTmpParent":@(canonicalParent),
        @"privateKitName":@(prefix),@"rootIsDirectory":@(isDirectory),@"rootUserOwned":@(owner),@"rootMode0700":@(mode),
        @"ownProcExecutableRealpath":@(live),@"bundleExecutableRealpath":@(bundleReal),@"sameExpectedExecutable":@(matching),
        @"requirementOSStatus":@(reqStatus),@"copySelfOSStatus":@(selfStatus),@"validateSelfOSStatus":@(selfValidity),
        @"copyPIDGuestOSStatus":@(guestStatus),@"validatePIDGuestOSStatus":@(guestValidity),@"selfAndGuestCFEqual":@(equivalent),
        @"existingOwnAccessibility":@(ax),@"identityAccepted":@(accepted)};
}
void *np_stage_launch_development_token(void) {
    return [np_stage_development_checks()[@"identityAccepted"] boolValue] ? (void *)CFBridgingRetain([NPSpacesLaunchToken new]) : NULL;
}
int32_t np_stage_development_focus(int32_t *pid,uint64_t *started,uint32_t *window) {
    return readFocus(pid,started,window);
}
#endif
