// Derived from stage-manager 69a7366 src/platform/spaces/ffi.rs (MIT, Eugene Tiutiunnyk).
// Nearpane validates the actual method ABI and never dispatches an object-returning call as void or vice versa.
#import "platform.h"
#import "../corner/scope_binding.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>

static const char *sky_path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
typedef CFArrayRef (*CopyManaged)(int);
typedef CFArrayRef (*CopySpaces)(int,int);
typedef CFArrayRef (*CopyForWindow)(int,int,CFArrayRef);
typedef CFArrayRef (*CopyWindowIDs)(int,uint32_t,CFArrayRef,uint32_t,uint64_t *,uint64_t *);
typedef uint64_t (*CreateSpace)(int,int,int);
typedef int (*DestroySpace)(int,uint64_t);
typedef int (*AddRemove)(int,uint64_t,CFArrayRef,int);
static struct {
    int (*connection)(void);
    CopyManaged managed; CopySpaces spaces; CopyForWindow membership; CopyWindowIDs occupants;
    CreateSpace create; DestroySpace destroy; AddRemove add;
    Class cls; SEL init, perform; bool returnsObject; uint32_t flags;
} api;

static BOOL signedImageAddress(const void *address) {
    Dl_info image = {0};
    return address && dladdr(address, &image) && image.dli_fname &&
        (!strcmp(image.dli_fname,sky_path) || !strcmp(image.dli_fname,"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"));
}

static char methodType(Method method, int argument) {
    char buffer[96] = {0};
    if (argument < 0) method_getReturnType(method,buffer,sizeof(buffer));
    else method_getArgumentType(method,(unsigned)argument,buffer,sizeof(buffer));
    if (!buffer[0]) return 0;
    // Only object and integer encodings reviewed for this selector/architecture are callable.
    return (buffer[1] == 0 || (buffer[0] == '@' && buffer[1] == '"')) ? buffer[0] : 0;
}
static BOOL signature(Method method, const char *arguments, char result) {
    if (!method || !signedImageAddress((const void *)method_getImplementation(method)) ||
        method_getNumberOfArguments(method) != strlen(arguments) || methodType(method,-1) != result) return NO;
    for (unsigned i=0;i<strlen(arguments);i++) if (methodType(method,(int)i) != arguments[i]) return NO;
    return YES;
}

int32_t np_stage_symbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *lib = dlopen(sky_path, RTLD_LOCAL | RTLD_NOW);
        if (!lib) return;
#define LOAD(field, name) do { void *address = dlsym(lib,name); if (signedImageAddress(address)) api.field = (__typeof__(api.field))address; } while(0)
        LOAD(connection,"SLSMainConnectionID"); LOAD(managed,"SLSCopyManagedDisplaySpaces"); LOAD(spaces,"SLSCopySpaces");
        LOAD(membership,"SLSCopySpacesForWindows"); LOAD(occupants,"SLSCopyWindowsWithOptionsAndTags");
        LOAD(create,"SLSSpaceCreate"); LOAD(destroy,"SLSSpaceDestroy"); LOAD(add,"SLSSpaceAddWindowsAndRemoveFromSpaces");
#undef LOAD
        if (api.connection && api.managed && api.spaces && api.membership && api.occupants && api.create && api.destroy) api.flags |= 1;
        if (api.add) api.flags |= 2;
        Class cls = objc_lookUpClass("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation");
        SEL initializer = sel_registerName("initWithSpaceID:windows:options:"), perform = sel_registerName("performWithWMBridgeDelegate");
        Method i = cls ? class_getInstanceMethod(cls,initializer) : NULL, f = cls ? class_getInstanceMethod(cls,perform) : NULL;
        if (cls && signedImageAddress((__bridge const void *)cls) && signature(i,"@:Q@I",'@') &&
            (signature(f,"@:",'v') || signature(f,"@:",'@'))) {
            api.cls=cls; api.init=initializer; api.perform=perform;
            api.returnsObject=methodType(f,-1)=='@'; api.flags |= 4;
        }
    });
    return api.flags;
}

