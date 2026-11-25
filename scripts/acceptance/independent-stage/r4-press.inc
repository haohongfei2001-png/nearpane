// Included by Controller. This client presses one exported AX button in its
// directly launching acceptance Host; it never invokes a product handler.
#import <Security/Security.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static BOOL r4Integer(id value,uint64_t *number) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    if(!strchr("csilqCSILQ",[value objCType][0]) || [value objCType][1])return NO;
    NSString *text=[value stringValue];
    if(!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound)return NO;
    errno=0;char *end=NULL;unsigned long long parsed=strtoull(text.UTF8String,&end,10);
    if(errno || !end || *end)return NO;
    *number=(uint64_t)parsed;return YES;
}
static NSString *r4Canonical(NSString *path) {
    if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath)return nil;
    char resolved[PATH_MAX]={0};return realpath(path.fileSystemRepresentation,resolved)?@(resolved):nil;
}
static NSDictionary *r4ReadFile(NSString *path,NSData **bytes) {
    if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return nil;
    struct stat info={0};NSMutableData *data=[NSMutableData data];BOOL valid=fstat(fd,&info)==0 && S_ISREG(info.st_mode) &&
        info.st_uid==getuid() && info.st_nlink==1 && info.st_size>0 && info.st_size<=262144;
    char buffer[8192];
    while(valid) {
        ssize_t count=read(fd,buffer,sizeof(buffer));
        if(count<0 && errno==EINTR)continue;
        if(count<0){valid=NO;break;}if(count==0)break;
        [data appendBytes:buffer length:(NSUInteger)count];if(data.length>262144)valid=NO;
    }
    close(fd);
    id parsed=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(![parsed isKindOfClass:NSDictionary.class])return nil;
    if(bytes)*bytes=data;return parsed;
}
static BOOL r4HostMatches(NSDictionary *host) {
    uint64_t pid=0,started=0,number=0;
    if(!r4Integer(host[@"pid"],&pid) || pid<=1 || pid>INT32_MAX || pid!=(uint64_t)getppid() ||
       !r4Integer(host[@"birth"],&started) || !started || !r4Integer(host[@"number"],&number) ||
       !number || number>UINT32_MAX || ![host[@"executable"] isKindOfClass:NSString.class])return NO;
    return ownerMatches(host) && birth((int32_t)pid)==started;
}
static BOOL r4HostSignature(NSDictionary *host) {
    if(!r4HostMatches(host))return NO;
    NSString *exe=r4Canonical(host[@"executable"]);
    NSString *app=exe.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSBundle *bundle=app?[NSBundle bundleWithPath:app]:nil;uint64_t marker=0;
    if(![exe.lastPathComponent isEqual:@"NearpaneHost"] ||
       ![r4Canonical(bundle.executablePath) isEqual:exe] ||
       ![bundle.bundleIdentifier isEqual:@"com.holdsnow.nearpane.independent-stage-candidate"] ||
       !r4Integer(bundle.infoDictionary[@"NearpaneIndependentStageAcceptance"],&marker) || marker!=1 ||
       bundle.infoDictionary[@"NearpaneIndependentStageWorkspace"]!=nil)return NO;
    SecRequirementRef requirement=NULL;SecCodeRef live=NULL;SecStaticCodeRef disk=NULL;
    OSStatus status=SecRequirementCreateWithString(CFSTR("identifier \"com.holdsnow.nearpane.independent-stage-candidate\""),kSecCSDefaultFlags,&requirement);
    NSDictionary *attributes=@{(__bridge NSString *)kSecGuestAttributePid:host[@"pid"]};
    if(status==errSecSuccess)status=SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)attributes,kSecCSDefaultFlags,&live);
    if(status==errSecSuccess)status=SecCodeCheckValidity(live,kSecCSStrictValidate,requirement);
    if(status==errSecSuccess)status=SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:app],kSecCSDefaultFlags,&disk);
    if(status==errSecSuccess)status=SecStaticCodeCheckValidity(disk,kSecCSStrictValidate,requirement);
    if(disk)CFRelease(disk);if(live)CFRelease(live);if(requirement)CFRelease(requirement);
    return status==errSecSuccess && r4HostMatches(host);
}
static BOOL r4Identifier(NSString *value) {
    if(![value isKindOfClass:NSString.class] || !value.length || value.length>320)return NO;
    for(NSString *prefix in @[@"current-desktop-window:",@"native-space-window:",@"stage-group-select:",@"native-held-group:"])
        if([value hasPrefix:prefix] && value.length>prefix.length)return YES;
    return NO;
}
static id r4Attribute(AXUIElementRef element,CFStringRef attribute,AXError *error) {
    CFTypeRef value=NULL;AXError result=AXUIElementCopyAttributeValue(element,attribute,&value);
    if(error)*error=result;
    if(result!=kAXErrorSuccess){if(value)CFRelease(value);return nil;}
    return CFBridgingRelease(value);
}
static BOOL r4Element(id value) { return value && CFGetTypeID((__bridge CFTypeRef)value)==AXUIElementGetTypeID(); }
static BOOL r4Rect(AXUIElementRef element,CGRect *frame,AXError *error) {
    AXError a=kAXErrorFailure,b=kAXErrorFailure;
    id position=r4Attribute(element,kAXPositionAttribute,&a),size=r4Attribute(element,kAXSizeAttribute,&b);
    if(error)*error=a!=kAXErrorSuccess?a:b;
    CGPoint p=CGPointZero;CGSize s=CGSizeZero;
    if(!position || !size || CFGetTypeID((__bridge CFTypeRef)position)!=AXValueGetTypeID() ||
       CFGetTypeID((__bridge CFTypeRef)size)!=AXValueGetTypeID() ||
       !AXValueGetValue((__bridge AXValueRef)position,kAXValueCGPointType,&p) ||
       !AXValueGetValue((__bridge AXValueRef)size,kAXValueCGSizeType,&s) ||
       !isfinite(p.x) || !isfinite(p.y) || !isfinite(s.width) || !isfinite(s.height) || s.width<=0 || s.height<=0)return NO;
    *frame=CGRectMake(p.x,p.y,s.width,s.height);return YES;
}
static NSArray *r4Frame(CGRect frame) { return @[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)]; }
static BOOL r4SameFrame(CGRect a,CGRect b) {
    return fabs(a.origin.x-b.origin.x)<=2 && fabs(a.origin.y-b.origin.y)<=2 &&
        fabs(a.size.width-b.size.width)<=2 && fabs(a.size.height-b.size.height)<=2;
}
static BOOL r4CGPanel(NSDictionary *host,CGRect *frame) {
    CFArrayRef raw=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    NSArray *rows=CFBridgingRelease(raw);if(![rows isKindOfClass:NSArray.class] || rows.count>16384)return NO;
    NSUInteger found=0;CGRect result=CGRectNull;
    for(id item in rows) {
        if(![item isKindOfClass:NSDictionary.class])return NO;
        uint64_t number=0;if(!r4Integer(item[(__bridge NSString *)kCGWindowNumber],&number))return NO;
        if(number!=[host[@"number"] unsignedLongLongValue])continue;
        uint64_t pid=0;id bounds=item[(__bridge NSString *)kCGWindowBounds],alpha=item[(__bridge NSString *)kCGWindowAlpha];
        if(!r4Integer(item[(__bridge NSString *)kCGWindowOwnerPID],&pid) || pid!=[host[@"pid"] unsignedLongLongValue] ||
           ![bounds isKindOfClass:NSDictionary.class] || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&result) ||
           CGRectIsNull(result) || CGRectIsInfinite(result) || CGRectIsEmpty(result) ||
           ![alpha isKindOfClass:NSNumber.class] || !isfinite([alpha doubleValue]) || [alpha doubleValue]<=0)return NO;
        id on=item[(__bridge NSString *)kCGWindowIsOnscreen];
        if(on && (CFGetTypeID((__bridge CFTypeRef)on)!=CFBooleanGetTypeID() || ![on boolValue]))return NO;
        found++;
    }
    if(found!=1 || !r4HostMatches(host))return NO;*frame=result;return YES;
}
typedef AXError (*R4WindowNumber)(AXUIElementRef,CGWindowID *);
static BOOL r4MapsToPanel(AXUIElementRef element,NSDictionary *host,R4WindowNumber reader) {
    pid_t pid=0;CGWindowID number=0;
    return element && reader && AXUIElementGetPid(element,&pid)==kAXErrorSuccess && pid==[host[@"pid"] intValue] &&
        reader(element,&number)==kAXErrorSuccess && number==[host[@"number"] unsignedIntValue];
}
static AXUIElementRef r4CopyPanel(AXUIElementRef application,NSDictionary *host,R4WindowNumber reader,AXError *error) CF_RETURNS_RETAINED;
static AXUIElementRef r4CopyPanel(AXUIElementRef application,NSDictionary *host,R4WindowNumber reader,AXError *error) {
    id rows=r4Attribute(application,kAXWindowsAttribute,error);
    if(![rows isKindOfClass:NSArray.class] || [rows count]>128)return NULL;
    AXUIElementRef found=NULL;
    for(id row in rows) {
        if(!r4Element(row))return NULL;
        AXUIElementRef element=(__bridge AXUIElementRef)row;
        if(r4MapsToPanel(element,host,reader)) {
            if(found && !CFEqual(found,element))return NULL;found=element;
        }
    }
    return found?(AXUIElementRef)CFRetain(found):NULL;
}
static BOOL r4Button(AXUIElementRef element,NSDictionary *host,NSSet<NSString *> *identifiers,
                     R4WindowNumber reader,CGRect panelFrame,NSMutableDictionary *diagnostic) {
    AXUIElementSetMessagingTimeout(element,.1f);
    AXError error=kAXErrorFailure;
    id role=r4Attribute(element,kAXRoleAttribute,&error);
    diagnostic[@"role"]=[role isKindOfClass:NSString.class] && [role length]<=64?role:@"unknown";
    diagnostic[@"roleRead"]=@(error);
    id identifier=r4Attribute(element,CFSTR("AXIdentifier"),&error);
    diagnostic[@"identifier"]=r4Identifier(identifier)?identifier:@"<redacted-or-absent>";
    diagnostic[@"identifierRead"]=@(error);
    if(![role isEqual:(__bridge NSString *)kAXButtonRole] || ![identifier isKindOfClass:NSString.class] ||
       ![identifiers containsObject:identifier])return NO;
    id enabled=r4Attribute(element,kAXEnabledAttribute,&error);
    BOOL isEnabled=enabled && CFGetTypeID((__bridge CFTypeRef)enabled)==CFBooleanGetTypeID() && [enabled boolValue];
    diagnostic[@"enabledRead"]=@(error);diagnostic[@"enabled"]=@(isEnabled);
    id window=r4Attribute(element,kAXWindowAttribute,&error);
    BOOL mapped=r4Element(window) && r4MapsToPanel((__bridge AXUIElementRef)window,host,reader);
    diagnostic[@"windowRead"]=@(error);diagnostic[@"windowMatches"]=@(mapped);
    CGRect bounds=CGRectNull;BOOL framed=r4Rect(element,&bounds,&error);
    if(framed)diagnostic[@"frame"]=r4Frame(bounds);
    diagnostic[@"frameRead"]=@(error);
    BOOL inside=framed && CGRectContainsRect(CGRectInset(panelFrame,-1,-1),bounds);
    diagnostic[@"insidePanel"]=@(inside);
    pid_t owner=0;BOOL own=AXUIElementGetPid(element,&owner)==kAXErrorSuccess && owner==[host[@"pid"] intValue];
    CFArrayRef actions=NULL;AXError actionRead=AXUIElementCopyActionNames(element,&actions);
    BOOL presses=actionRead==kAXErrorSuccess && actions && CFGetTypeID(actions)==CFArrayGetTypeID() &&
        CFArrayContainsValue(actions,CFRangeMake(0,CFArrayGetCount(actions)),kAXPressAction);
    if(actions)CFRelease(actions);diagnostic[@"pressSupported"]=@(presses);diagnostic[@"actionRead"]=@(actionRead);
    return isEnabled && mapped && inside && own && presses;
}
static NSArray *r4Buttons(AXUIElementRef panel,NSDictionary *host,NSSet<NSString *> *identifiers,
                         R4WindowNumber reader,CGRect frame,double deadline,NSMutableDictionary *report) {
    NSMutableArray *queue=[NSMutableArray arrayWithObject:(__bridge id)panel],*matches=[NSMutableArray array],*rows=[NSMutableArray array];
    CFMutableSetRef visited=CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);BOOL complete=YES;NSUInteger count=0;
    while(queue.count) {
        if(count>=768 || NSProcessInfo.processInfo.systemUptime>=deadline){complete=NO;break;}
        id object=queue.lastObject;[queue removeLastObject];
        if(!r4Element(object)){complete=NO;continue;}
        AXUIElementRef node=(__bridge AXUIElementRef)object;
        if(CFSetContainsValue(visited,node))continue;CFSetAddValue(visited,node);count++;
        pid_t pid=0;if(AXUIElementGetPid(node,&pid)!=kAXErrorSuccess || pid!=[host[@"pid"] intValue]){complete=NO;continue;}
        NSMutableDictionary *row=[NSMutableDictionary dictionary];
        if(r4Button(node,host,identifiers,reader,frame,row))[matches addObject:object];
        if(rows.count<48)[rows addObject:row];
        AXError error=kAXErrorFailure;id children=r4Attribute(node,kAXChildrenAttribute,&error);
        if(error==kAXErrorAttributeUnsupported || error==kAXErrorNoValue)continue;
        if(error!=kAXErrorSuccess || ![children isKindOfClass:NSArray.class] || [children count]>128){complete=NO;continue;}
        [queue addObjectsFromArray:children];
    }
    CFRelease(visited);report[@"visited"]=@(count);report[@"complete"]=@(complete);report[@"nodes"]=rows;
    report[@"matchingButtons"]=@(matches.count);
    return complete?matches:nil;
}
static BOOL r4Save(int descriptor,NSDictionary *report) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    if(!data)return NO;NSUInteger offset=0;
    while(offset<data.length) {
        ssize_t count=write(descriptor,(const char *)data.bytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;if(count<=0)return NO;offset+=(NSUInteger)count;
    }
    return fsync(descriptor)==0;
}
static int runR4Press(NSString *requestPath) {
    @autoreleasepool {
        NSDictionary *request=r4ReadFile(requestPath,NULL),*host=request[@"host"];
        NSString *nonce=request[@"nonce"],*configuration=request[@"configuration"],*resultPath=request[@"result"];
        NSMutableDictionary *report=[@{@"schema":@1,@"status":@"BLOCKED",@"issued":@NO,@"axError":@(kAXErrorFailure),
            @"reason":@"requestInvalid",@"nonce":[nonce isKindOfClass:NSString.class]?nonce:@"",
            @"physicalPointerGesture":@NO,@"directEngineInvocation":@NO,@"qualificationGranted":@NO} mutableCopy];
        uint64_t schema=0;int result=2,descriptor=-1;
        AXUIElementRef application=NULL,panel=NULL;
        do {
            if(!r4Integer(request[@"schema"],&schema) || schema!=1 || ![host isKindOfClass:NSDictionary.class] ||
               ![nonce isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:nonce] ||
               ![configuration isKindOfClass:NSString.class] || ![resultPath isKindOfClass:NSString.class])break;
            NSData *configBytes=nil;NSDictionary *config=r4ReadFile(configuration,&configBytes);
            NSString *output=r4Canonical(config[@"output"]),*requestReal=r4Canonical(requestPath),*configReal=r4Canonical(configuration);
            struct stat folder={0};
            if(!output || stat(output.fileSystemRepresentation,&folder)!=0 || !S_ISDIR(folder.st_mode) || folder.st_uid!=getuid() ||
               !r4Integer(config[@"schema"],&schema) || schema!=1 || ![config[@"nonce"] isEqual:nonce] ||
               ![configReal isEqual:[output stringByAppendingPathComponent:@"config.json"]] ||
               ![requestReal.stringByDeletingLastPathComponent isEqual:output] ||
               ![r4Canonical(resultPath.stringByDeletingLastPathComponent) isEqual:output] ||
               ![resultPath.lastPathComponent hasSuffix:@".json"] || [resultPath.lastPathComponent isEqual:@"config.json"] ||
               [resultPath.lastPathComponent isEqual:requestReal.lastPathComponent]){report[@"reason"]=@"configurationScopeMismatch";break;}
            NSString *destination=[output stringByAppendingPathComponent:resultPath.lastPathComponent];
            descriptor=open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            if(descriptor<0){report[@"reason"]=@"resultMustBeNew";break;}
            id values=request[@"identifiers"];
            if(![values isKindOfClass:NSArray.class] || ![values count] || [values count]>8)break;
            NSMutableSet<NSString *> *identifiers=[NSMutableSet set];BOOL valid=YES;
            for(id value in values){if(!r4Identifier(value) || [identifiers containsObject:value]){valid=NO;break;}[identifiers addObject:value];}
            if(!valid)break;
            if(!r4HostSignature(host)){report[@"reason"]=@"directAcceptanceParentUnconfirmed";break;}
            if(!AXIsProcessTrusted()){report[@"reason"]=@"controllerAccessibilityUnavailable";break;}
            R4WindowNumber reader=(R4WindowNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
            if(!reader){report[@"reason"]=@"windowNumberReaderUnavailable";break;}
            application=AXUIElementCreateApplication([host[@"pid"] intValue]);AXUIElementSetMessagingTimeout(application,.1f);
            double deadline=NSProcessInfo.processInfo.systemUptime+4;id selected=nil;CGRect frame=CGRectNull;
            do {
                if(!r4HostMatches(host)){report[@"reason"]=@"parentChanged";break;}
                if(panel){CFRelease(panel);panel=NULL;}
                AXError error=kAXErrorFailure;panel=r4CopyPanel(application,host,reader,&error);report[@"windowListRead"]=@(error);
                if(panel && r4CGPanel(host,&frame)) {
                    CGRect axFrame=CGRectNull;AXUIElementSetMessagingTimeout(panel,.1f);
                    if(r4Rect(panel,&axFrame,&error) && r4SameFrame(axFrame,frame)) {
                        report[@"panelFrame"]=r4Frame(frame);
                        NSMutableDictionary *tree=[NSMutableDictionary dictionary];
                        NSArray *buttons=r4Buttons(panel,host,identifiers,reader,frame,deadline,tree);report[@"tree"]=tree;
                        NSMutableArray *groups=[NSMutableArray array];
                        for(id button in buttons) {
                            id key=r4Attribute((__bridge AXUIElementRef)button,CFSTR("AXIdentifier"),NULL);
                            if([key isKindOfClass:NSString.class] && [key hasPrefix:@"stage-group-select:"])[groups addObject:button];
                        }
                        if(groups.count==1)selected=groups.firstObject;
                        else if(groups.count==0 && buttons.count==1)selected=buttons.firstObject;
                        report[@"reason"]=buttons?@"buttonMissingOrAmbiguous":@"accessibilityTreeIncomplete";
                    } else {report[@"reason"]=@"panelAXGeometryUnconfirmed";report[@"panelFrameRead"]=@(error);}
                } else report[@"reason"]=@"panelIdentityOrVisibilityUnconfirmed";
                if(selected)break;pump(.06);
            } while(NSProcessInfo.processInfo.systemUptime<deadline);
            if(!selected)break;
            NSData *freshBytes=nil;r4ReadFile(configuration,&freshBytes);
            NSMutableDictionary *last=[NSMutableDictionary dictionary];CGRect freshFrame=CGRectNull;
            if(![configBytes isEqual:freshBytes] || !r4HostSignature(host) || !r4CGPanel(host,&freshFrame) || !r4SameFrame(frame,freshFrame) ||
               !r4MapsToPanel(panel,host,reader) || !r4Button((__bridge AXUIElementRef)selected,host,identifiers,reader,freshFrame,last) ||
               !r4HostMatches(host)){report[@"reason"]=@"prePressEvidenceChanged";report[@"prePress"]=last;break;}
            report[@"prePress"]=last;report[@"issued"]=@YES;
            report[@"inputUptime"]=@(NSProcessInfo.processInfo.systemUptime);
            AXError pressed=AXUIElementPerformAction((__bridge AXUIElementRef)selected,kAXPressAction);
            report[@"axError"]=@(pressed);report[@"status"]=pressed==kAXErrorSuccess?@"ISSUED":@"BLOCKED";
            report[@"reason"]=pressed==kAXErrorSuccess?@"realAccessibilityPressIssued":@"accessibilityPressReturnedError";
            result=pressed==kAXErrorSuccess?0:2;
        } while(NO);
        if(panel)CFRelease(panel);if(application)CFRelease(application);
        report[@"uptime"]=@(NSProcessInfo.processInfo.systemUptime);
        BOOL saved=descriptor>=0 && r4Save(descriptor,report);if(descriptor>=0)close(descriptor);
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        if(json){fwrite(json.bytes,1,json.length,stdout);puts("");fflush(stdout);}
        return saved?result:3;
    }
}
