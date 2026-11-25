// Real cross-process acceptance using the shipping Spaces candidate ABI.
// Each write targets one of three windows created by this run's two fixture apps.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ColorSync/ColorSync.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <math.h>
#import "nearpane_window_engine.h"
#import "platform.h"

// The candidate is deliberately distinct from np_engine_create_qualified.
extern uint32_t np_engine_create_spaces_candidate(uint64_t *handle);
static NSMutableArray *timeline;
static NSMutableDictionary *checks;
static NSString *outDirectory, *runNonce;
static uint64_t engine, epoch;
static int connection;
static NPStageDesktop home;
static NSUUID *generation;
static NSMutableArray<NSMutableDictionary *> *targets;
static NSUInteger writeCount, setupAXWrites, fixtureFocusCommands;
static BOOL lastRequestFinished;

static void pump(double seconds) {
    if(NSThread.isMainThread)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    else [NSThread sleepForTimeInterval:seconds];
}
static NSRunningApplication *frontmostApplication(void) {
    if(NSThread.isMainThread)return NSWorkspace.sharedWorkspace.frontmostApplication;
    __block NSRunningApplication *application=nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ application=NSWorkspace.sharedWorkspace.frontmostApplication; });
    return application;
}
static uint64_t birth(int32_t pid) {
    struct proc_bsdinfo p={0};
    return pid>1 && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p) && p.pbi_uid==getuid()
        ? p.pbi_start_tvsec*1000000+p.pbi_start_tvusec : 0;
}
static void emit(NSDictionary *row) {
    NSMutableDictionary *record=[row mutableCopy];record[@"uptime"]=@(NSProcessInfo.processInfo.systemUptime);
    [timeline addObject:record];
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if(data){fwrite(data.bytes,1,data.length,stdout);puts("");fflush(stdout);}
}
static NSDictionary *readJSON(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path];id obj=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}
static NSArray<NSNumber *> *allSpaces(void) {
    uint64_t ids[2048];int n=np_stage_checked_inventory(connection,ids,2048);
    if(n<=0)return nil;NSMutableArray *rows=[NSMutableArray array];for(int i=0;i<n;i++)[rows addObject:@(ids[i])];
    return [rows sortedArrayUsingSelector:@selector(compare:)];
}
static BOOL ownerMatches(NSDictionary *target) {
    int32_t pid=[target[@"pid"] intValue];
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    return pid!=getpid() && birth(pid)==[target[@"birth"] unsignedLongLongValue] &&
        proc_pidpath(pid,path,sizeof(path))>0 && [@(path) isEqual:target[@"executable"]];
}
static NSDictionary *observe(NSDictionary *target,uint64_t expected,BOOL visible) {
    uint32_t n=[target[@"number"] unsignedIntValue];uint64_t spaces[128],members[8192];NPStageWindow cg={0};
    int count=np_stage_membership(connection,n,spaces,128), occupantCount=np_stage_occupants(connection,expected,members,8192);
    BOOL contains=NO;for(int i=0;i<occupantCount;i++)if(members[i]==n)contains=YES;
    int read=np_stage_window(n,&cg);NSArray *frame=target[@"frame"];BOOL geometry=read==1;
    for(NSUInteger i=0;i<4;i++)geometry=geometry&&fabs(cg.rect[i]-[frame[i] doubleValue])<=1;
    BOOL verified=ownerMatches(target)&&read==1&&cg.pid==[target[@"pid"] intValue]&&
        cg.birth==[target[@"birth"] unsignedLongLongValue]&&cg.layer_zero==1&&cg.onboard==(uint32_t)visible&&
        count==1&&spaces[0]==expected&&contains&&geometry;
    return @{@"number":@(n),@"pid":target[@"pid"],@"birth":target[@"birth"],@"expectedSpace":@(expected),
        @"windowSpaceCount":@(count),@"windowSpace":count==1?@(spaces[0]):NSNull.null,@"spaceContainsWindow":@(contains),
        @"onScreen":read==1?@(cg.onboard):NSNull.null,@"expectedOnScreen":@(visible),@"geometryPreserved":@(geometry),
        @"foreignProcess":[NSNumber numberWithBool:[target[@"pid"] intValue]!=getpid()],@"identityMatches":@(ownerMatches(target)),@"verified":@(verified)};
}
static BOOL verify(NSDictionary *target,uint64_t space,BOOL visible,NSString *phase) {
    unsigned consecutive=0;double end=NSProcessInfo.processInfo.systemUptime+2.5;NSDictionary *row=nil;
    do { row=observe(target,space,visible);consecutive=[row[@"verified"] boolValue]?consecutive+1:0;
        if(consecutive==2)break;pump(.035);
    } while(NSProcessInfo.processInfo.systemUptime<end);
    emit(@{@"event":@"independentReadback",@"phase":phase,@"observations":@(consecutive),@"read":row?:@{}});
    return consecutive==2;
}
static BOOL requestBefore(NPRequest *r,uint32_t operation,NSString *phase,NPReceipt *result,double deadline) {
    r->operation=operation;r->epoch=epoch;[NSUUID.UUID getUUIDBytes:r->intent];uint64_t ticket=0;
    uint32_t submitted=np_engine_submit(engine,r,&ticket),polled=NP_INVALID;
    *result=(NPReceipt){.size=sizeof(*result),.version=NP_ENGINE_ABI};
    double started=NSProcessInfo.processInfo.systemUptime,end=MIN(started+7,deadline);
    if(submitted==NP_OK)do {polled=np_engine_poll(engine,ticket,result);if(polled==NP_PENDING)pump(.005);}
        while(polled==NP_PENDING&&NSProcessInfo.processInfo.systemUptime<end);
    lastRequestFinished=submitted==NP_OK&&polled==NP_OK;
    BOOL passed=lastRequestFinished&&result->status==NP_PASS;
    emit(@{@"event":@"engineReceipt",@"phase":phase,@"operation":@(operation),@"submit":@(submitted),@"poll":@(polled),
        @"status":@(result->status),@"detail":@(result->detail),@"flags":@(result->flags),@"owned":@(result->owned),
        @"nativeSpace":@(result->native_id),@"seconds":@(NSProcessInfo.processInfo.systemUptime-started),@"verified":@(passed)});
    return passed;
}
static BOOL request(NPRequest *r,uint32_t operation,NSString *phase,NPReceipt *result) {
    return requestBefore(r,operation,phase,result,INFINITY);
}
static NPRequest windowRequest(NSDictionary *target) {
    NPRequest r={.size=sizeof(r),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=4000,
        .pid=[target[@"pid"] intValue],.birth=[target[@"birth"] unsignedLongLongValue],
        .window=[target[@"number"] unsignedIntValue],.native_id=home.id,.epoch=epoch};
    [generation getUUIDBytes:r.generation];
    NSUUID *group=[[NSUUID alloc] initWithUUIDString:target[@"group"]];[group getUUIDBytes:r.group];
    NSUUID *member=[[NSUUID alloc] initWithUUIDString:target[@"member"]];[member getUUIDBytes:r.member];
    NSUUID *lifetime=[[NSUUID alloc] initWithUUIDString:target[@"lifetime"]];[lifetime getUUIDBytes:r.lifetime];
    memcpy(r.display,home.display,16);memcpy(r.native_space,home.uuid,16);
    NSArray *f=target[@"frame"];r.frame=(NPRect){[f[0] doubleValue],[f[1] doubleValue],[f[2] doubleValue],[f[3] doubleValue]};
    return r;
}
static BOOL hideOperation(NSMutableDictionary *target,NSString *phase,uint32_t operation) {
    if([target[@"hidden"] boolValue])return YES;
    if(!ownerMatches(target))return NO;
    NPRequest r=windowRequest(target);NPReceipt receipt;writeCount++;
    BOOL accepted=request(&r,operation,phase,&receipt);
    // Keep the attempted target even after an uncertain receipt; cleanup reads actual membership.
    target[@"attempted"]=@YES;
    if(receipt.native_id && receipt.native_id!=home.id)target[@"parking"]=@(receipt.native_id);
    BOOL verified=accepted&&receipt.native_id!=home.id&&receipt.native_id&&verify(target,receipt.native_id,NO,phase);
    target[@"hidden"]=@(verified);return verified;
}
static BOOL hide(NSMutableDictionary *target,NSString *phase) { return hideOperation(target,phase,NP_HIDE); }
static BOOL show(NSMutableDictionary *target,NSString *phase) {
    if(!ownerMatches(target))return NO;
    NPRequest r=windowRequest(target);NPReceipt receipt;writeCount++;
    BOOL accepted=request(&r,NP_RESTORE,phase,&receipt);
    BOOL verified=accepted&&verify(target,home.id,YES,phase);
    if(verified){target[@"hidden"]=@NO;target[@"attempted"]=@NO;}return verified;
}
static BOOL ownerCommand(NSDictionary *target,NSString *action) {
    NSString *directory=target[@"directory"];
    NSDictionary *before=readJSON([directory stringByAppendingPathComponent:@"state.json"]);
    NSInteger sequence=[before[@"commandSequence"] integerValue]+1;
    NSDictionary *cmd=@{@"nonce":runNonce,@"sequence":@(sequence),@"index":target[@"index"],@"action":action};
    NSData *data=[NSJSONSerialization dataWithJSONObject:cmd options:0 error:NULL];
    if(![data writeToFile:[directory stringByAppendingPathComponent:@"command.json"] options:NSDataWritingAtomic error:NULL])return NO;
    double end=NSProcessInfo.processInfo.systemUptime+3;
    while(NSProcessInfo.processInfo.systemUptime<end){pump(.04);NSDictionary *state=readJSON([directory stringByAppendingPathComponent:@"state.json"]);
        if([state[@"nonce"] isEqual:runNonce]&&[state[@"commandSequence"] integerValue]==sequence)return YES;}
    return NO;
}
static BOOL ownerState(NSDictionary *target,NSString *field,BOOL wanted) {
    NSDictionary *state=readJSON([target[@"directory"] stringByAppendingPathComponent:@"state.json"]);
    NSArray *rows=state[@"windows"];NSUInteger i=[target[@"index"] unsignedIntegerValue];
    return [state[@"nonce"] isEqual:runNonce]&&i<rows.count&&[rows[i][@"number"] isEqual:target[@"number"]]&&[rows[i][field] boolValue]==wanted;
}
static BOOL waitOwnerState(NSDictionary *target,NSString *field,BOOL wanted) {
    double end=NSProcessInfo.processInfo.systemUptime+3;unsigned n=0;
    do{n=ownerState(target,field,wanted)?n+1:0;if(n==2)return YES;pump(.035);}while(NSProcessInfo.processInfo.systemUptime<end);
    return NO;
}
static NSDictionary *foregroundFocusSample(NSDictionary *target) {
    typedef AXError (*WindowNumber)(AXUIElementRef, CGWindowID *);
    WindowNumber numberReader=(WindowNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    pid_t pid=frontmostApplication().processIdentifier;
    uint64_t started=birth(pid);
    BOOL expectedOwner=pid==[target[@"pid"] intValue] && started==[target[@"birth"] unsignedLongLongValue];
    AXUIElementRef application=expectedOwner?AXUIElementCreateApplication(pid):NULL;
    CFTypeRef window=NULL,frontmost=NULL;pid_t windowPID=0;CGWindowID number=0;
    AXError windowResult=kAXErrorFailure,numberResult=kAXErrorFailure,pidResult=kAXErrorFailure,frontmostResult=kAXErrorFailure;
    if(application) {
        AXUIElementSetMessagingTimeout(application,.1);
        frontmostResult=AXUIElementCopyAttributeValue(application,kAXFrontmostAttribute,&frontmost);
        windowResult=AXUIElementCopyAttributeValue(application,kAXFocusedWindowAttribute,&window);
        if(windowResult==kAXErrorSuccess && window && CFGetTypeID(window)==AXUIElementGetTypeID() && numberReader) {
            pidResult=AXUIElementGetPid((AXUIElementRef)window,&windowPID);
            numberResult=numberReader((AXUIElementRef)window,&number);
        }
    }
    BOOL stableOwner=expectedOwner && frontmostApplication().processIdentifier==pid && birth(pid)==started;
    BOOL pidMatches=pidResult==kAXErrorSuccess && windowPID==pid;
    BOOL windowMatches=numberResult==kAXErrorSuccess && number==[target[@"number"] unsignedIntValue];
    BOOL frontmostTrue=frontmostResult==kAXErrorSuccess && frontmost && CFGetTypeID(frontmost)==CFBooleanGetTypeID() && CFBooleanGetValue(frontmost);
    // The stable foreground process and exact AX window are always required.
    // If AXFrontmost is implemented it must agree; unsupported is recorded
    // separately and is never reported as an affirmative AXFrontmost result.
    BOOL frontmostCompatible=frontmostTrue || frontmostResult==kAXErrorAttributeUnsupported;
    NSDictionary *sample=@{@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"stableForegroundOwner":@(stableOwner),
        @"windowRead":@(windowResult),@"windowNumberRead":@(numberResult),@"pidMatches":@(pidMatches),
        @"frontmostRead":@(frontmostResult),@"frontmostTrue":@(frontmostTrue),@"windowMatches":@(windowMatches),
        @"verified":[NSNumber numberWithBool:stableOwner&&pidMatches&&windowMatches&&frontmostCompatible]};
    if(frontmost)CFRelease(frontmost);if(window)CFRelease(window);if(application)CFRelease(application);
    return sample;
}
static BOOL waitFocusedFixture(NSDictionary *target) {
    NSMutableArray *confirmed=[NSMutableArray array];NSDictionary *last=nil;
    double end=NSProcessInfo.processInfo.systemUptime+3;
    do {
        last=foregroundFocusSample(target);
        if([last[@"verified"] boolValue])[confirmed addObject:last];else [confirmed removeAllObjects];
        if(confirmed.count==2)break;
        pump(.05);
    } while(NSProcessInfo.processInfo.systemUptime<end);
    emit(@{@"event":@"controlledForegroundFocusReadback",@"observations":confirmed.count?confirmed:@[last?:@{}],
        @"verified":[NSNumber numberWithBool:confirmed.count==2]});
    return confirmed.count==2;
}
static AXUIElementRef copyFixtureAXWindow(AXUIElementRef app,NSDictionary *target) CF_RETURNS_RETAINED;
static AXUIElementRef copyFixtureAXWindow(AXUIElementRef app,NSDictionary *target) {
    typedef AXError (*WindowNumber)(AXUIElementRef,CGWindowID *);
    WindowNumber numberReader=(WindowNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    CFTypeRef windows=NULL;AXUIElementRef found=NULL;BOOL complete=numberReader!=NULL;
    if(!app||AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&windows)!=kAXErrorSuccess||!windows||
       CFGetTypeID(windows)!=CFArrayGetTypeID()||CFArrayGetCount((CFArrayRef)windows)>32)complete=NO;
    if(complete)for(id item in (__bridge NSArray *)windows) {
        AXUIElementRef element=(__bridge AXUIElementRef)item;pid_t pid=0;CGWindowID number=0;
        if(CFGetTypeID(element)!=AXUIElementGetTypeID()||AXUIElementGetPid(element,&pid)!=kAXErrorSuccess||
           pid!=[target[@"pid"] intValue]||numberReader(element,&number)!=kAXErrorSuccess){complete=NO;break;}
        if(number==[target[@"number"] unsignedIntValue]){if(found){complete=NO;break;}found=element;}
    }
    if(complete&&found)CFRetain(found);else found=NULL;
    if(windows)CFRelease(windows);return found;
}
static BOOL fixtureConsoleAvailable(void) {
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();if(!session)return NO;
    NSDictionary *fields=(__bridge NSDictionary *)session;
    id uid=fields[(__bridge NSString *)kCGSessionUserIDKey];
    id console=fields[(__bridge NSString *)kCGSessionOnConsoleKey],login=fields[(__bridge NSString *)kCGSessionLoginDoneKey];
    id locked=fields[@"CGSSessionScreenIsLocked"];
    BOOL available=[uid isKindOfClass:NSNumber.class]&&[uid unsignedIntValue]==getuid()&&
        console&&CFEqual((__bridge CFTypeRef)console,kCFBooleanTrue)&&login&&CFEqual((__bridge CFTypeRef)login,kCFBooleanTrue)&&
        (!locked||CFEqual((__bridge CFTypeRef)locked,kCFBooleanFalse));
    CFRelease(session);return available;
}
static BOOL fixtureFocusWritePermitted(NSDictionary *target,AXUIElementRef app,AXUIElementRef window,
                                      int32_t origin,uint64_t originBirth) {
    NSDictionary *state=readJSON([target[@"directory"] stringByAppendingPathComponent:@"state.json"]);
    NSArray *rows=state[@"windows"];NSUInteger index=[target[@"index"] unsignedIntegerValue];
    NSString *bundle=state[@"bundle"];
    BOOL scoped=ownerMatches(target)&&[state[@"nonce"] isEqual:runNonce]&&[state[@"pid"] isEqual:target[@"pid"]]&&
       [state[@"birth"] isEqual:target[@"birth"]]&&
       [@[@"com.holdsnow.stage-engine-fixture-a",@"com.holdsnow.stage-engine-fixture-b"] containsObject:bundle?:@""]&&
       [rows isKindOfClass:NSArray.class]&&index<rows.count&&[rows[index][@"number"] isEqual:target[@"number"]];
    BOOL physical=scoped&&[observe(target,home.id,YES)[@"verified"] boolValue],console=fixtureConsoleAvailable();
    int32_t front=frontmostApplication().processIdentifier;
    BOOL foreground=(front==origin&&birth(front)==originBirth)||
         (front==[target[@"pid"] intValue]&&birth(front)==[target[@"birth"] unsignedLongLongValue]);
    if(!scoped||!physical||!console||!foreground) {
        emit(@{@"event":@"fixtureFocusAXGuard",@"nonceProcessWindowBound":@(scoped),@"originalHomeVisible":@(physical),
            @"consoleAvailable":@(console),@"foregroundUninterrupted":@(foreground)});return NO;
    }
    AXUIElementRef current=copyFixtureAXWindow(app,target);CFTypeRef title=NULL,minimized=NULL,fullScreen=NULL;
    NSString *expected=[NSString stringWithFormat:@"Nearpane Fixture %@ %@ %@",runNonce.lowercaseString,bundle,target[@"index"]];
    AXError titleRead=AXUIElementCopyAttributeValue(window,kAXTitleAttribute,&title);
    AXError minimizedRead=AXUIElementCopyAttributeValue(window,kAXMinimizedAttribute,&minimized);
    AXError fullScreenRead=AXUIElementCopyAttributeValue(window,CFSTR("AXFullScreen"),&fullScreen);
    BOOL same=current&&CFEqual(current,window);
    BOOL titleMatches=titleRead==kAXErrorSuccess&&title&&CFGetTypeID(title)==CFStringGetTypeID()&&[(__bridge NSString *)title isEqual:expected];
    BOOL notMinimized=minimizedRead==kAXErrorSuccess&&minimized&&CFEqual(minimized,kCFBooleanFalse);
    BOOL notFullScreen=fullScreenRead==kAXErrorSuccess&&fullScreen&&CFEqual(fullScreen,kCFBooleanFalse);
    BOOL valid=same&&titleMatches&&notMinimized&&notFullScreen;
    if(!valid)emit(@{@"event":@"fixtureFocusAXGuard",@"retainedExactAXWindow":@NO,
        @"enumeratedTargetFound":[NSNumber numberWithBool:current!=NULL],@"retainedObjectEqual":@(same),
        @"titleRead":@(titleRead),@"titleMatches":@(titleMatches),@"minimizedRead":@(minimizedRead),
        @"notMinimized":@(notMinimized),@"fullScreenRead":@(fullScreenRead),@"notFullScreen":@(notFullScreen)});
    if(current)CFRelease(current);if(title)CFRelease(title);if(minimized)CFRelease(minimized);if(fullScreen)CFRelease(fullScreen);
    return valid&&ownerMatches(target);
}
static BOOL waitRetainedFixtureFocus(NSDictionary *target,AXUIElementRef app,AXUIElementRef original) {
    typedef AXError (*WindowNumber)(AXUIElementRef,CGWindowID *);
    WindowNumber numberReader=(WindowNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    NSMutableArray *confirmed=[NSMutableArray array];NSDictionary *last=nil;
    double end=NSProcessInfo.processInfo.systemUptime+3;
    do {
        CFTypeRef focused=NULL;pid_t owner=0;CGWindowID number=0;
        AXError focusedRead=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute,&focused);
        AXError ownerRead=AXUIElementGetPid(original,&owner);
        AXError numberRead=numberReader?numberReader(original,&number):kAXErrorNotImplemented;
        BOOL retained=focusedRead==kAXErrorSuccess&&focused&&CFGetTypeID(focused)==AXUIElementGetTypeID()&&CFEqual(focused,original);
        BOOL originalIdentity=ownerRead==kAXErrorSuccess&&owner==[target[@"pid"] intValue]&&
            numberRead==kAXErrorSuccess&&number==[target[@"number"] unsignedIntValue]&&ownerMatches(target);
        BOOL ownerKey=ownerState(target,@"key",YES),physical=[observe(target,home.id,YES)[@"verified"] boolValue];
        NSDictionary *system=foregroundFocusSample(target);
        BOOL good=retained&&originalIdentity&&ownerKey&&physical&&[system[@"verified"] boolValue];
        last=@{@"retainedObjectFocused":@(retained),@"focusedRead":@(focusedRead),@"originalPIDRead":@(ownerRead),
            @"originalNumberRead":@(numberRead),@"originalIdentity":@(originalIdentity),@"ownerKey":@(ownerKey),
            @"originalHomeVisible":@(physical),@"systemFocus":system,@"verified":@(good)};
        if(focused)CFRelease(focused);
        if(good)[confirmed addObject:last];else [confirmed removeAllObjects];
        if(confirmed.count==2)break;pump(.05);
    } while(NSProcessInfo.processInfo.systemUptime<end);
    emit(@{@"event":@"fixtureFocusAXEndpoint",@"observations":confirmed.count?confirmed:@[last?:@{}],
        @"verified":[NSNumber numberWithBool:confirmed.count==2]});
    return confirmed.count==2;
}
static BOOL activateExactFixture(NSDictionary *target) {
    // AppKit may decline a background app's own activation request. Use the
    // shipping exact-window focus sequence, only on this run's retained fixture.
    int32_t origin=frontmostApplication().processIdentifier;uint64_t originBirth=birth(origin);
    AXUIElementRef app=AXUIElementCreateApplication([target[@"pid"] intValue]),window=NULL;
    BOOL good=app&&originBirth&&AXUIElementSetMessagingTimeout(app,.15)==kAXErrorSuccess;
    if(good)window=copyFixtureAXWindow(app,target);
    good=good&&window&&AXUIElementSetMessagingTimeout(window,.15)==kAXErrorSuccess;
    emit(@{@"event":@"fixtureFocusAXBound",@"originalForegroundBirthAvailable":@(originBirth>0),
        @"exactWindowBound":@(window!=NULL),@"ready":@(good)});
    for(NSString *step in @[@"main",@"frontmost",@"raise"]) {
        if(!good)break;
        BOOL permitted=fixtureFocusWritePermitted(target,app,window,origin,originBirth);
        AXError result=kAXErrorFailure;
        if(permitted) {
            setupAXWrites++;
            if([step isEqual:@"main"])result=AXUIElementSetAttributeValue(window,kAXMainAttribute,kCFBooleanTrue);
            else if([step isEqual:@"frontmost"])result=AXUIElementSetAttributeValue(app,kAXFrontmostAttribute,kCFBooleanTrue);
            else result=AXUIElementPerformAction(window,kAXRaiseAction);
        }
        emit(@{@"event":@"fixtureFocusAXStep",@"step":step,@"writeAttempted":@(permitted),
            @"axError":permitted?@(result):NSNull.null,@"setupAXWrites":@(setupAXWrites),@"pid":target[@"pid"],@"window":target[@"number"]});
        good=permitted&&result==kAXErrorSuccess;
        if(good&&![step isEqual:@"raise"]) {
            double end=NSProcessInfo.processInfo.systemUptime+.9;BOOL observed=NO;
            do {
                if([step isEqual:@"main"]) {
                    CFTypeRef main=NULL;AXError read=AXUIElementCopyAttributeValue(app,kAXMainWindowAttribute,&main);
                    observed=read==kAXErrorSuccess&&main&&CFGetTypeID(main)==AXUIElementGetTypeID()&&CFEqual(main,window);
                    if(main)CFRelease(main);
                } else observed=frontmostApplication().processIdentifier==[target[@"pid"] intValue]&&ownerMatches(target);
                if(observed)break;pump(.025);
            } while(NSProcessInfo.processInfo.systemUptime<end);
            good=observed;
            emit(@{@"event":@"fixtureFocusAXStepReadback",@"step":step,@"confirmed":@(observed)});
            // Activation can already make this original window the true key
            // window. Verify that endpoint directly; a second AXWindows listing
            // and a redundant Raise are not prerequisites for a completed focus.
            if(good&&frontmostApplication().processIdentifier==[target[@"pid"] intValue]&&
               waitRetainedFixtureFocus(target,app,window))break;
        }
    }
    if(window)CFRelease(window);if(app)CFRelease(app);return good;
}
static BOOL prepareFixtureFocus(NSDictionary *target,NSString *phase) {
    fixtureFocusCommands++;
    BOOL acknowledged=ownerCommand(target,@"focus");
    BOOL ownerKey=waitOwnerState(target,@"key",YES);
    // Always collect the stronger system focus read, even if the fixture's
    // local key-window flag disagrees. A failure must identify which fact failed.
    BOOL exactFocus=waitFocusedFixture(target);
    BOOL usedAX=NO,activatedAX=NO;
    if(acknowledged&&(!ownerKey||!exactFocus)&&ownerMatches(target)) {
        usedAX=YES;activatedAX=activateExactFixture(target);
        ownerKey=waitOwnerState(target,@"key",YES);
        exactFocus=waitFocusedFixture(target);
    }
    int32_t front=frontmostApplication().processIdentifier;
    NSDictionary *state=readJSON([target[@"directory"] stringByAppendingPathComponent:@"state.json"]);
    emit(@{@"event":@"fixtureFocusPreparation",@"phase":phase,@"commandAcknowledged":@(acknowledged),
        @"ownerKey":@(ownerKey),@"exactForegroundFocus":@(exactFocus),@"frontPID":@(front),@"expectedPID":target[@"pid"],
        @"applicationActive":state[@"applicationActive"]?:NSNull.null,
        @"activationRequested":state[@"focusActivationRequested"]?:NSNull.null,
        @"exactAXAttempted":@(usedAX),@"exactAXSequenceConfirmed":@(activatedAX),@"setupAXWrites":@(setupAXWrites),
        @"commandSequence":state[@"commandSequence"]?:NSNull.null});
    return acknowledged&&(!usedAX||activatedAX)&&ownerKey&&exactFocus&&front==[target[@"pid"] intValue]&&ownerMatches(target);
}
static void check(NSString *name,BOOL passed,NSString *scope) {
    checks[name]=@{@"status":passed?@"PASS":@"FAIL",@"scope":scope};
    emit(@{@"event":@"check",@"name":name,@"status":passed?@"PASS":@"FAIL",@"scope":scope});
}
static BOOL selectOnly(NSArray<NSNumber *> *indices,NSString *phase) {
    // Restore the incoming real windows, then retire the outgoing real windows. No corner path exists.
    for(NSNumber *i in indices){NSMutableDictionary *t=targets[i.unsignedIntegerValue];
        if([t[@"hidden"] boolValue]&&!show(t,[phase stringByAppendingString:@"/show"]))return NO;}
    for(NSUInteger i=0;i<targets.count;i++)if(![indices containsObject:@(i)]&&!hide(targets[i],[phase stringByAppendingString:@"/hide"]))return NO;
    for(NSUInteger i=0;i<targets.count;i++){BOOL visible=[indices containsObject:@(i)];
        uint64_t space=visible?home.id:[targets[i][@"parking"] unsignedLongLongValue];
        if(!verify(targets[i],space,visible,[phase stringByAppendingString:@"/all-members"]))return NO;}
    return YES;
}
static NSDictionary *spaceIdentity(id value) {
    if(![value isKindOfClass:NSDictionary.class])return @{@"class":value?NSStringFromClass([value class]):@"nil"};
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"id64",@"ManagedSpaceID",@"type",@"uuid"]) {
        id field=value[key];
        if(field)result[key]=@{@"class":NSStringFromClass([field class]),
            @"value":([field isKindOfClass:NSString.class]||[field isKindOfClass:NSNumber.class])?field:NSNull.null};
    }
    return result;
}
static NSDictionary *contextSnapshot(void) {
    int c=np_stage_connection();NPStageDesktop desktop[512];int count=np_stage_desktops(c,desktop,512),current=0;
    NSMutableArray *rows=[NSMutableArray array];
    for(int i=0;i<count;i++){current+=desktop[i].current&&!desktop[i].kind;
        [rows addObject:@{@"id":@(desktop[i].id),@"type":@(desktop[i].kind),@"current":@(desktop[i].current)}];}
    uint64_t ids[2048];int allCount=np_stage_all_spaces(c,ids,2048);
    NSMutableArray *allIDs=[NSMutableArray array];for(int i=0;i<allCount;i++)[allIDs addObject:@(ids[i])];
    int checked=np_stage_checked_inventory(c,ids,2048);
    NSMutableArray *rawDisplays=[NSMutableArray array];
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LOCAL|RTLD_NOW);
    CFArrayRef (*managed)(int)=sky?dlsym(sky,"SLSCopyManagedDisplaySpaces"):NULL;
    uint64_t (*directHome)(int,CFStringRef)=sky?dlsym(sky,"SLSManagedDisplayGetCurrentSpace"):NULL;
    CFTypeRef raw=managed?managed(c):NULL;
    if(raw&&CFGetTypeID(raw)==CFArrayGetTypeID())for(id value in (__bridge NSArray *)raw) {
        if(![value isKindOfClass:NSDictionary.class]){[rawDisplays addObject:@{@"class":NSStringFromClass([value class])}];continue;}
        id token=value[@"Display Identifier"];NSMutableArray *roster=[NSMutableArray array];
        id spaces=value[@"Spaces"];if([spaces isKindOfClass:NSArray.class])for(id item in spaces)[roster addObject:spaceIdentity(item)];
        [rawDisplays addObject:@{@"displayIdentifier":[token isKindOfClass:NSString.class]?token:NSNull.null,
            @"current":spaceIdentity(value[@"Current Space"]),@"spaces":roster,
            @"directCurrentID":@([token isKindOfClass:NSString.class]&&directHome?directHome(c,(__bridge CFStringRef)token):0)}];
    }
    BOOL rawReadable=raw&&CFGetTypeID(raw)==CFArrayGetTypeID();if(raw)CFRelease(raw);
    CFDictionaryRef (*sessionReader)(void)=dlsym(RTLD_DEFAULT,"CGSessionCopyCurrentDictionary");
    CFDictionaryRef session=sessionReader?sessionReader():NULL;NSMutableDictionary *sessionFields=[NSMutableDictionary dictionary];
    NSDictionary *sessionKeys=@{@"userID":(__bridge NSString *)kCGSessionUserIDKey,
        @"onConsole":(__bridge NSString *)kCGSessionOnConsoleKey,@"loginDone":(__bridge NSString *)kCGSessionLoginDoneKey,
        @"screenLocked":@"CGSSessionScreenIsLocked"};
    if(session&&CFGetTypeID(session)==CFDictionaryGetTypeID())for(NSString *label in sessionKeys) {
        id value=((__bridge NSDictionary *)session)[sessionKeys[label]];
        if([value isKindOfClass:NSNumber.class])sessionFields[label]=value;
    }
    if(session)CFRelease(session);
    CGRect screen=CGDisplayBounds(CGMainDisplayID());__block NSMutableArray *appKitScreens=[NSMutableArray array];
    __block NSMutableArray *systemProcesses=[NSMutableArray array];__block BOOL applicationRunning=NO;
    void (^readScreens)(void)=^{for(NSScreen *item in NSScreen.screens){NSRect f=item.frame;
        [appKitScreens addObject:@[@(f.origin.x),@(f.origin.y),@(f.size.width),@(f.size.height)]];}
        applicationRunning=NSApp.running;
        for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
            if([@[@"com.apple.dock",@"com.apple.WindowManager",@"com.apple.MissionControl"] containsObject:app.bundleIdentifier?:@""])
                [systemProcesses addObject:@{@"bundleIdentifier":app.bundleIdentifier,@"pid":@(app.processIdentifier)}];};
    if(NSThread.isMainThread)readScreens();else dispatch_sync(dispatch_get_main_queue(),readScreens);
    uint32_t active=0,online=0;(void)CGGetActiveDisplayList(0,NULL,&active);(void)CGGetOnlineDisplayList(0,NULL,&online);
    CFUUIDRef mainUUID=CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());NSString *uuid=nil;
    if(mainUUID){uuid=CFBridgingRelease(CFUUIDCreateString(NULL,mainUUID));CFRelease(mainUUID);}
    return @{@"connection":@(c),@"desktopReadCount":@(count),@"ordinaryCurrentCount":@(current),@"desktops":rows,
        @"allSpaceCount":@(allCount),@"allSpaceIDs":allIDs,@"checkedInventoryCount":@(checked),@"rawManagedReadable":@(rawReadable),
        @"rawManagedDisplays":rawDisplays,@"session":sessionFields,@"uid":@(getuid()),@"appKitScreens":appKitScreens,
        @"applicationRunning":@(applicationRunning),@"systemProcesses":systemProcesses,
        @"symbols":@(np_stage_symbols()),@"mainDisplayUUID":uuid?:NSNull.null,
        @"mainDisplayMirrored":[NSNumber numberWithBool:CGDisplayIsInMirrorSet(CGMainDisplayID())],
        @"activeDisplayCount":@(active),@"onlineDisplayCount":@(online),@"mainDisplay":@(CGMainDisplayID()),
        @"mainDisplayBounds":@[@(screen.origin.x),@(screen.origin.y),@(screen.size.width),@(screen.size.height)]};
}
static int inspectContext(NSString *path) {
    @autoreleasepool {
        NSMutableDictionary *report=[contextSnapshot() mutableCopy];report[@"schema"]=@1;
        report[@"windowWrites"]=@0;report[@"qualificationGranted"]=@NO;
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        return data&&[data writeToFile:path options:NSDataWritingAtomic error:NULL]?0:1;
    }
}
static int runScenario(NSString *configuration) {
    @autoreleasepool {
        NSDictionary *config=readJSON(configuration);outDirectory=config[@"output"];runNonce=config[@"nonce"];
        if(![outDirectory isKindOfClass:NSString.class]||![[NSUUID alloc]initWithUUIDString:runNonce])return 2;
        timeline=[NSMutableArray array];checks=[NSMutableDictionary dictionary];targets=[NSMutableArray array];generation=NSUUID.UUID;
        for(NSString *name in @[@"launchCanary",@"foreignRoundTrip",@"sameAppIndependent",@"crossAppGroup",@"repeatedSwitch",@"yellowButton",@"focusRestore",@"cleanup"])
            checks[name]=@{@"status":@"NOT_RUN"};
        NSRunningApplication *original=frontmostApplication();
        uint64_t originalBirth=original?birth(original.processIdentifier):0;
        char build[64]={0};size_t length=sizeof(build);(void)sysctlbyname("kern.osversion",build,&length,NULL,0);
        int sip=np_stage_sip_enabled();
        emit(@{@"event":@"environment",@"kernelBuild":@(build),@"sipEnabled":sip<0?NSNull.null:[NSNumber numberWithBool:sip==1],
            @"exactTarget":[NSNumber numberWithBool:np_stage_target_build()==1],@"accessibility":[NSNumber numberWithBool:AXIsProcessTrusted()],@"controllerPID":@(getpid())});
        emit(@{@"event":@"readOnlyConsoleContext",@"context":contextSnapshot()});
        NSString *status=@"BLOCKED",*reason=@"ordinaryDesktopUnavailable";BOOL clean=YES,all=NO;
        NSArray *originalSpaces=nil;NPReceipt receipt={0};
        connection=np_stage_connection();NPStageDesktop desktops[512];int n=np_stage_desktops(connection,desktops,512),homes=0;
        for(int i=0;i<n;i++)if(desktops[i].current&&!desktops[i].kind){home=desktops[i];homes++;}
        originalSpaces=allSpaces();
        NSMutableArray *desktopRows=[NSMutableArray array];
        for(int i=0;i<n;i++)[desktopRows addObject:@{@"id":@(desktops[i].id),@"kind":@(desktops[i].kind),@"current":@(desktops[i].current)}];
        emit(@{@"event":@"ordinaryDesktopPreflight",@"connection":@(connection),@"desktopReadCount":@(n),
            @"currentOrdinaryCount":@(homes),@"desktops":desktopRows,@"spaceInventoryReadable":[NSNumber numberWithBool:originalSpaces!=nil],
            @"spaceInventory":originalSpaces?:@[]});
        if(homes!=1){reason=@"ordinaryCurrentDesktopCountNotOne";goto finish;}
        if(!originalSpaces){reason=@"windowServerSpaceInventoryUnreadable";goto finish;}
        {
            CFPropertyListRef raw=CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"),CFSTR("com.apple.WindowManager"));
            BOOL enabled=raw&&[(__bridge id)raw respondsToSelector:@selector(boolValue)]&&[(__bridge id)raw boolValue];if(raw)CFRelease(raw);
            if(enabled){reason=@"appleStageManagerEnabled";goto finish;}
        }
        for(NSDictionary *owner in config[@"fixtures"]) {
            NSDictionary *state=readJSON([owner[@"directory"] stringByAppendingPathComponent:@"state.json"]);
            if(![state[@"nonce"] isEqual:runNonce]){reason=@"fixtureNonceMismatch";goto finish;}
            for(NSDictionary *window in state[@"windows"]) {
                NSMutableDictionary *t=[@{@"pid":state[@"pid"],@"birth":state[@"birth"],@"number":window[@"number"],
                    @"index":window[@"index"],@"directory":owner[@"directory"],@"executable":owner[@"executable"],
                    @"group":NSUUID.UUID.UUIDString,@"member":NSUUID.UUID.UUIDString,@"lifetime":NSUUID.UUID.UUIDString,
                    @"hidden":@NO,@"attempted":@NO} mutableCopy];
                NPStageWindow observed={0};
                if(!ownerMatches(t)||np_stage_window([t[@"number"] unsignedIntValue],&observed)!=1){reason=@"fixtureIdentityMismatch";goto finish;}
                t[@"frame"]=@[@(observed.rect[0]),@(observed.rect[1]),@(observed.rect[2]),@(observed.rect[3])];[targets addObject:t];
                if(!verify(t,home.id,YES,@"baseline")){reason=@"fixtureNotOnOriginalDesktop";goto finish;}
            }
        }
        if(targets.count!=3 || ![targets[0][@"pid"] isEqual:targets[1][@"pid"]] || [targets[1][@"pid"] isEqual:targets[2][@"pid"]]) {
            reason=@"threeWindowsInTwoForeignProcessesRequired";goto finish;
        }
        // Establish a real, controlled foreground before the canary captures focus.
        // An idle desktop can legitimately have no AXFocusedApplication at all.
        if(!prepareFixtureFocus(targets[0],@"beforeLaunchCanary")) {
            reason=@"controlledFixtureFocusUnavailable";goto finish;
        }
        emit(@{@"event":@"controlledFixtureFocusPrepared",@"pid":targets[0][@"pid"],@"window":targets[0][@"number"]});
        if(np_engine_create_spaces_candidate(&engine)!=NP_OK || np_engine_epoch(engine,&epoch)!=NP_OK){reason=@"candidateHandleUnavailable";goto finish;}
        {
            NPRequest r={.size=sizeof(r),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=5000,.epoch=epoch};
            BOOL launched=request(&r,NP_LAUNCH,@"launch-canary",&receipt);
            checks[@"launchCanary"]=@{@"status":launched?@"PASS":@"BLOCKED",@"scope":@"controller-owned panel only"};
            if(!launched){reason=@"candidateCanaryNotConfirmed";goto finish;}
        }
        reason=@"foreignRoundTripFailed";status=@"FAIL";
        {
            BOOL good=hide(targets[0],@"foreign-hide")&&verify(targets[1],home.id,YES,@"same-app-bystander")&&
                verify(targets[2],home.id,YES,@"other-app-bystander")&&show(targets[0],@"foreign-return");
            check(@"foreignRoundTrip",good,@"foreign window, same-app sibling and other-app bystander");
            if(!good)goto finish;
            check(@"sameAppIndependent",YES,@"only one of two windows from the same foreign app left the ordinary desktop");
        }
        reason=@"crossAppGroupFailed";
        if(!selectOnly(@[@0,@2],@"cross-app-combination")){check(@"crossAppGroup",NO,@"two foreign apps visible, same-app sibling hidden");goto finish;}
        check(@"crossAppGroup",YES,@"two foreign apps visible, same-app sibling hidden; engine calls, not R4 input");
        {
            NSUInteger cycles=MAX(1,MIN(50,[config[@"iterations"] unsignedIntegerValue]));BOOL good=YES;
            for(NSUInteger i=0;i<cycles&&good;i++)good=selectOnly(@[@1],[NSString stringWithFormat:@"cycle-%lu/B",(unsigned long)i])&&
                selectOnly(@[@2],[NSString stringWithFormat:@"cycle-%lu/C",(unsigned long)i])&&
                selectOnly(@[@0],[NSString stringWithFormat:@"cycle-%lu/A",(unsigned long)i]);
            check(@"repeatedSwitch",good,@"A→B→C→A through candidate ABI with independent readback");
            if(!good){reason=@"repeatedSwitchFailed";goto finish;}
        }
        {
            BOOL minimized=ownerCommand(targets[0],@"minimize")&&waitOwnerState(targets[0],@"miniaturized",YES);
            BOOL retired=minimized&&hideOperation(targets[0],@"yellow-button-retire",NP_HIDE_MINIMIZED)&&
                waitOwnerState(targets[0],@"miniaturized",NO);
            BOOL restored=retired&&show(targets[0],@"yellow-button-return")&&waitOwnerState(targets[0],@"miniaturized",NO);
            if(!retired)(void)ownerCommand(targets[0],@"restore");
            check(@"yellowButton",minimized&&retired&&restored,@"real title-bar action → candidate hidden Space → AX deminiaturized while hidden → restored; R4 observer tested separately");
            if(!minimized||!restored){reason=@"yellowButtonFailed";goto finish;}
        }
        {
            BOOL focused=prepareFixtureFocus(targets[0],@"afterWindowRestoration");
            check(@"focusRestore",focused,@"fixture-owned focus witness after exact window restoration");
            if(!focused){reason=@"focusReturnFailed";goto finish;}
        }
        all=YES;reason=@"verified";
    finish: ;
        // Keep the behavior outcome independent of final cleanup. A restore
        // can return a window home even if later receipt validation rejects it;
        // release and physical readback can still prove complete cleanup.
        NSString *operationStatus=all?@"PASS":status,*operationReason=reason;
        BOOL releaseVerified=YES,destroyVerified=YES,hadEngine=engine!=0;
        if(engine){
            double releaseDeadline=NSProcessInfo.processInfo.systemUptime+4;NSUInteger attempt=0;
            do {
                uint32_t remaining=(uint32_t)MAX(1,(releaseDeadline-NSProcessInfo.processInfo.systemUptime)*1000);
                NPRequest release={.size=sizeof(release),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=remaining,.epoch=epoch};
                NSString *phase=[NSString stringWithFormat:@"cleanup-all-spaces/%lu",(unsigned long)++attempt];
                releaseVerified=requestBefore(&release,NP_RELEASE_SPACES,phase,&receipt,releaseDeadline)&&receipt.owned==0;
                // A consumed failure can be retried through the same retained
                // leases. Never enqueue another writer behind an unconsumed call.
                if(releaseVerified||!lastRequestFinished)break;
                pump(.05);
            } while(NSProcessInfo.processInfo.systemUptime<releaseDeadline);
            uint32_t destroyed=np_engine_destroy(engine);destroyVerified=destroyed==NP_OK;
            emit(@{@"event":@"engineDestroyed",@"status":@(destroyed)});
        }
        NSMutableArray *finalObservations=[NSMutableArray array];NSDictionary *lastRestorationSample=nil;
        if(originalSpaces) {
            double deadline=NSProcessInfo.processInfo.systemUptime+2.5;
            do {
                NSArray *before=allSpaces();NSMutableArray *windows=[NSMutableArray array];BOOL windowsHome=YES;
                for(NSDictionary *target in targets){NSDictionary *row=observe(target,home.id,YES);[windows addObject:row];windowsHome=[row[@"verified"] boolValue]&&windowsHome;}
                NSArray *after=allSpaces();BOOL inventoryRestored=[before isEqual:originalSpaces]&&[after isEqual:originalSpaces];
                BOOL verified=inventoryRestored&&windowsHome;
                NSDictionary *sample=@{@"inventoryBefore":before?:NSNull.null,@"inventoryAfter":after?:NSNull.null,
                    @"originalInventoryRestored":@(inventoryRestored),@"windows":windows,@"verified":@(verified)};
                lastRestorationSample=sample;
                if(verified)[finalObservations addObject:sample];else [finalObservations removeAllObjects];
                if(finalObservations.count==2)break;
                pump(.035);
            } while(NSProcessInfo.processInfo.systemUptime<deadline);
            clean=finalObservations.count==2&&releaseVerified&&destroyVerified;
        } else {
            // The UUID/topology preflight can stop before an engine or any
            // target lease exists. No Space operation occurred in this case.
            clean=!hadEngine&&targets.count==0&&writeCount==0;
        }
        emit(@{@"event":@"cleanupFinalReadback",@"observations":finalObservations,
            @"lastObservation":lastRestorationSample?:NSNull.null,
            @"engineReleaseConfirmed":@(releaseVerified),@"engineDestroyConfirmed":@(destroyVerified),@"verified":@(clean)});
        check(@"cleanup",clean,@"all enrolled foreign windows on their original desktop; no owned Space remains");
        int32_t front=frontmostApplication().processIdentifier;
        BOOL testFront=front==getpid();for(NSDictionary *t in targets)testFront=testFront||front==[t[@"pid"] intValue];
        if(testFront&&original&&birth(original.processIdentifier)==originalBirth)
            dispatch_sync(dispatch_get_main_queue(), ^{ [original activateWithOptions:0]; });
        if(!clean){status=@"UNKNOWN";reason=@"cleanupUnconfirmed";}else if(all)status=@"FOREIGN_ENGINE_PASS";
        NSDictionary *report=@{@"schema":@1,@"status":status,@"reason":reason,@"nonce":runNonce,@"checks":checks,
            @"cleanup":@(clean),@"operationStatus":operationStatus,@"operationReason":operationReason,
            @"windowWrites":@(writeCount),@"windowWritesScope":@"engine hide/restore request attempts, including rejected or unverified requests",
            @"setupAXWrites":@(setupAXWrites),@"fixtureFocusCommands":@(fixtureFocusCommands),
            @"foreignProcesses":[NSNumber numberWithBool:targets.count==3],
            @"enrolledWindows":targets,@"originalSpaceInventory":originalSpaces?:@[],@"ordinaryHome":@(home.id),
            @"targetEnvironment":@{ @"kernelBuild":@(build),@"sipEnabled":sip<0?NSNull.null:[NSNumber numberWithBool:sip==1],
                @"exactTarget":[NSNumber numberWithBool:np_stage_target_build()==1]},
            @"R4ProductPath":@"NOT_RUN",@"missionControl":@"NOT_RUN",@"desktopGestures":@"NOT_RUN",@"fullScreenSplitView":@"NOT_RUN",
            @"qualificationGranted":@NO};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        [data writeToFile:[outDirectory stringByAppendingPathComponent:@"engine-result.json"] options:NSDataWritingAtomic error:NULL];
        emit(@{@"event":@"terminal",@"status":status,@"reason":reason,@"cleanup":@(clean)});
        return [status isEqual:@"FOREIGN_ENGINE_PASS"]?0:([status isEqual:@"BLOCKED"]?2:1);
    }
}

