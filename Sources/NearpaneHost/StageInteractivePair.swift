import AppKit
import Carbon.HIToolbox
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneWindowEngine

@MainActor enum StageInteractivePair {
    typealias JSON = [String: Any]
    typealias Observe = @MainActor (StageEngineHostScope.Fixture?) async throws -> JSON

    struct InputState {
        let secure: Bool
        let hardwareButtons, sessionButtons: UInt32
        var refusal: String? {
            if secure { return "secureEventInputEnabled" }
            if hardwareButtons != 0 || sessionButtons != 0 { return "mouseButtonHeld" }
            return nil
        }
        var evidence: JSON { ["secureEventInput":secure,"hardwareButtonMask":hardwareButtons,"combinedButtonMask":sessionButtons] }
        static func physical() -> Self {
            let before = IsSecureEventInputEnabled()
            var hardware: UInt32 = 0, combined: UInt32 = 0
            for n in UInt32(0)..<32 {
                guard let button = CGMouseButton(rawValue:n) else { return .init(secure:true,hardwareButtons:hardware,sessionButtons:combined) }
                if CGEventSource.buttonState(.hidSystemState, button:button) { hardware |= 1 << n }
                if CGEventSource.buttonState(.combinedSessionState, button:button) { combined |= 1 << n }
            }
            return .init(secure:before || IsSecureEventInputEnabled(),hardwareButtons:hardware,sessionButtons:combined)
        }
        func requireClear() throws {
            if let reason = refusal { throw StagePairRefusal(reason) }
        }
    }
    /// Re-sample at the actual effect boundary, including between down, drag and up.
    static func whileInputClear(_ sample: () -> InputState, perform: () -> Void) throws {
        try sample().requireClear()
        perform()
    }

    static func accepts(_ pre: JSON, _ now: JSON, focus: JSON, beganHID: [UInt32], currentHID: [UInt32]) -> Bool {
        StageEnginePackageProbe.admitsPhysicalScope(preflight: pre, current: now) &&
        (now["permissions"] as? [String: Bool])?["postEvent"] == true && focus["sameOriginalAX"] as? Bool == true &&
        focus["reason"] == nil && beganHID.count == 14 && beganHID == currentHID
    }

    /// The fixture reports both receivers independently at the app queue and their actual content views.
    static func deliveryConfirmed(_ row: JSON, intent: UUID, kind: String, receiver: String, pid: Int32) -> Bool {
        guard (row["intent"] as? String).flatMap(UUID.init(uuidString:)) == intent, row["sourcePID"] as? Int32 == pid,
              row["kind"] as? String == kind, row["receiver"] as? String == receiver,
              row["status"] as? String == "PASS", row["reason"] as? String == "matchingQueueAndContentDelivery",
              ["mouse","key"].contains(kind), ["target","sibling","bystander"].contains(receiver),
              let rows = row["receivers"] as? [JSON], rows.compactMap({ $0["role"] as? String }) == (receiver == "bystander" ? ["bystander"] : ["target","sibling"]),
              rows.count == (receiver == "bystander" ? 1 : 2)
        else { return false }
        return rows.allSatisfy { r in
            guard let app = r["appQueue"] as? NSDictionary, let view = r["contentView"] as? NSDictionary,
                  app.isEqual(view), app["orderConflict"] as? Bool == false, let drags = app["drag"] as? Int else { return false }
            let expected = r["role"] as? String == receiver
            return app["down"] as? Int == (expected ? 1 : 0) && app["up"] as? Int == (expected ? 1 : 0) &&
                (expected && kind == "mouse" ? drags > 0 : drags == 0)
        }
    }

