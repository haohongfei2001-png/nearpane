// Hosted diagnostic only. Included by controller.m after its read-only helpers.
// Uses the shipping platform atoms, not a second engine or a product fallback.
#import <Security/Security.h>

static NSNumber *pfNumber(id value, BOOL zeroAllowed) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() ||
       CFNumberIsFloatType((__bridge CFNumberRef)value))return nil;
    int64_t number=0;
    return CFNumberGetValue((__bridge CFNumberRef)value,kCFNumberSInt64Type,&number) &&
        (zeroAllowed?number>=0:number>0)?@(number):nil;
}
static BOOL pfTrue(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() &&
        CFEqual((__bridge CFTypeRef)value,kCFBooleanTrue);
}
static NSNumber *pfSpaceID(NSDictionary *record) {
    if(![record isKindOfClass:NSDictionary.class])return nil;
    NSNumber *one=pfNumber(record[@"id64"][@"value"],NO), *two=pfNumber(record[@"ManagedSpaceID"][@"value"],NO);
    return one && two && ![one isEqual:two]?nil:(one?:two);
}
static NSArray *pfInventory(void) {
    uint64_t ids[2048];int count=np_stage_all_spaces(connection,ids,2048);
    if(count<=0)return nil;
    NSMutableArray *result=[NSMutableArray array];for(int i=0;i<count;i++)[result addObject:@(ids[i])];
    return [result sortedArrayUsingSelector:@selector(compare:)];
}
static NSDictionary *pfContext(void) {
    NSDictionary *raw=contextSnapshot(), *session=raw[@"session"];
    NSArray *displays=raw[@"rawManagedDisplays"];
    char boot[128]={0};size_t length=sizeof(boot);
    if(sysctlbyname("kern.bootsessionuuid",boot,&length,NULL,0) || !boot[0] ||
       !pfTrue(raw[@"applicationRunning"]) || !pfTrue(raw[@"rawManagedReadable"]) ||
       [raw[@"connection"] intValue]!=connection || [session[@"userID"] unsignedIntValue]!=getuid() ||
       !pfTrue(session[@"onConsole"]) || !pfTrue(session[@"loginDone"]) || pfTrue(session[@"screenLocked"]) ||
       [raw[@"activeDisplayCount"] unsignedIntValue]!=1 || [raw[@"onlineDisplayCount"] unsignedIntValue]!=1 ||
       pfTrue(raw[@"mainDisplayMirrored"]) || displays.count!=1 || [raw[@"appKitScreens"] count]!=1)return nil;
    NSDictionary *display=displays[0], *current=display[@"current"];NSArray *spaces=display[@"spaces"];
    NSNumber *homeID=pfSpaceID(current), *type=pfNumber(current[@"type"][@"value"],YES);
    NSString *displayID=display[@"displayIdentifier"];
    if(!homeID || !type || type.intValue!=0 || ![displayID isKindOfClass:NSString.class] ||
       ![[NSUUID alloc]initWithUUIDString:displayID] || ![displayID isEqual:raw[@"mainDisplayUUID"]] ||
       ![display[@"directCurrentID"] isEqual:homeID] || ![spaces isKindOfClass:NSArray.class] || !spaces.count)return nil;
    NSMutableDictionary *kinds=[NSMutableDictionary dictionary];NSMutableArray *numeric=[NSMutableArray array];BOOL found=NO;
    for(NSDictionary *record in spaces) {
        NSNumber *sid=pfSpaceID(record), *kind=pfNumber(record[@"type"][@"value"],YES);
        if(!sid || !kind || (kind.intValue!=0 && kind.intValue!=4) || kinds[sid.stringValue])return nil;
        kinds[sid.stringValue]=kind;[numeric addObject:@{@"id":sid,@"type":kind}];
        if([sid isEqual:homeID]){if(![kind isEqual:type])return nil;found=YES;}
    }
    if(!found)return nil;
    return @{@"home":homeID,@"display":displayID,@"boot":@(boot),@"managed":numeric,
        @"mainDisplay":raw[@"mainDisplay"],@"bounds":raw[@"mainDisplayBounds"],@"screens":raw[@"appKitScreens"],@"kinds":kinds};
}
static BOOL pfInventoryValid(NSArray *inventory, NSDictionary *context) {
    if(!inventory.count)return NO;
    NSCountedSet *counts=[[NSCountedSet alloc]initWithArray:inventory];NSDictionary *kinds=context[@"kinds"];
    for(NSString *sid in kinds)if(![counts containsObject:@(sid.longLongValue)])return NO;
    for(NSNumber *sid in counts)if([counts countForObject:sid]>1 &&
        ([counts countForObject:sid]!=2 || [kinds[sid.stringValue] intValue]!=4))return NO;
    return YES;
}
static BOOL pfStable(NSDictionary *context,NSArray *inventory) {
    return [context isEqual:pfContext()] && [inventory isEqual:pfInventory()] && np_stage_connection()==connection;
}
static BOOL pfSignedFixture(NSDictionary *owner,NSDictionary *state,NSUInteger index) {
    NSString *expected=index==0?@"com.holdsnow.stage-engine-fixture-a":@"com.holdsnow.stage-engine-fixture-b";
    NSString *path=owner[@"executable"], *directory=owner[@"directory"];
    if(![path isKindOfClass:NSString.class] || ![directory isKindOfClass:NSString.class] ||
       ![state[@"nonce"] isEqual:runNonce] || ![state[@"bundle"] isEqual:expected] ||
       ![owner[@"pid"] isEqual:state[@"pid"]] || ![owner[@"birth"] isEqual:state[@"birth"]] ||
       ![[directory stringByDeletingLastPathComponent] isEqual:outDirectory])return NO;
    NSURL *executable=[NSURL fileURLWithPath:path], *root=executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSBundle *bundle=[NSBundle bundleWithURL:root];SecStaticCodeRef code=NULL;
    BOOL valid=[root.pathExtension isEqual:@"app"] && [bundle.bundleIdentifier isEqual:expected] &&
        [bundle.executableURL.URLByResolvingSymlinksInPath.path isEqual:path] &&
        SecStaticCodeCreateWithPath((__bridge CFURLRef)root,kSecCSDefaultFlags,&code)==errSecSuccess && code &&
        SecStaticCodeCheckValidity(code,kSecCSStrictValidate,NULL)==errSecSuccess;
    if(code)CFRelease(code);return valid;
}
static BOOL pfVerifyAll(void *handles[3],int hiddenIndex,uint64_t parking,NSDictionary *context,NSArray *inventory,NSString *phase) {
    NSMutableArray *confirmed=[NSMutableArray array];NSDictionary *last=nil;
    double end=NSProcessInfo.processInfo.systemUptime+2.5;
    do {
        BOOL valid=pfStable(context,inventory);NSMutableArray *reads=[NSMutableArray array];
        for(NSUInteger i=0;i<targets.count;i++) {
            NSDictionary *t=targets[i];BOOL visible=(int)i!=hiddenIndex;
            NSMutableDictionary *row=[observe(t,visible?home.id:parking,visible) mutableCopy];
            BOOL bound=np_stage_check_bound(handles[i],[t[@"number"] unsignedIntValue],[t[@"pid"] intValue],
                [t[@"birth"] unsignedLongLongValue],visible)==1;
            uint64_t members[8192];uint64_t other=visible?parking:home.id;
            int count=other?np_stage_occupants(connection,other,members,8192):0;BOOL excludes=count>=0;
            for(int j=0;j<count;j++)if(members[j]==[t[@"number"] unsignedIntValue])excludes=NO;
            row[@"retainedAXIdentity"]=@(bound);row[@"otherSpaceExcludesWindow"]=@(excludes);
            BOOL pass=[row[@"verified"] boolValue]&&bound&&excludes;row[@"verified"]=@(pass);
            valid=valid&&pass;[reads addObject:row];
        }
        last=@{@"contextStable":[NSNumber numberWithBool:pfStable(context,inventory)],@"windows":reads};
        valid=valid&&[last[@"contextStable"] boolValue];
        if(valid)[confirmed addObject:last];else [confirmed removeAllObjects];
        if(confirmed.count==2)break;pump(.035);
    }while(NSProcessInfo.processInfo.systemUptime<end);
    emit(@{@"event":@"platformReadback",@"phase":phase,@"verified":[NSNumber numberWithBool:confirmed.count==2],
        @"observations":confirmed.count?confirmed:@[last?:@{}]});
    return confirmed.count==2;
}

