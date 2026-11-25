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
                      let spaces = NPReadWindowSpaces(window.number) as? [UInt64], spaces.count == 1,
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
            feed.observe(true)
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            var groupIDs = [UInt32: UUID]()
            var candidateReady = false
            while ContinuousClock.now < readyDeadline {
                feed.changed()
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
                    if groupIDs.count == 3, Set(groupIDs.values).count == 3, feed.stageEngine.observedCapability == .spaces,
                       modules.workRect?.permitsStageEngine(on: screen.id) == true { candidateReady = true; break }
                }
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
                    if let spaces = NPReadWindowSpaces(first.window.number) as? [UInt64], spaces.count == 1,
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
                                     allAtHome: Bool = false) async -> [[String: Any]]? {
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
                      let membership = NPReadWindowSpaces(number) as? [UInt64], membership.count == 1,
                      let space = membership.first, let members = NPReadCatalogSpaceWindowNumbers(space) as? [UInt32],
                      members.filter({ $0 == number }).count == 1 else { valid = false; break }
                let shouldShow = visible?.contains(number)
                let matchingFrame = abs(observed.frame.minX - target.frame.minX) <= 1 && abs(observed.frame.minY - target.frame.minY) <= 1 &&
                    abs(observed.frame.width - target.frame.width) <= 1 && abs(observed.frame.height - target.frame.height) <= 1
                let onScreenMatches = shouldShow.map { $0 == observed.visible } ?? true
                let expectedAtHome = allAtHome || shouldShow == true
                valid = valid && onScreenMatches && (expectedAtHome ? space == target.home : space != target.home) && matchingFrame
                observations.append(["number": number, "pid": target.fixture.pid, "space": space,
                    "onScreen": observed.visible, "framePreserved": matchingFrame])
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
