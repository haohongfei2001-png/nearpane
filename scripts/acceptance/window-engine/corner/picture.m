// Signed disposable fixtures only. No wallpaper files, full-screen capture or saved images.
#import "picture.h"
#import "scene-picture.h"
#import "patch_sheet.h"
static CGRect cg(NCFrame r) { return CGRectMake(r.x, r.y, r.w, r.h); }
static void requirePatch(BOOL ok, NSString *reason) {
    if (!ok)
        @throw [NSException exceptionWithName:@"patch" reason:reason userInfo:nil];
}
static BOOL readWindow(const NPRequest *r, NCSample *sample) {
    NCMember m = {.pid = r->pid, .birth = r->birth, .window = r->window, .native = r->native_id};
    memcpy(m.display, r->display, 16);
    memcpy(m.space, r->native_space, 16);
    return !np_corner_sample(&m, sample) && !sample->minimized && sample->onscreen;
}
static uint32_t realOrder(const NPRequest *a, const NPRequest *b, uint32_t patch, NCFrame frame, BOOL planned) {
    size_t cap = 8192;
    NSMutableData *storage = [NSMutableData dataWithLength:cap * sizeof(NCListed)];
    NCListed *list = storage.mutableBytes;
    uint32_t n = 0, above = 0, found = 0;
    NCDock dock = {0};
    if (np_corner_visual_zorder(list, (uint32_t)cap, &n, &dock))
        return 0;
    for (uint32_t i = 0; i < n; i++) {
        NCListed w = list[i];
        if (w.window == patch && w.pid != getpid()) return 0;
        if (w.window == a->window || (b && w.window == b->window)) {
            const NPRequest *r = w.window == a->window ? a : b;
            if (w.pid != r->pid || w.layer != 0 || w.alpha <= 0 || !CGRectIntersectsRect(cg(w.frame), cg(frame)))
                return 0;
            if (!above)
                above = w.window;
            found++;
        } else if (w.window != patch && w.layer >= CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) && w.alpha > 0 &&
                   CGRectIntersectsRect(cg(w.frame), cg(frame))) {
            if (w.pid != dock.pid || w.layer != 20 || !dock.count)
                return 0;
            for (unsigned j = 0; j < dock.count; j++)
                if (CGRectIntersectsRect(cg(dock.bars[j]), cg(frame)))
                    return 0;
        }
    }
    uint32_t ids[2] = {a->window, b ? b->window : 0}, expected = b ? 2 : 1;
    return found == expected && np_corner_patch_order(list, n, ids, expected, patch, above, frame, planned)
               ? above
               : 0;
}

NSDictionary *nc_fixture_picture(NSString *kit, const NPRequest *a, const NPRequest *b) {
    NSMutableArray *samples = [NSMutableArray array];
    NSMutableDictionary *receipt = [@{@"status":@"BLOCKED", @"samples":samples, @"storedFrames":@0,
        @"panelsCreatedByObserver":@0, @"renderer":@"linkedCornerEngine", @"physicalDisplayPixelComparison":@"NOT_RUN"} mutableCopy];
    @try {
        requirePatch(a && kit && ncg_disposable() && NSThread.isMainThread && CGPreflightScreenCaptureAccess(),
                     @"captureInDisposableFixtureRequired");
        uint32_t hid[13], latest[13], count = 0;
        np_corner_inputs(hid);
        NCDisplay d = {};
        requirePatch(!np_corner_displays(&d,1,&count) && count == 1 && !memcmp(a->display,d.uuid,16) &&
            (!b || (a->window != b->window && !memcmp(b->display,d.uuid,16) && a->native_id == b->native_id &&
                    !memcmp(a->native_space,b->native_space,16))), @"singleBoundOrdinaryDesktopRequired");
        uint32_t members = b ? 2 : 1, ids[] = {a->window,b ? b->window : 0};
        const NPRequest *requests[] = {a,b};
        NCSceneWindow leaves[2] = {};
        NCFrame frames[2] = {}, frame = {};
        for (unsigned i=0; i<members; i++) {
            const NPRequest *r = requests[i];
            NCSample s = {};
            requirePatch(readWindow(r,&s), @"enrolledWindowReadbackUnavailable");
            frames[i] = s.cg;
            leaves[i] = (NCSceneWindow){r->window,r->pid,r->birth,cg(s.cg)};
            requirePatch(sceneSubject(leaves[i],kit), @"signedChildIdentityUnavailable");
        }
        requirePatch(np_corner_patch_bounds(frames,members,d.frame,&frame), @"confirmedSliverRectangleUnavailable");
        uint32_t number = np_corner_patch_visible(ids,members,d.uuid,frame);
        requirePatch(number, @"linkedSheetUnavailable");
        receipt[@"panelID"] = @(number);
        receipt[@"parkedWindows"] = b ? @[@(a->window),@(b->window)] : @[@(a->window)];
        receipt[@"patchFrame"] = @[@(frame.x),@(frame.y),@(frame.w),@(frame.h)];
        receipt[@"status"] = @"UNKNOWN";
        receipt[@"physicalDisplayPixelComparison"] = @"UNKNOWN";
        CGDirectDisplayID display = CGMainDisplayID();
        for (unsigned i=0; i<2; i++) {
            requirePatch(realOrder(a,b,number,frame,NO), @"relativeOrderUnavailable");
            NSDictionary *row = readCornerScene(display,cg(frame),number,leaves,members,kit);
            [samples addObject:row];
            np_corner_inputs(latest);
            NCDisplay current = {};
            requirePatch(!memcmp(hid,latest,sizeof(hid)) && !np_corner_displays(&current,1,&count) && count==1 &&
                !memcmp(d.uuid,current.uuid,16) && CGRectEqualToRect(cg(d.frame),cg(current.frame)) &&
                CGRectEqualToRect(cg(d.visible),cg(current.visible)) && CGMainDisplayID()==display &&
                np_corner_patch_visible(ids,members,d.uuid,frame)==number && realOrder(a,b,number,frame,NO),
                @"scopeInputOrOrderingChanged");
            for (unsigned j=0; j<members; j++) {
                NCSample s = {};
                requirePatch(readWindow(requests[j],&s) && CGRectEqualToRect(cg(s.cg),leaves[j].frame),
                             @"enrolledWindowMovedOrChanged");
            }
            if (![row[@"status"] isEqual:@"PASS"]) {
                receipt[@"status"] = row[@"status"];
                receipt[@"physicalDisplayPixelComparison"] = row[@"status"];
                receipt[@"reason"] = row[@"reason"] ?: @"composedSliverMismatchOrInconclusiveControl";
                return receipt;
            }
        }
        receipt[@"status"] = @"PASS";
        receipt[@"physicalDisplayPixelComparison"] = @"PASS";
        receipt[@"scope"] = @"twoPositiveFilteredDisplayCompositesOfSignedParkedChildren";
    } @catch (NSException *e) {
        receipt[@"reason"] = [e.name isEqual:@"patch"] ? e.reason : @"unexpectedPatchException";
    }
    return receipt;
}
