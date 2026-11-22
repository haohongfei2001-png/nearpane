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
              ["mouse","key"].contains(kind), ["target","sibling"].contains(receiver),
              let rows = row["receivers"] as? [JSON], rows.count == 2, rows.compactMap({ $0["role"] as? String }) == ["target","sibling"]
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
                              current: () throws -> Void) async -> JSON {
        let intent = UUID()
        var row: JSON = ["kind":kind,"receiver":receiver,"intent":intent.uuidString,"status":"BLOCKED","submitted":0,
                         "deliveryRoute":"PID_TARGETED","physicalHitOrSystemKeyboardRouting":"NOT_MEASURED"]
        var count = 0
        do {
            guard let owner = peer.image, let slot = windows.rows.firstIndex(where: { $0.row.role == receiver }) else {
                throw StagePairRefusal("unregisteredReceiver")
            }
            try current()
            let first = try StageInteractiveWindows(raw: peer.exchange("sample")["windows"], pid: owner.pid, previous: windows)
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
            let armed = try StageInteractiveWindows(raw: before["windows"], pid: owner.pid, previous: windows)
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
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(target.row.window))
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(target.row.window))
                    events.append(e)
                }
            }
            for event in events {
                try current()
                try peer.verify()
                let sample = try StageInteractiveWindows(raw: peer.exchange("sample")["windows"], pid: owner.pid, previous: windows)
                guard kind != "key" || (sample.rows[slot].row.key && sample.rows[slot].row.firstResponderIsContent),
                      ProcessInfo.processInfo.systemUptime < deadline else { throw StagePairRefusal("armedReceiverOrDeadlineChanged") }
                try current()
                try peer.verify()
                event.flags = []; event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:tag))
                try whileInputClear(InputState.physical) { event.postToPid(owner.pid) }
                count += 1
                try await Task.sleep(for:.milliseconds(22))
            }
            try await Task.sleep(for:.milliseconds(120))
            let answer = try peer.exchange("finish", ["intent":intent.uuidString.lowercased()])
            guard let decision = answer["delivery"] as? JSON, let after = answer["after"] as? JSON else { throw StagePairRefusal("missingReceiverEvidence") }
            row["receipt"] = decision
            row["finishWindowObservations"] = StageInteractiveWindows.evidence(after["windows"])
            _ = try StageInteractiveWindows(raw:after["windows"],pid:owner.pid,previous:windows)
            try current()
            row["status"] = deliveryConfirmed(decision,intent:intent,kind:kind,receiver:receiver,pid:getpid()) ? "PASS" :
                decision["status"] as? String == "FAIL" ? "FAIL" : "UNKNOWN"
        } catch {
            row["reason"] = (error as? StagePairRefusal)?.reason ?? "fixtureEvidenceUnavailable"
            if count > 0 { row["status"] = "UNKNOWN" }
        }
        row["submitted"] = count
        return row
    }

    static func run(_ nonce: UUID, channel: StageScopeReply, observe: Observe) async throws -> JSON {
        let hid = StageCanaryOverview.hid(), initialInput = InputState.physical()
        let original = StageCanaryOverview.beginFocusObservation()
        let pre = try await observe(nil)
        try channel.finish(JSONSerialization.data(withJSONObject: pre, options: [.sortedKeys]) + Data([10]), preflight: true)
        var result: JSON = ["status":"BLOCKED","fixtureLaunchRequested":false,"openRequestAttempted":false,"windowObservations":[],"inputs":[],
            "physicalMouseHit":"NOT_RUN","physicalKeyboardRouting":"NOT_RUN","hiddenInputIsolation":"NOT_RUN",
            "productionQualified":false,"windowEngineRoundTrip":["status":"NOT_RUN","reason":"installedSingleWindowRouteRequiresPinnedTransparentNoninteractiveFixture"],
            "originalFocus":original.first,"initialHID":hid,"initialInput":initialInput.evidence,"restorationInputEvents":0]
        var peer: StageInteractivePeer?, ids = [UInt32](), openRequested = false, closed = false
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
                    shot = try StageInteractiveFootprint.sample(display: display, foregroundPID: focusPID, foregroundWindow: focusNumber)
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
            func unchanged() throws {
                try InputState.physical().requireClear()
                guard try !channel.exists(.abort), StageCanaryOverview.hid() == hid, AXIsProcessTrusted(),
                      CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
                      try StageCanaryOverview.inventoryIdentity(StageCanaryOverview.inventory()).isEqual(inventory),
                      original.finish()["sameOriginalAX"] as? Bool == true else { throw StagePairRefusal("originalFocusHIDPermissionOrAbortChanged") }
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
            let registered = try local.map { row -> StageInteractiveFootprint.Window in
                guard let frame = row.rect else { throw StagePairRefusal("fixtureOuterFrameUnavailable") }
                return .init(pid: image.pid, number: row.window, frame: frame)
            }
            _ = try census("afterOpen", previous: baseline, registered: registered)
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
            var observations = [JSON]()
            for bound in windows.rows {
                var fixture = StageEngineHostScope.Fixture(pid:image.pid,birth:image.launch,number:bound.row.window,
                                                          executable:client.executable,cdhash:client.digest)
                fixture.interactiveChallenge = nonce
                let proof = try await observe(fixture)
                guard let scope = proof["spaceScope"] as? JSON else { throw StagePairRefusal("missingMembershipObservation") }
                var row = bound.evidence
                row["pid"] = image.pid; row["birth"] = image.launch; row["cdhash"] = client.digest
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
            for (kind, receiver) in [("mouse","target"),("key","target")] {
                try currentPair()
                let entry = await input(kind:kind,receiver:receiver,peer:client,windows:windows,current:currentPair)
                inputRows.append(entry)
                if entry["status"] as? String != "PASS" { break }
            }
            result["status"] = inputRows.count == 2 && inputRows.allSatisfy { $0["status"] as? String == "PASS" } ? "PASS" : inputRows.last?["status"] ?? "UNKNOWN"
            result["reason"] = inputRows.last?["reason"] ?? "seeTargetedReceiverReceipts"
        } catch {
            result["reason"] = (error as? StagePairRefusal)?.reason ?? "interactivePairObservationUnavailable"
            if openRequested { result["status"] = "UNKNOWN" }
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