int32_t np_stage_sip_enabled(void) {
    int (*configuration)(uint32_t *) = dlsym(RTLD_DEFAULT,"csr_get_active_config");
    uint32_t flags = UINT32_MAX;
    return configuration && configuration(&flags)==0 ? (int32_t)(flags==0) : -1;
}
int32_t np_stage_target_build(void) {
#if !defined(__arm64__)
    return 0;
#else
    char build[64] = {0}; size_t len=sizeof(build);
    if (sysctlbyname("kern.osversion",build,&len,NULL,0) || !len || strcmp(build,"26A428")) return 0;
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion!=27 || v.minorVersion!=0 || v.patchVersion!=0) return 0;
    return np_stage_sip_enabled()==1;
#endif
}
int32_t np_stage_candidate_supported(void) {
#if !defined(__arm64__)
    return 0;
#else
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    // Availability is established by the actual ABI below and per-move readbacks.
    // SIP posture is recorded separately; a hosted run is not a target-device result.
    BOOL recent = v.majorVersion >= 27 || (v.majorVersion == 26 && v.minorVersion >= 4);
    return recent && getuid() == geteuid() && getuid() != 0 && (np_stage_symbols() & 5) == 5;
#endif
}
int32_t np_stage_connection(void) { np_stage_symbols(); return api.connection ? api.connection() : 0; }
static bool same(int connection) { return connection>0 && np_stage_connection()==connection; }

