// Derived from stage-manager 69a7366 src/platform/spaces/ffi.rs (MIT, Eugene Tiutiunnyk).
// Nearpane validates the actual method ABI and never dispatches an object-returning call as void or vice versa.
#import "platform.h"
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
static BOOL getUUID(id src,uint8_t *dst) {
    if (![src isKindOfClass:NSString.class]) return NO;
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:src];
    if (!uuid) return NO;
    [uuid getUUIDBytes:dst];return YES;
}
static int copyNumbers(NSArray *values,uint64_t *out,uint32_t cap) {
    if (!values || !out || !cap || values.count>cap) return -1;
    for (NSUInteger i=0; i<values.count; i++) if (!exactNumber(values[i],out+i,NO)) return -1;
    return (int)values.count;
}
int32_t np_stage_desktops(int32_t c,NPStageDesktop *out,uint32_t cap) {
    @autoreleasepool { @try {
        if (!same(c) || !api.managed || !out || !cap) return -1;
        NSArray *list=copied(api.managed(c));
        if (!list.count || list.count>32) return -1;
        unsigned index=0;
        for (id obj in list) {
            if (![obj isKindOfClass:NSDictionary.class]) return -1;
            NSDictionary *d=obj; uint8_t display[16]; uint64_t current=0;
            NSDictionary *front=d[@"Current Space"]; NSArray *spaces=d[@"Spaces"];
            if (![front isKindOfClass:NSDictionary.class] || ![spaces isKindOfClass:NSArray.class] || !spaces.count ||
                !getUUID(d[@"Display Identifier"],display) || !exactNumber(front[@"id64"],&current,NO)) return -1;
            unsigned found=0;
            for (id record in spaces) {
                if (index>=cap || ![record isKindOfClass:NSDictionary.class]) return -1;
                NSDictionary *row=record; uint64_t kind=0; NPStageDesktop *s=&out[index++];
                if (!exactNumber(row[@"id64"],&s->id,NO) || !exactNumber(row[@"type"],&kind,YES) ||
                    kind>INT32_MAX || !getUUID(row[@"uuid"],s->uuid)) return -1;
                memcpy(s->display,display,16); s->kind=(int32_t)kind; s->current=(s->id==current);
                found+=s->current;
            }
            if (found!=1) return -1;
        }
        return same(c) ? (int)index : -1;
    } @catch (NSException *e) { return -1; } }
}
int32_t np_stage_all_spaces(int32_t c,uint64_t *out,uint32_t cap) {
    @autoreleasepool { @try { return same(c)&&api.spaces ? copyNumbers(copied(api.spaces(c,15)),out,cap) : -1; }
        @catch(NSException *e) { return -1; } }
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
int32_t np_stage_window(uint32_t number,NPStageWindow *out) {
    @autoreleasepool { @try {
        if (!number || !out) return -1;
        const void *raw=(const void *)(uintptr_t)number;
        CFArrayRef ids=CFArrayCreate(NULL,&raw,1,NULL);
        if (!ids) return -1;
        NSArray *rows=copied(CGWindowListCreateDescriptionFromArray(ids));CFRelease(ids);
        if (!rows || rows.count>1) return -1;
        if (!rows.count) return 0;
        NSDictionary *r=rows[0];uint64_t n=0,p=0;
        if (![r isKindOfClass:NSDictionary.class] || !exactNumber(r[(id)kCGWindowNumber],&n,NO) || n!=number ||
            !exactNumber(r[(id)kCGWindowOwnerPID],&p,NO) || p>INT32_MAX) return -1;
        NSNumber *layer=r[(id)kCGWindowLayer], *on=r[(id)kCGWindowIsOnscreen];
        uint64_t owner=birth((int32_t)p);
        if (!owner || ![layer isKindOfClass:NSNumber.class] || (on && CFGetTypeID((__bridge CFTypeRef)on)!=CFBooleanGetTypeID())) return -1;
        CGRect rect=CGRectNull;
        NSDictionary *bounds=r[(id)kCGWindowBounds];
        if (![bounds isKindOfClass:NSDictionary.class] || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&rect) ||
            !isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height) ||
            rect.size.width<=0 || rect.size.height<=0) return -1;
        int visible=screenContains(number);
        // The optional onscreen property is often absent when a surface is parked.
        // An absent property alone cannot establish invisibility.
        if (visible<0 || (on && on.boolValue!=visible) || (visible && !on) || birth((int32_t)p)!=owner) return -1;
        *out=(NPStageWindow){number,(int32_t)p,owner,(uint32_t)visible,layer.intValue==0,{rect.origin.x,rect.origin.y,rect.size.width,rect.size.height}};
        return 1;
    } @catch(NSException *e) { return -1; } }
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
static AXUIElementRef boundWindow(uint32_t n, int32_t pid, uint64_t started, AXUIElementRef retainedOffscreen) CF_RETURNS_RETAINED;
static AXUIElementRef boundWindow(uint32_t n,int32_t pid,uint64_t started,AXUIElementRef retainedOffscreen) {
    if (!n || !started || birth(pid)!=started || !AXIsProcessTrusted()) return NULL;
    static AXNumber number; static dispatch_once_t once;
    dispatch_once(&once,^{number=(AXNumber)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");});
    if (!number) return NULL;
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    CFArrayRef windows=NULL; CFIndex count=0;
    if (!app || AXUIElementSetMessagingTimeout(app,0.15f)!=kAXErrorSuccess ||
        AXUIElementGetAttributeValueCount(app,kAXWindowsAttribute,&count)!=kAXErrorSuccess || count<0 || count>96 ||
        (count && (AXUIElementCopyAttributeValues(app,kAXWindowsAttribute,0,count,&windows)!=kAXErrorSuccess ||
        !windows || CFGetTypeID(windows)!=CFArrayGetTypeID() || CFArrayGetCount(windows)!=count))) {
        if (app) CFRelease(app); if (windows) CFRelease(windows); return NULL;
    }
    AXUIElementRef found=NULL;
    BOOL complete=YES;
    for (CFIndex j=0;j<count;j++) {
        AXUIElementRef item=(AXUIElementRef)CFArrayGetValueAtIndex(windows,j);
        CGWindowID id=0; pid_t owner=0;
        if (!item || CFGetTypeID(item)!=AXUIElementGetTypeID() || AXUIElementGetPid(item,&owner)!=kAXErrorSuccess ||
            owner!=pid || number(item,&id)!=kAXErrorSuccess) {complete=NO;break;}
        if (id!=n) continue;
        if (found && !CFEqual(found,item)) {complete=NO;break;}
        found=item;
    }
    if (!complete) found=NULL;
    else if (retainedOffscreen) {
        // An ordinary window may leave AXWindows on a private Space. It must still
        // answer for the previously retained object, same PID/CGID and same lifetime.
        // Reject conflicting entries, partial lists and missing attributes.
        if (found && !CFEqual(found,retainedOffscreen)) found=NULL;
        else {
            CGWindowID id=0;pid_t owner=0;
            found=AXUIElementGetPid(retainedOffscreen,&owner)==kAXErrorSuccess && owner==pid &&
                number(retainedOffscreen,&id)==kAXErrorSuccess && id==n ? retainedOffscreen : NULL;
        }
    }
    if (found) {
        CFTypeRef role=NULL,sub=NULL,min=NULL,full=NULL;
        BOOL ordinary=AXUIElementSetMessagingTimeout(found,0.15f)==kAXErrorSuccess &&
            AXUIElementCopyAttributeValue(found,kAXRoleAttribute,&role)==kAXErrorSuccess && role && CFEqual(role,kAXWindowRole) &&
            AXUIElementCopyAttributeValue(found,kAXSubroleAttribute,&sub)==kAXErrorSuccess && sub && CFEqual(sub,kAXStandardWindowSubrole) &&
            AXUIElementCopyAttributeValue(found,kAXMinimizedAttribute,&min)==kAXErrorSuccess && min && CFEqual(min,kCFBooleanFalse);
        AXError fs=AXUIElementCopyAttributeValue(found,CFSTR("AXFullScreen"),&full);
        ordinary = ordinary && fs==kAXErrorSuccess && full && CFEqual(full,kCFBooleanFalse);
        if (role) CFRelease(role); if (sub) CFRelease(sub); if (min) CFRelease(min); if (full) CFRelease(full);
        if (ordinary && birth(pid)==started) CFRetain(found); else found=NULL;
    }
    if (windows) CFRelease(windows);
    CFRelease(app);return found;
}
void *np_stage_bind(uint32_t n,int32_t pid,uint64_t started) { return (void *)boundWindow(n,pid,started,NULL); }
int32_t np_stage_check_bound(void *handle,uint32_t n,int32_t pid,uint64_t started,uint32_t onScreen) {
    if (!handle || onScreen>1) return 0;
    AXUIElementRef current=boundWindow(n,pid,started,onScreen?NULL:(AXUIElementRef)handle);
    if (!current) return 0;
    BOOL ok=CFEqual((CFTypeRef)handle,current); CFRelease(current);return ok;
}
void np_stage_release(void *handle) { if (handle) CFRelease((CFTypeRef)handle); }
#include "launch-panel.inc"
#include "installed-fixture.inc"