// This mode never creates an engine or submits a window operation. A separate
// process verifies the product's held checkpoint and its worker's crash recovery.
static int runReadback(NSString *configuration,NSString *resultPath) {
    @autoreleasepool {
        NSDictionary *config=readJSON(configuration);
        NSArray *windows=config[@"windows"],*original=config[@"originalSpaceInventory"];
        NSString *mode=config[@"mode"];
        BOOL held=[mode isEqual:@"held"],homeMode=[mode isEqual:@"home"];
        if((!held&&!homeMode)||![windows isKindOfClass:NSArray.class]||windows.count!=3||
           ![original isKindOfClass:NSArray.class]||!original.count||
           ![[NSUUID alloc]initWithUUIDString:config[@"nonce"]])return 2;
        NSMutableSet *numbers=[NSMutableSet set],*owners=[NSMutableSet set];NSUInteger visible=0;
        for(NSDictionary *target in windows) {
            NSArray *frame=target[@"frame"];uint64_t expected=[target[@"expectedSpace"] unsignedLongLongValue];
            uint64_t originalHome=[target[@"home"] unsignedLongLongValue];BOOL shown=[target[@"expectedOnScreen"] boolValue];
            if(![frame isKindOfClass:NSArray.class]||frame.count!=4||!expected||!originalHome||
               ![target[@"executable"] isKindOfClass:NSString.class]||![original containsObject:@(originalHome)]||
               [target[@"pid"] intValue]<=1||![target[@"birth"] unsignedLongLongValue]||![target[@"number"] unsignedIntValue])return 2;
            if((homeMode||shown)?expected!=originalHome:[original containsObject:@(expected)])return 2;
            [numbers addObject:target[@"number"]];[owners addObject:target[@"pid"]];visible+=shown?1:0;
        }
        if(numbers.count!=3||owners.count!=2||visible!=(held?1:3))return 2;
        connection=np_stage_connection();NSMutableArray *samples=[NSMutableArray array];
        NSDictionary *last=@{};double deadline=NSProcessInfo.processInfo.systemUptime+MAX(1,MIN(25,[config[@"seconds"] doubleValue]));
        BOOL matched=NO;
        do {
            NSMutableArray *rows=[NSMutableArray array];BOOL valid=YES;
            for(NSDictionary *target in windows) {
                NSDictionary *row=observe(target,[target[@"expectedSpace"] unsignedLongLongValue],
                                          [target[@"expectedOnScreen"] boolValue]);
                [rows addObject:row];valid=valid&&[row[@"verified"] boolValue];
            }
            NSArray *inventory=allSpaces();BOOL inventoryRestored=[inventory isEqual:original];
            BOOL hostUnchanged=!held||ownerMatches(config[@"host"]);
            valid=valid&&inventory!=nil&&(!homeMode||inventoryRestored)&&hostUnchanged;
            last=@{@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"windows":rows,
                   @"originalInventoryRestored":@(inventoryRestored),@"hostUnchanged":@(hostUnchanged),@"verified":@(valid)};
            if(valid)[samples addObject:last];else [samples removeAllObjects];
            if(samples.count==2){matched=YES;break;}
            pump(.06);
        } while(NSProcessInfo.processInfo.systemUptime<deadline);
        NSDictionary *report=@{@"schema":@1,@"nonce":config[@"nonce"],@"mode":mode,
            @"status":matched?@"INDEPENDENT_READBACK_PASS":@"UNKNOWN",@"windowWrites":@0,
            @"observations":matched?samples:@[last],@"cleanup":[NSNumber numberWithBool:homeMode&&matched],
            @"qualificationGranted":@NO};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        BOOL saved=data&&[data writeToFile:resultPath options:NSDataWritingAtomic error:NULL];
        return matched&&saved?0:1;
    }
}

