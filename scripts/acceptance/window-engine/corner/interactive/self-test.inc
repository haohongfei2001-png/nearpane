static NPInputWitness *trial(BOOL key) {
    return [[NPInputWitness alloc] initWithIntent:NSUUID.UUID source:42 slot:0 keyboard:key now:1];
}
static void input(NPInputWitness *w, NPInputPhase phase, unsigned slot, NPReceiver stream) {
    [w receive:phase from:42 tag:w.tag slot:slot stream:stream now:2 markerMatches:YES];
}
static void route(NPInputWitness *w, unsigned slot, NPReceiver stream) {
    if (w.keyboard) {
        input(w,NPKeyDown,slot,stream); input(w,NPKeyUp,slot,stream);
    } else {
        input(w,NPDown,slot,stream); input(w,NPDrag,slot,stream); input(w,NPUp,slot,stream);
    }
}
// A real named Darwin socket is required: an unnamed socketpair need not have a peer address.
// Verify that the fixture has a real, resolvable audit token and that it cannot pass the Host predicate.
static void testLocalTransport(NSMutableDictionary *checks) {
    char work[] = "/private/tmp/nearpane-interactive-selftest.XXXXXXXX";
    BOOL image = NO, denied = NO, transfer = NO;
    if (mkdtemp(work)) {
        struct sockaddr_un addr = {.sun_family=AF_UNIX};
        snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/sock",work); addr.sun_len = SUN_LEN(&addr);
        int listener = socket(AF_UNIX,SOCK_STREAM,0), client = socket(AF_UNIX,SOCK_STREAM,0), peer = -1;
        if (listener >= 0 && client >= 0 && !bind(listener,(struct sockaddr *)&addr,addr.sun_len) && !listen(listener,1) &&
            !connect(client,(struct sockaddr *)&addr,addr.sun_len)) peer = accept(listener,NULL,NULL);
        if (peer >= 0) {
            char ownPath[PROC_PIDPATHINFO_MAXSIZE];
            NSDictionary *identity = proc_pidpath(getpid(),ownPath,sizeof(ownPath)) > 0 ? verifiedPeerImage(peer,@(ownPath),fixtureID) : nil;
            image = [identity[@"pid"] intValue] == getpid() && [identity[@"birth"] unsignedLongLongValue] == processBirth(getpid());
            denied = !authenticatedHost(peer);
            char buf[128] = {};
            transfer = sendReply(peer,@{@"testCase":@1}) && recv(client,buf,sizeof(buf),0) > 0 && !strcmp(buf,"{\"testCase\":1}\n");
        }
        if (peer >= 0) close(peer);
        if (listener >= 0) close(listener);
        if (client >= 0) close(client);
        unlink(addr.sun_path); rmdir(work);
    }
    checks[@"realSocketAuditTokenAndSignedPeerResolved"] = @(image);
    checks[@"realSocketFixtureCannotImpersonateHost"] = @(denied && image);
    checks[@"realBoundedSocketResponse"] = @(transfer);
}
static int offlineTests(void) {
    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    NPInputWitness *m = trial(NO);
    checks[@"zeroEventsUnknown"] = @([[m resultAt:2][@"status"] isEqual:@"UNKNOWN"]);
    route(m,0,NPQueue);
    checks[@"queueWithoutResponderUnknown"] = @([[m resultAt:2][@"status"] isEqual:@"UNKNOWN"]);
    route(m,0,NPContent);
    checks[@"matchingMouseSequence"] = @([[m resultAt:2][@"status"] isEqual:@"PASS"]);
    checks[@"expiredNeverPasses"] = @([[m resultAt:8][@"reason"] isEqual:@"intentExpired"]);
    input(m,NPUp,1,NPContent);
    checks[@"siblingContaminationFails"] = @([[m resultAt:2][@"status"] isEqual:@"FAIL"]);
    m = trial(NO); input(m,NPDrag,0,NPQueue); route(m,0,NPQueue); route(m,0,NPContent);
    checks[@"outOfOrderFails"] = @([[m resultAt:2][@"status"] isEqual:@"FAIL"]);
    m = trial(NO); input(m,NPDown,0,NPQueue); input(m,NPUp,0,NPQueue);
    checks[@"missingDragFails"] = @([[m resultAt:2][@"status"] isEqual:@"FAIL"]);
    m = trial(NO); route(m,1,NPQueue); route(m,1,NPContent);
    checks[@"onlySiblingFails"] = @([[m resultAt:2][@"status"] isEqual:@"FAIL"]);
    m = trial(NO); route(m,0,NPQueue); route(m,0,NPContent);
    [m receive:NPDown from:43 tag:m.tag slot:0 stream:NPQueue now:2 markerMatches:YES];
    checks[@"differentSourceInterrupts"] = @([[m resultAt:2][@"reason"] isEqual:@"sourceOrInputInterrupted"]);
    m = trial(NO); route(m,0,NPQueue); route(m,0,NPContent);
    [m receive:NPDown from:42 tag:m.tag ^ 1 slot:0 stream:NPQueue now:2 markerMatches:YES];
    checks[@"wrongTagInterrupts"] = @([[m resultAt:2][@"status"] isEqual:@"UNKNOWN"]);
    NPInputWitness *k = trial(YES); route(k,0,NPQueue); route(k,0,NPContent);
    checks[@"uniqueMarkerExactBothStreams"] = @(k.marker.length == 36 && ![k.marker isEqual:trial(YES).marker] &&
                                                 [[k resultAt:2][@"status"] isEqual:@"PASS"]);
    NSString *result = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:[k resultAt:2] options:0 error:NULL]
                                              encoding:NSUTF8StringEncoding];
    checks[@"noMarkerTextInStoredResult"] = @(result && ![result containsString:k.marker]);
    k = trial(YES); [k receive:NPKeyDown from:42 tag:k.tag slot:0 stream:NPContent now:2 markerMatches:NO];
    checks[@"wrongKeyboardMarkerFails"] = @([[k resultAt:2][@"status"] isEqual:@"FAIL"]);
    NSString *uuid = NSUUID.UUID.UUIDString.lowercaseString, *display = NSUUID.UUID.UUIDString, *space = NSUUID.UUID.UUIDString;
    NSDictionary *open = @{@"challenge":uuid, @"seq":@1, @"op":@"open", @"displayUUID":display, @"spaceUUID":space, @"nativeID":@7};
    NSMutableDictionary *bad = open.mutableCopy; bad[@"pid"] = @8;
    checks[@"rejectArbitraryWindowPIDAndPastSeq"] = @(!exactKeys(bad,@[@"displayUUID",@"spaceUUID",@"nativeID"]) &&
                                                      !headerOK(open,uuid,2) && !headerOK(open,space,1));
    NSDictionary *peer = @{@"pid":@42,@"birth":@902,@"cdhash":@"test-hash",@"securitySession":@3};
    NSMutableDictionary *subject = peer.mutableCopy;
    [subject addEntriesFromDictionary:@{@"identifier":hostID, @"teamIdentifier":@"ZB9D4T66QB", @"kernelExecutable":hostBinary,
                                         @"atDailyInstallPath":@YES, @"sourceState":@"clean"}];
    NSMutableDictionary *scope = [@{@"status":@"PASS", @"displayUUID":display, @"spaceUUID":space, @"nativeID":@7} mutableCopy];
    NSMutableDictionary *s = [@{@"hostPID":@42, @"hostBirth":@902, @"startedUptimeNS":@1, @"endedUptimeNS":@2,
        @"session":@{@"securitySessionID":@3,@"qualified":@YES}, @"display":@{@"topologyConfirmed":@YES,@"activeCGCount":@1},
        @"ordinaryIdentity":@{@"status":@"PASS"},@"directCurrent":@7,@"directCurrentAfter":@7} mutableCopy];
    NSMutableDictionary *s2 = s.mutableCopy; s2[@"startedUptimeNS"] = @3; s2[@"endedUptimeNS"] = @4;
    NSDictionary *pre = @{@"challenge":uuid,@"subject":subject,@"permissions":@{@"accessibility":@YES,@"listenEvent":@YES},
        @"system":@{@"build":@"26A428",@"sip":@{@"enabled":@YES}},@"spaceScope":@{@"scope":scope,@"readOnly":@YES,@"samples":@[s,s2]}};
    checks[@"twoFreshOrdinaryHostSamples"] = @(ordinaryHostPreflight(pre,peer,open,5));
    checks[@"stalePhysicalScopeRejected"] = @(!ordinaryHostPreflight(pre,peer,open,13*NSEC_PER_SEC));
    s2[@"directCurrentAfter"] = @8;
    checks[@"spaceChangedRejected"] = @(!ordinaryHostPreflight(pre,peer,open,5));
    s2[@"directCurrentAfter"] = @7;
    subject[@"birth"] = @903;
    checks[@"changedHostBirthRejected"] = @(!ordinaryHostPreflight(pre,peer,open,5));
    subject[@"birth"] = @902; scope[@"status"] = @"BLOCKED";
    checks[@"fullscreenPreflightCannotOpen"] = @(!ordinaryHostPreflight(pre,peer,open,5));
    scope[@"status"] = @"PASS";
    NSMutableDictionary *denied = pre.mutableCopy; denied[@"permissions"] = @{};
    checks[@"missingHostAccessRefusedBeforeAppKit"] = @(!ordinaryHostPreflight(denied,peer,open,5));
    char dirName[] = "/private/tmp/nearpane-lease-selftest.XXXXXXXX";
    if (mkdtemp(dirName)) {
        int dir = privateDirectory(@(dirName));
        if (dir >= 0) {
            BOOL clear = !engineStillOwns(dir,uuid);
            int hold = openat(dir,"interactive-lease",O_CREAT|O_EXCL|O_WRONLY,0600);
            if (hold >= 0) close(hold);
            BOOL retained = engineStillOwns(dir,uuid);
            int release = openat(dir,"interactive-release",O_CREAT|O_EXCL|O_WRONLY,0600);
            BOOL partial = engineStillOwns(dir,uuid);
            if (release >= 0) {
                (void)write(release,uuid.UTF8String,36); (void)fsync(release); close(release);
            }
            BOOL released = !engineStillOwns(dir,uuid) && engineStillOwns(dir,NSUUID.UUID.UUIDString.lowercaseString);
            checks[@"crashAfterClaimPreservesOwnedWindowsUntilExactRelease"] = @(clear && retained && partial && released);
            unlinkat(dir,"interactive-release",0); unlinkat(dir,"interactive-lease",0); close(dir);
        }
        rmdir(dirName);
    }
    testLocalTransport(checks);
    SecCodeRef self = NULL;
    NSString *digest = nil;
    if (!SecCodeCopySelf(0,&self)) { digest = codeHash(self,fixtureID); CFRelease(self); }
    checks[@"liveSignedFixtureCodeReadback"] = @(digest.length == 40);
    for (NSString *name in checks.allKeys) checks[name] = [checks[name] boolValue] ? @YES : @NO;
    BOOL pass = ![checks.allValues containsObject:@NO] && !owned && NSApp == nil;
    NSDictionary *out = @{@"schema":@1,@"status":pass ? @"PASS":@"FAIL", @"checks":checks,@"cdhash":digest ?: @"",
        @"windowCount":@(owned.count),@"appKitApplicationInitialized":NSApp ? @YES : @NO, @"processBirth":@(processBirth(getpid())),
        @"physicalMouseKeyboardDelivery":@"NOT_RUN",@"launchServicesOpen":@"NOT_RUN",@"stageHideShow":@"NOT_RUN"};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:NULL];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:encoded];
    return pass ? 0 : 4;
}
