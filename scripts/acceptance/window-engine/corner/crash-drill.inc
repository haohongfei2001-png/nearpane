// Included by this disposable signed controller. The system under test is the separately signed Guardian.
static void persistPacket(int fd, NSFileHandle *pipe, const NCGuardianEntry *entry) {
    require(write(fd, entry, sizeof(*entry)) == (ssize_t)sizeof(*entry) && fsync(fd) == 0,
            @"fixtureGuardianJournalFsync");
    NSData *bytes = [NSData dataWithBytes:entry length:sizeof(*entry)];
    NSError *err = nil;
    require([pipe writeData:bytes error:&err], @"fixtureGuardianPipeWrite");
}
static void waitAck(NSFileHandle *receiver, char expected, NSTask *task) {
    double deadline = NSProcessInfo.processInfo.systemUptime + 6;
    struct pollfd p = {.fd = receiver.fileDescriptor, .events = POLLIN};
    while (NSProcessInfo.processInfo.systemUptime < deadline && task.running) {
        if (poll(&p, 1, 0) > 0) {
            char ack = 0;
            require(read(p.fd, &ack, 1) == 1 && ack == expected, @"guardianDeclinedActualPreOrPostimage");
            return;
        }
        pauseFor(.015);
    }
    stop(@"BLOCKED", @"guardianReplyOrSeparateAccessibilityPermissionUnavailable");
}
static void crashHost(NSString *kit, NPRequest r) {
    r.operation = NP_HIDE;
    r.timeout_ms = 4000;
    r.epoch = epoch;
    [NSUUID.UUID getUUIDBytes:r.intent];
    NCGuardianEntry pre = {
        .version = 1, .phase = NCG_PREPARE, .host = getpid(), .host_birth = ncg_birth(getpid(), NULL), .lease = r};
    np_corner_inputs(pre.hid);
    int journal = open([output stringByAppendingPathComponent:@"guardian-ledger.bin"].fileSystemRepresentation,
                       O_CREAT | O_EXCL | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    require(journal >= 0, @"exclusiveFixtureLedgerUnavailable");
    NSPipe *input = [NSPipe pipe], *reply = [NSPipe pipe];
    (void)fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);
    NSTask *guardian = [NSTask new];
    guardian.executableURL = [NSURL fileURLWithPath:[kit stringByAppendingPathComponent:@"guardian"]];
    guardian.arguments = @[ kit, output ];
    guardian.standardInput = input;
    guardian.standardOutput = reply;
    BOOL owed = NO;
    @try {
        require([guardian launchAndReturnError:NULL], @"separatelySignedGuardianLaunchFailed");
        persistPacket(journal, input.fileHandleForWriting, &pre);
        waitAck(reply.fileHandleForReading, 'R', guardian);
        NPReceipt parked = requestID(r, NP_HIDE, r.intent);
        owed = (parked.flags & NP_OWNED) != 0;
        NCGuardianEntry sealed = pre;
        sealed.phase = NCG_CONFIRMED;
        sealed.result = parked;
        np_corner_inputs(sealed.hid);
        require(ncg_correlates(&pre, &sealed), @"issuedHideOrUnchangedHIDNotConfirmed");
        NSArray *sample = owners();
        require(closeFrame(window(sample, r)[@"frame"], unpack(parked.frame)) &&
                    closeFrame(cgFrame(@(r.window), @(r.pid)), unpack(parked.frame)),
                @"independentOwnerDidNotSeeParkedPostimage");
        persistPacket(journal, input.fileHandleForWriting, &sealed);
        waitAck(reply.fileHandleForReading, 'P', guardian);
        result[@"crashIntent"] = @{
            @"intent" : [[NSUUID alloc] initWithUUIDBytes:r.intent].UUIDString,
            @"hostPID" : @(getpid()),
            @"hostBirth" : @(pre.host_birth),
            @"guardianPID" : @(guardian.processIdentifier),
            @"fixturePID" : @(r.pid),
            @"fixtureBirth" : @(r.birth),
            @"window" : @(r.window),
            @"frame" : unpack(r.frame),
            @"postimage" : unpack(parked.frame)
        };
        save();
        // Only this explicitly created sacrificial controller terminates. The external fixture owners,
        // the recovery worker and the observing supervisor all remain alive.
        kill(getpid(), SIGKILL);
        stop(@"UNKNOWN", @"selfTerminationNotDelivered");
    } @finally {
        [input.fileHandleForWriting closeFile];
        if (owed) {
            NPReceipt clean = request(r, NP_RESTORE);
            result[@"hostCompensation"] = @(clean.status);
        }
        close(journal);
    }
}
static NSDictionary *readJSON(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[output stringByAppendingPathComponent:name]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static void witnessCrash(NSString *kit) {
    NSString *exe = [kit stringByAppendingPathComponent:@"controller"];
    require(ncg_hash(getpid(), exe, @"com.holdsnow.nearpane.engine-fixture").length > 0,
            @"signedSupervisorUnavailable");
    NSTask *sacrificial = [NSTask new];
    sacrificial.executableURL = [NSURL fileURLWithPath:exe];
    sacrificial.arguments = @[ kit, output, @"--crash-host" ];
    require([sacrificial launchAndReturnError:NULL], @"sacrificialSignedHostLaunchFailed");
    pid_t original = sacrificial.processIdentifier;
    uint64_t birth = ncg_birth(original, NULL);
    require(birth && ncg_hash(original, exe, @"com.holdsnow.nearpane.engine-fixture").length > 0,
            @"originalSignedHostGenerationUnknown");
    double end = NSProcessInfo.processInfo.systemUptime + 35;
    while (sacrificial.running && NSProcessInfo.processInfo.systemUptime < end)
        pauseFor(.035);
    require(!sacrificial.running, @"originalHostStillRunning");
    result[@"hostTermination"] = @(sacrificial.terminationStatus);
    NSDictionary *state = readJSON(@"crash-host.json"), *intent = state[@"crashIntent"];
    if (!intent) {
        result[@"hostPreparationReason"] = state[@"reason"] ?: @"reasonUnavailable";
        stop(@"BLOCKED", @"fixtureHostDidNotArmGuardian");
    }
    require(sacrificial.terminationReason == NSTaskTerminationReasonUncaughtSignal &&
                sacrificial.terminationStatus == SIGKILL && [intent[@"hostPID"] intValue] == original &&
                [intent[@"hostBirth"] unsignedLongLongValue] == birth,
            @"authorizedOriginalHostCrashUnconfirmed");
    end = NSProcessInfo.processInfo.systemUptime + 10;
    NSDictionary *receipt = nil;
    while (!(receipt = readJSON(@"guardian-receipt.json")) && NSProcessInfo.processInfo.systemUptime < end)
        pauseFor(.025);
    result[@"guardian"] = receipt ?: @{};
    if (![receipt[@"status"] isEqual:@"PASS"])
        stop(@"UNKNOWN", @"separateGuardianDidNotVerifyRestore");
    BOOL authorized =
        [receipt[@"intent"] isEqual:intent[@"intent"]] && [receipt[@"trustedHostPID"] intValue] == original &&
        [receipt[@"trustedHostBirth"] unsignedLongLongValue] == birth &&
        [receipt[@"guardianPID"] isEqual:intent[@"guardianPID"]] &&
        [receipt[@"pid"] isEqual:intent[@"fixturePID"]] && [receipt[@"birth"] isEqual:intent[@"fixtureBirth"]] &&
        [receipt[@"window"] isEqual:intent[@"window"]] && [receipt[@"issued"] isEqual:@1] &&
        [receipt[@"originalFrameReadbacks"] isEqual:@2] && [receipt[@"originalPipeEOF"] isEqual:@YES] &&
        [receipt[@"kernelHostExit"] isEqual:@YES] && [receipt[@"sameRetainedWindow"] isEqual:@YES];
    require(authorized && [scope() isEqual:state[@"nativeScope"]], @"independentGuardianReceiptNotCorrelated");
    NPRequest originalWindow = {.pid = [intent[@"fixturePID"] intValue],
                                .birth = [intent[@"fixtureBirth"] unsignedLongLongValue],
                                .window = [intent[@"window"] unsignedIntValue],
                                .frame = rect(intent[@"frame"])};
    NSArray *initial = state[@"baseline"], *returned = owners();
    require(ncg_birth(originalWindow.pid, NULL) == originalWindow.birth &&
                ncg_fixture_hash(originalWindow.pid, kit).length && noChange(initial, returned, 0, YES) &&
                closeFrame(cgFrame(@(originalWindow.window), @(originalWindow.pid)), intent[@"frame"]),
            @"independentOwnerOrSiblingGeometryAfterRealCrashChanged");
    require(positive(originalWindow, 0), @"restoredOriginalWindowDidNotReceiveWholeClick");
    result[@"status"] = @"PASS";
    result[@"processCrashAndRelaunch"] = @"SIGKILL_RETAINED_REFERENCE_RECOVERY_PASS";
    result[@"originalWindowClickReceived"] = @YES;
    result[@"productionInstalledGuardian"] = @"NOT_RUN";
    result[@"previousOwnerPIDs"] = @[ initial[0][@"pid"], initial[1][@"pid"] ];
    result[@"previousOwnerBirths"] = @[ initial[0][@"birth"], initial[1][@"birth"] ];
}
