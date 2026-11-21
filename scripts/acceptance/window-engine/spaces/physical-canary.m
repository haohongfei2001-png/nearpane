// One explicitly requested physical experiment, limited to a separately signed, transparent canary.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>
#import "platform.h"

extern void *np_stage_launch_development_token(void);
extern NSDictionary *np_stage_development_checks(void);
extern int32_t np_stage_development_focus(int32_t *,uint64_t *,uint32_t *);
static void event(NSDictionary *row) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
    if(data){fwrite(data.bytes,1,data.length,stdout);puts("");fflush(stdout);}
}
static void pump(void) {[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.012]];}
static const CGEventType hardware[]={kCGEventLeftMouseDown,kCGEventLeftMouseUp,kCGEventRightMouseDown,
    kCGEventRightMouseUp,kCGEventOtherMouseDown,kCGEventOtherMouseUp,kCGEventMouseMoved,kCGEventKeyDown,
    kCGEventKeyUp,kCGEventFlagsChanged,kCGEventScrollWheel,kCGEventLeftMouseDragged,kCGEventRightMouseDragged};
static uint32_t counters[sizeof(hardware)/sizeof(*hardware)];
static double end;
static uint8_t salt[16];
static int32_t allowed(void *ctx) {
    if(!ctx || NSProcessInfo.processInfo.systemUptime>=end)return 0;
    for(size_t i=0;i<sizeof(hardware)/sizeof(*hardware);i++)
        if(counters[i]!=CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,hardware[i]))return 0;
    return 1;
}
static void noop(void *ctx){(void)ctx;}
static NSString *focus(void) {
    int32_t pid=0;uint64_t birth=0;uint32_t win=0;
    if(!np_stage_development_focus(&pid,&birth,&win) || pid==getpid())return nil;
    uint8_t bytes[32];memcpy(bytes,salt,16);memcpy(bytes+16,&pid,4);memcpy(bytes+20,&birth,8);memcpy(bytes+28,&win,4);
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,sizeof(bytes),hash);
    NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];return s;
}
static NSSet *allSpaces(int c) {
    uint64_t ids[1024]; int n=np_stage_all_spaces(c,ids,1024);
    if(n<=0)return nil;NSMutableSet *s=[NSMutableSet set];
    for(int i=0;i<n;i++){if(!ids[i] || [s containsObject:@(ids[i])])return nil;[s addObject:@(ids[i])];}
    return s;
}
static NSDictionary *active(int c) {
    NPStageDesktop ds[512];int n=np_stage_desktops(c,ds,512);
    if(n<=0)return nil;NSMutableDictionary *active=[NSMutableDictionary dictionary];NSMutableSet *displays=[NSMutableSet set];
    for(int i=0;i<n;i++){
        NSUUID *display=[[NSUUID alloc]initWithUUIDBytes:ds[i].display];[displays addObject:display];
        if(ds[i].current){if(ds[i].kind!=0 || active[display] || !ds[i].id)return nil;
            active[display]=@[ @(ds[i].id),[[NSUUID alloc]initWithUUIDBytes:ds[i].uuid] ];}
    }
    return active.count==displays.count?active:nil;
}
static BOOL exact(void *token,int c,NPStageCanary initial,uint64_t wanted,uint64_t other,BOOL hidden) {
    NPStageCanary p={0};NPStageWindow cg={0};uint64_t reverse[128],forward[8192];
    int n=np_stage_membership(c,initial.number,reverse,128),m=np_stage_occupants(c,wanted,forward,8192);
    BOOL contains=NO;for(int i=0;i<m;i++)if(forward[i]==initial.number)contains=YES;
    BOOL excludes=YES;if(other){int k=np_stage_occupants(c,other,forward,8192);if(k<0)excludes=NO;
        for(int i=0;i<k;i++)if(forward[i]==initial.number)excludes=NO;}
    BOOL obj=np_stage_launch_call(token,2,NULL,NULL,NULL,&p)==1 && p.registered && p.focus_same &&
        p.number==initial.number && p.pid==getpid() && p.birth==initial.birth;
    BOOL same=np_stage_window(initial.number,&cg)==1 && cg.pid==getpid() && cg.birth==initial.birth && cg.layer_zero;
    BOOL ok=obj && same && n==1 && reverse[0]==wanted && contains && excludes && (!hidden || m==1);
    event(@{@"event":@"independentReadback",@"monotonic":@(NSProcessInfo.processInfo.systemUptime),@"fixtureNumber":@(initial.number),
            @"requestedSpace":@(wanted),@"reverseCount":@(n),@"reverseSingleton":n==1?@(reverse[0]):NSNull.null,
            @"forwardContains":@(contains),@"otherExcludes":@(excludes),@"exactSelfAppKit":@(obj),@"exactCGGeneration":@(same),@"confirmed":@(ok)});
    return ok;
}
static BOOL twice(void *t,int c,NPStageCanary p,uint64_t wanted,uint64_t other,BOOL hidden){
    int streak=0;double limit=NSProcessInfo.processInfo.systemUptime+.40;
    do{if(!allowed(t))return NO;streak=exact(t,c,p,wanted,other,hidden)?streak+1:0;if(streak==2)return YES;pump();}
    while(NSProcessInfo.processInfo.systemUptime<limit);return NO;
}
static BOOL stable(int c,NSDictionary *desks,NSString *front,void *t){
    return allowed(t) && np_stage_connection()==c && [active(c)isEqual:desks] && [focus() isEqual:front];
}
static BOOL empty(int c,uint64_t s){uint64_t w[8192];return s && np_stage_occupants(c,s,w,8192)==0;}
static int blocked(NSString *why) {event(@{@"status":@"BLOCKED",@"reason":why,@"systemWrites":@0,@"qualificationGranted":@NO});return 2;}
int main(int argc,const char **argv){@autoreleasepool{
    NSDictionary *env=NSProcessInfo.processInfo.environment;
    BOOL readonly=(argc==2 && !strcmp(argv[1],"preflight"));
    if(!readonly && (argc!=2 || (strcmp(argv[1],"bridged") && strcmp(argv[1],"classic")) || ![env[@"NP_RUN_EXACT_SPACES_CANARY"] isEqual:@"1"]))
        return blocked(@"explicitExactPhysicalCanaryRequired");
    NSDictionary *checks=np_stage_development_checks();event(checks);
    if(readonly) {
        if(![checks[@"identityAccepted"] boolValue])return blocked(@"developmentIdentityPreflightRefused");
        if(![checks[@"existingOwnAccessibility"] boolValue])return blocked(@"canaryOwnExistingAccessibilityUnavailable");
        event(@{@"status":@"PREFLIGHT_READY",@"appKitApplicationCreated":@NO,@"systemWrites":@0,@"qualificationGranted":@NO});return 0;
    }
    void *token=np_stage_launch_development_token();
    if(!token)return blocked(@"exactTargetSIPAndSignedPrivateDevelopmentExecutableRequired");
    if(!AXIsProcessTrusted()){np_stage_release(token);return blocked(@"canaryOwnExistingAccessibilityUnavailable");}
    uint32_t route=!strcmp(argv[1],"classic")?1:2;int api=np_stage_symbols();
    if(!(api&1) || !(api&(route==1?2:4))){np_stage_release(token);return blocked(@"exactTypedRouteUnavailable");}
    [NSApplication sharedApplication];
    if(NSApp.activationPolicy!=NSApplicationActivationPolicyProhibited &&
       (![NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited] || NSApp.activationPolicy!=NSApplicationActivationPolicyProhibited)){
        np_stage_release(token);return blocked(@"nonActivatingPolicyUnavailable");}
    [NSUUID.UUID getUUIDBytes:salt];
    for(size_t i=0;i<sizeof(hardware)/sizeof(*hardware);i++)counters[i]=CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState,hardware[i]);
    end=NSProcessInfo.processInfo.systemUptime+7.0;
    int c=np_stage_connection();NSString *front=focus();NSDictionary *desks=active(c);NSSet *before=allSpaces(c),*expected=nil;
    if(!front || !desks.count || !before.count){np_stage_release(token);return blocked(@"originalExternalFocusOrOrdinaryNativeSpaceUnavailable");}
    NPStageCanary p={0},probe={0};uint64_t home=0,sid=0,mem[128];int writes=0;BOOL sidOwned=NO;
    BOOL hideSent=NO,restored=NO,restoreSent=NO,hidden=NO,destroyed=NO,destroySent=NO,closed=NO;
    NSString *reason=@"preflightChanged";pump();
    if(!stable(c,desks,front,token) || np_stage_launch_call(token,0,NULL,NULL,NULL,&p)!=1 || !p.focus_same || !p.absent)
        {np_stage_release(token);return blocked(reason);}
    event(@{@"event":@"before",@"kernelBuild":@"26A428",@"sipEnabled":@YES,@"route":@(argv[1]),@"ownAccessibility":@YES,
            @"externalFocusSaltedSHA256":front,@"displayCount":@(desks.count),@"initialSpaceCount":@(before.count)});
    reason=@"transparentCanaryIdentityUnavailable";writes++;
    if(np_stage_launch_call(token,1,token,allowed,noop,&probe)!=1 || !probe.registered || !probe.focus_same || probe.pid!=getpid() || !probe.birth)goto cleanup;
    if(np_stage_membership(c,probe.number,mem,128)!=1)goto cleanup;
    home=mem[0];BOOL ordinary=NO;for(NSArray *row in desks.allValues)if([row[0] isEqual:@(home)])ordinary=YES;
    if(!ordinary || ![before containsObject:@(home)] || !twice(token,c,probe,home,0,NO) || !stable(c,desks,front,token))goto cleanup;
    reason=@"createEmptySpaceUnconfirmed";writes++;
    if(np_stage_create(c,&sid)!=1 || !sid || [before containsObject:@(sid)])goto cleanup;
    sidOwned=YES;expected=[before setByAddingObject:@(sid)];
    if(![allSpaces(c)isEqualToSet:expected] || !empty(c,sid) || !stable(c,desks,front,token))goto cleanup;
    reason=@"canaryHideMembershipUnconfirmed";hideSent=YES;writes++;
    int ret=np_stage_move(c,route,probe.number,sid,7);event(@{@"event":@"hideIssued",@"dispatch":@(ret),@"space":@(sid)});
    hidden=twice(token,c,probe,sid,home,YES);if(!hidden)goto cleanup;
    reason=@"canaryRestoreMembershipUnconfirmed";
cleanup:
    if(sidOwned && hideSent && stable(c,desks,front,token) && [allSpaces(c)isEqualToSet:expected]){
        if(twice(token,c,probe,sid,home,YES) && stable(c,desks,front,token)){
            restoreSent=YES;writes++;int rc=np_stage_move(c,route,probe.number,home,15);
            event(@{@"event":@"restoreIssued",@"dispatch":@(rc),@"space":@(home)});
        }
        restored=twice(token,c,probe,home,sid,NO);
    } else if(home && !hideSent && stable(c,desks,front,token))restored=twice(token,c,probe,home,0,NO);
    if(sidOwned && stable(c,desks,front,token) && [allSpaces(c)isEqualToSet:expected] && empty(c,sid) && empty(c,sid)){
        destroySent=YES;writes++;int rc=np_stage_destroy(c,sid);event(@{@"event":@"emptySpaceDestroyIssued",@"dispatch":@(rc)});
    }
    destroyed=[allSpaces(c)isEqualToSet:before];pump();destroyed=destroyed && [allSpaces(c)isEqualToSet:before];
    if(stable(c,desks,front,token) && np_stage_launch_call(token,3,token,allowed,noop,&p)==1){
        writes++;NPStageWindow cg={0};int streak=0;double deadline=NSProcessInfo.processInfo.systemUptime+.4;
        do{pump();BOOL gone=np_stage_launch_call(token,2,NULL,NULL,NULL,&p)==1 && p.absent && p.focus_same &&
            (!probe.number || np_stage_window(probe.number,&cg)==0);
            streak=gone?streak+1:0;if(streak==2){closed=YES;break;}}while(NSProcessInfo.processInfo.systemUptime<deadline);
    }
    NSString *after=focus();BOOL sameFocus=[after isEqual:front],sameDesk=[active(c)isEqual:desks],hid=allowed(token);
    BOOL ok=hidden&&restoreSent&&restored&&destroySent&&destroyed&&closed&&sameFocus&&sameDesk&&hid;
    event(@{@"status":ok?@"OWN_SIGNED_CANARY_PASS":@"UNKNOWN",@"reason":ok?@"verified":(!hid?@"hardwareInputOrDeadlineChanged":reason),
            @"qualificationGranted":@NO,@"fixtureNumber":@(probe.number),@"pid":@(probe.pid),@"birth":@(probe.birth),@"originalDesktop":@(home),
            @"parkingSpace":@(sidOwned?sid:0),@"hiddenReadback":@(hidden),@"restoredReadback":@(restored),@"originalSpaceSetRestored":@(destroyed),
            @"emptyPrivateSpaceDestroyIssued":@(destroySent),@"canaryClosedAndCGAbsent":@(closed),@"externalFocusSaltedSHA256":after?:NSNull.null,
            @"originalExternalFocusUnchanged":@(sameFocus),@"originalActiveDesktopsUnchanged":@(sameDesk),@"hardwareUnchangedWithinDeadline":@(hid),
            @"ownObjectOperationsAttempted":@(writes),@"installedHost":@"NOT_RUN",@"thirdPartyWindows":@"NOT_RUN"});
    np_stage_release(token);return ok?0:2;
}}
