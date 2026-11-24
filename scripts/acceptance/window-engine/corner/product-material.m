// Link the reviewed product archive into the normal signed QA observer. The only request has
// no window, group, Guardian, fixture permit or qualified handle. No pixels are returned.
#import <AppKit/AppKit.h>
#import <unistd.h>
#import "nearpane_window_engine.h"
#import "nearpane_host_scope.h"
#import "scope_binding.h"
#import "patch_sheet.h"
#import "scene-picture.h"

static NSDictionary *ordinaryDisplay(void) {
    CGDirectDisplayID active[2]; uint32_t n = 0;
    if (CGGetActiveDisplayList(2, active, &n) != kCGErrorSuccess || n != 1 || CGDisplayIsInMirrorSet(active[0])) return nil;
    CFUUIDRef identifier = CGDisplayCreateUUIDFromDisplayID(active[0]);
    if (!identifier) return nil;
    NSString *display = CFBridgingRelease(CFUUIDCreateString(NULL, identifier));
    CFRelease(identifier);
    int32_t connection = 0, error = 0;
    NSArray *rows = CFBridgingRelease(np_host_scope_copy_managed(&connection, &error));
    if (error || rows.count != 1) return nil;
    NSDictionary *row = rows.firstObject; NSString *token = row[@"Display Identifier"];
    uint64_t direct = np_host_scope_direct(connection, (__bridge CFStringRef)token, &error);
    NSDictionary *home = nc_bound_scope(row, display, [nc_single_main_uuid(rows.count).UUIDString isEqual:display], direct, nil);
    if (error || !direct || ![home[@"native"] isEqual:@(direct)] || !nc_uuid(home[@"space"])) return nil;
    return @{@"display":display, @"space":home[@"space"], @"native":@(direct)};
}

bool NPCornerObserverMatchesHome(CFStringRef display, CFStringRef space, uint64_t native) {
    NSDictionary *home = ordinaryDisplay();
    return native && [home[@"native"] isEqual:@(native)] &&
        [nc_uuid(home[@"display"]) isEqual:nc_uuid((__bridge NSString *)display)] &&
        [nc_uuid(home[@"space"]) isEqual:nc_uuid((__bridge NSString *)space)];
}

static NSDictionary *observe(uint64_t handle, NSDictionary *home, NSUUID *nonce) {
    NSMutableDictionary *record = [@{@"challenge":nonce.UUIDString, @"status":@"UNKNOWN"} mutableCopy];
    NPRequest request = {.size=sizeof(NPRequest), .version=NP_ENGINE_ABI, .backend=NP_CORNER,
        .operation=NP_CORNER_DISPLAY_MATERIAL, .timeout_ms=4000, .native_id=[home[@"native"] unsignedLongLongValue]};
    [nc_uuid(home[@"display"]) getUUIDBytes:request.display]; [nc_uuid(home[@"space"]) getUUIDBytes:request.native_space];
    [nonce getUUIDBytes:request.intent];
    uint64_t ticket = 0;
    uint32_t code = np_engine_epoch(handle, &request.epoch);
    if (code == NP_OK) code = np_engine_submit(handle, &request, &ticket);
    NPReceipt receipt = {.size=sizeof(NPReceipt), .version=NP_ENGINE_ABI};
    if (code == NP_OK) {
        NSTimeInterval limit = NSProcessInfo.processInfo.systemUptime + 6;
        do {
            code = np_engine_poll(handle, ticket, &receipt);
            if (code == NP_PENDING) usleep(10000);
        } while (code == NP_PENDING && NSProcessInfo.processInfo.systemUptime < limit);
    }
    record[@"transport"] = @(code);
    if (code == NP_OK) {
        record[@"nativeStatus"] = @(receipt.status); record[@"nativeDetail"] = @(receipt.detail);
        record[@"flags"] = @(receipt.flags); record[@"owned"] = @(receipt.owned); record[@"elapsedNS"] = @(receipt.elapsed_ns);
        record[@"shadowFootprint"] = @[@(receipt.frame.x), @(receipt.frame.y), @(receipt.frame.width), @(receipt.frame.height)];
        if (receipt.status == NP_PASS && receipt.native_id == request.native_id &&
            !memcmp(receipt.intent,request.intent,16) && receipt.epoch == request.epoch && !receipt.flags && !receipt.owned &&
            receipt.detail == NP_CORNER_MATERIAL_WALLPAPER_SURFACE &&
            receipt.frame.width > 0 && receipt.frame.height > 0) record[@"status"] = @"PASS";
        if (receipt.status == NP_UNSUPPORTED) record[@"status"] = @"BLOCKED";
    }
    return record;
}

