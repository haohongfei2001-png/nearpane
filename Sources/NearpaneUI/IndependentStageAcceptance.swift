import AppKit
import CReadOnlySpaces
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// An isolated app exercises the real R4 views and their production click handlers.
/// The configuration names only the two signed fixture processes created by run.py.
/// An engine receipt alone never sets PRODUCT_R4_PASS.
@MainActor public enum IndependentStageAcceptance {
    private struct Configuration: Decodable {
        struct Window: Decodable { let index: Int; let number: UInt32 }
        struct Fixture: Decodable {
            let directory: String, executable: String
            let pid: Int32, birth: UInt64
            let windows: [Window]
        }
        let schema: Int, nonce: UUID, output: String, profile: String, iterations: Int
        let purpose: String?
        let systemHelper: String?
        let fixtures: [Fixture]
    }
    private struct Target {
        let fixture: Configuration.Fixture, window: Configuration.Window, frame: CGRect, home: UInt64
        var key: NativeSpaceWindow { .init(pid: fixture.pid, birth: fixture.birth, number: window.number) }
    }
    private struct Failure: Error { let reason: String }

    public static func run(configuration url: URL) async -> Int32 {
        let config: Configuration
        do { config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)) }
        catch { return 2 }
        let output = URL(fileURLWithPath: config.output).standardizedFileURL
        var report: [String: Any] = ["schema": 1, "status": "BLOCKED", "reason": "preflight",
            "actualR4Inputs": 0, "foreignWindowReadback": false, "cleanup": true,
            "missionControl": "NOT_RUN", "desktopGestures": "NOT_RUN", "fullScreenSplitView": "NOT_RUN",
            "nativeFullScreen": "NOT_RUN", "nativeDesktopSwitch": "NOT_RUN", "appExpose": "NOT_RUN",
            "nativeDesktopReveal": "NOT_RUN",
            "yellowButtonRouting": "NOT_RUN", "groupMergeSplit": "NOT_RUN", "qualificationGranted": false]
        var events = [[String: Any]]()
        func record(_ phase: String, _ fields: [String: Any] = [:]) {
            var row = fields; row["phase"] = phase; row["uptime"] = ProcessInfo.processInfo.systemUptime
            events.append(row)
        }
        func save() {
            report["events"] = events
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("product-result.json"), options: .atomic)
            }
        }
        let pids = Set(config.fixtures.map(\.pid))
        guard IndependentStagePolicy.candidateRequested, config.schema == 1,
              pids.count == 2, config.fixtures.count == 2, pids == IndependentStagePolicy.candidatePIDs,
              !pids.contains(getpid()), config.fixtures.map(\.windows.count).sorted() == [1, 2],
              url.standardizedFileURL.deletingLastPathComponent() == output,
              URL(fileURLWithPath: config.profile).standardizedFileURL.deletingLastPathComponent() == output else {
            report["reason"] = "isolatedFixtureConfigurationRequired"; save(); return 2
        }
        guard AXIsProcessTrusted(), NPProbeReadOnlyCatalog() == 1 else {
            report["reason"] = AXIsProcessTrusted() ? "windowServerReadbackUnavailable" : "candidateAccessibilityUnavailable"
            save(); return 2
        }
        var targets = [Target]()
        for fixture in config.fixtures {
            guard let image = try? NearpaneCore.OrdinaryProcessImage.read(fixture.pid), image.launch == fixture.birth,
                  image.executable == URL(fileURLWithPath: fixture.executable).resolvingSymlinksInPath(),
                  (try? NearpaneCore.OrdinaryProcessImage.signingDigest(fixture.pid)) != nil else {
                report["reason"] = "fixtureProcessIdentityChanged"; save(); return 2
            }
            for window in fixture.windows {
                guard let row = cg(window.number), row.pid == fixture.pid, row.visible,
                      let spaces = NPReadWindowSpacesIncludingHidden(window.number) as? [UInt64], spaces.count == 1,
                      let home = spaces.first, home > 0 else {
                    report["reason"] = "fixtureBaselineUnavailable"; save(); return 2
                }
                targets.append(.init(fixture: fixture, window: window, frame: row.frame, home: home))
            }
        }
        guard targets.count == 3, Set(targets.map(\.home)).count == 1 else {
            report["reason"] = "sameOrdinaryDesktopRequired"; save(); return 2
        }
        let original = NSWorkspace.shared.frontmostApplication
        let originalImage = original.flatMap { try? NearpaneCore.OrdinaryProcessImage.read($0.processIdentifier) }
        let support = URL(fileURLWithPath: config.profile).appendingPathComponent("Nearpane")
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { report["reason"] = "privateProfileUnavailable"; save(); return 2 }
        let modules = EmbeddedModules(support: support, candidate: true)
        var configuration = HostConfiguration()
        configuration.overviewShortcut = .off
        configuration.candidateTrayConnected = false
        configuration.modules = BuiltinCatalog.productManifests.map { .init(id: $0.id, enabled: $0.id == BuiltinCatalog.desktop) }
        let host = modules.makeHost(store: MemoryConfigurationStore(configuration), provider: NativeDesktopProvider.packaged())
        await host.start()
        host.setSurfaceHidden(false)
        let controller = EdgeWindowController(host: host, modules: modules)
        let panels = DisplayPanels(host: host, primary: controller, domains: modules)
        modules.workRect?.independentStageSnapshot = { [weak modules] in modules?.windowPreviews.currentDesktop?.snapshot }
        panels.refresh = { [weak panels] in panels?.update(screens: SystemScreens.geometry()) }
        panels.managementChanged = { [weak modules] id, state, deadline in
            modules?.workRect?.ordinaryPresentation(state, display: id, deadline: deadline)
        }
        panels.update(screens: SystemScreens.geometry())
        var actualInputs = 0
        var switchLatenciesMS = [Double]()
        var productPassed = false
        var startedWrites = false
        do {
            guard let feed = modules.windowPreviews.currentDesktop else { throw Failure(reason: "packagedOverviewReaderUnavailable") }
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            var groupIDs = [UInt32: UUID]()
            var candidateReady = false
            var r4RequestedDisplay: String?
            while ContinuousClock.now < readyDeadline {
                // Use the same explicit opening path as the real overview command.
                // Observation and panel visibility remain owned by DisplayPanels.
                if r4RequestedDisplay == nil, host.isRunning, panels.windowDispatchEligible,
                   let screen = SystemScreens.geometry().first,
                   await panels.confirmWindowDispatch(), panels.windowDispatchEligible,
                   SystemScreens.geometry().contains(where: { $0.id == screen.id }) {
                    host.setSurfaceHidden(false)
                    panels.request(screen.id)
                    panels.update(screens: SystemScreens.geometry())
                    r4RequestedDisplay = screen.id
                    report["r4OpenRequested"] = true
                    report["r4OpenDisplay"] = screen.id
                    record("R4OverviewOpenRequested", ["display": screen.id, "route": "productionOverviewCommand"])
                }
                feed.changed()
                groupIDs.removeAll(keepingCapacity: true)
                var readiness: [String: Any] = ["snapshotAvailable": feed.snapshot != nil,
                    "accessibilityTrusted": AXIsProcessTrusted(),
                    "r4OpenRequested": r4RequestedDisplay != nil,
                    "windowDispatchEligible": panels.windowDispatchEligible,
                    "missionControlState": panels.missionControlDispatchState,
                    "missionControlEvidence": panels.missionControlDispatchEvidence,
                    "panelVisible": controller.window?.isVisible == true,
                    "previewVisibleDisplays": modules.windowPreviews.visibleDisplays.sorted(),
                    "observedCapability": feed.stageEngine.observedCapability.map { String(describing: $0) } ?? "unavailable"]
                if let sample = feed.snapshot {
                    readiness["revision"] = sample.revision
                    readiness["fresh"] = sample.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                    readiness["catalogComplete"] = sample.native?.catalogComplete ?? false
                    readiness["catalogCompletenessObserved"] = sample.native?.catalogComplete != nil
                    readiness["nativeStageManager"] = sample.native?.stageManagerEnabled.map { $0 ? "on" : "off" } ?? "unknown"
                    readiness["accessibilityRead"] = sample.native.map { String(describing: $0.accessibility) } ?? "unavailable"
                    readiness["spacesRead"] = sample.native.map { String(describing: $0.spaces) } ?? "unavailable"
                    readiness["windowCount"] = sample.windows.count
                    if let issues = sample.native?.catalogIssues,
                       let data = try? JSONEncoder().encode(issues),
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        readiness["catalogIssues"] = json
                    }
                    readiness["roster"] = sample.windows.prefix(32).map { window -> [String: Any] in
                        var row: [String: Any] = ["membership": String(describing: window.membership),
                            "display": window.displayID]
                        if let metadata = window.metadata {
                            row["pid"] = metadata.pid; row["number"] = metadata.number
                            row["ordinaryRole"] = metadata.overviewOrdinaryRole.map { $0 ? "ordinary" : "nonordinary" } ?? "unknown"
                            row["onActiveDesktop"] = metadata.onActiveDesktop ?? false
                            row["isOnscreen"] = metadata.isOnscreen ?? false
                        }
                        return row
                    }
                    readiness["currentScopes"] = sample.scopes.flatMap { scope in
                        scope.records.filter(\.isCurrent).map { record in
                            ["display": scope.displayID, "record": record.id,
                             "ordinaryUUID": record.ordinaryUUID?.uuidString ?? "unavailable"]
                        }
                    }
                    readiness["targets"] = targets.map { target -> [String: Any] in
                        let observation = sample.windows.first {
                            $0.metadata?.pid == target.fixture.pid && $0.metadata?.number == target.window.number &&
                            $0.metadata?.launchMicroseconds == target.fixture.birth
                        }
                        var entry: [String: Any] = ["pid": target.fixture.pid, "number": target.window.number,
                            "included": observation != nil]
                        if let observation {
                            entry["display"] = observation.displayID
                            entry["membership"] = String(describing: observation.membership)
                            entry["onActiveDesktop"] = observation.metadata?.onActiveDesktop ?? false
                            entry["isOnscreen"] = observation.metadata?.isOnscreen ?? false
                        }
                        return entry
                    }
                }
                if let sample = feed.snapshot, sample.native?.stageManagerEnabled == false,
                   sample.native?.catalogComplete == true, sample.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime),
                   let screen = sample.displays.first, let display = UUID(uuidString: screen.id),
                   let nativeSpace = sample.scopes.first(where: { $0.displayID == screen.id })?.records.first(where: \.isCurrent)?.ordinaryUUID {
                    let groups = feed.groups.groups(in: .init(display: display, nativeSpace: nativeSpace))
                    for target in targets {
                        if let group = groups.first(where: { $0.members.contains(where: { $0.windowHint == target.key }) }) {
                            groupIDs[target.window.number] = group.id
                        }
                    }
                    readiness["permitsStageEngine"] = modules.workRect?.permitsStageEngine(on: screen.id) == true
                    if groupIDs.count == 3, Set(groupIDs.values).count == 3, feed.stageEngine.observedCapability == .spaces,
                       r4RequestedDisplay == screen.id, controller.window?.isVisible == true,
                       modules.windowPreviews.visibleDisplays.contains(screen.id),
                       modules.workRect?.permitsStageEngine(on: screen.id) == true { candidateReady = true }
                }
                readiness["fixtureGroupCount"] = groupIDs.count
                readiness["distinctFixtureGroupCount"] = Set(groupIDs.values).count
                report["lastReadiness"] = readiness
                // A later transient absence must not erase the last real catalog
                // and its concrete rejection reasons from the terminal evidence.
                if feed.snapshot != nil { report["lastObservedReadiness"] = readiness }
                if candidateReady { break }
                try await Task.sleep(for: .milliseconds(100))
                panels.update(screens: SystemScreens.geometry())
            }
            guard groupIDs.count == 3, Set(groupIDs.values).count == 3 else { throw Failure(reason: "fixtureGroupsNotReady") }
            guard candidateReady else { throw Failure(reason: "candidateDispatchUnavailable") }
            guard await ownerCommand(targets[0], action: "focus", nonce: config.nonce) else { throw Failure(reason: "fixtureStartingFocusUnavailable") }
            @MainActor func selectR4(_ index: Int, group: UUID, visible: Set<UInt32>, phase: String,
                                    exactMember: Bool = false) async throws {
                let target = targets[index]
                let windowID = "current-desktop-window:\(target.fixture.pid):\(target.window.number)"
                let ids: Set<String> = exactMember ? [windowID] : Set(["native-held-group:" + group.uuidString,
                    "stage-group-select:" + group.uuidString, windowID])
                guard let button = await waitButton(ids, panel: controller.window) else { throw Failure(reason: "realR4ButtonUnavailable") }
                startedWrites = true
                let pressedAt = ProcessInfo.processInfo.systemUptime
                guard button.accessibilityPerformPress() else { throw Failure(reason: "realR4ButtonRefused") }
                actualInputs += 1
                record("R4AccessibilityButton", ["group": group.uuidString, "window": target.window.number,
                    "step": phase, "exactMember": exactMember])
                let readings = await waitForState(targets, visible: visible, focus: target, seconds: 8)
                guard let readings else { throw Failure(reason: "R4SwitchReadbackFailed") }
                let latencyMS = (ProcessInfo.processInfo.systemUptime - pressedAt) * 1000
                switchLatenciesMS.append(latencyMS)
                record("R4SwitchConfirmed", ["window": target.window.number, "step": phase, "observations": readings,
                    "pressToDoubleReadMS": latencyMS])
                savePanel(controller.window, to: output.appendingPathComponent("r4-\(actualInputs).png"))
                feed.changed()
                try await Task.sleep(for: .milliseconds(120))
            }
            let cycles = min(50, max(1, config.iterations))
            if config.purpose == "hostCrash" {
                guard let firstGroup = groupIDs[targets[0].window.number] else { throw Failure(reason: "crashTargetGroupMissing") }
                try await selectR4(0, group: firstGroup, visible: [targets[0].window.number], phase: "beforeHostCrash")
                guard let readings = await waitForState(targets, visible: [targets[0].window.number], focus: targets[0], seconds: 3),
                      let image = try? NearpaneCore.OrdinaryProcessImage.read(getpid()) else {
                    throw Failure(reason: "crashCheckpointNotConfirmed")
                }
                let checkpoint: [String: Any] = ["schema": 1, "nonce": config.nonce.uuidString.lowercased(),
                    "hostPID": getpid(), "hostBirth": image.launch, "actualR4Inputs": actualInputs,
                    "visibleWindow": targets[0].window.number, "observations": readings,
                    "qualificationGranted": false]
                let data = try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("host-crash-ready.json"), options: .atomic)
                // Only the harness's exact child Process is eligible for SIGKILL.
                // If it does not act, take the normal release path after this bound.
                try await Task.sleep(for: .seconds(40))
                throw Failure(reason: "hostCrashInputNotReceived")
            }
            let cyclePath = [0] + (0..<cycles).flatMap { _ in [1, 2, 0] }
            for (step, index) in cyclePath.enumerated() {
                guard let group = groupIDs[targets[index].window.number] else { throw Failure(reason: "groupIdentityLost") }
                try await selectR4(index, group: group, visible: [targets[index].window.number], phase: "singletonCycle/\(step)")
            }
            report["foreignWindowReadback"] = true

            // Invoke the same production handlers as the held-card context menu.
            // These edits are explicitly recorded as handler inputs; the subsequent
            // group/member selections are actual R4 accessibility button presses.
            guard let heldB = feed.stageEngine.heldGroups.first(where: { $0.id == groupIDs[targets[2].window.number] }) else {
                throw Failure(reason: "crossAppSourceNotHeld")
            }
            let scope = heldB.scope
            let live: @MainActor () -> Bool = { IndependentStagePolicy.candidateRequested && IndependentStagePolicy.candidatePIDs == pids }
            report["groupMergeSplit"] = "FAIL"
            try await IndependentStageGroupEditing.perform(.joinCurrent, held: heldB, in: feed, current: live)
            let combinedKeys: Set<NativeSpaceWindow> = [targets[0].key, targets[2].key]
            guard let combined = feed.groups.groups(in: scope).first(where: { Set($0.members.map(\.windowHint)) == combinedKeys }),
                  let paired = await waitForState(targets, visible: [targets[0].window.number, targets[2].window.number],
                                                  focus: targets[0], seconds: 8),
                  let siblingGroup = groupIDs[targets[1].window.number] else {
                throw Failure(reason: "crossAppJoinReadbackFailed")
            }
            record("crossAppJoin", ["entry": "IndependentStageGroupEditing.perform: production context-menu handler",
                "group": combined.id.uuidString, "observations": paired, "pointerGestureClaimed": false])
            try await selectR4(1, group: siblingGroup, visible: [targets[1].window.number], phase: "leaveCombinedGroup")
            try await selectR4(0, group: combined.id, visible: [targets[0].window.number, targets[2].window.number], phase: "restoreCombinedGroup")
            try await selectR4(2, group: combined.id, visible: [targets[0].window.number, targets[2].window.number],
                               phase: "exactMemberWithinCombinedGroup", exactMember: true)
            try await selectR4(1, group: siblingGroup, visible: [targets[1].window.number], phase: "holdCombinedForSplit")
            guard let heldCombined = feed.stageEngine.heldGroups.first(where: { $0.id == combined.id }),
                  let detached = feed.groups.groups(in: scope).first(where: { $0.id == combined.id })?.members
                    .first(where: { $0.windowHint == targets[2].key }) else {
                throw Failure(reason: "combinedGroupNotHeldForSplit")
            }
            try await IndependentStageGroupEditing.perform(.detach(detached.id), held: heldCombined, in: feed, current: live)
            guard let split = await waitForState(targets, visible: [targets[2].window.number], focus: targets[2], seconds: 8) else {
                throw Failure(reason: "groupSplitReadbackFailed")
            }
            let singles = feed.groups.groups(in: scope)
            guard singles.count == 3, singles.allSatisfy({ $0.members.count == 1 }) else { throw Failure(reason: "splitDirectoryMismatch") }
            for target in targets {
                guard let group = singles.first(where: { $0.members.first?.windowHint == target.key }) else {
                    throw Failure(reason: "splitMemberIdentityLost")
                }
                groupIDs[target.window.number] = group.id
            }
            record("groupSplit", ["entry": "IndependentStageGroupEditing.perform: production context-menu handler",
                "member": detached.id.uuidString, "observations": split, "pointerGestureClaimed": false])
            guard let firstGroup = groupIDs[targets[0].window.number] else { throw Failure(reason: "splitFirstGroupMissing") }
            try await selectR4(0, group: firstGroup, visible: [targets[0].window.number], phase: "returnAfterSplit")
            report["groupMergeSplit"] = "PASS"

            // Exercise the real yellow button while the production minimize observer is active.
            let first = targets[0]
            if await ownerCommand(first, action: "minimize", nonce: config.nonce) {
                let until = ContinuousClock.now.advanced(by: .seconds(5))
                var retired = false
                while ContinuousClock.now < until {
                    if let spaces = NPReadWindowSpacesIncludingHidden(first.window.number) as? [UInt64], spaces.count == 1,
                       spaces[0] != first.home, cg(first.window.number)?.visible == false { retired = true; break }
                    feed.changed(); try await Task.sleep(for: .milliseconds(80))
                }
                if retired, let group = groupIDs[first.window.number],
                   let button = await waitButton(["native-held-group:" + group.uuidString], panel: controller.window),
                   button.accessibilityPerformPress() {
                    actualInputs += 1
                    let restored = await waitForState(targets, visible: [first.window.number], focus: first, seconds: 6)
                    report["yellowButtonRouting"] = restored == nil ? "FAIL" : "PASS"
                    record("yellowButtonRouting", ["retiredIntoHiddenSpace": retired, "restored": restored != nil])
                } else { report["yellowButtonRouting"] = "FAIL" }
            } else { report["yellowButtonRouting"] = "BLOCKED" }
            productPassed = true
            report["status"] = "PRODUCT_R4_PASS"
            report["reason"] = "realR4ButtonsDispatchedAndReadBack"
            try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeDesktopReveal")
            let reveal = await exerciseDesktopReveal(targets, nonce: config.nonce, feed: feed, panels: panels)
            report["nativeDesktopReveal"] = reveal["status"]
            record("nativeDesktopReveal", reveal)
            if reveal["status"] as? String == "PASS", let sibling = groupIDs[targets[1].window.number] {
                try await selectR4(1, group: sibling, visible: [targets[1].window.number], phase: "afterDesktopRevealHeldCard")
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "returnAfterDesktopReveal")
            }
            // The ordinary system overview must receive restored real windows, never corner proxies.
            if CGPreflightPostEventAccess() {
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeMissionControl")
                let opened = Process(); opened.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opened.arguments = ["-a", "Mission Control"]
                do {
                    try opened.run()
                    let until = ContinuousClock.now.advanced(by: .seconds(5))
                    var exposed = false
                    while ContinuousClock.now < until {
                        if let read = await panels.observeMissionControl(), read.mode == 1 { exposed = true; break }
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let restored = exposed ? await waitForState(targets, visible: Set(targets.map { $0.window.number }), focus: nil, seconds: 4) : nil
                    let source = CGEventSource(stateID: .privateState)
                    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                    var ordinary = false
                    let closeDeadline = ContinuousClock.now.advanced(by: .seconds(4))
                    while ContinuousClock.now < closeDeadline {
                        if let read = await panels.observeMissionControl(), read.mode == 0 { ordinary = true; break }
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let resumed = ordinary ? await waitForFocusedGroup(targets, in: feed, scope: scope, seconds: 8) : nil
                    report["missionControl"] = exposed && restored != nil && resumed != nil ? "PASS" : "FAIL"
                    record("missionControl", ["exposed": exposed, "realWindowsReturned": restored != nil,
                        "ordinaryReturned": ordinary, "focusedGroupAutomaticallyResumed": resumed != nil,
                        "focusedWindow": resumed?.window ?? 0, "resumeObservations": resumed?.observations ?? []])
                } catch { report["missionControl"] = "BLOCKED" }
            } else { report["missionControl"] = "BLOCKED" }
            // Real full-screen entry belongs to the fixture AppKit window. The test
            // observes the product yielding its sidebar and returning to the same desktop.
            if currentDesktop()?.id == first.home {
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeFullScreen")
            }
            if currentDesktop()?.id == first.home, await ownerCommand(first, action: "fullscreen", nonce: config.nonce) {
                var entered = false
                let enterDeadline = ContinuousClock.now.advanced(by: .seconds(6))
                while ContinuousClock.now < enterDeadline {
                    panels.update(screens: SystemScreens.geometry())
                    if ownerFlag(first, "fullScreen"), let current = currentDesktop(), current.kind == 4,
                       cg(first.window.number)?.visible == true, controller.window?.isVisible == false {
                        entered = true; break
                    }
                    try await Task.sleep(for: .milliseconds(80))
                }
                let companions = targets.filter { $0.key != first.key }
                let yielded = entered ? await waitForState(companions, visible: [], focus: nil, seconds: 5, allAtHome: true) : nil
                // Always unwind the owned window even when the sidebar observation failed.
                if ownerFlag(first, "fullScreen") { _ = await ownerCommand(first, action: "fullscreen", nonce: config.nonce) }
                let returned = await waitForFocusedGroup(targets, in: feed, scope: scope, seconds: 10)
                report["nativeFullScreen"] = entered && yielded != nil && returned != nil ? "PASS" : "FAIL"
                record("nativeFullScreen", ["realFullScreenSpace": entered, "inactiveWindowsReturnedToOriginalDesktop": yielded != nil,
                    "focusedGroupAutomaticallyResumed": returned != nil, "focusedWindow": returned?.window ?? 0,
                    "resumeObservations": returned?.observations ?? []])
            } else { report["nativeFullScreen"] = "BLOCKED" }

            if let helper = config.systemHelper, currentDesktop()?.id == first.home {
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeNativeSplitView")
                let split = await exerciseSplitView(targets, nonce: config.nonce, helper: helper, output: output,
                                                  feed: feed, panels: panels, panel: controller.window, scope: scope)
                report["fullScreenSplitView"] = split["status"]
                record("fullScreenSplitView", split)
            } else {
                report["fullScreenSplitView"] = "BLOCKED"
                record("fullScreenSplitView", ["reason": "systemSplitHelperOrOriginalDesktopUnavailable"])
            }

            if CGPreflightPostEventAccess(), let before = currentDesktop(), before.kind == 0,
               before.id == first.home, let adjacent = adjacentOrdinary(to: before.id) {
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeDesktopSwitch")
                let outbound: CGKeyCode = adjacent.forward ? 124 : 123
                sendControlArrow(outbound)
                let arrived = await waitDesktop(adjacent.id, seconds: 5)
                let yielded = arrived ? await waitForState(targets, visible: [], focus: nil, seconds: 5, allAtHome: true) : nil
                // Return only from the exact adjacent desktop we just selected.
                // A different desktop is preserved if external activity changed it.
                if currentDesktop()?.id == adjacent.id { sendControlArrow(adjacent.forward ? 123 : 124) }
                let back = await waitDesktop(before.id, seconds: 5)
                let returned = back ? await waitForFocusedGroup(targets, in: feed, scope: scope, seconds: 8) : nil
                report["nativeDesktopSwitch"] = yielded != nil && returned != nil ? "PASS" : "FAIL"
                record("nativeDesktopSwitch", ["source": before.id, "destination": adjacent.id,
                    "sourceWindowMembershipPreserved": yielded != nil, "focusedGroupAutomaticallyResumed": returned != nil,
                    "focusedWindow": returned?.window ?? 0, "resumeObservations": returned?.observations ?? [],
                    "input": "existing Control-arrow system shortcut; physical trackpad gesture not asserted"])
            } else { report["nativeDesktopSwitch"] = "BLOCKED" }

            if CGPreflightPostEventAccess(), currentDesktop()?.id == first.home {
                try await selectR4(0, group: firstGroup, visible: [first.window.number], phase: "beforeAppExpose")
                sendControlArrow(125) // Existing system App Exposé action.
                let until = ContinuousClock.now.advanced(by: .seconds(4))
                var exposed = false
                while ContinuousClock.now < until {
                    if let read = await panels.observeMissionControl(), read.mode == 1 { exposed = true; break }
                    try await Task.sleep(for: .milliseconds(80))
                }
                let yielded = exposed ? await waitForState(targets, visible: nil, focus: nil, seconds: 5, allAtHome: true) : nil
                sendEscape()
                let returned = await waitForFocusedGroup(targets, in: feed, scope: scope, seconds: 8)
                report["appExpose"] = exposed && yielded != nil && returned != nil ? "PASS" : "FAIL"
                record("appExpose", ["nativeOverviewObserved": exposed, "realWindowsReturned": yielded != nil,
                    "focusedGroupAutomaticallyResumed": returned != nil, "focusedWindow": returned?.window ?? 0,
                    "resumeObservations": returned?.observations ?? []])
            } else { report["appExpose"] = "BLOCKED" }
        } catch {
            report["status"] = startedWrites ? "FAIL" : "BLOCKED"
            report["reason"] = (error as? Failure)?.reason ?? String(describing: error)
        }
        report["dispatchAttempted"] = startedWrites
        report["statusBeforeCleanup"] = report["status"]
        report["reasonBeforeCleanup"] = report["reason"]
        report["windowPreviewMetrics"] = modules.windowPreviewMetrics
        let released = await modules.prepareStageWindowShutdown()
        let returned = await waitForState(targets, visible: Set(targets.map { $0.window.number }), focus: nil, seconds: 4)
        let clean = released && returned != nil
        panels.stop(); controller.close(); host.stop(); await modules.finishStopping()
        report["actualR4Inputs"] = actualInputs
        let orderedLatencies = switchLatenciesMS.sorted()
        if let maximum = orderedLatencies.last {
            func percentile(_ value: Double) -> Double {
                orderedLatencies[min(orderedLatencies.count - 1, max(0, Int((Double(orderedLatencies.count) * value).rounded(.up)) - 1))]
            }
            let summary: [String: Any] = ["samples": orderedLatencies.count, "p50": percentile(0.5),
                "p95": percentile(0.95), "max": maximum, "measurement": "R4 press to two matching physical readbacks"]
            report["switchLatencyMS"] = summary
        }
        report["cleanup"] = clean
        if !clean { report["status"] = "UNKNOWN"; report["reason"] = "productionRestoreIncomplete" }
        if let original, let originalImage,
           pids.contains(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
           (try? NearpaneCore.OrdinaryProcessImage.read(original.processIdentifier)) == originalImage {
            _ = original.activate(options: [])
        }
        save()
        return productPassed && clean ? 0 : (startedWrites ? 1 : 2)
    }

    private static func cg(_ number: UInt32) -> (pid: Int32, frame: CGRect, visible: Bool)? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == number,
              let pid = row[kCGWindowOwnerPID as String] as? Int32, row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        var enrolled = number
        guard let visible = NPReadVisibleWindowDescriptions(&enrolled, 1) as? [[String: Any]], visible.count <= 1 else { return nil }
        return (pid, frame, visible.count == 1)
    }

    private static func currentDesktop() -> (id: UInt64, kind: Int)? {
        guard let inventory = NPReadInventory() as? [[String: Any]], inventory.count == 1,
              let current = inventory.first?["Current Space"] as? [String: Any],
              let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value,
              let kind = (current["type"] as? NSNumber)?.intValue else { return nil }
        return (id, kind)
    }

    private static func physicalWindow(at point: CGPoint) -> Int {
        let appKit = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - point.y)
        return NSWindow.windowNumber(at: appKit, belowWindowWithWindowNumber: 0)
    }

    private static func blankDesktopPoint() -> CGPoint? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        for y in [0.25, 0.5, 0.75, 0.15, 0.85] {
            for x in [0.25, 0.5, 0.75, 0.15, 0.85] {
                let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
                if WallpaperRevealMonitor.isBlankDesktop(at: point, windowNumber: physicalWindow(at: point)) { return point }
            }
        }
        return nil
    }

    private static func clickBlankDesktop(at point: CGPoint) -> Bool {
        guard CGPreflightPostEventAccess(),
              WallpaperRevealMonitor.isBlankDesktop(at: point, windowNumber: physicalWindow(at: point)),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    private static func exerciseDesktopReveal(_ targets: [Target], nonce: UUID, feed: CurrentDesktopWindows,
                                              panels: DisplayPanels) async -> [String: Any] {
        guard let active = targets.first, CGPreflightPostEventAccess(), let point = blankDesktopPoint(),
              currentDesktop()?.id == active.home else {
            return ["status": "BLOCKED", "reason": "nativeBlankDesktopClickUnavailable"]
        }
        let activePoint = CGPoint(x: active.frame.midX, y: active.frame.midY)
        guard physicalWindow(at: activePoint) == Int(active.window.number) else {
            return ["status": "BLOCKED", "reason": "activeWindowPhysicalWitnessUnavailable"]
        }
        var hidden = [UInt32: UInt64]()
        for target in targets.dropFirst() {
            guard let spaces = NPReadWindowSpacesIncludingHidden(target.window.number) as? [UInt64], spaces.count == 1,
                  let space = spaces.first, space != target.home else {
                return ["status": "FAIL", "reason": "inactiveGroupNotHeldBeforeDesktopReveal"]
            }
            hidden[target.window.number] = space
        }
        let mouse = CGEvent(source: nil)?.location
        guard clickBlankDesktop(at: point) else { return ["status": "BLOCKED", "reason": "blankDesktopChangedBeforeClick"] }
        var entered = false, heldContinuously = true, samples = 0
        let enterDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < enterDeadline {
            for (number, space) in hidden {
                heldContinuously = heldContinuously && (NPReadWindowSpacesIncludingHidden(number) as? [UInt64]) == [space]
                    && cg(number)?.visible == false
            }
            samples += 1
            let revealed = WallpaperRevealMonitor.isBlankDesktop(at: activePoint, windowNumber: physicalWindow(at: activePoint))
            if revealed, panels.stageDisposition == .wallpaper, feed.stageEngine.wallpaperPaused { entered = true; break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        if entered {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(100))
                for (number, space) in hidden {
                    heldContinuously = heldContinuously && (NPReadWindowSpacesIncludingHidden(number) as? [UInt64]) == [space]
                        && cg(number)?.visible == false
                }
                heldContinuously = heldContinuously && feed.stageEngine.wallpaperPaused
                samples += 1
            }
        }
        // A second confirmed background click asks the OS to restore its own view.
        // If this preference is disabled, the original active window remains in place.
        let returnClick = entered && clickBlankDesktop(at: point)
        if entered && !returnClick { _ = await ownerCommand(active, action: "focus", nonce: nonce) }
        var returned = false
        let returnDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < returnDeadline {
            _ = await panels.observeMissionControl()
            feed.changed()
            if !feed.stageEngine.wallpaperPaused, panels.stageDisposition == .ordinary,
               physicalWindow(at: activePoint) == Int(active.window.number),
               await waitForState(targets, visible: [active.window.number], focus: nil, seconds: 0.3) != nil {
                returned = true; break
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        if !returned { _ = await ownerCommand(active, action: "focus", nonce: nonce) }
        if let mouse, let present = CGEvent(source: nil)?.location, abs(present.x - point.x) <= 1, abs(present.y - point.y) <= 1 {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mouse, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return ["status": !entered ? "BLOCKED" : (heldContinuously && returnClick && returned ? "PASS" : "FAIL"),
            "reason": !entered ? "clickWallpaperDidNotProduceConfirmedNativeReveal" : "nativeDesktopRevealMeasured",
            "input": "synthetic click on AX/WindowServer-confirmed blank desktop; no preference change",
            "nativeRevealObserved": entered, "originalHiddenSpacesPreserved": heldContinuously,
            "membershipSamples": samples, "returnClickIssued": returnClick, "ordinaryGroupReturned": returned,
            "physicalTrackpadGestureClaimed": false]
    }

    private static func splitInput(_ operation: String, targets: [Target], nonce: UUID,
                                   helper: String, output: URL) async -> [String: Any] {
        guard targets.count == 3, targets[0].fixture.pid == targets[1].fixture.pid else {
            return ["status": "BLOCKED", "reason": "sameApplicationPairRequired"]
        }
        var kit = URL(fileURLWithPath: targets[0].fixture.executable).resolvingSymlinksInPath()
        for _ in 0..<4 { kit.deleteLastPathComponent() }
        let binary = URL(fileURLWithPath: helper).resolvingSymlinksInPath()
        guard binary == kit.appendingPathComponent("SplitViewHelper") else {
            return ["status": "BLOCKED", "reason": "fixtureScopedSplitHelperRequired"]
        }
        let input: [String: Any] = ["operation": operation, "fixturePID": targets[0].fixture.pid,
            "fixtureBirth": targets[0].fixture.birth, "fixtureExecutable": targets[0].fixture.executable,
            "nonce": nonce.uuidString.lowercased(), "numbers": [targets[0].window.number, targets[1].window.number],
            "home": targets[0].home]
        let child = Process(), request = Pipe(), response = Pipe()
        child.executableURL = binary; child.standardInput = request; child.standardOutput = response
        let errorURL = output.appendingPathComponent("split-\(operation).stderr.log")
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: Data())
        let errorFile = try? FileHandle(forWritingTo: errorURL)
        child.standardError = errorFile ?? FileHandle.nullDevice
        defer { try? errorFile?.close() }
        do {
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            try data.write(to: output.appendingPathComponent("split-\(operation)-request.json"), options: .atomic)
            try child.run()
            try request.fileHandleForWriting.write(contentsOf: data)
            try request.fileHandleForWriting.close()
            let until = ContinuousClock.now.advanced(by: .seconds(12))
            while child.isRunning, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(50)) }
            guard !child.isRunning else {
                child.terminate()
                return ["status": "UNKNOWN", "reason": "systemSplitHelperTimedOut"]
            }
            let result = response.fileHandleForReading.readDataToEndOfFile()
            try result.write(to: output.appendingPathComponent("split-\(operation)-receipt.json"), options: .atomic)
            guard child.terminationReason == .exit, child.terminationStatus == 0,
                  let decoded = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
                return ["status": "UNKNOWN", "reason": "systemSplitHelperReceiptUnavailable"]
            }
            return decoded
        } catch {
            if child.isRunning { child.terminate() }
            return ["status": "BLOCKED", "reason": "systemSplitHelperFailed", "detail": String(describing: error)]
        }
    }

    private static func exerciseSplitView(_ targets: [Target], nonce: UUID, helper: String, output: URL,
                                         feed: CurrentDesktopWindows, panels: DisplayPanels, panel: NSWindow?,
                                         scope: StageGroupScope) async -> [String: Any] {
        let first = targets[0], second = targets[1]
        let tile = await splitInput("tile", targets: targets, nonce: nonce, helper: helper, output: output)
        guard tile["issued"] as? Bool == true else {
            return ["status": "BLOCKED", "reason": tile["reason"] ?? "nativeTileActionNotAccepted", "tile": tile]
        }
        var halfSpace: UInt64?, handedBack = false, paired = false
        var pair: [String: Any] = ["status": "NOT_RUN"]
        var pairReadbacks = [[String: Any]]()
        let halfDeadline = ContinuousClock.now.advanced(by: .seconds(7))
        while ContinuousClock.now < halfDeadline {
            panels.update(screens: SystemScreens.geometry())
            if let spaces = NPReadWindowSpacesIncludingHidden(first.window.number) as? [UInt64], spaces.count == 1,
               let space = spaces.first, space != first.home, nativeSpaceKind(space) == 4,
               panel?.isVisible == false {
                halfSpace = space
                // The OS may scale the original document in its native picker.
                // Only that system transition omits the ordinary-frame assertion.
                handedBack = await waitForState(Array(targets.dropFirst()), visible: nil, focus: nil,
                                                seconds: 0.4, allAtHome: true, preservingFrames: false) != nil
                if handedBack { break }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if handedBack {
            pair = await splitInput("pair", targets: targets, nonce: nonce, helper: helper, output: output)
            let issued = pair["issued"] as? Bool == true && (pair["axError"] as? Int).map({ $0 == 0 }) != false
            if issued || pair["alreadyTogether"] as? Bool == true {
                let pairDeadline = ContinuousClock.now.advanced(by: .seconds(7))
                while ContinuousClock.now < pairDeadline {
                    var matched = false
                    if let space = halfSpace, currentDesktop()?.id == space, nativeSpaceKind(space) == 4,
                       [first, second].allSatisfy({ target in
                           (NPReadWindowSpacesIncludingHidden(target.window.number) as? [UInt64]) == [space] &&
                           (NPReadCatalogSpaceWindowNumbers(space) as? [UInt32])?.filter({ $0 == target.window.number }).count == 1
                       }), let a = cg(first.window.number), let b = cg(second.window.number), a.visible, b.visible {
                        let halves = [a.frame, b.frame].sorted { $0.minX < $1.minX }, screen = CGDisplayBounds(CGMainDisplayID())
                        let geometry = abs(halves[0].maxX - halves[1].minX) < 30 && abs(a.frame.height - b.frame.height) < 40 &&
                            min(a.frame.height, b.frame.height) > screen.height * 0.8 &&
                            halves[1].maxX - halves[0].minX > screen.width * 0.9
                        if geometry, panel?.isVisible == false,
                           await waitForState([targets[2]], visible: [], focus: nil, seconds: 0.3, allAtHome: true) != nil {
                            matched = true
                            pairReadbacks.append(["uptime": ProcessInfo.processInfo.systemUptime, "space": space,
                                "windows": [first.window.number, second.window.number],
                                "frames": [a.frame, b.frame].map { [$0.minX, $0.minY, $0.width, $0.height] }])
                        }
                    }
                    if !matched { pairReadbacks.removeAll() }
                    if pairReadbacks.count == 2 { paired = true; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        // Always exit the native state through the fixture's own AppKit windows.
        if halfSpace != nil { sendEscape() }
        for target in [first, second] where ownerFlag(target, "fullScreen") {
            _ = await ownerCommand(target, action: "fullscreen", nonce: nonce)
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            while ownerFlag(target, "fullScreen"), ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        _ = await ownerCommand(first, action: "focus", nonce: nonce)
        let ordinary = await waitDesktop(first.home, seconds: 7)
        let returned = ordinary ? await waitForFocusedGroup(targets, in: feed, scope: scope, seconds: 9) : nil
        return ["status": paired && handedBack && returned != nil ? "PASS" :
                    (handedBack && pair["status"] as? String == "BLOCKED" && returned != nil ? "BLOCKED" : "FAIL"),
            "reason": paired ? "nativeSplitViewMeasured" : pair["reason"] ?? "nativeSplitViewNotConfirmed",
            "tile": tile, "pair": pair, "nativeFullScreenSpace": halfSpace ?? 0,
            "inactiveWindowsHandedBack": handedBack, "sameNativeSpaceAndSplitGeometry": paired,
            "splitObservations": pairReadbacks,
            "focusedGroupAutomaticallyResumed": returned != nil, "returnObservations": returned?.observations ?? []]
    }

    private static func nativeSpaceKind(_ id: UInt64) -> Int? {
        guard let rows = NPReadInventory() as? [[String: Any]] else { return nil }
        for display in rows {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                let number = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (space["id64"] as? NSNumber)?.uint64Value
                if number == id { return (space["type"] as? NSNumber)?.intValue }
            }
        }
        return nil
    }

    private static func adjacentOrdinary(to id: UInt64) -> (id: UInt64, forward: Bool)? {
        guard let inventory = NPReadInventory() as? [[String: Any]], inventory.count == 1,
              let spaces = inventory.first?["Spaces"] as? [[String: Any]] else { return nil }
        func identifier(_ row: [String: Any]) -> UInt64? {
            (row["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (row["id64"] as? NSNumber)?.uint64Value
        }
        guard let index = spaces.firstIndex(where: { identifier($0) == id }) else { return nil }
        for direction in [1, -1] {
            let next = index + direction
            if spaces.indices.contains(next), (spaces[next]["type"] as? NSNumber)?.intValue == 0,
               let neighbor = identifier(spaces[next]), neighbor != id { return (neighbor, direction == 1) }
        }
        return nil
    }

    private static func waitDesktop(_ id: UInt64, seconds: Double) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        var consecutive = 0
        while ContinuousClock.now < until {
            consecutive = currentDesktop()?.id == id ? consecutive + 1 : 0
            if consecutive == 2 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func sendControlArrow(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = .maskControl; up?.flags = .maskControl
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    private static func sendEscape() {
        let source = CGEventSource(stateID: .privateState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func ownerFlag(_ target: Target, _ name: String) -> Bool {
        let path = URL(fileURLWithPath: target.fixture.directory).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: path), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = state["windows"] as? [[String: Any]], windows.indices.contains(target.window.index),
              windows[target.window.index]["number"] as? UInt32 == target.window.number else { return false }
        return windows[target.window.index][name] as? Bool == true
    }

    private static func waitForFocusedGroup(_ targets: [Target], in feed: CurrentDesktopWindows, scope: StageGroupScope,
                                           seconds: Double) async -> (window: UInt32, observations: [[String: Any]])? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        let enrolled = Set(targets.map(\.key))
        while ContinuousClock.now < until {
            feed.changed()
            if let home = targets.first?.home, currentDesktop()?.id == home,
               let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, targets.contains(where: { $0.fixture.pid == pid }) {
                let app = AXUIElementCreateApplication(pid)
                _ = AXUIElementSetMessagingTimeout(app, 0.1)
                var focused: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                   let focused, let target = targets.first(where: { $0.fixture.pid == pid && NPReadAXWindowNumber(focused) == $0.window.number }),
                   let group = feed.groups.groups(in: scope).first(where: { $0.members.contains { $0.windowHint == target.key } }),
                   Set(group.members.map(\.windowHint)).isSubset(of: enrolled),
                   let readings = await waitForState(targets, visible: Set(group.members.map { $0.windowHint.number }),
                                                     focus: target, seconds: 0.4) {
                    return (target.window.number, readings)
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private static func waitForState(_ targets: [Target], visible: Set<UInt32>?, focus: Target?, seconds: Double,
                                     allAtHome: Bool = false, preservingFrames: Bool = true) async -> [[String: Any]]? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        var consecutive = [[String: Any]]()
        while ContinuousClock.now < until {
            var valid = true
            var observations = [[String: Any]]()
            for target in targets {
                let number = target.window.number
                guard let image = try? NearpaneCore.OrdinaryProcessImage.read(target.fixture.pid), image.launch == target.fixture.birth,
                      image.executable == URL(fileURLWithPath: target.fixture.executable).resolvingSymlinksInPath(),
                      let observed = cg(number), observed.pid == target.fixture.pid,
                      let membership = NPReadWindowSpacesIncludingHidden(number) as? [UInt64], membership.count == 1,
                      let space = membership.first, let members = NPReadCatalogSpaceWindowNumbers(space) as? [UInt32],
                      members.filter({ $0 == number }).count == 1 else { valid = false; break }
                let shouldShow = visible?.contains(number)
                let matchingFrame = abs(observed.frame.minX - target.frame.minX) <= 1 && abs(observed.frame.minY - target.frame.minY) <= 1 &&
                    abs(observed.frame.width - target.frame.width) <= 1 && abs(observed.frame.height - target.frame.height) <= 1
                let onScreenMatches = shouldShow.map { $0 == observed.visible } ?? true
                let expectedAtHome = allAtHome || shouldShow == true
                valid = valid && onScreenMatches && (expectedAtHome ? space == target.home : space != target.home) &&
                    (!preservingFrames || matchingFrame)
                observations.append(["number": number, "pid": target.fixture.pid, "space": space,
                    "onScreen": observed.visible, "framePreserved": matchingFrame, "frameRequired": preservingFrames])
            }
            if let focus {
                let app = AXUIElementCreateApplication(focus.fixture.pid)
                var focused: CFTypeRef?
                valid = valid && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.fixture.pid &&
                    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success &&
                    focused.map { NPReadAXWindowNumber($0) == focus.window.number } == true
            }
            if valid {
                consecutive.append(["uptime": ProcessInfo.processInfo.systemUptime, "windows": observations])
                if consecutive.count == 2 { return consecutive }
            } else { consecutive.removeAll() }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return nil
    }

    private static func waitButton(_ ids: Set<String>, panel: NSWindow?) async -> (any NSAccessibilityProtocol)? {
        guard let panel else { return nil }
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < until {
            if let button = button(ids, panel: panel) { return button }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }
    private static func button(_ ids: Set<String>, panel: NSWindow) -> (any NSAccessibilityProtocol)? {
        guard panel.isVisible else { return nil }
        var queue: [AnyObject] = [panel], visited = Set<ObjectIdentifier>()
        var matches = [any NSAccessibilityProtocol]()
        while let object = queue.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 1024, let node = object as? any NSAccessibilityProtocol else { continue }
            if node.accessibilityRole() == .button, node.isAccessibilityEnabled(),
               ids.contains(node.accessibilityIdentifier() ?? ""), node.accessibilityWindow() as? NSWindow === panel,
               panel.frame.intersects(node.accessibilityFrame()) { matches.append(node) }
            queue.append(contentsOf: (node.accessibilityChildren() ?? []).prefix(128).map { $0 as AnyObject })
        }
        // Prefer the group selector when a member and its group both have an input.
        if let group = matches.first(where: { ($0.accessibilityIdentifier() ?? "").hasPrefix("stage-group-select:") }) { return group }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func ownerCommand(_ target: Target, action: String, nonce: UUID) async -> Bool {
        let directory = URL(fileURLWithPath: target.fixture.directory)
        func state() -> [String: Any]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
                  let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return value as? [String: Any]
        }
        guard let before = state(), (before["nonce"] as? String).flatMap(UUID.init(uuidString:)) == nonce,
              let previous = before["commandSequence"] as? Int else { return false }
        let sequence = previous + 1
        let command: [String: Any] = ["nonce": nonce.uuidString.lowercased(), "sequence": sequence, "index": target.window.index, "action": action]
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              (try? data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)) != nil else { return false }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < until {
            if let reply = state(), reply["commandSequence"] as? Int == sequence { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func savePanel(_ panel: NSWindow?, to path: URL) {
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: path, options: .atomic) }
    }
}