static NSArray *copied(CFArrayRef raw) {
    if (!raw) return nil;
    if (CFGetTypeID(raw)!=CFArrayGetTypeID()) { CFRelease(raw); return nil; }
    return CFBridgingRelease(raw);
}
static BOOL exactNumber(id value, uint64_t *out, BOOL zero) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() || CFNumberIsFloatType((__bridge CFNumberRef)value)) return NO;
    int64_t n = 0;
    if (!CFNumberGetValue((__bridge CFNumberRef)value,kCFNumberSInt64Type,&n) || n<0 || (!zero && !n)) return NO;
    *out=(uint64_t)n;return YES;
}
static int copyNumbers(NSArray *values,uint64_t *out,uint32_t cap) {
    if (!values || !out || !cap || values.count>cap) return -1;
    for (NSUInteger i=0; i<values.count; i++) if (!exactNumber(values[i],out+i,NO)) return -1;
    return (int)values.count;
}
static int topologyFailure(const char *phase,int32_t managed,int32_t inventory) {
    if(getenv("NP_SPACES_TOPOLOGY_TRACE")) {
        fprintf(stderr,"{\"event\":\"spacesTopology\",\"phase\":\"%s\",\"managedCount\":%d,\"inventoryCount\":%d}\n",
            phase,managed,inventory);
        fflush(stderr);
    }
    return -1;
}
int32_t np_stage_desktops(int32_t c,NPStageDesktop *out,uint32_t cap) {
    @autoreleasepool { @try {
        if (!same(c) || !api.managed || !out || !cap) return topologyFailure("connection-or-buffer",-1,-1);
        NSArray *list=copied(api.managed(c));
        if (!list.count || list.count>32) return topologyFailure("managed-display-list",(int32_t)list.count,-1);
        unsigned index=0;
        for (id obj in list) {
            if (![obj isKindOfClass:NSDictionary.class]) return topologyFailure("managed-display-record",(int32_t)list.count,-1);
            NSDictionary *d=obj;
            NSString *token=d[@"Display Identifier"];
            NSUUID *display=[token isEqual:@"Main"] ? nc_single_main_uuid(list.count) : nc_uuid(token);
            NSDictionary *front=d[@"Current Space"]; NSArray *spaces=d[@"Spaces"];
            if (!display) return topologyFailure("physical-display-identity",(int32_t)list.count,-1);
            if (![front isKindOfClass:NSDictionary.class] || ![spaces isKindOfClass:NSArray.class] || !spaces.count)
                return topologyFailure("current-or-roster-missing",(int32_t)list.count,-1);
            uint64_t current=nc_space_number(front).unsignedLongLongValue;
            NSNumber *currentKind=nc_integer(front[@"type"]);
            NSUUID *currentUUID=nc_uuid(front[@"uuid"]);
            if (!current || !currentUUID || !currentKind) return topologyFailure("current-record-identity",(int32_t)list.count,-1);
            if (nc_direct_home(c,token)!=current) return topologyFailure("current-direct-readback",(int32_t)list.count,-1);
            unsigned found=0;
            for (id record in spaces) {
                if (index>=cap || ![record isKindOfClass:NSDictionary.class]) return topologyFailure("roster-capacity-or-record",(int32_t)list.count,-1);
                NSDictionary *row=record; uint64_t kind=0; NPStageDesktop *s=&out[index++];
                memset(s,0,sizeof(*s));
                s->id=nc_space_number(row).unsignedLongLongValue;
                NSUUID *uuid=nc_uuid(row[@"uuid"]);
                BOOL absentUUID=!row[@"uuid"] || ([row[@"uuid"] isKindOfClass:NSString.class] && ![row[@"uuid"] length]);
                s->current=(s->id==current);
                // Fresh macOS VM accounts can retain an uninitialized, inactive
                // Desktop 1 with uuid="" after the system creates a real Desktop 2.
                // Preserve it as an ID/type/order observation, never invent a UUID
                // or allow it to authorize a current/home window transaction.
                if (!s->id || (!uuid && (s->current || !absentUUID)) ||
                    !exactNumber(row[@"type"],&kind,YES) || kind>INT32_MAX)
                    return topologyFailure("roster-record-identity",(int32_t)list.count,-1);
                if(uuid)[uuid getUUIDBytes:s->uuid];
                [display getUUIDBytes:s->display];
                s->kind=(int32_t)kind;
                if (s->current && (![uuid isEqual:currentUUID] || kind!=currentKind.unsignedLongLongValue))
                    return topologyFailure("current-roster-disagreement",(int32_t)list.count,-1);
                found+=s->current;
            }
            if (found!=1 || nc_direct_home(c,token)!=current ||
                ([token isEqual:@"Main"] && ![display isEqual:nc_single_main_uuid(list.count)]))
                return topologyFailure("current-or-display-changed",(int32_t)list.count,-1);
        }
        return same(c) ? (int)index : topologyFailure("connection-changed",(int32_t)list.count,-1);
    } @catch (NSException *e) { return topologyFailure("exception",-1,-1); } }
}
int32_t np_stage_all_spaces(int32_t c,uint64_t *out,uint32_t cap) {
    @autoreleasepool { @try { return same(c)&&api.spaces ? copyNumbers(copied(api.spaces(c,15)),out,cap) : -1; }
        @catch(NSException *e) { return -1; } }
}
static int compareIDs(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}
// On 26A428 SLSCopySpaces(mask=15) can list a managed full-screen Space twice.
// Preserve both occurrences in the baseline, comparisons, and durable journal.
static BOOL validateInventory(uint64_t *ids, size_t n, const NPStageDesktop *managed, size_t count) {
    if (!ids || !managed || !n || !count) return NO;
    qsort(ids, n, sizeof(*ids), compareIDs);
    if (!ids[0]) return NO;
    for (size_t i = 0; i < count; i++) {
        if (!bsearch(&managed[i].id, ids, n, sizeof(*ids), compareIDs)) return NO;
        for (size_t j = 0; j < i; j++) if (managed[j].id == managed[i].id) return NO;
    }
    for (size_t i = 1; i < n; i++) {
        if (ids[i] != ids[i-1]) continue;
        if (i + 1 < n && ids[i+1] == ids[i]) return NO;
        BOOL fullScreen = NO;
        for (size_t j = 0; j < count; j++)
            if (managed[j].id == ids[i] && managed[j].kind == 4) fullScreen = YES;
        if (!fullScreen) return NO;
    }
    return YES;
}
int32_t np_stage_checked_inventory(int32_t c, uint64_t *out, uint32_t cap) {
    NPStageDesktop managed[512];
    int n = np_stage_all_spaces(c, out, cap);
    int count = np_stage_desktops(c, managed, 512);
    return n > 0 && count > 0 && validateInventory(out, (size_t)n, managed, (size_t)count) && same(c)
        ? n : topologyFailure("checked-inventory",count,n);
}
int32_t np_stage_membership(int32_t c,uint32_t num,uint64_t *out,uint32_t cap) {
    @autoreleasepool { @try { return same(c)&&api.membership&&num ? copyNumbers(copied(api.membership(c,15,(__bridge CFArrayRef)@[@(num)])),out,cap) : -1; }
        @catch(NSException *e) { return -1; } }
}
int32_t np_stage_occupants(int32_t c,uint64_t space,uint64_t *out,uint32_t cap) {
    @autoreleasepool { @try {
        uint64_t set=0,clear=0;
        return same(c)&&api.occupants&&space ? copyNumbers(copied(api.occupants(c,0,(__bridge CFArrayRef)@[@(space)],7,&set,&clear)),out,cap) : -1;
    } @catch(NSException *e) { return -1; } }
}
static uint64_t birth(int32_t pid) {
    struct proc_bsdinfo info={0};
    return pid>1 && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info) &&
        info.pbi_pid==(uint32_t)pid && info.pbi_uid==getuid() && info.pbi_start_tvsec && info.pbi_start_tvusec<1000000
        ? info.pbi_start_tvsec*1000000+info.pbi_start_tvusec : 0;
}
uint64_t np_stage_hosted_self_birth(void) {
    @autoreleasepool {
        NSDictionary *env=NSProcessInfo.processInfo.environment;
        if (getuid()==0 || getuid()!=geteuid() ||
            ![env[@"GITHUB_ACTIONS"] isEqual:@"true"] || ![env[@"RUNNER_ENVIRONMENT"] isEqual:@"github-hosted"] ||
            ![env[@"RUNNER_OS"] isEqual:@"macOS"] || ![env[@"NP_RUN_HOSTED_SPACES_TRIAL"] isEqual:@"1"]) return 0;
        return birth(getpid());
    }
}
static int screenContains(uint32_t number) {
    CFArrayRef ordered=CGWindowListCreate(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    if (!ordered) return -1;
    CFIndex count=CFArrayGetCount(ordered);
    // These are unretained raw CGWindowIDs. No other window's description is requested.
    CFIndex found=count>0 && count<=8192 ? CFArrayGetCountOfValue(ordered,CFRangeMake(0,count),
        (const void *)(uintptr_t)number) : -1;
    CFRelease(ordered);
    return found==0 || found==1 ? (int)found : -1;
}
static int32_t windowReadFailure(uint32_t number,const char *phase,long long first,long long second) {
    if(getenv("NP_SPACES_LAUNCH_TRACE"))
        fprintf(stderr,"{\"event\":\"spacesCGReadFailure\",\"window\":%u,\"phase\":\"%s\",\"first\":%lld,\"second\":%lld}\n",
            number,phase,first,second);
    return -1;
}
int32_t np_stage_window(uint32_t number,NPStageWindow *out) {
    @autoreleasepool { @try {
        if (!number || !out) return windowReadFailure(number,"arguments",0,0);
        const void *raw=(const void *)(uintptr_t)number;
        CFArrayRef ids=CFArrayCreate(NULL,&raw,1,NULL);
        if (!ids) return windowReadFailure(number,"id-array",0,0);
        NSArray *rows=copied(CGWindowListCreateDescriptionFromArray(ids));CFRelease(ids);
        if (!rows || rows.count>1) return windowReadFailure(number,"description-count",rows!=nil,(long long)rows.count);
        if (!rows.count) return 0;
        NSDictionary *r=rows[0];uint64_t n=0,p=0;
        if (![r isKindOfClass:NSDictionary.class] || !exactNumber(r[(id)kCGWindowNumber],&n,NO) || n!=number ||
            !exactNumber(r[(id)kCGWindowOwnerPID],&p,NO) || p>INT32_MAX) return windowReadFailure(number,"description-identity",(long long)n,(long long)p);
        NSNumber *layer=r[(id)kCGWindowLayer], *on=r[(id)kCGWindowIsOnscreen];
        uint64_t owner=birth((int32_t)p);
        if (!owner || ![layer isKindOfClass:NSNumber.class] || (on && CFGetTypeID((__bridge CFTypeRef)on)!=CFBooleanGetTypeID())) return windowReadFailure(number,"description-types",(long long)owner,on?CFGetTypeID((__bridge CFTypeRef)on):0);
        CGRect rect=CGRectNull;
        NSDictionary *bounds=r[(id)kCGWindowBounds];
        if (![bounds isKindOfClass:NSDictionary.class] || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&rect) ||
            !isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height) ||
            rect.size.width<=0 || rect.size.height<=0) return windowReadFailure(number,"geometry",0,0);
        int visible=screenContains(number);
        // The optional onscreen property is often absent when a surface is parked.
        // An absent property alone cannot establish invisibility.
        if (visible<0 || (on && on.boolValue!=visible) || (visible && !on))
            return windowReadFailure(number,"onscreen-samples",on?on.boolValue:-1,visible);
        uint64_t finalBirth=birth((int32_t)p);
        if(finalBirth!=owner)return windowReadFailure(number,"process-birth",(long long)owner,(long long)finalBirth);
        *out=(NPStageWindow){number,(int32_t)p,owner,(uint32_t)visible,layer.intValue==0,{rect.origin.x,rect.origin.y,rect.size.width,rect.size.height}};
        return 1;
    } @catch(NSException *e) { return windowReadFailure(number,"exception",0,0); } }
}