CFDictionaryRef NPObserveProductCornerMaterial(CFStringRef nonceText) {
    NSMutableDictionary *record = [@{@"scope":@"readOnlyProductCornerMaterial", @"status":@"BLOCKED",
        @"windowWrites":@0, @"inputEvents":@0, @"storedFrames":@0, @"productionQualified":@NO} mutableCopy];
    NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:(__bridge NSString *)nonceText];
    NSDictionary *home = ordinaryDisplay();
    if (!nonce || !home || NSThread.isMainThread) { record[@"reason"] = @"ordinaryDisplay"; return CFBridgingRetain(record); }
    record[@"challenge"] = nonce.UUIDString; record[@"before"] = home;
    record[@"observerScreenCapturePreflight"] = @(CGPreflightScreenCaptureAccess());
    NPConfig config = {.size=sizeof(NPConfig), .version=NP_ENGINE_ABI, .mode=NP_HOST};
    uint64_t handle = 0;
    if (np_engine_create(&config, &handle) != NP_OK) { record[@"reason"] = @"engineCreate"; return CFBridgingRetain(record); }
    NSDictionary *cold = observe(handle, home, nonce);
    record[@"cold"] = cold;
    record[@"status"] = cold[@"status"];
    if ([cold[@"status"] isEqual:@"PASS"] && [ordinaryDisplay() isEqual:home]) {
        NSDictionary *warm = observe(handle, home, NSUUID.UUID);
        record[@"warm"] = warm;
        record[@"status"] = [warm[@"shadowFootprint"] isEqual:cold[@"shadowFootprint"]] &&
            [warm[@"nativeDetail"] isEqual:cold[@"nativeDetail"]] ? warm[@"status"] : @"UNKNOWN";
    } else if ([cold[@"status"] isEqual:@"PASS"]) record[@"status"] = @"UNKNOWN";
    uint32_t closed = np_engine_destroy(handle);
    record[@"handleClosed"] = @(closed == NP_OK);
    NSDictionary *after = ordinaryDisplay(); if (after) record[@"after"] = after;
    if (closed != NP_OK || ![home isEqual:after]) record[@"status"] = @"UNKNOWN";
    return CFBridgingRetain(record);
}

static BOOL coveredMarker(CGWindowID sheet, CGWindowID marker, CGFloat level) {
    NSArray *rows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    BOOL sawSheet = NO;
    for (NSDictionary *row in rows) {
        CGWindowID number = [row[(id)kCGWindowNumber] unsignedIntValue];
        if (number != sheet && number != marker) continue;
        if ([row[(id)kCGWindowOwnerPID] intValue] != getpid() || ![row[(id)kCGWindowAlpha] isEqual:@1]) return NO;
        NSInteger layer = [row[(id)kCGWindowLayer] integerValue];
        if (number == marker) return sawSheet && layer == level;
        if (sawSheet || layer != level + 1) return NO;
        sawSheet = YES;
    }
    return NO;
}

static NSDictionary *observeSheetOrder(CGWindowID sheet) {
    NSMutableData *buffer = [NSMutableData dataWithLength:2048*sizeof(NCListed)];
    NCListed *rows = buffer.mutableBytes;
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    for (NSNumber *visual in @[@YES,@NO]) {
        uint32_t count = 0;
        NCDock dock = {};
        uint32_t code = visual.boolValue ? np_corner_visual_zorder(rows,2048,&count,&dock) :
                                          np_corner_zorder(rows,2048,&count,&dock);
        NSString *key = visual.boolValue ? @"visual" : @"input";
        NSMutableDictionary *values = [@{@"detail":@(code)} mutableCopy];
        if (!code) for (unsigned i=0; i<count; i++) if (rows[i].window == sheet && rows[i].pid == getpid())
            values[@"opacity"] = @(rows[i].alpha);
        read[key] = values;
    }
    read[@"status"] = !read[@"visual"][@"opacity"] || !read[@"input"][@"opacity"] ? @"UNKNOWN" :
        ([read[@"visual"][@"opacity"] isEqual:@1] && [read[@"input"][@"opacity"] isEqual:@0] ? @"PASS" : @"FAIL");
    return read;
}

