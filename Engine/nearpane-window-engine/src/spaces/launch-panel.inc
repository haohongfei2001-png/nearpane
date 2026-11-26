// Included by platform.m so the same Apple SDK shim and symbol policy serves both routes.
// Only this class can be a production launch probe. No caller supplies an NSWindow or CGWindowID.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
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
    AXUIElementRef originalDesktopFocus;
    BOOL prepared, opened, closed, closeIssued;
}
@end
@implementation NPSpacesLaunchToken
- (void)dealloc { if(originalDesktopFocus)CFRelease(originalDesktopFocus); }
@end

static int launchTrace(NPSpacesLaunchToken *t,unsigned op,int result,const char *phase) {
    if (getenv("NP_SPACES_LAUNCH_TRACE")) {
        BOOL main=NSThread.isMainThread;
        fprintf(stderr,"{\"event\":\"spacesLaunchPlatform\",\"phase\":\"%s\",\"operation\":%u,\"result\":%d,\"mainThread\":%d,\"appRunning\":%d,\"prepared\":%d,\"opened\":%d,\"window\":%u,\"closeIssued\":%d}\n",
            phase,op,result,main,main?NSApp.isRunning:-1,main?t->prepared:-1,main?t->opened:-1,main?t->window:0,main?t->closeIssued:-1);
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
static BOOL focusFailure(const char *phase,AXError error,BOOL sameOwner) {
    if(getenv("NP_SPACES_LAUNCH_TRACE")) {
        fprintf(stderr,"{\"event\":\"spacesLaunchFocus\",\"phase\":\"%s\",\"axError\":%d,\"sameOwner\":%d}\n",phase,error,sameOwner);
        fflush(stderr);
    }
    return NO;
}
static BOOL focusSession(void) {
    CFDictionaryRef raw=CGSessionCopyCurrentDictionary();
    if(!raw)return focusFailure("console-session",kAXErrorSuccess,NO);
    NSDictionary *session=CFBridgingRelease(raw);
    id locked=session[@"CGSSessionScreenIsLocked"], uid=session[(__bridge NSString *)kCGSessionUserIDKey];
    BOOL active=CFEqual((__bridge CFTypeRef)(session[(__bridge NSString *)kCGSessionOnConsoleKey]?:@NO),kCFBooleanTrue) &&
        CFEqual((__bridge CFTypeRef)(session[(__bridge NSString *)kCGSessionLoginDoneKey]?:@NO),kCFBooleanTrue) &&
        [uid isKindOfClass:NSNumber.class] && [uid unsignedIntValue]==getuid() &&
        (!locked || (CFGetTypeID((__bridge CFTypeRef)locked)==CFBooleanGetTypeID() && ![locked boolValue]));
    return active || focusFailure("inactive-console",kAXErrorSuccess,NO);
}
static BOOL finderDesktopFocus(NSRunningApplication *front,AXUIElementRef app,AXUIElementRef focused,
                               AXError canonicalError,CGWindowID canonicalNumber) {
    // Match FrontFocus.isFinderDesktop. A zero or unavailable canonical number
    // proves nothing; only the independent positive AX structure proves desktop.
    char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
    BOOL finder=[front.bundleIdentifier isEqualToString:@"com.apple.finder"] &&
        proc_pidpath(front.processIdentifier,executable,sizeof(executable))>0 &&
        !strcmp(executable,"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder");
    if(!finder)return focusFailure("desktop-system-finder",kAXErrorSuccess,YES);
    AXError timeout=AXUIElementSetMessagingTimeout(focused,.08f);
    if(timeout!=kAXErrorSuccess)return focusFailure("desktop-timeout",timeout,YES);
    CFTypeRef role=NULL,parent=NULL,containing=NULL,rawWindows=NULL;
    AXError roleError=AXUIElementCopyAttributeValue(focused,kAXRoleAttribute,&role);
    AXError parentError=AXUIElementCopyAttributeValue(focused,kAXParentAttribute,&parent);
    AXError containingError=AXUIElementCopyAttributeValue(focused,kAXWindowAttribute,&containing);
    BOOL scroll=roleError==kAXErrorSuccess && role && CFEqual(role,kAXScrollAreaRole);
    BOOL root=parentError==kAXErrorSuccess && parent && CFGetTypeID(parent)==AXUIElementGetTypeID() && CFEqual(parent,app);
    BOOL noWindow=(containingError==kAXErrorNoValue || containingError==kAXErrorAttributeUnsupported) && !containing;
    CFIndex expected=0,actual=-1;
    AXError countError=AXUIElementGetAttributeValueCount(app,kAXWindowsAttribute,&expected);
    BOOL countValid=countError!=kAXErrorAPIDisabled && countError!=kAXErrorInvalidUIElement &&
        (countError!=kAXErrorSuccess || (expected>=0 && expected<=64));
    AXError arrayError=countValid?AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&rawWindows):kAXErrorFailure;
    BOOL complete=arrayError==kAXErrorSuccess && rawWindows && CFGetTypeID(rawWindows)==CFArrayGetTypeID();
    BOOL listed=NO;
    if(complete) {
        CFArrayRef windows=(CFArrayRef)rawWindows;actual=CFArrayGetCount(windows);
        complete=actual<=64 && (countError!=kAXErrorSuccess || actual==expected);
        for(CFIndex i=0;complete && i<actual;i++) {
            CFTypeRef item=CFArrayGetValueAtIndex(windows,i);pid_t owner=0;
            complete=item && CFGetTypeID(item)==AXUIElementGetTypeID() &&
                AXUIElementGetPid((AXUIElementRef)item,&owner)==kAXErrorSuccess && owner==front.processIdentifier;
            if(complete && CFEqual(item,focused))listed=YES;
        }
    }
    BOOL accepted=scroll && root && noWindow && complete && !listed;
    if(getenv("NP_SPACES_LAUNCH_TRACE")) {
        fprintf(stderr,"{\"event\":\"spacesLaunchDesktopFocus\",\"systemFinder\":true,\"canonicalError\":%d,\"canonicalNumber\":%u,\"roleError\":%d,\"desktopScrollArea\":%s,\"parentError\":%d,\"parentIsApplication\":%s,\"containingWindowError\":%d,\"containingWindowReturnedValue\":%s,\"countError\":%d,\"reportedCount\":%ld,\"arrayError\":%d,\"actualCount\":%ld,\"windowListComplete\":%s,\"listedAsWindow\":%s,\"confirmedDesktop\":%s}\n",
            canonicalError,canonicalNumber,roleError,scroll?"true":"false",parentError,root?"true":"false",containingError,containing?"true":"false",
            countError,(long)expected,arrayError,(long)actual,complete?"true":"false",listed?"true":"false",accepted?"true":"false");
        fflush(stderr);
    }
    if(role)CFRelease(role);if(parent)CFRelease(parent);if(containing)CFRelease(containing);if(rawWindows)CFRelease(rawWindows);
    return accepted;
}
static BOOL readFocus(pid_t *pid,uint64_t *started,uint32_t *window,AXUIElementRef *desktop) {
    if(desktop)*desktop=NULL;
    AXUIElementRef retainedDesktop=NULL;
    if(!focusSession())return NO;
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t owner=front.processIdentifier; uint64_t generation=birth(owner); CGWindowID n=0;
    if (!generation) return focusFailure("process-birth",kAXErrorSuccess,NO);
    if (owner==getpid()) {
        NSWindow *key=NSApp.keyWindow;
        if(key && (key.windowNumber<=0 || key.windowNumber>UINT32_MAX)) return focusFailure("own-key-number",kAXErrorSuccess,YES);
        n=key ? (CGWindowID)key.windowNumber : 0;
    } else {
        if(!AXIsProcessTrusted())return focusFailure("permission",kAXErrorAPIDisabled,NO);
        // Match the shipping ordinary controller's FrontFocus witness: the
        // frontmost process, its own AX focused window, and a second process check.
        // macOS 27 can fail system-wide AXFocusedApplication while this exact
        // application's AXFocusedWindow remains positively readable.
        AXUIElementRef app=AXUIElementCreateApplication(owner);CFTypeRef focused=NULL,active=NULL;
        pid_t axOwner=0;AXError error=kAXErrorFailure;const char *phase="application-timeout";
        BOOL valid=app && (error=AXUIElementSetMessagingTimeout(app,.08f))==kAXErrorSuccess;
        if(valid){phase="application-frontmost";error=AXUIElementCopyAttributeValue(app,kAXFrontmostAttribute,&active);
            valid=error==kAXErrorSuccess && active && CFEqual(active,kCFBooleanTrue);}
        if(valid) {
            phase="focused-window";error=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute,&focused);
            if(error==kAXErrorNoValue && !focused) {
                // An explicitly supported, empty focused-window attribute is a
                // known no-window state. Unsupported/failed reads stay unknown.
                CFArrayRef names=NULL;error=AXUIElementCopyAttributeNames(app,&names);
                valid=error==kAXErrorSuccess && names && CFArrayContainsValue(names,
                    CFRangeMake(0,CFArrayGetCount(names)),kAXFocusedWindowAttribute);
                if(names)CFRelease(names);n=0;
            } else {
                AXNumber number=(AXNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
                valid=error==kAXErrorSuccess && focused && CFGetTypeID(focused)==AXUIElementGetTypeID();
                if(valid){phase="focused-window-owner";error=AXUIElementGetPid((AXUIElementRef)focused,&axOwner);
                    valid=error==kAXErrorSuccess && axOwner==owner;}
                if(valid){phase="focused-window-number";error=number?number((AXUIElementRef)focused,&n):kAXErrorNotImplemented;
                    valid=error==kAXErrorSuccess && n>0;
                    if(!valid){phase="focused-desktop-structure";valid=finderDesktopFocus(front,app,(AXUIElementRef)focused,error,n);
                        if(valid){retainedDesktop=(AXUIElementRef)CFRetain(focused);n=0;}}}
            }
        }
        if(focused)CFRelease(focused);if(active)CFRelease(active);if(app)CFRelease(app);
        if(!valid)return focusFailure(phase,error,axOwner==owner);
    }
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=owner || birth(owner)!=generation || !focusSession()) {
        if(retainedDesktop)CFRelease(retainedDesktop);return focusFailure("foreground-changed",kAXErrorSuccess,NO);
    }
    if(desktop)*desktop=retainedDesktop;else if(retainedDesktop)CFRelease(retainedDesktop);
    *pid=owner;*started=generation;*window=n;return YES;
}
static BOOL originalFocus(NPSpacesLaunchToken *t) {
    pid_t pid=0;uint64_t started=0;uint32_t number=0;AXUIElementRef desktop=NULL;
    BOOL same=t->prepared && readFocus(&pid,&started,&number,&desktop) && pid==t->foreground &&
        started==t->foregroundBirth && number==t->originalFocus &&
        ((!t->originalDesktopFocus && !desktop) || (t->originalDesktopFocus && desktop && CFEqual(t->originalDesktopFocus,desktop)));
    if(desktop)CFRelease(desktop);return same;
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
        if(!noRegisteredProbe() || !readFocus(&t->foreground,&t->foregroundBirth,&t->originalFocus,&t->originalDesktopFocus))return launchTrace(t,op,0,"prepare-focus");
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
        // Commit the own probe's pending order-in before Rust reads its Space.
        // Upstream's launch probe explicitly flushes here; a registered AppKit
        // number alone does not establish WindowServer membership.
        [CATransaction flush];
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
    return readFocus(pid,started,window,NULL);
}
#endif