#include "platform-foreign-probe.inc"
#include "r4-press.inc"

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc==4&&!strcmp(argv[1],"--readback"))return runReadback(@(argv[2]),@(argv[3]));
        BOOL inspect=argc==3&&!strcmp(argv[1],"--inspect-context");
        BOOL platformOnly=argc==3&&!strcmp(argv[1],"--platform-only");
        BOOL pressR4=argc==3&&!strcmp(argv[1],"--press-r4");
        if(argc!=2&&!inspect&&!platformOnly&&!pressR4)return 2;
        NSString *configuration=@(argv[(inspect||platformOnly||pressR4)?2:1]);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        // AppKit's real application loop is required by the production canary's
        // focus and window lifecycle checks. A manually pumped NSRunLoop leaves
        // NSApplication.isRunning false and does not exercise the same contract.
        // The scenario waits for Rust worker receipts. Keep it off the main GCD
        // queue so AppKit callbacks submitted by the engine can actually run.
        dispatch_async(dispatch_get_main_queue(), ^{
            // Schedule only the worker here, then release the main queue. This
            // proves NSApp.run started without occupying its AppKit callbacks.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                int result=inspect?inspectContext(configuration):(platformOnly?runPlatformForeignProbe(configuration):
                    (pressR4?runR4Press(configuration):runScenario(configuration)));
                dispatch_async(dispatch_get_main_queue(), ^{ exit(result); });
            });
        });
        [NSApp run];
        return 2;
    }
}