// Both modes use the product sheet below ordinary windows. The occlusion control
// adds one small colored window owned by the observer underneath that sheet.
CFDictionaryRef NPObserveProductCornerPanel(CFStringRef nonceText, bool occlusion) {
    NSMutableDictionary *record = [@{@"scope":@"ownNonactivatingMaterialPanel",@"status":@"BLOCKED",
        @"thirdPartyWindowWrites":@0,@"inputEvents":@0,@"nativeSpaceWrites":@0,@"storedFrames":@0,
        @"singleWindowIsolation":@"NOT_RUN",@"productionQualified":@NO} mutableCopy];
    NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:(__bridge NSString *)nonceText];
    NSDictionary *home = ordinaryDisplay();
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (NSThread.isMainThread || !nonce || !home || !front || !CGPreflightScreenCaptureAccess())
        return CFBridgingRetain(record);
    record[@"challenge"] = nonce.UUIDString;
    record[@"before"] = home;
    record[@"foregroundPID"] = @(front.processIdentifier);
    record[@"observerPID"] = @(getpid());
    NPConfig config = {.size=sizeof(NPConfig), .version=NP_ENGINE_ABI, .mode=NP_HOST};
    uint64_t handle = 0;
    if (np_engine_create(&config, &handle) != NP_OK) return CFBridgingRetain(record);
    NSDictionary *geometry = observe(handle, home, nonce);
    record[@"material"] = geometry;
    if (np_engine_destroy(handle) != NP_OK || ![geometry[@"status"] isEqual:@"PASS"]) return CFBridgingRetain(record);
    NSArray *a = geometry[@"shadowFootprint"];
    NCFrame area = {[a[0] doubleValue],[a[1] doubleValue],[a[2] doubleValue],[a[3] doubleValue]};
    NCMember subject = {.native=[home[@"native"] unsignedLongLongValue]};
    [nc_uuid(home[@"display"]) getUUIDBytes:subject.display];
    [nc_uuid(home[@"space"]) getUUIDBytes:subject.space];
    void *store = np_corner_patch_material();
    if (!store) return CFBridgingRetain(record);
    uint32_t material = np_corner_patch_prepare_source(store, &subject, area, true);
    __block NSPanel *panel = nil, *marker = nil;
    NSWindowLevel floor = CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
    uint32_t hid[13], finalHID[13];
    np_corner_inputs(hid);
    if (material == NP_CORNER_MATERIAL_WALLPAPER_SURFACE) dispatch_sync(dispatch_get_main_queue(), ^{
        if (![front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication] || ![ordinaryDisplay() isEqual:home]) return;
        panel = np_corner_material_panel(store, &subject, area);
        if (!panel) return;
        panel.level = floor + (occlusion ? 1 : 0);
        [panel orderBack:nil];
        [panel displayIfNeeded];
        if (occlusion) {
            NSRect rect = NSMakeRect(NSMidX(panel.frame)-8, NSMidY(panel.frame)-8, 16, 16);
            marker = [[NSPanel alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
                backing:NSBackingStoreBuffered defer:NO];
            marker.level = floor;
            marker.backgroundColor = NSColor.magentaColor;
            marker.opaque = YES;
            marker.hasShadow = NO;
            marker.ignoresMouseEvents = YES;
            marker.hidesOnDeactivate = NO;
            marker.releasedWhenClosed = NO;
            marker.collectionBehavior = NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
            [marker orderBack:nil];
            [marker displayIfNeeded];
        }
    });
    np_corner_patch_material_end(store);
    if (!panel) return CFBridgingRetain(record);
    __block CGWindowID number = 0, markerID = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        number = (CGWindowID)panel.windowNumber;
        if (marker) markerID = (CGWindowID)marker.windowNumber;
    });
    record[@"panelID"] = @(number);
    NSMutableArray *samples = [NSMutableArray array];
    for (unsigned i = 0; i < 2; i++) {
        usleep(80000);
        if (occlusion) {
            record[@"scope"] = @"ownMarkerUnderLinkedSheet";
            record[@"markerID"] = @(markerID);
            CGRect region = CGRectMake(area.x,area.y,area.w,area.h);
            NCSceneWindow leaf = {markerID,getpid(),ncg_birth(getpid(),NULL),
                CGRectMake(CGRectGetMidX(region)-8,CGRectGetMidY(region)-8,16,16)};
            np_corner_inputs(finalHID);
            if (!markerID || memcmp(hid,finalHID,sizeof(hid)) || ![ordinaryDisplay() isEqual:home] ||
                ![front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication] || !coveredMarker(number,markerID,floor)) {
                [samples addObject:@{@"status":@"UNKNOWN",@"reason":@"scopeOrWindowOrderChangedBeforeSample"}];
                break;
            }
            __block NSDictionary *reading = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{ reading = readCornerScene(CGMainDisplayID(),region,number,&leaf,1,nil); });
            NSMutableDictionary *row = [reading mutableCopy];
            row[@"engineOrder"] = observeSheetOrder(number);
            if ([row[@"status"] isEqual:@"PASS"] && ![row[@"engineOrder"][@"status"] isEqual:@"PASS"]) {
                row[@"status"] = row[@"engineOrder"][@"status"];
                row[@"reason"] = @"engineSheetOpacityOrInputClassification";
            }
            np_corner_inputs(finalHID);
            if (memcmp(hid,finalHID,sizeof(hid)) || ![ordinaryDisplay() isEqual:home] ||
                ![front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication] || !coveredMarker(number,markerID,floor)) {
                row[@"status"] = @"UNKNOWN";
                row[@"reason"] = @"scopeOrWindowOrderChangedDuringSample";
            }
            [samples addObject:row];
            if (![row[@"status"] isEqual:@"PASS"]) break;
            continue;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NCCornerPicture result = NCCornerPictureUnavailable;
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        dispatch_async(dispatch_get_main_queue(), ^{
            np_corner_compare_panel(panel, subject, area, ^(NCCornerPicture outcome) {
                result = outcome;
                dispatch_semaphore_signal(done);
            });
        });
        BOOL returned = !dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        NSString *status = !returned || result == NCCornerPictureUnavailable ? @"UNKNOWN" :
                           result == NCCornerPictureMatch ? @"PASS" : @"FAIL";
        [samples addObject:@{@"status":status, @"startedNS":@(began), @"endedNS":@(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))}];
        if (![status isEqual:@"PASS"]) break;
    }
    record[@"samples"] = samples;
    record[@"status"] = [samples.lastObject objectForKey:@"status"];
    dispatch_sync(dispatch_get_main_queue(), ^{
        [marker orderOut:nil];
        [marker close];
        [panel orderOut:nil];
        [panel close];
    });
    NSMutableArray *closeReads = [NSMutableArray array];
    unsigned absent = 0;
    for (unsigned attempt = 0; attempt < 30 && absent < 2; attempt++) {
        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
        BOOL visible = NO;
        for (NSDictionary *w in list) {
            CGWindowID seen = [w[(id)kCGWindowNumber] unsignedIntValue];
            if ((seen == number || (markerID && seen == markerID)) && [w[(id)kCGWindowOwnerPID] intValue] == getpid()) {
                visible = YES; break;
            }
        }
        absent = list && !visible ? absent + 1 : 0;
        [closeReads addObject:@{@"timeNS":@(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
                                @"observed":@(list != nil),@"onscreen":@(visible)}];
        if (absent < 2) usleep(25000);
    }
    BOOL removed = absent == 2;
    record[@"closeReads"] = closeReads;
    record[@"panelGone"] = @(removed);
    record[@"sameForegroundProcess"] = @([front isEqual:NSWorkspace.sharedWorkspace.frontmostApplication]);
    NSDictionary *after = ordinaryDisplay();
    if (after) record[@"after"] = after;
    if (!removed || ![record[@"sameForegroundProcess"] boolValue] || ![after isEqual:home]) record[@"status"] = @"UNKNOWN";
    return CFBridgingRetain(record);
}