int32_t np_stage_create(int32_t c,uint64_t *created) {
    @autoreleasepool { @try {
        if (!same(c) || !api.create || !created) return 0;
        *created=api.create(c,1,0);
        return *created ? 1 : -1;
    } @catch(NSException *e) { return -1; } }
}
int32_t np_stage_destroy(int32_t c,uint64_t sid) {
    @autoreleasepool { @try {
        if (!same(c) || !api.destroy || !sid) return 0;
        return api.destroy(c,sid)==0 ? 1 : -1;
    } @catch(NSException *e) { return -1; } }
}
@protocol NPAddRemove
- (instancetype)initWithSpaceID:(uint64_t)space windows:(NSArray *)windows options:(uint32_t)options;
@end
@protocol NPPerformVoid
- (void)performWithWMBridgeDelegate;
@end
@protocol NPPerformObject
- (id)performWithWMBridgeDelegate;
@end
int32_t np_stage_move(int32_t c,uint32_t route,uint32_t num,uint64_t sid,uint32_t mask) {
    @autoreleasepool { @try {
        if (!same(c) || !num || !sid || (mask!=7 && mask!=15)) return 0;
        NSArray *windows=@[@(num)];
        if (route==1 && api.add) return api.add(c,sid,(__bridge CFArrayRef)windows,(int)mask)==0 ? 1 : -1;
        if (route!=2 || !(api.flags&4)) return 0;
        Method initializer=class_getInstanceMethod(api.cls,api.init), perform=class_getInstanceMethod(api.cls,api.perform);
        if (!signature(initializer,"@:Q@I",'@') || !signature(perform,"@:",api.returnsObject?'@':'v')) return 0;
        id op=[(id<NPAddRemove>)[api.cls alloc] initWithSpaceID:sid windows:windows options:mask];
        if (!op || ![op isKindOfClass:api.cls] || class_getInstanceMethod(object_getClass(op),api.perform)!=perform) return 0;
        if (api.returnsObject) { (void)[(id<NPPerformObject>)op performWithWMBridgeDelegate]; }
        else { [(id<NPPerformVoid>)op performWithWMBridgeDelegate]; }
        return 1;
    } @catch(NSException *e) { return -1; } }
}