static int runPlatformForeignProbe(NSString *configuration) {
    @autoreleasepool {
        NSDictionary *config=readJSON(configuration);outDirectory=config[@"output"];runNonce=config[@"nonce"];
        if(![outDirectory isKindOfClass:NSString.class] || ![runNonce isKindOfClass:NSString.class] ||
           ![[NSUUID alloc]initWithUUIDString:runNonce] ||
           ![[configuration stringByDeletingLastPathComponent] isEqual:outDirectory])return 2;
        timeline=[NSMutableArray array];targets=[NSMutableArray array];writeCount=0;home=(NPStageDesktop){0};
        NSString *status=@"BLOCKED", *reason=@"hostedDiagnosticPrerequisiteRequired";
        NSDictionary *prior=readJSON([outDirectory stringByAppendingPathComponent:@"engine-result.json"]);
        NSDictionary *context=nil;NSArray *original=nil,*withSpace=nil;uint64_t parking=0;void *handles[3]={0};
        BOOL clean=YES,passed=NO,created=NO,createAttempted=NO;NSUInteger cycles=0;int createResult=0,destroyResult=0;
        NSDictionary *env=NSProcessInfo.processInfo.environment;
        if(![env[@"GITHUB_ACTIONS"] isEqual:@"true"] || ![env[@"GITHUB_REPOSITORY"] isEqual:@"haohongfei2001-png/nearpane"] ||
           ![prior[@"status"] isEqual:@"BLOCKED"] || ![prior[@"nonce"] isEqual:runNonce] ||
           ![pfNumber(prior[@"windowWrites"],YES) isEqual:@0] || !pfTrue(prior[@"cleanup"]))goto finish;
        connection=np_stage_connection();
        if(!AXIsProcessTrusted() || (np_stage_symbols()&5)!=5 || !connection){reason=@"platformOrAccessibilityUnavailable";goto finish;}
        context=pfContext();original=pfInventory();
        if(!context || !pfInventoryValid(original,context)){reason=@"stableNumericDesktopUnavailable";goto finish;}
        home.id=[context[@"home"] unsignedLongLongValue];
        {
            CFPropertyListRef raw=CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"),CFSTR("com.apple.WindowManager"));
            BOOL enabled=raw&&[(__bridge id)raw respondsToSelector:@selector(boolValue)]&&[(__bridge id)raw boolValue];if(raw)CFRelease(raw);
            if(enabled){reason=@"appleStageManagerEnabled";goto finish;}
        }
        if(![config[@"fixtures"] isKindOfClass:NSArray.class] || [config[@"fixtures"] count]!=2){reason=@"twoFreshFixturesRequired";goto finish;}
        for(NSUInteger i=0;i<2;i++) {
            NSDictionary *owner=config[@"fixtures"][i],*state=readJSON([owner[@"directory"] stringByAppendingPathComponent:@"state.json"]);
            if(!pfSignedFixture(owner,state,i) || ![state[@"windows"] isKindOfClass:NSArray.class] ||
               [state[@"windows"] count]!=(i==0?2:1)){reason=@"signedFixtureIdentityMismatch";goto finish;}
            for(NSDictionary *window in state[@"windows"]) {
                NSMutableDictionary *t=[@{@"pid":state[@"pid"],@"birth":state[@"birth"],@"number":window[@"number"],
                    @"index":window[@"index"],@"directory":owner[@"directory"],@"executable":owner[@"executable"]} mutableCopy];
                NPStageWindow cg={0};
                if(!ownerMatches(t) || np_stage_window([t[@"number"] unsignedIntValue],&cg)!=1 ||
                   cg.pid!=[t[@"pid"] intValue] || cg.birth!=[t[@"birth"] unsignedLongLongValue] ||
                   !cg.onboard || cg.layer_zero!=1){reason=@"fixtureBaselineUnavailable";goto finish;}
                t[@"frame"]=@[@(cg.rect[0]),@(cg.rect[1]),@(cg.rect[2]),@(cg.rect[3])];
                void *handle=np_stage_bind(cg.number,cg.pid,cg.birth);
                if(!handle){reason=@"originalAXBindingUnavailable";goto finish;}
                handles[targets.count]=handle;[targets addObject:t];
            }
        }
        if(targets.count!=3 || ![targets[0][@"pid"] isEqual:targets[1][@"pid"]] ||
           [targets[1][@"pid"] isEqual:targets[2][@"pid"]] ||
           [NSSet setWithArray:[targets valueForKey:@"number"]].count!=3){reason=@"threeDistinctForeignWindowsRequired";goto finish;}
        if(!pfVerifyAll(handles,-1,0,context,original,@"baseline")){reason=@"numericHomeBaselineNotConfirmed";goto finish;}
        createAttempted=YES;createResult=np_stage_create(connection,&parking);created=parking!=0;
        emit(@{@"event":@"platformCreate",@"result":@(createResult),@"space":@(parking)});
        if(createResult!=1 || !parking || [original containsObject:@(parking)]){reason=@"hiddenSpaceCreationNotConfirmed";goto finish;}
        withSpace=[[original arrayByAddingObject:@(parking)] sortedArrayUsingSelector:@selector(compare:)];
        if(!pfVerifyAll(handles,-1,parking,context,withSpace,@"created-empty")){reason=@"createdSpaceInventoryNotConfirmed";goto finish;}
        for(NSNumber *index in @[@0,@2]) {
            NSUInteger i=index.unsignedIntegerValue;NSDictionary *target=targets[i];uint32_t number=[target[@"number"] unsignedIntValue];
            writeCount++;int moved=np_stage_move(connection,2,number,parking,7);
            emit(@{@"event":@"platformMove",@"phase":@"hide",@"number":@(number),@"space":@(parking),@"mask":@7,@"result":@(moved)});
            BOOL observed=pfVerifyAll(handles,(int)i,parking,context,withSpace,@"hidden-target-and-unchanged-bystanders");
            if(moved!=1 || !observed) {
                reason=@"foreignHideNotConfirmed";status=@"FAIL";goto finish;
            }
            writeCount++;moved=np_stage_move(connection,2,number,home.id,15);
            emit(@{@"event":@"platformMove",@"phase":@"return",@"number":@(number),@"space":@(home.id),@"mask":@15,@"result":@(moved)});
            observed=pfVerifyAll(handles,-1,parking,context,withSpace,@"returned-target-and-unchanged-bystanders");
            if(moved!=1 || !observed) {
                reason=@"foreignReturnNotConfirmed";status=@"FAIL";goto finish;
            }
            cycles++;
        }
        passed=YES;reason=@"verifiedPlatformOnly";
    finish:
        if(created && parking && ![original containsObject:@(parking)]) {
            // Return only these original retained fixtures, then destroy only our empty Space.
            for(NSUInteger i=0;i<targets.count;i++) {
                NSDictionary *t=targets[i];uint64_t ids[128];int count=np_stage_membership(connection,[t[@"number"] unsignedIntValue],ids,128);
                if(count==1 && ids[0]==home.id)continue;
                if(![context isEqual:pfContext()] || !ownerMatches(t) ||
                   np_stage_check_bound(handles[i],[t[@"number"] unsignedIntValue],[t[@"pid"] intValue],[t[@"birth"] unsignedLongLongValue],0)!=1){clean=NO;continue;}
                writeCount++;int restored=np_stage_move(connection,2,[t[@"number"] unsignedIntValue],home.id,15);
                emit(@{@"event":@"platformMove",@"phase":@"cleanup-return",@"number":t[@"number"],@"space":@(home.id),@"mask":@15,@"result":@(restored)});
            }
            withSpace=withSpace?:[[original arrayByAddingObject:@(parking)] sortedArrayUsingSelector:@selector(compare:)];
            BOOL returned=targets.count==3 && pfVerifyAll(handles,-1,parking,context,withSpace,@"cleanup-before-destroy");
            uint64_t occupants[8192];int count=np_stage_occupants(connection,parking,occupants,8192);
            if(returned && count==0 && [context isEqual:pfContext()])destroyResult=np_stage_destroy(connection,parking);
            emit(@{@"event":@"platformDestroy",@"space":@(parking),@"occupantCount":@(count),@"result":@(destroyResult)});
            clean=clean&&returned&&destroyResult==1&&pfVerifyAll(handles,-1,0,context,original,@"cleanup-final");
        } else if(created)clean=NO;
        else if(createAttempted) {
            // A failed return value is not evidence that creation had no effect.
            clean=pfVerifyAll(handles,-1,0,context,original,@"failed-create-cleanup");
        }
        for(NSUInteger i=0;i<3;i++)if(handles[i])np_stage_release(handles[i]);
        if(!clean){status=@"UNKNOWN";reason=@"cleanupUnconfirmed";}else if(passed)status=@"PLATFORM_FOREIGN_PASS";
        char build[64]={0};size_t size=sizeof(build);(void)sysctlbyname("kern.osversion",build,&size,NULL,0);int sip=np_stage_sip_enabled();
        NSDictionary *report=@{@"schema":@1,@"scope":@"platform-only-mechanism",@"status":status,@"reason":reason,@"nonce":runNonce,
            @"qualificationGranted":@NO,@"R4ProductPath":@"NOT_RUN",@"engineStateMachine":@"NOT_RUN",@"ordinaryUUIDRequiredByProduct":@YES,
            @"cleanup":[NSNumber numberWithBool:clean],@"windowWrites":@(writeCount),@"completedForeignCycles":@(cycles),
            @"foreignProcesses":[NSNumber numberWithBool:targets.count==3],@"numericHome":@(home.id),@"createdSpace":@(parking),
            @"originalSpaceInventory":original?:@[],@"context":context?:@{},@"prerequisiteEngineStatus":prior[@"status"]?:@"missing",
            @"targetEnvironment":@{@"kernelBuild":@(build),@"sipEnabled":sip<0?NSNull.null:[NSNumber numberWithBool:sip==1],
                @"exactTarget":[NSNumber numberWithBool:np_stage_target_build()==1]},@"events":timeline};
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        if(!bytes || ![bytes writeToFile:[outDirectory stringByAppendingPathComponent:@"platform-result.json"] options:NSDataWritingAtomic error:NULL])return 1;
        return [status isEqual:@"PLATFORM_FOREIGN_PASS"]?0:([status isEqual:@"BLOCKED"]?2:1);
    }
}