    private static func input(kind: String, receiver: String, peer: StageInteractivePeer, windows: StageInteractiveWindows,
                              systemRoute: Bool = false, current: () throws -> Void) async -> JSON {
        let intent = UUID()
        var row: JSON = ["kind":kind,"receiver":receiver,"intent":intent.uuidString,"status":"BLOCKED","submitted":0,
                         "deliveryRoute":systemRoute ? "WINDOWSERVER_SESSION" : "PID_TARGETED",
                         "physicalHitOrSystemKeyboardRouting":systemRoute ? "UNKNOWN" : "NOT_MEASURED"]
        var count = 0, syntheticDown = false
        let pointer = systemRoute && kind == "mouse" ? CGEvent(source:nil)?.location : nil
        let originalHID = StageCanaryOverview.hid()
        var lastPointer: CGPoint?
        defer {
            if let pointer, let lastPointer, let now = CGEvent(source:nil)?.location,
               abs(now.x-lastPointer.x) < 2, abs(now.y-lastPointer.y) < 2,
               !syntheticDown, StageCanaryOverview.hid() == originalHID, InputState.physical().refusal == nil {
                _ = CGWarpMouseCursorPosition(pointer)
            }
        }
        do {
            guard let owner = peer.image, let slot = windows.rows.firstIndex(where: { $0.row.role == receiver }) else {
                throw StagePairRefusal("unregisteredReceiver")
            }
            try current()
            let first = try StageInteractiveWindows(raw: peer.exchange("sample")["windows"], pid: owner.pid, previous: windows, bystander: peer.isBystander)
            if kind == "key" && !(first.rows[slot].row.key && first.rows[slot].row.firstResponderIsContent) {
                throw StagePairRefusal("registeredWindowHasNoLocalKeyResponder")
            }
            let arm = try peer.exchange("arm", ["intent":intent.uuidString.lowercased(),"kind":kind,"receiver":receiver])
            guard (arm["intent"] as? String).flatMap(UUID.init(uuidString:)) == intent,
                  let tagHex = arm["tagHex"] as? String, tagHex.count == 16, tagHex.hasPrefix("4e50"),
                  let tag = UInt64(tagHex,radix:16), let deadline = arm["deadlineUptime"] as? Double,
                  let before = arm["before"] as? JSON, let source = CGEventSource(stateID:.privateState) else {
                throw StagePairRefusal("fixtureDidNotArmUniqueMarker")
            }
            row["armWindowObservations"] = StageInteractiveWindows.evidence(before["windows"])
            let armed = try StageInteractiveWindows(raw: before["windows"], pid: owner.pid, previous: windows, bystander: peer.isBystander)
            let target = armed.rows[slot]
            var events = [CGEvent]()
            if kind == "key" {
                guard target.row.key && target.row.firstResponderIsContent,
                      let text = arm["marker"] as? String, UUID(uuidString:text)?.uuidString.lowercased() == text else {
                    throw StagePairRefusal("fixtureKeyReceiverChanged")
                }
                let marker = Array(text.utf16)
                for down in [true,false] {
                    guard let e = CGEvent(keyboardEventSource:source, virtualKey:0,keyDown:down) else { throw StagePairRefusal("fixtureKeyPacketUnavailable") }
                    e.keyboardSetUnicodeString(stringLength:marker.count,unicodeString:marker)
                    events.append(e)
                }
            } else {
                for type: CGEventType in [.leftMouseDown,.leftMouseDragged,.leftMouseUp] {
                    let point = CGPoint(x:target.cg.midX + (type == .leftMouseDown ? 0 : 3), y:target.cg.midY)
                    guard target.cg.insetBy(dx:8,dy:30).contains(point),
                          let e = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left)
                    else { throw StagePairRefusal("fixtureMousePacketUnavailable") }
                    if !systemRoute {
                        e.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(target.row.window))
                        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(target.row.window))
                    }
                    events.append(e)
                }
            }
            for event in events {
                try current()
                try peer.verify()
                let sample = try StageInteractiveWindows(raw: peer.exchange("sample")["windows"], pid: owner.pid, previous: windows, bystander: peer.isBystander)
                guard kind != "key" || (sample.rows[slot].row.key && sample.rows[slot].row.firstResponderIsContent),
                      ProcessInfo.processInfo.systemUptime < deadline else { throw StagePairRefusal("armedReceiverOrDeadlineChanged") }
                try current()
                try peer.verify()
                event.flags = []; event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:tag))
                if systemRoute {
                    try StageInteractiveRouting.clearInput(InputState.physical(),syntheticDown:syntheticDown)
                    guard StageCanaryOverview.hid() == originalHID, StageInteractiveRouting.hasFocus(target,pid:owner.pid),
                          kind != "mouse" || (pointer != nil && StageInteractiveRouting.hit(target,at:event.location))
                    else { throw StagePairRefusal("actualSystemReceiverChanged") }
                    event.post(tap:.cgSessionEventTap)
                    if kind == "mouse" { syntheticDown = event.type != .leftMouseUp; lastPointer = event.location }
                } else {
                    try whileInputClear(InputState.physical) { event.postToPid(owner.pid) }
                }
                count += 1
                try await Task.sleep(for:.milliseconds(22))
            }
            try await Task.sleep(for:.milliseconds(120))
            let answer = try peer.exchange("finish", ["intent":intent.uuidString.lowercased()])
            guard let decision = answer["delivery"] as? JSON, let after = answer["after"] as? JSON else { throw StagePairRefusal("missingReceiverEvidence") }
            row["receipt"] = decision
            row["physicalHitOrSystemKeyboardRouting"] = systemRoute ? "SUBMITTED_TO_SESSION" : "NOT_MEASURED"
            row["finishWindowObservations"] = StageInteractiveWindows.evidence(after["windows"])
            try current()
            let finished = try StageInteractiveWindows(raw:after["windows"],pid:owner.pid,previous:windows,bystander:peer.isBystander)
            let countsMatch = zip(armed.rows, finished.rows).allSatisfy { before, after in
                guard let x = before.row.documentWrites, let y = after.row.documentWrites,
                      before.row.documentErrors == 0, after.row.documentErrors == 0 else { return false }
                return y == x + ((kind == "key" && after.row.role == receiver) ? 1 : 0)
            }
            let fileMatches = kind == "key" ? try peer.documentMatches(intent:intent, marker:arm["marker"] as? String ?? "", bound:target) : true
            row["independentDocument"] = ["expectedNewFile":kind == "key","countDeltasMatch":countsMatch,"filesMatch":fileMatches]
            row["status"] = countsMatch && fileMatches && deliveryConfirmed(decision,intent:intent,kind:kind,receiver:receiver,pid:getpid()) ? "PASS" :
                decision["status"] as? String == "FAIL" ? "FAIL" : "UNKNOWN"
        } catch {
            row["reason"] = (error as? StagePairRefusal)?.reason ?? "fixtureEvidenceUnavailable"
            if count > 0 { row["status"] = "UNKNOWN" }
            if syntheticDown {
                row["releaseAfterInterruption"] = "UNKNOWN"
                if let pid = peer.image?.pid, let target = windows.rows.first(where: { $0.row.role == receiver }),
                   let p = lastPointer, StageCanaryOverview.hid() == originalHID,
                   (try? StageInteractiveRouting.clearInput(InputState.physical(),syntheticDown:true)) != nil,
                   StageInteractiveRouting.hasFocus(target,pid:pid), StageInteractiveRouting.hit(target,at:p),
                   let release = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:p,mouseButton:.left) {
                    release.flags = []
                    release.post(tap:.cgSessionEventTap)
                    syntheticDown = false
                    row["releaseAfterInterruption"] = "SUBMITTED_TO_VERIFIED_RECEIVER"
                }
            }
        }
        row["submitted"] = count
        return row
    }

    static func run(_ nonce: UUID, channel: StageScopeReply, spacesCycle: Bool = false, observe: Observe) async throws -> JSON {
        let hid = StageCanaryOverview.hid(), initialInput = InputState.physical()
        let original = StageCanaryOverview.beginFocusObservation()
        let pre = try await observe(nil)
        try channel.finish(JSONSerialization.data(withJSONObject: pre, options: [.sortedKeys]) + Data([10]), preflight: true)
        var result: JSON = ["status":"BLOCKED","fixtureLaunchRequested":false,"openRequestAttempted":false,"windowObservations":[],"inputs":[],
            "physicalMouseHit":"NOT_RUN","physicalKeyboardRouting":"NOT_RUN","hiddenInputIsolation":"NOT_RUN",
            "productionQualified":false,"windowEngineRoundTrip":["status":"NOT_RUN","reason":spacesCycle ? "awaitingTrioAdmission" : "observationOnly"],
            "originalFocus":original.first,"initialHID":hid,"initialInput":initialInput.evidence,"restorationInputEvents":0]
        var peer: StageInteractivePeer?, ids = [UInt32](), openRequested = false, closed = false
        var bystanderPeer: StageInteractivePeer?, bystanderIDs = [UInt32](), bystanderOpen = false
        var final = pre, inputRows = [JSON](), footprintReads = [JSON]()
        do {
            try initialInput.requireClear()
            let fresh = try await observe(nil), initialClose = original.finish()
            result["preOpenFocus"] = initialClose
            guard try !channel.exists(.abort), accepts(pre,fresh,focus:initialClose,beganHID:hid,currentHID:StageCanaryOverview.hid()),
                  let subject = fresh["subject"] as? JSON, let hostBirth = subject["birth"] as? UInt64, let hash = subject["cdhash"] as? String,
                  let scope = fresh["spaceScope"] as? JSON, let home = scope["scope"] as? JSON,
                  let display = home["displayUUID"] as? String, let space = home["spaceUUID"] as? String,
                  let native = home["nativeID"] as? UInt64, let samples = scope["samples"] as? [JSON],
                  let login = (samples.first?["session"] as? JSON)?["securitySessionID"] as? UInt32 else {
                throw StagePairRefusal("ordinaryScopeFocusHIDOrPermissionsUnavailable")
            }
            let client = try StageInteractivePeer(nonce,pin:channel.registration(),hostBirth:hostBirth,hostHash:hash,login:login)
            peer = client
            let bystander = try StageInteractivePeer(nonce,pin:channel.registration(),hostBirth:hostBirth,hostHash:hash,login:login,bystander:true)
            bystanderPeer = bystander
            let inventory = try StageCanaryOverview.inventoryIdentity(StageCanaryOverview.inventory())
            guard let originalSpace = inventory["current"] as? NSDictionary, originalSpace["type"] as? UInt64 == 0,
                  originalSpace["id"] as? UInt64 == native, originalSpace["uuid"] as? String == space
            else { throw StagePairRefusal("originalDesktopInventoryDisagrees") }
            guard let focusPID = original.first["workspacePID"] as? pid_t, let focusNumber = original.first["cgWindowID"] as? UInt32
            else { throw StagePairRefusal("fixtureCensusMissingHeldForeground") }
            func census(_ phase: String, previous: StageInteractiveFootprint? = nil,
                        registered: [StageInteractiveFootprint.Window] = [], record: Bool = true) throws -> StageInteractiveFootprint {
                let shot: StageInteractiveFootprint
                do {
                    shot = try StageInteractiveFootprint.sample(display: display, foregroundPID: focusPID, foregroundWindow: focusNumber, includeBystander: true)
                } catch {
                    footprintReads.append(["phase":phase, "uptime":ProcessInfo.processInfo.systemUptime,
                                           "reason":(error as? StagePairRefusal)?.reason ?? "fixtureCensusUnavailable"])
                    throw error
                }
                let check = shot.assess(previous: previous, registered: registered)
                if record || check.reason != nil {
                    var evidence = check.evidence
                    evidence["phase"] = phase
                    footprintReads.append(evidence)
                }
                if let reason = check.reason { throw StagePairRefusal(reason) }
                return shot
            }
            var expectedFocus: () -> Bool = { original.finish()["sameOriginalAX"] as? Bool == true }
            func unchanged() throws {
                try InputState.physical().requireClear()
                guard try !channel.exists(.abort), StageCanaryOverview.hid() == hid, AXIsProcessTrusted(),
                      CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
                      try StageCanaryOverview.inventoryIdentity(StageCanaryOverview.inventory()).isEqual(inventory),
                      expectedFocus() else { throw StagePairRefusal("originalFocusHIDPermissionOrAbortChanged") }
            }
            try unchanged()
            let baseline = try census("beforeFixtureLaunch")
            try await Task.sleep(for: .milliseconds(65))
            try unchanged()
            _ = try census("confirmBeforeFixtureLaunch", previous: baseline)
            result["fixtureLaunchRequested"] = true
            try await client.launch()
            guard let image = client.image else { throw StagePairRefusal("ordinaryFixtureUnavailable") }
            result["fixturePID"] = image.pid; result["fixtureBirth"] = image.launch; result["fixtureCDHash"] = client.digest
            try unchanged()
            result["bystanderLaunchAttempted"] = true
            try await bystander.launch()
            guard let other = bystander.image, other.pid != image.pid else { throw StagePairRefusal("independentBystanderUnavailable") }
            result["bystanderPID"] = other.pid; result["bystanderBirth"] = other.launch; result["bystanderCDHash"] = bystander.digest
            let last = try await observe(nil)
            guard accepts(pre,last,focus:original.finish(),beganHID:hid,currentHID:StageCanaryOverview.hid()) else { throw StagePairRefusal("ordinaryScopeChangedBeforeOpeningFixture") }
            try unchanged()
            _ = try census("beforeOpen", previous: baseline)
            let opened = try client.exchange("open",["displayUUID":display,"spaceUUID":space,"nativeID":native]) {
                try unchanged()
                _ = try census("atOpenSend", previous: baseline)
                try InputState.physical().requireClear()
                openRequested = true
            }
            guard opened["regular"] as? Bool == true else { throw StagePairRefusal("ordinaryFixtureUnavailable") }
            result["openedWindowObservations"] = StageInteractiveWindows.evidence(opened["windows"])
            let local = try StageInteractiveWindows.decoded(opened["windows"])
            ids = local.map(\.window)
            var registered = try local.map { row -> StageInteractiveFootprint.Window in
                guard let frame = row.rect else { throw StagePairRefusal("fixtureOuterFrameUnavailable") }
                return .init(pid: image.pid, number: row.window, frame: frame)
            }
            _ = try census("afterOpen", previous: baseline, registered: registered)
            let observerOpen = try bystander.exchange("open",["displayUUID":display,"spaceUUID":space,"nativeID":native]) {
                try unchanged()
                _ = try census("atBystanderOpen", previous: baseline, registered: registered)
                bystanderOpen = true
            }
            let localBystander = try StageInteractiveWindows.decoded(observerOpen["windows"], bystander: true)[0]
            guard let otherFrame = localBystander.rect else { throw StagePairRefusal("bystanderFrameUnavailable") }
            bystanderIDs = [localBystander.window]
            registered.append(.init(pid:other.pid, number:localBystander.window, frame:otherFrame))
            func currentPair() throws {
                try unchanged()
                _ = try census("whileOpen", previous: baseline, registered: registered, record: false)
            }
            // The owning NSWindow numbers can precede their AX publication. Wait only for missing
            // references; a conflicting identity, geometry, focus or human input stops the trial.
            var raw = opened["windows"], settled: StageInteractiveWindows?
            let until = ContinuousClock.now.advanced(by:.seconds(2))
            while settled == nil {
                try currentPair()
                let sample = try StageInteractiveWindows.decoded(raw)
                guard zip(local,sample).allSatisfy({ $0.window == $1.window && $0.lifetime == $1.lifetime && $0.frame == $1.frame })
                else { throw StagePairRefusal("fixtureWindowChangedDuringAXPublication") }
                do { settled = try StageInteractiveWindows(raw:raw,pid:image.pid) }
                catch let failure as StagePairRefusal {
                    guard ["registeredFixtureAXWindowsUnavailable","fixtureAXRosterNotYetComplete"].contains(failure.reason),
                          ContinuousClock.now < until else { throw failure }
                    try await Task.sleep(for:.milliseconds(55))
                    raw = try client.exchange("sample")["windows"]
                }
            }
            guard let windows = settled else { throw StagePairRefusal("registeredFixtureAXWindowsUnavailable") }
            var protected: StageInteractiveWindows?
            let settleDeadline = ContinuousClock.now.advanced(by:.seconds(2))
            while protected == nil {
                try currentPair()
                do { protected = try StageInteractiveWindows(raw:bystander.exchange("sample")["windows"],pid:other.pid,bystander:true) }
                catch let failure as StagePairRefusal {
                    guard ["registeredFixtureAXWindowsUnavailable","fixtureAXRosterNotYetComplete"].contains(failure.reason),
                          ContinuousClock.now < settleDeadline else { throw failure }
                    try await Task.sleep(for:.milliseconds(50))
                }
            }
            guard let protected, protected.rows[0].row.window == localBystander.window,
                  protected.rows[0].row.lifetime == localBystander.lifetime else { throw StagePairRefusal("bystanderRecreatedDuringEnrollment") }
            var observations = [JSON]()
            for (bound, owner, endpoint) in windows.rows.map({ ($0, image, client) }) + [(protected.rows[0], other, bystander)] {
                var fixture = StageEngineHostScope.Fixture(pid:owner.pid,birth:owner.launch,number:bound.row.window,
                                                          executable:endpoint.executable,cdhash:endpoint.digest)
                fixture.interactiveChallenge = nonce
                let proof = try await observe(fixture)
                guard let scope = proof["spaceScope"] as? JSON else { throw StagePairRefusal("missingMembershipObservation") }
                var row = bound.evidence
                row["pid"] = owner.pid; row["birth"] = owner.launch; row["cdhash"] = endpoint.digest
                row["scope"] = scope["scope"]; row["membership"] = scope["fixtureMembership"]
                row["membershipSamples"] = (scope["samples"] as? [JSON])?.compactMap { $0["fixture"] }
                observations.append(row)
                result["windowObservations"] = observations
                guard StageEnginePackageProbe.admitsInstalledCycle(preflight:pre,registered:proof)
                else { throw StagePairRefusal("registeredWindowMembershipUnconfirmed") }
            }
            _ = try StageInteractiveWindows(raw:client.exchange("sample")["windows"],pid:image.pid,previous:windows)
            try currentPair()
            if let engine = NativeStageWindowEngine() {
                let probe = try await engine.submit(.init(backend:UInt32(NP_CORNER),operation:UInt32(NP_PROBE),intent:UUID()))
                result["productionReadOnlyProbe"] = ["status":probe.status,"flags":probe.flags,"detail":probe.detail,"closed":await engine.close(),"visibilityWrites":0] as JSON
            }
            if spacesCycle {
                try currentPair()
                try bystander.verify()
                try client.verify()
                let receiver = protected.rows[0], target = windows.rows[0]
                try await StageInteractiveRouting.selectOwned(receiver,peer:bystander)
                expectedFocus = { StageInteractiveRouting.hasFocus(receiver,pid:other.pid) }
                try currentPair()
                let dock = try StageInteractiveRouting.DockState.read()
                result["dockBeforeMigration"] = dock.evidence
                result["engineEntryFocus"] = StageCanaryOverview.beginFocusObservation().first
                var nativeReply: JSON?
                let cycle = Task { @MainActor in
                    nativeReply = await InstalledSpacesFixtureCycle.read(challenge:nonce,ownPanelOnly:false,interactive:true)
                }
                var parkedRows = [JSON]()
                do {
                    let deadline = ContinuousClock.now.advanced(by:.seconds(11))
                    while try !StageInteractiveRouting.parked(client) {
                        guard nativeReply == nil, ContinuousClock.now < deadline else { throw StagePairRefusal("noParkedReadback") }
                        try await Task.sleep(for:.milliseconds(20))
                    }
                    let parkedUntil = ContinuousClock.now.advanced(by:.seconds(2.8))
                    func atPark() throws {
                        guard nativeReply == nil, ContinuousClock.now < parkedUntil, try !channel.exists(.abort),
                              StageCanaryOverview.hid() == hid, expectedFocus(), StageInteractiveRouting.targetAbsent(target,pid:image.pid),
                              AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
                            throw StagePairRefusal("parkedSystemReceiverOrScopeChanged")
                        }
                    }
                    for kind in ["mouse","key"] {
                        let row = await input(kind:kind,receiver:"bystander",peer:bystander,windows:protected,systemRoute:true,current:atPark)
                        parkedRows.append(row)
                        if row["status"] as? String != "PASS" { break }
                    }
                    try atPark()
                    let raw = try client.exchange("sample")["windows"]
                    guard let raw, let rows = try? JSONDecoder().decode([StageInteractiveWindows.Row].self,from:JSONSerialization.data(withJSONObject:raw)),
                          rows.count == windows.rows.count, zip(rows,windows.rows).allSatisfy({ row, old in
                              row.window == old.row.window && row.lifetime == old.row.lifetime && row.markedEvents == 0 &&
                                row.documentWrites == 0 && row.documentErrors == 0
                          }) else { throw StagePairRefusal("parkedTargetOrSiblingReceivedMarkedInput") }
                    let dockDuring = try StageInteractiveRouting.DockState.read()
                    result["dockWhileParked"] = dockDuring.evidence
                    guard dock == dockDuring else { throw StagePairRefusal("dockChangedWhileParked") }
                    let correct = parkedRows.count == 2 && parkedRows.allSatisfy { $0["status"] as? String == "PASS" }
                    try StageInteractiveRouting.acknowledge(client,target:target.row.window,receiver:receiver.row.window,status:correct ? "PASS" : "UNKNOWN")
                    result["hiddenInputIsolation"] = correct ? "PASS" : "UNKNOWN"
                    result["parkedProtectedReceivers"] = rows.map { ["role":$0.role,"window":$0.window,"markedEvents":$0.markedEvents ?? UInt64.max,
                                                                  "documentWrites":$0.documentWrites ?? UInt64.max] as JSON }
                } catch {
                    result["hiddenInputIsolation"] = (error as? StagePairRefusal)?.reason == "parkedTargetOrSiblingReceivedMarkedInput" ? "FAIL" : "UNKNOWN"
                    result["parkedInputReason"] = (error as? StagePairRefusal)?.reason ?? "missingParkedReceiverEvidence"
                    if (try? StageInteractiveRouting.parked(client)) == true {
                        try? StageInteractiveRouting.acknowledge(client,target:target.row.window,receiver:receiver.row.window,status:"UNKNOWN")
                    }
                }
                result["parkedInputs"] = parkedRows
                await cycle.value
                let dispatch = nativeReply ?? ["status":"UNKNOWN","safeToRollback":false]
                result["windowEngineRoundTrip"] = dispatch
                guard dispatch["safeToRollback"] as? Bool == true else {
                    throw StagePairRefusal("interactiveCycleRetainedRecoveryResponsibility")
                }
                guard dispatch["status"] as? String == "PASS",
                      let subject = dispatch["fixture"] as? JSON, subject["pid"] as? Int32 == image.pid,
                      subject["birth"] as? UInt64 == image.launch, subject["window"] as? UInt32 == windows.rows[0].row.window,
                      subject["parkedIndependentReads"] as? UInt32 == 2, subject["returnedIndependentReads"] as? UInt32 == 2 else {
                    throw StagePairRefusal("interactiveCycleDidNotProveReturn")
                }
                let dockAfter = try StageInteractiveRouting.DockState.read()
                result["dockAfterReturn"] = dockAfter.evidence
                guard dockAfter == dock else { throw StagePairRefusal("dockChangedAfterReturn") }
                try currentPair()
                _ = try StageInteractiveWindows(raw:client.exchange("sample")["windows"],pid:image.pid,previous:windows)
                _ = try StageInteractiveWindows(raw:bystander.exchange("sample")["windows"],pid:other.pid,previous:protected,bystander:true)
            }
            if spacesCycle {
                try currentPair()
                try await StageInteractiveRouting.selectOwned(windows.rows[0],peer:client)
                expectedFocus = { StageInteractiveRouting.hasFocus(windows.rows[0],pid:image.pid) }
                try currentPair()
            }
            func returnedInputScope() throws {
                if !spacesCycle { try currentPair(); return }
                guard try !channel.exists(.abort), expectedFocus(), StageCanaryOverview.hid() == hid,
                      AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
                      try StageCanaryOverview.inventoryIdentity(StageCanaryOverview.inventory()).isEqual(inventory) else {
                    throw StagePairRefusal("returnedSystemScopeChanged")
                }
                _ = try census("returnedWindowInput",previous:baseline,registered:registered,record:false)
            }
            for (kind, receiver) in [("mouse","target"),("key","target")] {
                try currentPair()
                let entry = await input(kind:kind,receiver:receiver,peer:client,windows:windows,systemRoute:spacesCycle,current:returnedInputScope)
                inputRows.append(entry)
                if entry["status"] as? String != "PASS" { break }
            }
            let afterBystander = try StageInteractiveWindows(raw:bystander.exchange("sample")["windows"],pid:other.pid,previous:protected,bystander:true)
            let expectedEvents: UInt64 = spacesCycle ? 5 : 0
            guard let initialEvents = protected.rows[0].row.markedEvents, afterBystander.rows[0].row.markedEvents == initialEvents + expectedEvents,
                  afterBystander.rows[0].row.documentWrites == (spacesCycle ? 1 : 0), afterBystander.rows[0].row.documentErrors == 0 else {
                throw StagePairRefusal("bystanderReceivedInputOrDocumentWrite")
            }
            if spacesCycle {
                result["physicalMouseHit"] = inputRows.first { $0["kind"] as? String == "mouse" }?["status"] ?? "NOT_RUN"
                result["physicalKeyboardRouting"] = inputRows.first { $0["kind"] as? String == "key" }?["status"] ?? "NOT_RUN"
            }
            result["bystanderStable"] = true
            result["status"] = inputRows.count == 2 && inputRows.allSatisfy { $0["status"] as? String == "PASS" } ? "PASS" : inputRows.last?["status"] ?? "UNKNOWN"
            result["reason"] = inputRows.last?["reason"] ?? (spacesCycle ? "seeSessionRoutedReceiverReceipts" : "seeTargetedReceiverReceipts")
        } catch {
            result["reason"] = (error as? StagePairRefusal)?.reason ?? "interactivePairObservationUnavailable"
            if openRequested { result["status"] = "UNKNOWN" }
        }
        let engineReceipt = result["windowEngineRoundTrip"] as? JSON
        if spacesCycle && engineReceipt?["safeToRollback"] as? Bool == false {
            result["status"] = "UNKNOWN"
            result["retainedRecovery"] = true
            result["inputs"] = inputRows
            result["fixtureFootprintReads"] = footprintReads
            result["openRequestAttempted"] = openRequested
            final["interactiveWindowPair"] = result
            return final
        }
        if let other = bystanderPeer {
            var confirmed = false
            if bystanderOpen, let reply = try? other.exchange("close") {
                result["bystanderLocalCleanup"] = reply
                confirmed = reply["ownWindowsCreated"] as? Int == 1 && reply["ownWindowsClosed"] as? Bool == true && reply["reason"] as? String == "hostClosed"
            }
            other.disconnect()
            if let proc = other.process {
                let end = ContinuousClock.now.advanced(by:.seconds(bystanderOpen ? 4 : 13))
                while !proc.isTerminated, ContinuousClock.now < end { try? await Task.sleep(for:.milliseconds(40)) }
                let gone = proc.isTerminated && other.image.map { (try? OrdinaryProcessImage.read($0.pid)) != $0 } != false
                let removed = !bystanderOpen || (confirmed && StageInteractiveWindows.removed(bystanderIDs,count:1))
                result["bystanderCleanup"] = ["exited":gone,"removed":removed,"openAttempted":bystanderOpen]
                if !gone || !removed { result["status"] = "UNKNOWN"; result["cleanupReason"] = "bystanderCleanupUnconfirmed" }
            }
        }
        if let peer {
            if openRequested, let reply = try? peer.exchange("close") {
                result["localCleanup"] = reply
                closed = reply["ownWindowsCreated"] as? Int == 2 && reply["ownWindowsClosed"] as? Bool == true &&
                    reply["reason"] as? String == "hostClosed"
            }
            peer.disconnect()  // The fixture also closes only its own windows on EOF.
            if let process = peer.process {
                let end = ContinuousClock.now.advanced(by:.seconds(openRequested ? 4 : 13))
                while !process.isTerminated, ContinuousClock.now < end { try? await Task.sleep(for:.milliseconds(40)) }
                let gone = process.isTerminated && peer.image.map { (try? OrdinaryProcessImage.read($0.pid)) != $0 } != false
                let removed = gone && StageInteractiveWindows.removed(ids)
                result["cleanup"] = ["fixtureExited":gone,"exactWindowsGone":removed,"ownCloseAcknowledged":closed] as JSON
                if (openRequested && !(closed && removed)) || !gone { result["status"] = "UNKNOWN"; result["cleanupReason"] = "independentRemovalNotConfirmed" }
            }
        }
        result["openRequestAttempted"] = openRequested
        result["fixtureFootprintReads"] = footprintReads
        let afterFocus = original.finish(), afterHID = StageCanaryOverview.hid(), afterInput = InputState.physical()
        for kind in ["mouse","key"] where !inputRows.contains(where:{ $0["kind"] as? String == kind }) {
            inputRows.append(["kind":kind,"receiver":"target","status":"NOT_RUN","submitted":0,"reason":"earlierAdmissionOrReceiverUnconfirmed"])
        }
        result["finalFocus"] = afterFocus; result["finalHID"] = afterHID; result["finalInput"] = afterInput.evidence; result["inputs"] = inputRows
        if let sampled = try? await observe(nil) {
            final = sampled
        } else {
            result["finalScopeRead"] = "UNKNOWN"
        }
        if openRequested && (afterInput.refusal != nil || result["finalScopeRead"] != nil || !accepts(pre,final,focus:afterFocus,beganHID:hid,currentHID:afterHID)) {
            result["status"] = "UNKNOWN"; result["environmentAfter"] = "scopeHIDOrOriginalFocusChanged"
        }
        final["interactiveWindowPair"] = result
        return final
    }
}