typedef AXError (*AXNumber)(AXUIElementRef, CGWindowID *);
static AXUIElementRef boundWindow(uint32_t n, int32_t pid, uint64_t started, AXUIElementRef retainedOffscreen, BOOL allowMinimized) CF_RETURNS_RETAINED;
static void bindingFailure(uint32_t number,int32_t pid,const char *phase,AXError error,long long first,long long second) {
    if(getenv("NP_SPACES_LAUNCH_TRACE"))
        fprintf(stderr,"{\"event\":\"spacesBindingFailure\",\"window\":%u,\"pid\":%d,\"phase\":\"%s\",\"axError\":%d,\"first\":%lld,\"second\":%lld}\n",
            number,pid,phase,(int)error,first,second);
}
static BOOL bindingAttribute(AXUIElementRef window,CFStringRef attribute,CFTypeRef expected,
                             BOOL allowTrue,uint32_t number,int32_t pid,const char *phase) {
    CFTypeRef value=NULL;
    AXError error=AXUIElementCopyAttributeValue(window,attribute,&value);
    BOOL valid=error==kAXErrorSuccess && value && (CFEqual(value,expected) || (allowTrue && CFEqual(value,kCFBooleanTrue)));
    if(!valid)bindingFailure(number,pid,phase,error,value?(long long)CFGetTypeID(value):0,(long long)allowTrue);
    if(value)CFRelease(value);
    return valid;
}
static AXUIElementRef boundWindow(uint32_t n,int32_t pid,uint64_t started,AXUIElementRef retainedOffscreen, BOOL allowMinimized) {
    if (!n || !started || birth(pid)!=started || !AXIsProcessTrusted()) {
        bindingFailure(n,pid,"process-precondition",kAXErrorSuccess,0,0);return NULL;
    }
    static AXNumber number; static dispatch_once_t once;
    dispatch_once(&once,^{number=(AXNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");});
    if (!number) {bindingFailure(n,pid,"window-number-symbol",kAXErrorNotImplemented,0,0);return NULL;}
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    CFArrayRef windows=NULL; CFIndex count=0;
    AXError error=app?AXUIElementSetMessagingTimeout(app,0.15f):kAXErrorInvalidUIElement;
    const char *phase="app-timeout";
    if(error==kAXErrorSuccess){phase="window-count";error=AXUIElementGetAttributeValueCount(app,kAXWindowsAttribute,&count);}
    BOOL enumerated=error==kAXErrorSuccess && count>=0 && count<=96;
    if(enumerated && count){
        phase="window-list";error=AXUIElementCopyAttributeValues(app,kAXWindowsAttribute,0,count,&windows);
        enumerated=error==kAXErrorSuccess && windows && CFGetTypeID(windows)==CFArrayGetTypeID() && CFArrayGetCount(windows)==count;
    }
    if(!enumerated){
        bindingFailure(n,pid,phase,error,(long long)count,windows?(long long)CFGetTypeID(windows):0);
        if(app)CFRelease(app);if(windows)CFRelease(windows);return NULL;
    }
    AXUIElementRef found=NULL;
    BOOL complete=YES;
    for(CFIndex j=0;j<count;j++){
        AXUIElementRef item=(AXUIElementRef)CFArrayGetValueAtIndex(windows,j);
        CGWindowID id=0;pid_t owner=0;
        phase="listed-window-type";error=kAXErrorSuccess;
        BOOL valid=item && CFGetTypeID(item)==AXUIElementGetTypeID();
        if(valid){phase="listed-window-pid";error=AXUIElementGetPid(item,&owner);valid=error==kAXErrorSuccess && owner==pid;}
        if(valid){phase="listed-window-number";error=number(item,&id);valid=error==kAXErrorSuccess;}
        if(!valid){bindingFailure(n,pid,phase,error,(long long)j,(long long)id);complete=NO;break;}
        if(id!=n)continue;
        if(found && !CFEqual(found,item)){
            bindingFailure(n,pid,"conflicting-target",kAXErrorSuccess,(long long)j,0);complete=NO;break;
        }
        found=item;
    }
    if(!complete)found=NULL;
    else if(retainedOffscreen){
        // An ordinary window may leave AXWindows on a private Space. It must still
        // answer for the previously retained object, same PID/CGID and same lifetime.
        // Reject conflicting entries, partial lists and missing attributes.
        if(found && !CFEqual(found,retainedOffscreen)){
            bindingFailure(n,pid,"retained-conflict",kAXErrorSuccess,0,0);found=NULL;
        }else{
            CGWindowID id=0;pid_t owner=0;
            phase="retained-pid";error=AXUIElementGetPid(retainedOffscreen,&owner);
            BOOL valid=error==kAXErrorSuccess && owner==pid;
            if(valid){phase="retained-number";error=number(retainedOffscreen,&id);valid=error==kAXErrorSuccess && id==n;}
            if(!valid)bindingFailure(n,pid,phase,error,(long long)owner,(long long)id);
            found=valid?retainedOffscreen:NULL;
        }
    }else if(!found){
        bindingFailure(n,pid,"target-not-listed",kAXErrorSuccess,(long long)count,(long long)allowMinimized);
    }
    if(found){
        error=AXUIElementSetMessagingTimeout(found,0.15f);
        if(error!=kAXErrorSuccess)bindingFailure(n,pid,"window-timeout",error,0,0);
        BOOL ordinary=error==kAXErrorSuccess &&
            bindingAttribute(found,kAXRoleAttribute,kAXWindowRole,NO,n,pid,"role") &&
            bindingAttribute(found,kAXSubroleAttribute,kAXStandardWindowSubrole,NO,n,pid,"subrole") &&
            bindingAttribute(found,kAXMinimizedAttribute,kCFBooleanFalse,allowMinimized,n,pid,"minimized");
        // Preserve the original check even if an earlier attribute failed; a
        // missing full-screen or minimized value never means false.
        BOOL notFull=bindingAttribute(found,CFSTR("AXFullScreen"),kCFBooleanFalse,NO,n,pid,"full-screen");
        uint64_t currentBirth=birth(pid);
        if(currentBirth!=started)bindingFailure(n,pid,"changed-birth",kAXErrorSuccess,(long long)started,(long long)currentBirth);
        if(ordinary && notFull && currentBirth==started)CFRetain(found);else found=NULL;
    }
    if(windows)CFRelease(windows);
    CFRelease(app);return found;
}
void *np_stage_bind(uint32_t n,int32_t pid,uint64_t started) { return (void *)boundWindow(n,pid,started,NULL,NO); }
int32_t np_stage_check_bound(void *handle,uint32_t n,int32_t pid,uint64_t started,uint32_t onScreen) {
    if (!handle || onScreen>1) return 0;
    AXUIElementRef current=boundWindow(n,pid,started,onScreen?NULL:(AXUIElementRef)handle,NO);
    if (!current) return 0;
    BOOL ok=CFEqual((CFTypeRef)handle,current); CFRelease(current);return ok;
}
void *np_stage_bind_minimized(uint32_t n,int32_t pid,uint64_t started) {
    AXUIElementRef current=boundWindow(n,pid,started,NULL,YES);
    if (current && np_stage_is_minimized((void *)current)!=1) {CFRelease(current);current=NULL;}
    return (void *)current;
}
int32_t np_stage_check_bound_minimized(void *handle,uint32_t n,int32_t pid,uint64_t started,uint32_t onScreen) {
    if (!handle || onScreen>1) return 0;
    AXUIElementRef current=boundWindow(n,pid,started,onScreen?NULL:(AXUIElementRef)handle,YES);
    if (!current) return 0;
    BOOL ok=CFEqual((CFTypeRef)handle,current);CFRelease(current);return ok;
}
int32_t np_stage_is_minimized(void *handle) {
    if (!handle) return -1;
    CFTypeRef value=NULL;
    AXError result=AXUIElementCopyAttributeValue((AXUIElementRef)handle,kAXMinimizedAttribute,&value);
    int32_t state=result==kAXErrorSuccess && value && CFGetTypeID(value)==CFBooleanGetTypeID()
        ? (CFEqual(value,kCFBooleanTrue)?1:0) : -1;
    if(state<0 && getenv("NP_SPACES_LAUNCH_TRACE")) {
        // Observe the retained object, not a reconstructed AX writer. Keep a
        // timeout/invalid object/unsupported attribute distinct in diagnostics;
        // none is equivalent to a positive AXMinimized=false read.
        pid_t owner=0;CGWindowID id=0;
        AXError ownerRead=AXUIElementGetPid((AXUIElementRef)handle,&owner);
        static AXNumber number;static dispatch_once_t once;
        dispatch_once(&once,^{number=(AXNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");});
        AXError numberRead=number?number((AXUIElementRef)handle,&id):kAXErrorNotImplemented;
        fprintf(stderr,"{\"event\":\"spacesMinimizedReadFailure\",\"axError\":%d,\"valuePresent\":%s,\"valueType\":%lu,\"booleanValue\":%s,\"retainedPID\":%d,\"pidRead\":%d,\"retainedWindow\":%u,\"windowRead\":%d}\n",
            (int)result,value?"true":"false",value?(unsigned long)CFGetTypeID(value):0UL,value&&CFGetTypeID(value)==CFBooleanGetTypeID()?"true":"false",
            (int)owner,(int)ownerRead,(unsigned)id,(int)numberRead);
    }
    if(value)CFRelease(value);return state;
}
int32_t np_stage_set_minimized(void *handle,uint32_t n,int32_t pid,uint64_t started,uint32_t minimized) {
    if (!handle || minimized>1 || !np_stage_check_bound_minimized(handle,n,pid,started,0))return 0;
    return AXUIElementSetAttributeValue((AXUIElementRef)handle,kAXMinimizedAttribute,
        minimized?kCFBooleanTrue:kCFBooleanFalse)==kAXErrorSuccess ? 1 : -1;
}
void np_stage_release(void *handle) { if (handle) CFRelease((CFTypeRef)handle); }
#include "launch-panel.inc"
#include "installed-fixture.inc"
