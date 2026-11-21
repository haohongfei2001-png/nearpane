#import "Lab.h"

static id ax(AXUIElementRef elem, NSString *key) {
    if (!elem) return nil;
    CFTypeRef out = NULL;
    if (AXUIElementCopyAttributeValue(elem, (__bridge CFStringRef)key, &out) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(out);
}
static AXUIElementRef element(id value) { return (__bridge AXUIElementRef)value; }
static NSArray *axRect(id obj) {
    id p = ax(element(obj), @"AXPosition"), s = ax(element(obj), @"AXSize"); CGPoint point; CGSize size;
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() || CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID()
        || !AXValueGetValue((__bridge AXValueRef)p,kAXValueCGPointType,&point) || !AXValueGetValue((__bridge AXValueRef)s,kAXValueCGSizeType,&size)) return nil;
    return rectArray((CGRect){point,size});
}
static CGPoint center(NSArray *r) { return CGPointMake([r[0] doubleValue]+[r[2] doubleValue]/2,[r[1] doubleValue]+[r[3] doubleValue]/2); }
static id axWindow(NSDictionary *owner, NSString *label) {
    id app = CFBridgingRelease(AXUIElementCreateApplication([owner[@"pid"] intValue]));
    for (id value in ax(element(app), @"AXWindows")) if ([ax(element(value), @"AXIdentifier") isEqual:label]) return value;
    return nil;
}
static NSDictionary *focus(NSDictionary *a, NSDictionary *b) {
    id system = CFBridgingRelease(AXUIElementCreateSystemWide());
    id app = ax(element(system), @"AXFocusedApplication");
    pid_t pid = -1; if (app) AXUIElementGetPid(element(app), &pid);
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    id window = ax(element(app), @"AXFocusedWindow");
    NSString *label = (pid == [a[@"pid"] intValue] || pid == [b[@"pid"] intValue]) ? ax(element(window), @"AXIdentifier") : nil;
    uint32_t number = 0;
    int (*numberOf)(AXUIElementRef,uint32_t *) = sky(@"_AXUIElementGetWindow");
    if (!numberOf) numberOf = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    int err = window && label && numberOf ? numberOf(element(window), &number) : -1;
    return @{@"axPID":@(pid),@"frontPID":@(front),@"label":label ?: none(),@"actualID":err == 0 ? @(number) : none()};
}
static NSDictionary *dock(NSString *root) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (apps.count != 1) return @{};
    id obj = CFBridgingRelease(AXUIElementCreateApplication([apps[0] processIdentifier]));
    NSArray *children = ax(element(obj), @"AXChildren"); NSNumber *tiles = nil; NSArray *tile = nil; BOOL mc = NO;
    NSURL *expected = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"A.app"] isDirectory:YES];
    for (id child in children) {
        if ([ax(element(child),@"AXIdentifier") isEqual:@"mc"]) mc = YES;
        if (![ax(element(child),@"AXRole") isEqual:@"AXList"]) continue;
        NSArray *items = ax(element(child),@"AXChildren"); BOOL hasApp = NO, complete = items.count > 0; NSInteger count = 0;
        for (id item in items) {
            NSString *role = ax(element(item),@"AXSubrole");
            if (!role) complete = NO;
            if ([role isEqual:@"AXMinimizedWindowDockItem"]) count++;
            if (![role isEqual:@"AXApplicationDockItem"]) continue;
            hasApp = YES; NSURL *url = ax(element(item),@"AXURL");
            if ([url isKindOfClass:NSURL.class] && [url.URLByResolvingSymlinksInPath.path isEqual:expected.URLByResolvingSymlinksInPath.path]) tile = axRect(item);
        }
        if (complete && hasApp) tiles = @(count);
    }
    return @{@"minimizedTiles":tiles ?: none(),@"appTile":tile ?: none(),@"missionControl":mc ? @YES : (tiles ? @NO : none()),@"pid":@([apps[0] processIdentifier])};
}
static NSArray *displays(int cid) {
    uint32_t count = 0; CGDirectDisplayID ids[32];
    if (CGGetActiveDisplayList(32,ids,&count) != 0 || count == 32) return nil;
    uint64_t (*space)(int,CFStringRef) = sky(@"SLSManagedDisplayGetCurrentSpace");
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(ids[i]); NSString *key = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
        if (uuid) CFRelease(uuid);
        uint64_t active = cid && key && space ? space(cid, (__bridge CFStringRef)key) : 0;
        [result addObject:@{@"id":@(ids[i]),@"uuid":key ?: none(),@"bounds":rectArray(CGDisplayBounds(ids[i])),@"activeSpace":active ? @(active) : none()}];
    }
    return result;
}
static NSArray *cgList(CGWindowListOption option) {
    return CFBridgingRelease(CGWindowListCopyWindowInfo(option | kCGWindowListExcludeDesktopElements,kCGNullWindowID));
}
static id cgRow(NSArray *list, NSNumber *number, NSNumber *pid) {
    for (NSDictionary *row in list) {
        if (![row[(id)kCGWindowNumber] isEqual:number] || ![row[(id)kCGWindowOwnerPID] isEqual:pid]) continue;
        CGRect r; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&r)) return none();
        return @{@"frame":rectArray(r),@"layer":row[(id)kCGWindowLayer],@"onscreen":row[(id)kCGWindowIsOnscreen] ?: @NO};
    }
    return none();
}
static NSDictionary *hit(CGPoint pt, NSDictionary *a, NSDictionary *b) {
    id sys = CFBridgingRelease(AXUIElementCreateSystemWide()); AXUIElementRef el = NULL;
    pid_t pid = -1; NSString *label = nil;
    if (AXUIElementCopyElementAtPosition(element(sys),pt.x,pt.y,&el) == kAXErrorSuccess && el) {
        AXUIElementGetPid(el,&pid);
        if (pid == [a[@"pid"] intValue] || pid == [b[@"pid"] intValue]) {
            id win = ax(el,@"AXWindow"); label = ax(element(win),@"AXIdentifier") ?: ax(el,@"AXIdentifier");
        }
        CFRelease(el);
    }
    NSNumber *top = nil;
    for (NSDictionary *row in cgList(kCGWindowListOptionOnScreenOnly)) {
        CGRect r;
        if ([row[(id)kCGWindowLayer] intValue] != 0 || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&r) || !CGRectContainsPoint(r,pt)) continue;
        top = row[(id)kCGWindowNumber]; break;
    }
    return @{@"point":@[@(pt.x),@(pt.y)],@"axPID":@(pid),@"axWindow":label ?: none(),@"cgFrontWindow":top ?: none()};
}
static void mouseEvent(CGEventType type, CGPoint p) {
    CGEventRef event = CGEventCreateMouseEvent(NULL,type,p,kCGMouseButtonLeft);
    if (!event) exit(70);
    CGEventPost(kCGHIDEventTap,event); CFRelease(event);
}
static void keyEvent(CGKeyCode code) {
    for (int down=1; down>=0; down--) {
        CGEventRef e=CGEventCreateKeyboardEvent(NULL,code,down); if (!e) exit(70); CGEventPost(kCGHIDEventTap,e); CFRelease(e);
        usleep(45000);
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1],"symbols")) {
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        for (NSString *n in @[@"SLSMainConnectionID",@"SLSNewConnection",@"SLSReleaseConnection",@"SLSOrderWindow",@"SLSTransactionCreate",
                @"SLSTransactionOrderWindow",@"SLSTransactionCommit",@"SLSWindowIsOrderedIn",@"SLSCopySpacesForWindows",@"SLSManagedDisplayGetCurrentSpace"]) s[n] = @(sky(n) != NULL);
        for (NSString *n in @[@"CGVirtualDisplay",@"CGVirtualDisplayDescriptor",@"CGVirtualDisplayMode",@"CGVirtualDisplaySettings"]) s[n] = @(NSClassFromString(n) != nil);
        emit(s); return 0;
    }
    if (argc < 3 || !hosted()) return 64;
    NSString *root = @(argv[1]), *op = @(argv[2]);
    NSDictionary *a = fixtureIdentity(root,@"A"), *b = fixtureIdentity(root,@"B");
    if (!a || !b) return 65;
    MainConnection main = sky(@"SLSMainConnectionID"); int cid = main ? main() : 0;
    if ([op isEqual:@"leases"]) {
        NSMutableDictionary *leases = [NSMutableDictionary dictionary];
        for (NSString *label in @[@"A0",@"A1",@"B0",@"B1"]) {
            id window = axWindow([label hasPrefix:@"A"] ? a : b,label);
            if (window) leases[label] = window;
        }
        emit(@{@"enrolled":leases.allKeys,@"pid":@(getpid())});
        char line[32];
        while (fgets(line,sizeof(line),stdin) && !strcmp(line,"sample\n")) { @autoreleasepool {
            NSMutableDictionary *r = [NSMutableDictionary dictionary];
            for (NSString *label in leases) {
                NSString *name=[label hasPrefix:@"A"] ? @"A" : @"B";
                if (!fixtureIdentity(root,name)) return 65;
                AXUIElementRef w=element(leases[label]); id identifier=ax(w,@"AXIdentifier");
                r[label]=@{@"identifier":identifier ?: none(),@"mini":ax(w,@"AXMinimized") ?: none(),@"frame":axRect(leases[label]) ?: none()};
            }
            emit(r);
        }}
        return 0;
    }
    if ([op isEqual:@"snapshot"]) {
        int (*ordered)(int,uint32_t,uint8_t*) = sky(@"SLSWindowIsOrderedIn");
        CFArrayRef (*spaces)(int,int,CFArrayRef) = sky(@"SLSCopySpacesForWindows");
        NSArray *all = cgList(kCGWindowListOptionAll), *on = cgList(kCGWindowListOptionOnScreenOnly);
        NSMutableDictionary *rows = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"A",@"B"]) {
            NSDictionary *o = [name isEqual:@"A"] ? a : b;
            for (int i=0;i<2;i++) {
                NSNumber *wid = o[@"windows"][i]; NSString *label = [name stringByAppendingFormat:@"%d",i];
                id win = axWindow(o,label); uint8_t visible = 0;
                int e = ordered && cid ? ordered(cid,wid.unsignedIntValue,&visible) : -1;
                NSArray *membership = spaces && cid ? CFBridgingRelease(spaces(cid,7,(__bridge CFArrayRef)@[wid])) : nil;
                rows[label] = @{@"number":wid,@"pid":o[@"pid"],@"generation":o[@"generation"],@"axKnown":@(win != nil),@"axMini":ax(element(win),@"AXMinimized") ?: none(),
                   @"axFrame":axRect(win) ?: none(),@"orderedReadError":@(e),@"ordered":e == 0 ? @(!!visible) : none(),
                   @"spaces":membership.count ? membership : none(),@"cgAll":cgRow(all,wid,o[@"pid"]),@"cgScreen":cgRow(on,wid,o[@"pid"])};
            }
        }
        CGEventRef ptr = CGEventCreate(NULL); CGPoint p = ptr ? CGEventGetLocation(ptr) : CGPointZero; if (ptr) CFRelease(ptr);
        emit(@{@"axTrusted":@(AXIsProcessTrusted()),@"postAllowed":@(CGPreflightPostEventAccess()),@"screenAllowed":@(CGPreflightScreenCaptureAccess()),
               @"cgListsAvailable":@(all != nil && on != nil),@"focus":focus(a,b),@"dock":dock(root),@"windows":rows,@"displays":displays(cid) ?: none(),
               @"pointer":@[@(p.x),@(p.y)]}); return 0;
    }
    if ([op isEqual:@"key"]) {
        NSDictionary *f = focus(a,b);
        if ([f[@"frontPID"] isEqual:a[@"pid"]] && [f[@"axPID"] isEqual:a[@"pid"]] && [a[@"windows"] containsObject:f[@"actualID"]]) {
            keyEvent(7); emit(@{@"posted":@YES,@"before":f});
        } else emit(@{@"posted":@NO,@"before":f}); return 0;
    }
    if ([op isEqual:@"dock-click"]) {
        NSDictionary *d = dock(root); id tile = d[@"appTile"];
        if (![tile isKindOfClass:NSArray.class]) { emit(@{@"posted":@NO,@"dock":d}); return 0; }
        CGPoint p = center(tile); NSDictionary *at = hit(p,a,b);
        if (![at[@"axPID"] isEqual:d[@"pid"]]) { emit(@{@"posted":@NO,@"hit":at}); return 0; }
        mouseEvent(kCGEventLeftMouseDown,p); usleep(50000); mouseEvent(kCGEventLeftMouseUp,p); emit(@{@"posted":@YES,@"hit":at}); return 0;
    }
    if ([op isEqual:@"escape-mc"]) {
        BOOL mc = [dock(root)[@"missionControl"] isEqual:@YES]; if (mc) keyEvent(53); emit(@{@"posted":@(mc)}); return 0;
    }
    if (argc >= 5 && ([@[@"hit",@"click",@"warp"] containsObject:op])) {
        CGPoint p = CGPointMake(atof(argv[3]),atof(argv[4])); NSDictionary *at = hit(p,a,b);
        if ([op isEqual:@"warp"]) { emit(@{@"error":@(CGWarpMouseCursorPosition(p)),@"requested":@[@(p.x),@(p.y)]}); return 0; }
        if ([op isEqual:@"click"]) {
            BOOL allowed = ([at[@"axPID"] isEqual:a[@"pid"]] || [at[@"axPID"] isEqual:b[@"pid"]])
                 && ([a[@"windows"] containsObject:at[@"cgFrontWindow"]] || [b[@"windows"] containsObject:at[@"cgFrontWindow"]]);
            if (allowed) { mouseEvent(kCGEventLeftMouseDown,p); usleep(50000); mouseEvent(kCGEventLeftMouseUp,p); }
            emit(@{@"posted":@(allowed),@"hit":at}); return 0;
        }
        emit(at); return 0;
    }
    if (argc >= 4 && ([@[@"minimize",@"restore",@"move"] containsObject:op])) {
        NSString *label = @(argv[3]); if (![@[@"A0",@"A1"] containsObject:label]) return 64;
        id w = axWindow(a,label);
        if (!w) { emit(@{@"axError":@(kAXErrorInvalidUIElement)}); return 0; }
        AXError e;
        if ([op isEqual:@"move"] && argc == 6) {
            CGPoint p = CGPointMake(atof(argv[4]),atof(argv[5]));
            id value = CFBridgingRelease(AXValueCreate(kAXValueCGPointType,&p));
            e = AXUIElementSetAttributeValue(element(w), CFSTR("AXPosition"), (__bridge CFTypeRef)value);
        } else if (![op isEqual:@"move"]) {
            e = AXUIElementSetAttributeValue(element(w), CFSTR("AXMinimized"), [op isEqual:@"minimize"] ? kCFBooleanTrue : kCFBooleanFalse);
        } else return 64;
        emit(@{@"axError":@(e)}); return 0;
    }
    return 64;
}}
