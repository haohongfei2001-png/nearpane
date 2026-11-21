// Disposable hosted macOS test app. It creates two of its own ordinary windows. The second is a bystander.
// A fixed normal user session outside the hosted test environment never enters this fixture.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import "nearpane_window_engine.h"
#import "platform.h"

static void emit(NSDictionary *dict) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes,1,data.length,stdout);puts("");fflush(stdout); }
}
static void pump(double duration) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];
}
static uint64_t procBirth(void) {
    struct proc_bsdinfo p={0};
    return proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p) && p.pbi_uid==getuid()
        ? p.pbi_start_tvsec*1000000+p.pbi_start_tvusec : 0;
}
static BOOL sameHardware(const uint32_t before[5]) {
    CGEventType events[]={kCGEventLeftMouseDown,kCGEventRightMouseDown,kCGEventOtherMouseDown,kCGEventKeyDown,kCGEventScrollWheel};
    for(unsigned i=0;i<5;i++) if(before[i]!=CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,events[i])) return NO;
    return YES;
}
static BOOL sendRequest(uint64_t h,NPRequest *r,uint32_t op,const char *label,NPReceipt *out,const uint32_t hardware[5]) {
    if (!sameHardware(hardware)) {emit(@{@"event":@"submissionRefused",@"phase":@(label),@"reason":@"hardwareInputChanged"});return NO;}
    r->operation=op;
    [NSUUID.UUID getUUIDBytes:r->intent];uint64_t t=0;
    uint32_t submitted=np_engine_submit(h,r,&t);
    if(submitted!=NP_OK){emit(@{@"event":@"submissionRefused",@"phase":@(label),@"transport":@(submitted)});return NO;}
    *out=(NPReceipt){.size=sizeof(*out),.version=NP_ENGINE_ABI};
    double end=NSProcessInfo.processInfo.systemUptime+8;uint32_t transport;BOOL superseded=NO;
    do { if (!superseded && !sameHardware(hardware)) {superseded=YES;np_engine_revoke(h);}
         transport=np_engine_poll(h,t,out); if(transport==NP_PENDING)pump(.01); }
    while(transport==NP_PENDING && NSProcessInfo.processInfo.systemUptime<end);
    emit(@{@"event":@"engineReceipt",@"phase":@(label),@"transport":@(transport),@"status":@(out->status),
           @"detail":@(out->detail),@"issuedIntent":[[NSUUID alloc] initWithUUIDBytes:r->intent].UUIDString,
           @"flags":@(out->flags),@"owned":@(out->owned),@"observedSpace":@(out->native_id),@"superseded":@(superseded)});
    return !superseded && transport==NP_OK && out->status==NP_PASS;
}
static NSSet<NSNumber *> *spaceIDs(int c) {
    uint64_t ids[1024];int n=np_stage_all_spaces(c,ids,1024);
    if(n<=0)return nil;
    NSMutableSet<NSNumber *> *result=[NSMutableSet setWithCapacity:(NSUInteger)n];
    for (int i=0;i<n;i++) { if(!ids[i] || [result containsObject:@(ids[i])])return nil;[result addObject:@(ids[i])];}
    return result;
}
static BOOL verify(uint32_t w,int c,uint64_t space,uint32_t visible) {
    uint64_t ids[128],occupants[8192]; NPStageWindow observed={0};
    int n=np_stage_membership(c,w,ids,128), count=np_stage_occupants(c,space,occupants,8192);
    BOOL contains=NO; for(int i=0;i<count;i++) if(occupants[i]==w) contains=YES;
    int read=np_stage_window(w,&observed);
    BOOL exact=n==1 && ids[0]==space && contains && read==1 && observed.pid==getpid() &&
        observed.birth==procBirth() && observed.layer_zero==1 && observed.onboard==visible;
    emit(@{@"event":@"independentWindowReadback",@"number":@(w),@"wantedSpace":@(space),@"listedSpaceCount":@(n),
           @"listedSingleton":n==1?@(ids[0]):NSNull.null,@"forwardContainsTarget":@(contains),@"cgRead":@(read),
           @"ownedGeneration":@(observed.pid==getpid() && observed.birth==procBirth()),@"onScreen":@(observed.onboard),
           @"expectedOnScreen":@(visible),@"verified":@(exact)});
    return exact;
}
static NSWindow *document(NSRect rect, NSString *name) {
    NSWindow *w=[[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
        NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed=NO;w.title=name;
    w.collectionBehavior=NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorFullScreenPrimary;
    [w orderFront:nil];return w;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSDictionary *env=NSProcessInfo.processInfo.environment;
        if(argc!=2 || (strcmp(argv[1],"classic") && strcmp(argv[1],"bridged")) ||
           ![env[@"GITHUB_ACTIONS"] isEqual:@"true"] || ![env[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"] ||
           ![env[@"RUNNER_OS"] isEqual:@"macOS"] || ![env[@"NP_RUN_HOSTED_SPACES_TRIAL"] isEqual:@"1"] ||
           getuid()!=geteuid() || getuid()==0) {emit(@{@"status":@"BLOCKED",@"reason":@"disposableHostedFixtureRequired",@"systemWrites":@0});return 2;}
        NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
        char build[64]={0};size_t length=sizeof(build);
        NSString *kernel=sysctlbyname("kern.osversion",build,&length,NULL,0)==0 && length>0 ?
            [NSString stringWithUTF8String:build]:@"unknown";
        BOOL exact=np_stage_target_build()==1,ax=AXIsProcessTrusted();
        int sip=np_stage_sip_enabled();
        emit(@{@"event":@"targetPreflight",@"osVersion":[NSString stringWithFormat:@"%ld.%ld.%ld",(long)os.majorVersion,(long)os.minorVersion,(long)os.patchVersion],
            @"kernelBuild":kernel?:@"unknown",@"sipEnabled":sip<0?NSNull.null:@(sip==1),@"exactTarget":@(exact),@"existingAccessibility":@(ax)});
        if (!np_stage_hosted_self_birth() || !ax) {emit(@{@"status":@"BLOCKED",@"reason":!ax?@"existingAccessibilityUnavailable":@"disposableOwnProcessIdentityUnavailable",@"systemWrites":@0});return 2;}
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
        int c=np_stage_connection();NPStageDesktop inventory[512];int count=np_stage_desktops(c,inventory,512);
        if (count<=0 || NSScreen.screens.count!=1) {emit(@{@"status":@"BLOCKED",@"reason":@"singleDisposableOrdinaryDisplayUnavailable"});return 2;}
        NPStageDesktop home={0};int homes=0;for(int i=0;i<count;i++) if(inventory[i].current && !inventory[i].kind){home=inventory[i];homes++;}
        NSSet<NSNumber *> *originalSpaces=spaceIDs(c);
        if(homes!=1 || !originalSpaces || ![originalSpaces containsObject:@(home.id)]) {
            emit(@{@"status":@"BLOCKED",@"reason":@"originalCurrentDesktopOrSpaceInventoryUnavailable",@"systemWrites":@0});return 2;}
        uint32_t physical[5]; CGEventType types[]={kCGEventLeftMouseDown,kCGEventRightMouseDown,kCGEventOtherMouseDown,kCGEventKeyDown,kCGEventScrollWheel};
        for(unsigned i=0;i<5;i++) physical[i]=CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,types[i]);
        NSWindow *a=document(NSMakeRect(100,120,240,135),@"Gate 2 A"), *b=document(NSMakeRect(415,120,240,135),@"Gate 2 B");
        [CATransaction flush];pump(.22);
        uint32_t w=(uint32_t)a.windowNumber, other=(uint32_t)b.windowNumber;NSWindow *heldA=a,*heldB=b;
        uint64_t h=0;NPConfig config={.size=sizeof(config),.version=NP_ENGINE_ABI,.mode=NP_ISOLATED_FIXTURE,.process_count=1,
                                      .processes={{getpid(),0,procBirth()}}};
        NPRequest r={.size=sizeof(r),.version=NP_ENGINE_ABI,.backend=NP_SPACES,.timeout_ms=4000,.pid=getpid(),.birth=procBirth(),
                     .native_id=home.id,.window=w,.epoch=1};
        [NSUUID.UUID getUUIDBytes:r.generation];[NSUUID.UUID getUUIDBytes:r.member];[NSUUID.UUID getUUIDBytes:r.group];[NSUUID.UUID getUUIDBytes:r.lifetime];
        memcpy(r.display,home.display,16);memcpy(r.native_space,home.uuid,16);
        NPStageWindow source={0};BOOL good=NO,cleanup=NO,wasHidden=NO; uint64_t parking=0;
        NPReceipt receipt={0};NSString *reason=@"originalIndependentReadbackOrEngineCreationUnavailable";
        if(!verify(w,c,home.id,1) || !verify(other,c,home.id,1) || !sameHardware(physical) ||
           np_stage_window(w,&source)!=1 || np_engine_create(&config,&h)!=NP_OK || np_engine_epoch(h,&r.epoch)!=NP_OK) goto finish;
        r.frame=(NPRect){source.rect[0],source.rect[1],source.rect[2],source.rect[3]};
        r.flags=!strcmp(argv[1],"classic")?1u<<16:0;
        reason=@"ownFixtureLaunchProbeNotConfirmed";
        if(!sendRequest(h,&r,NP_TRIAL,"ownFixtureLaunchProbe",&receipt,physical)) goto finish;
        r.flags=0;
        reason=@"originalBystanderOrHardwareScopeChanged";
        if(!verify(other,c,home.id,1)||!sameHardware(physical)) goto finish;
        reason=@"hideNotConfirmed";
        if(!sendRequest(h,&r,NP_HIDE,"hideA",&receipt,physical)) goto finish;
        wasHidden=YES;parking=receipt.native_id;
        reason=@"hiddenMembershipOrBystanderNotConfirmed";
        if(parking==home.id || !verify(w,c,parking,0) || !verify(other,c,home.id,1) || !sameHardware(physical)) goto finish;
        reason=@"whileHiddenHealthNotConfirmed";
        if(!sendRequest(h,&r,NP_HEALTH,"whileHidden",&receipt,physical) || !sameHardware(physical)) goto finish;
        reason=@"restoreNotConfirmed";
        if(!sendRequest(h,&r,NP_RESTORE,"restoreA",&receipt,physical)) goto finish;
        wasHidden=NO;
        reason=@"independentRestoreReadbackUnavailable";
        good=verify(w,c,home.id,1)&&verify(other,c,home.id,1)&&sameHardware(physical);
    finish:
        if (h && (wasHidden || receipt.owned) && sameHardware(physical)) {
            r.flags=0; (void)sendRequest(h,&r,NP_RESTORE,"exactFixtureRecovery",&receipt,physical);
        }
        cleanup=(!h || np_engine_destroy(h)==NP_OK) && verify(w,c,home.id,1) && verify(other,c,home.id,1);
        NSSet<NSNumber *> *after=spaceIDs(c);BOOL sameInventory=after && [after isEqualToSet:originalSpaces];
        cleanup=cleanup && sameInventory && (!parking || ![after containsObject:@(parking)]);
        [heldA close];[heldB close];[CATransaction flush];pump(.05);
        emit(@{@"status":good&&cleanup?@"OWN_FIXTURE_PASS":(receipt.status==NP_FAIL?@"FAIL":@"UNKNOWN"),
               @"reason":!sameHardware(physical)?@"hardwareInputChanged":(good?(cleanup?@"verified":@"cleanupUnconfirmed"):reason),
               @"route":@(argv[1]),@"originalMembershipAndCleanup":@(cleanup),@"originalSpaceSetRestored":@(sameInventory),
               @"parkingSpace":@(parking),@"postCleanupAllSpaceCount":after?@(after.count):NSNull.null,
               @"windowsOwnedByTest":@2,@"foreignAppTrial":@"NOT_RUN",@"physicalSignedHostQualification":@"NOT_RUN"});
        return good&&cleanup?0:2;
    }
}
