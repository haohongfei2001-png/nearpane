// Standalone Route A diagnostic. No injection, hooks, window moves or private mutators.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static void emit(id value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingSortedKeys error:&error];
    if (!data) { fprintf(stderr, "%s\n", error.description.UTF8String); exit(2); }
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
}
static NSArray *rect(CGRect r) {
    return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)];
}
static id attribute(AXUIElementRef node, CFStringRef key, AXError *status) {
    CFTypeRef value = NULL;
    AXUIElementSetMessagingTimeout(node, .05f);
    AXError e = AXUIElementCopyAttributeValue(node, key, &value);
    if (status) *status = e;
    return CFBridgingRelease(value);
}
static NSArray *axFrame(AXUIElementRef node) {
    id value = attribute(node, CFSTR("AXFrame"), NULL);
    CGRect r = CGRectZero;
    if (value && CFGetTypeID((__bridge CFTypeRef)value) == AXValueGetTypeID() &&
        AXValueGetValue((__bridge AXValueRef)value, kAXValueCGRectType, &r)) return rect(r);
    return @[];
}
static NSArray *displays(void) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (uint32_t i = 0; i < count; ++i)
        [out addObject:@{@"id":@(ids[i]), @"bounds":rect(CGDisplayBounds(ids[i])),
                        @"main":@(ids[i] == CGMainDisplayID())}];
    return out;
}
static NSDictionary *strips(pid_t pid) {
    NSMutableArray *out = [NSMutableArray array];
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXError status = kAXErrorSuccess;
    NSArray *spaces = attribute(app, kAXChildrenAttribute, &status);
    CFRelease(app);
    if (status != kAXErrorSuccess || ![spaces isKindOfClass:NSArray.class])
        return @{@"status":@(status), @"complete":@NO, @"strips":out};
    double deadline = NSProcessInfo.processInfo.systemUptime + 1;
    for (id rawSpace in spaces) {
        if (NSProcessInfo.processInfo.systemUptime > deadline) { status=kAXErrorCannotComplete; break; }
        AXUIElementRef space = (__bridge AXUIElementRef)rawSpace;
        if (![attribute(space, kAXIdentifierAttribute, NULL) isEqual:@"sm.space"]) continue;
        NSArray *lists = attribute(space, kAXChildrenAttribute, &status);
        if (status || ![lists isKindOfClass:NSArray.class]) break;
        for (id rawList in lists) {
            AXUIElementRef list = (__bridge AXUIElementRef)rawList;
            if (![attribute(list, kAXIdentifierAttribute, NULL) isEqual:@"sm.strip"]) continue;
            NSArray *children = attribute(list, kAXChildrenAttribute, &status);
            if (status || ![children isKindOfClass:NSArray.class]) break;
            NSMutableArray *items = [NSMutableArray array];
            for (id rawItem in children) {
                if (NSProcessInfo.processInfo.systemUptime > deadline) { status=kAXErrorCannotComplete; break; }
                AXUIElementRef item = (__bridge AXUIElementRef)rawItem;
                id ids = attribute(item, CFSTR("AXWindowsIDs"), NULL);
                if (![ids isKindOfClass:NSArray.class]) ids = @[];
                CFArrayRef rawActions = NULL;
                AXError actionStatus = AXUIElementCopyActionNames(item, &rawActions);
                NSArray *actions = CFBridgingRelease(rawActions);
                // No titles, descriptions or document contents are read.
                [items addObject:@{@"frame":axFrame(item), @"windows":ids,
                                   @"actions":actions ?: @[], @"actionStatus":@(actionStatus)}];
            }
            [out addObject:@{@"displayFrame":axFrame(space), @"frame":axFrame(list), @"items":items}];
        }
        if (status) break;
    }
    return @{@"status":@(status), @"complete":@(status==kAXErrorSuccess), @"strips":out};
}
static NSDictionary *snapshot(void) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *raw = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    for (NSDictionary *r in raw) {
        CGRect b = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r[(__bridge NSString *)kCGWindowBounds], &b)) continue;
        [rows addObject:@{@"id":r[(__bridge NSString *)kCGWindowNumber] ?: @0,
                          @"pid":r[(__bridge NSString *)kCGWindowOwnerPID] ?: @0,
                          @"layer":r[(__bridge NSString *)kCGWindowLayer] ?: @0,
                          @"onscreen":r[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
                          @"alpha":r[(__bridge NSString *)kCGWindowAlpha] ?: @0,
                          @"bounds":rect(b)}];
    }
    NSArray *managers = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.WindowManager"];
    NSMutableArray *owners = [NSMutableArray array];
    for (NSRunningApplication *app in managers)
        [owners addObject:@{@"pid":@(app.processIdentifier), @"path":app.executableURL.path ?: @"",
                            @"ax":AXIsProcessTrusted() ? strips(app.processIdentifier) : @{@"complete":@NO, @"status":@(-25211), @"strips":@[]}}];
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if(e) CFRelease(e);
    id enabled = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("GloballyEnabled"), CFSTR("com.apple.WindowManager")));
    id autoHide = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AutoHide"), CFSTR("com.apple.WindowManager")));
    return @{@"uptime":@(NSProcessInfo.processInfo.systemUptime),
             @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
             @"nativeEnabled":enabled ?: NSNull.null, @"autoHide":autoHide ?: NSNull.null,
             @"accessibility":@(AXIsProcessTrusted()), @"screenCapture":@(CGPreflightScreenCaptureAccess()),
             @"frontPID":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
             @"pointer":@[@(p.x), @(p.y)], @"displays":displays(),
             @"windowListAvailable":@(raw != nil), @"windows":rows, @"managers":owners};
}
static NSDictionary *inventory(void) {
    NSArray *paths = @[@"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                       @"/System/Library/PrivateFrameworks/WindowManagement.framework/WindowManagement"];
    NSMutableArray *loaded = [NSMutableArray array];
    NSMutableArray *symbols = [NSMutableArray array];
    for (NSString *path in paths) {
        void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY|RTLD_LOCAL);
        const char *error = h ? NULL : dlerror();
        [loaded addObject:@{@"path":path,@"loaded":@(h!=NULL),@"error":error ? @(error):@""}];
        if (!h) continue;
        for (NSString *name in @[@"SLSMainConnectionID",@"SLSCopyManagedDisplaySpaces",@"SLSCopySpacesForWindows",
                @"SLSSpaceCreate",@"SLSSpaceDestroy",@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation",
                @"SLSBridgedMoveWindowsToManagedSpaceOperation",@"SLSGetWindowPresenter"])
            [symbols addObject:@{@"image":path,@"name":name,@"present":@(dlsym(h,name.UTF8String)!=NULL)}];
        // Keep loaded so the Objective-C runtime inventory remains valid. Never instantiate classes.
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned int i=0;i<count;i++) {
        const char *image = class_getImageName(classes[i]);
        if (!image || (!strstr(image,"WindowManagement.framework") && !strstr(image,"SkyLight.framework"))) continue;
        NSMutableArray *methods = [NSMutableArray array];
        for (int meta=0;meta<2;meta++) {
            unsigned int n=0;
            Method *ms = class_copyMethodList(meta ? object_getClass(classes[i]) : classes[i], &n);
            for (unsigned int j=0;j<n;j++) {
                const char *types = method_getTypeEncoding(ms[j]);
                [methods addObject:@{@"kind":meta ? @"class":@"instance",
                    @"selector":NSStringFromSelector(method_getName(ms[j])),@"types":types ? @(types):@""}];
            }
            free(ms);
        }
        [out addObject:@{@"name":@(class_getName(classes[i])),@"image":@(image),@"methods":methods}];
    }
    free(classes);
    return @{@"frameworks":loaded,@"symbols":symbols,@"classes":out,
             @"scope":@"Local-process runtime metadata, not WindowManager daemon memory; symbol presence is not capability."};
}
static int fixture(NSString *destination, NSString *label) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
    for (int i=0;i<2;i++) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(260+i*55,220+i*55,420,260)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        w.title = [NSString stringWithFormat:@"Nearpane Route A %@ %d", label,i+1];
        w.releasedWhenClosed = NO;
        w.backgroundColor = i ? NSColor.systemTealColor : NSColor.systemOrangeColor;
        NSTextField *text = [NSTextField labelWithString:w.title]; text.frame=NSMakeRect(24,100,370,50);
        text.font=[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
        [w.contentView addSubview:text]; [w makeKeyAndOrderFront:nil]; [windows addObject:w];
    }
    [NSApp activateIgnoringOtherApps:YES];
    void (^write)(void) = ^{
        NSMutableArray *items=[NSMutableArray array];
        for(NSWindow *w in windows) [items addObject:@{@"id":@(w.windowNumber),@"frame":rect(w.frame),
            @"visible":@(w.visible),@"key":@(w.keyWindow),@"minimized":@(w.miniaturized)}];
        NSDictionary *r=@{@"pid":@(getpid()),@"label":label,@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"windows":items};
        NSData *data=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:NULL];
        [data writeToFile:destination options:NSDataWritingAtomic error:NULL];
    };
    write();
    [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[destination stringByAppendingString:@".stop"]]) [NSApp terminate:nil];
        write();
    }];
    [NSApp run]; return 0;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc<2) return 2;
        NSString *command=@(argv[1]);
        if([command isEqual:@"snapshot"]) emit(snapshot());
        else if([command isEqual:@"inventory"]) emit(inventory());
        else if([command isEqual:@"preferences"]) {
            NSMutableDictionary *values=[NSMutableDictionary dictionary];
            for(NSString *key in @[@"GloballyEnabled",@"AutoHide",@"LeftStripMaximumRowCount"])
                values[key]=CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,
                    CFSTR("com.apple.WindowManager"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) ?: NSNull.null;
            emit(values);
        } else if([command isEqual:@"set-preferences"] && argc==3) {
            NSData *data=[NSData dataWithContentsOfFile:@(argv[2])];
            NSDictionary *values=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
            NSSet *allowed=[NSSet setWithArray:@[@"GloballyEnabled",@"AutoHide",@"LeftStripMaximumRowCount"]];
            if(![values isKindOfClass:NSDictionary.class]) return 2;
            for(NSString *key in values) if(![allowed containsObject:key]) return 2;
            for(NSString *key in values) {
                id value=values[key];
                CFPreferencesSetValue((__bridge CFStringRef)key,value==NSNull.null ? NULL:(__bridge CFPropertyListRef)value,
                    CFSTR("com.apple.WindowManager"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
            }
            BOOL ok=CFPreferencesSynchronize(CFSTR("com.apple.WindowManager"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
            emit(@{@"synchronized":@(ok)}); if(!ok) return 1;
        }
        else if([command isEqual:@"fixture"] && argc==4) return fixture(@(argv[2]),@(argv[3]));
        else if([command isEqual:@"activate"] && argc==3) {
            NSRunningApplication *a=[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
            emit(@{@"accepted":@([a activateWithOptions:NSApplicationActivateIgnoringOtherApps])});
        } else if([command isEqual:@"move-pointer"] && argc==4) {
            CGPoint p=CGPointMake(atof(argv[2]),atof(argv[3]));
            if(!isfinite(p.x)||!isfinite(p.y)) return 2;
            CGEventRef e=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,p,kCGMouseButtonLeft);
            if(!e) return 2;
            CGEventPost(kCGHIDEventTap,e); CFRelease(e);
            emit(@{@"posted":@YES,@"requested":@[@(p.x),@(p.y)]});
        } else return 2;
        return 0;
    }
}
