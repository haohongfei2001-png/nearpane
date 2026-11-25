// Real cross-process acceptance using the shipping Spaces candidate ABI.
// Each write targets one of three windows created by this run's two fixture apps.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
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
static NSUInteger writeCount;

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
static BOOL request(NPRequest *r,uint32_t operation,NSString *phase,NPReceipt *result) {
    r->operation=operation;r->epoch=epoch;[NSUUID.UUID getUUIDBytes:r->intent];uint64_t ticket=0;
    uint32_t submitted=np_engine_submit(engine,r,&ticket),polled=NP_INVALID;
    *result=(NPReceipt){.size=sizeof(*result),.version=NP_ENGINE_ABI};
    double started=NSProcessInfo.processInfo.systemUptime,end=started+7;
    if(submitted==NP_OK)do {polled=np_engine_poll(engine,ticket,result);if(polled==NP_PENDING)pump(.005);}
        while(polled==NP_PENDING&&NSProcessInfo.processInfo.systemUptime<end);
    BOOL passed=submitted==NP_OK&&polled==NP_OK&&result->status==NP_PASS;
    emit(@{@"event":@"engineReceipt",@"phase":phase,@"operation":@(operation),@"submit":@(submitted),@"poll":@(polled),
        @"status":@(result->status),@"detail":@(result->detail),@"flags":@(result->flags),@"owned":@(result->owned),
        @"nativeSpace":@(result->native_id),@"seconds":@(NSProcessInfo.processInfo.systemUptime-started),@"verified":@(passed)});
    return passed;
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
        NSString *status=@"BLOCKED",*reason=@"ordinaryDesktopUnavailable";BOOL clean=YES,all=NO;
        NSArray *originalSpaces=nil;NPReceipt receipt={0};
        connection=np_stage_connection();NPStageDesktop desktops[512];int n=np_stage_desktops(connection,desktops,512),homes=0;
        for(int i=0;i<n;i++)if(desktops[i].current&&!desktops[i].kind){home=desktops[i];homes++;}
        if(homes!=1 || !(originalSpaces=allSpaces()))goto finish;
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
            BOOL focused=ownerCommand(targets[0],@"focus")&&waitOwnerState(targets[0],@"key",YES)&&
                frontmostApplication().processIdentifier==[targets[0][@"pid"] intValue];
            check(@"focusRestore",focused,@"fixture-owned focus witness after exact window restoration");
            if(!focused){reason=@"focusReturnFailed";goto finish;}
        }
        all=YES;reason=@"verified";
    finish:
        if(engine){
            for(NSMutableDictionary *target in targets)if([target[@"attempted"] boolValue]||[target[@"hidden"] boolValue])
                clean=show(target,@"cleanup-return")&&clean;
            if(receipt.owned){NPRequest r={.size=sizeof(r),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=4000,.epoch=epoch};
                (void)request(&r,NP_CLEAN_LAUNCH,@"cleanup-canary",&receipt);}
            NPRequest release={.size=sizeof(release),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=5000,.epoch=epoch};
            clean=request(&release,NP_RELEASE_SPACES,@"cleanup-all-spaces",&receipt)&&clean;
            uint32_t destroyed=np_engine_destroy(engine);clean=destroyed==NP_OK&&clean;
            emit(@{@"event":@"engineDestroyed",@"status":@(destroyed)});
        }
        for(NSDictionary *target in targets)clean=verify(target,home.id,YES,@"cleanup-final")&&clean;
        if(originalSpaces)clean=[originalSpaces isEqual:allSpaces()]&&clean;
        check(@"cleanup",clean,@"all enrolled foreign windows on their original desktop; no owned Space remains");
        int32_t front=frontmostApplication().processIdentifier;
        BOOL testFront=front==getpid();for(NSDictionary *t in targets)testFront=testFront||front==[t[@"pid"] intValue];
        if(testFront&&original&&birth(original.processIdentifier)==originalBirth)
            dispatch_sync(dispatch_get_main_queue(), ^{ [original activateWithOptions:0]; });
        if(!clean){status=@"UNKNOWN";reason=@"cleanupUnconfirmed";}else if(all)status=@"FOREIGN_ENGINE_PASS";
        NSDictionary *report=@{@"schema":@1,@"status":status,@"reason":reason,@"nonce":runNonce,@"checks":checks,
            @"cleanup":@(clean),@"windowWrites":@(writeCount),@"foreignProcesses":[NSNumber numberWithBool:targets.count==3],
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

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2)return 2;
        NSString *configuration=@(argv[1]);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        // AppKit's real application loop is required by the production canary's
        // focus and window lifecycle checks. A manually pumped NSRunLoop leaves
        // NSApplication.isRunning false and does not exercise the same contract.
        // The scenario waits for Rust worker receipts. Keep it off the main GCD
        // queue so AppKit callbacks submitted by the engine can actually run.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int result=runScenario(configuration);
            dispatch_async(dispatch_get_main_queue(), ^{ exit(result); });
        });
        [NSApp run];
        return 2;
    }
}
