import AppKit
import CReadOnlySpaces
import Darwin
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import QuartzCore

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
        let r4Controller: String?
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
            "nonce": config.nonce.uuidString.lowercased(), "purpose": config.purpose ?? "product",
            "actualR4Inputs": 0, "foreignWindowReadback": false, "cleanup": true,
            "missionControl": "NOT_RUN", "desktopGestures": "NOT_RUN", "fullScreenSplitView": "NOT_RUN",
            "nativeFullScreen": "NOT_RUN", "nativeDesktopSwitch": "NOT_RUN", "appExpose": "NOT_RUN",
            "nativeDesktopReveal": "NOT_RUN",
            "newWindowLifecycle": "NOT_RUN", "windowCloseLifecycle": "NOT_RUN", "applicationExitLifecycle": "NOT_RUN",
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
        var externalR4ClientConfirmed = false
        var switchLatenciesMS = [Double]()
        var productPassed = false
        var startedWrites = false
        var lifecycleCreated: Target?
        var lifecycleCreationUnresolved = false
        scenario: do {
            guard let feed = modules.windowPreviews.currentDesktop else { throw Failure(reason: "packagedOverviewReaderUnavailable") }
            // Let the existing focus request settle before proving the live R4
            // panel ready. Its acknowledgement is not a verified foreground claim.
            guard await ownerCommand(targets[0], action: "focus", nonce: config.nonce) else { throw Failure(reason: "fixtureStartingFocusUnavailable") }
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
            @MainActor func selectR4(_ index: Int, group: UUID, visible: Set<UInt32>, phase: String,
                                    exactMember: Bool = false) async throws {
                let target = targets[index]
                let windowID = "current-desktop-window:\(target.fixture.pid):\(target.window.number)"
                var ids: Set<String> = exactMember ? [windowID] : Set(["native-held-group:" + group.uuidString,
                    "stage-group-select:" + group.uuidString, windowID])
                if exactMember, let sample = feed.snapshot,
                   let observed = sample.windows.first(where: { $0.metadata?.pid == target.fixture.pid && $0.metadata?.number == target.window.number }),
                   let catalog = NativeSpaceCatalog(sample, displayID: observed.displayID, now: .now, uptime: ProcessInfo.processInfo.systemUptime) {
                    ids.insert("native-space-window:\(catalog.display.id):\(catalog.current.id):\(target.fixture.pid):\(target.window.number)")
                }
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.window?.contentView?.displayIfNeeded()
                CATransaction.flush()
                if actualInputs == 0 { savePanel(controller.window, to: output.appendingPathComponent("r4-baseline.png")) }
                let button: (any NSAccessibilityProtocol)?
                if config.r4Controller != nil {
                    if !externalR4ClientConfirmed, let panel = controller.window {
                        // The exported SwiftUI AX tree is served out of process.
                        // Preserve one local diagnostic without delaying real input.
                        _ = Self.button(ids, panel: panel) { report["lastR4ButtonSearch"] = $0 }
                    }
                    button = nil
                } else { button = await waitButton(ids, panel: controller.window) { report["lastR4ButtonSearch"] = $0 } }
                var pressedAt = ProcessInfo.processInfo.systemUptime
                var route = "inProcessAccessibilityButton"
                if let button {
                    startedWrites = true
                    guard button.accessibilityPerformPress() else { throw Failure(reason: "realR4ButtonRefused") }
                    actualInputs += 1
                } else {
                    if !externalR4ClientConfirmed { savePanel(controller.window, to: output.appendingPathComponent("r4-before-external-input.png")) }
                    guard let helper = config.r4Controller, let panel = controller.window else { throw Failure(reason: "realR4ButtonUnavailable") }
                    let priorWrites = startedWrites
                    startedWrites = true
                    let external = await pressR4Externally(ids, panel: panel, helper: helper, configuration: url,
                                                          config: config, targets: targets, output: output)
                    report["lastExternalR4Press"] = external
                    if external["issued"] as? Bool == false { startedWrites = priorWrites }
                    if external["issued"] as? Bool == true { actualInputs += 1 }
                    guard external["status"] as? String == "ISSUED", external["issued"] as? Bool == true,
                          external["axError"] as? Int == 0 else { throw Failure(reason: "realExternalR4ButtonNotAccepted") }
                    externalR4ClientConfirmed = true
                    if let inputUptime = external["inputUptime"] as? Double, inputUptime.isFinite,
                       inputUptime >= pressedAt, inputUptime <= ProcessInfo.processInfo.systemUptime { pressedAt = inputUptime }
                    route = "externalAXPress"
                }
                record("R4AccessibilityButton", ["group": group.uuidString, "window": target.window.number,
                    "step": phase, "exactMember": exactMember, "route": route])
                let readings = await waitForState(targets, visible: visible, focus: target, seconds: 8,
                    diagnostic: { report["lastR4SwitchReadback"] = $0 })
                guard let readings else {
                    savePanel(controller.window, to: output.appendingPathComponent("r4-readback-failed.png"))
                    throw Failure(reason: "R4SwitchReadbackFailed")
                }
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
            if config.purpose == "hostRestart" {
                guard let group = groupIDs[targets[1].window.number],
                      let image = try? NearpaneCore.OrdinaryProcessImage.read(getpid()) else {
                    throw Failure(reason: "restartTargetIdentityUnavailable")
                }
                // The runner retains the crashed Host's original profile and ledger.
                // Only the normal startup path may reconcile that old owner. This
                // selection uses the same real R4 input and physical proof as above.
                try await selectR4(1, group: group, visible: [targets[1].window.number], phase: "afterSameProfileRestart")
                report["status"] = "HOST_RESTART_R4_PASS"
                report["reason"] = "sameProfileRestartDispatchedRealR4AndReadBack"
                report["foreignWindowReadback"] = true
                report["hostPID"] = getpid(); report["hostBirth"] = image.launch
                report["profile"] = URL(fileURLWithPath: config.profile).resolvingSymlinksInPath().path
                productPassed = true
                break scenario
            }
            if config.purpose == "lifecycle" {
                // This purpose runs only after the earlier three-window product
                // and crash/restart passes have returned their original windows.
                let originals = targets
                guard originals[0].fixture.pid == originals[1].fixture.pid,
                      originals[0].fixture.pid != originals[2].fixture.pid,
                      let firstGroup = groupIDs[originals[0].window.number],
                      let siblingGroup = groupIDs[originals[1].window.number],
                      let sample = feed.snapshot,
                      let displayID = sample.windows.first(where: { $0.metadata?.pid == originals[0].fixture.pid &&
                          $0.metadata?.number == originals[0].window.number })?.displayID,
                      let display = UUID(uuidString: displayID),
                      let nativeSpace = sample.scopes.first(where: { $0.displayID == displayID })?.records.first(where: \.isCurrent)?.ordinaryUUID
                else { throw Failure(reason: "lifecycleOriginalGroupsUnavailable") }
                let scope = StageGroupScope(display: display, nativeSpace: nativeSpace)
                let gallery = modules.windowPreviews.gallery
                let exitPicture = await waitForLifecyclePicture(originals[2], in: feed, scope: scope, gallery: gallery, seconds: 4)
                try await selectR4(0, group: firstGroup, visible: [originals[0].window.number], phase: "lifecycleBeforeCreate")
                report["foreignWindowReadback"] = true
                let idleUntil = ContinuousClock.now.advanced(by: .seconds(3))
                while NativeSidebarNavigation.shared.idleGeneration == nil, ContinuousClock.now < idleUntil {
                    try await Task.sleep(for: .milliseconds(80))
                }
                guard NativeSidebarNavigation.shared.idleGeneration != nil,
                      let before = ownerState(originals[0], nonce: config.nonce),
                      let priorSequence = before["commandSequence"] as? Int,
                      (before["windows"] as? [[String: Any]])?.count == 2,
                      before["lastCreatedIndex"] as? Int == -1 else { throw Failure(reason: "lifecycleCreationPreconditionUnavailable") }
                lifecycleCreationUnresolved = true
                let createAcknowledged = await ownerCommand(originals[0], action: "create", nonce: config.nonce)
                guard let created = await waitForCreatedWindow(originals[0], nonce: config.nonce, after: priorSequence,
                                                               excluding: Set(originals.map { $0.window.number })) else {
                    report["newWindowLifecycle"] = "FAIL"
                    record("lifecycleCreateUnconfirmed", ["commandAcknowledged": createAcknowledged])
                    throw Failure(reason: "lifecycleCreatedWindowIdentityUnconfirmed")
                }
                lifecycleCreationUnresolved = false; lifecycleCreated = created; targets.append(created)
                // Observe automatic scheduling before sending any subsequent R4
                // input. A later explicit card press cannot erase this failure.
                let automatic = await waitForState(targets, visible: [created.window.number], focus: created, seconds: 8,
                                                   diagnostic: { report["lastLifecycleArrivalReadback"] = $0 })
                report["lifecycleAutomaticArrival"] = automatic == nil ? "FAIL" : "PASS"
                record("lifecycleAutomaticArrival", ["window": created.window.number, "commandAcknowledged": createAcknowledged,
                    "status": automatic == nil ? "FAIL" : "PASS", "observations": automatic ?? [], "laterR4InputsIssued": false])
                let picture = await waitForLifecyclePicture(created, in: feed, scope: scope, gallery: gallery, seconds: 8)
                var cardSwitch = false
                if let picture {
                    savePanel(controller.window, to: output.appendingPathComponent("r4-lifecycle-created.png"))
                    record("lifecycleNewThumbnail", ["window": created.window.number, "group": picture.group.uuidString,
                        "frameSequence": picture.sequence, "width": picture.width, "height": picture.height])
                    do {
                        try await selectR4(0, group: firstGroup, visible: [originals[0].window.number], phase: "lifecycleLeaveNewWindow")
                        try await selectR4(3, group: picture.group, visible: [created.window.number], phase: "lifecycleSelectNewCard")
                        cardSwitch = true
                    } catch { record("lifecycleNewCardFailure", ["reason": (error as? Failure)?.reason ?? String(describing: error)]) }
                }
                report["lifecycleNewCardSwitch"] = cardSwitch ? "PASS" : "FAIL"
                report["newWindowLifecycle"] = createAcknowledged && automatic != nil && picture != nil && cardSwitch ? "PASS" : "FAIL"
                // Close an inactive real window so the original A0 focus remains
                // independently testable through retirement and app termination.
                try await selectR4(0, group: firstGroup, visible: [originals[0].window.number], phase: "lifecycleBeforeClose")
                let closeAcknowledged = await ownerCommand(created, action: "close", nonce: config.nonce)
                let closed = await waitForLifecycleAbsence(created, processExit: false, seconds: 6)
                record("lifecycleWindowClosed", ["window": created.window.number, "commandAcknowledged": closeAcknowledged,
                    "observations": closed ?? []])
                guard closed != nil else {
                    report["windowCloseLifecycle"] = "FAIL"
                    throw Failure(reason: "lifecycleClosedWindowAbsenceUnconfirmed")
                }
                targets.removeAll { $0.key == created.key }; lifecycleCreated = nil
                let retired = await waitForLifecycleRetirement(created, picture: picture?.target, in: feed, scope: scope,
                                                               gallery: gallery, seconds: 6)
                let retained = await waitForState(targets, visible: [originals[0].window.number], focus: originals[0], seconds: 6)
                report["windowCloseLifecycle"] = closeAcknowledged && retired != nil && retained != nil && picture != nil ? "PASS" : "FAIL"
                record("lifecycleWindowRetired", ["window": created.window.number, "retirement": retired ?? [],
                    "originalThreePreserved": retained ?? [], "thumbnailWasObserved": picture != nil])
                savePanel(controller.window, to: output.appendingPathComponent("r4-lifecycle-closed.png"))
                // B is quit last, after every earlier phase depending on its real
                // original window. Only its own fixture command closes this app.
                guard retired != nil, retained != nil else { throw Failure(reason: "lifecycleOriginalThreeAfterCloseUnconfirmed") }
                let quitAcknowledged = await ownerCommand(originals[2], action: "quit", nonce: config.nonce)
                let exited = await waitForLifecycleAbsence(originals[2], processExit: true, seconds: 6)
                record("lifecycleApplicationExited", ["pid": originals[2].fixture.pid, "birth": originals[2].fixture.birth,
                    "commandAcknowledged": quitAcknowledged, "observations": exited ?? []])
                guard exited != nil else {
                    report["applicationExitLifecycle"] = "FAIL"
                    throw Failure(reason: "lifecycleExitedOwnerGenerationUnconfirmed")
                }
                targets.removeAll { $0.fixture.pid == originals[2].fixture.pid && $0.fixture.birth == originals[2].fixture.birth }
                let exitRetired = await waitForLifecycleRetirement(originals[2], picture: exitPicture?.target, in: feed,
                    scope: scope, gallery: gallery, seconds: 6)
                var survivors = false
                if exitRetired != nil {
                    do {
                        try await selectR4(1, group: siblingGroup, visible: [originals[1].window.number], phase: "lifecycleSurvivingA1")
                        try await selectR4(0, group: firstGroup, visible: [originals[0].window.number], phase: "lifecycleSurvivingA0")
                        survivors = true
                    } catch { record("lifecycleSurvivingCardFailure", ["reason": (error as? Failure)?.reason ?? String(describing: error)]) }
                }
                report["applicationExitLifecycle"] = quitAcknowledged && exitRetired != nil && exitPicture != nil && survivors ? "PASS" : "FAIL"
                record("lifecycleExitedGroupRetired", ["retirement": exitRetired ?? [], "survivingR4Switches": survivors,
                    "thumbnailWasObserved": exitPicture != nil])
                savePanel(controller.window, to: output.appendingPathComponent("r4-lifecycle-exited.png"))
                productPassed = ["newWindowLifecycle", "windowCloseLifecycle", "applicationExitLifecycle"].allSatisfy { report[$0] as? String == "PASS" }
                report["status"] = productPassed ? "PRODUCT_LIFECYCLE_PASS" : "FAIL"
                report["reason"] = productPassed ? "realCreationClosureExitAndR4SurvivorsConfirmed" : "lifecycleEvidenceIncomplete"
                report["foreignWindowReadback"] = true
                break scenario
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
                if retired, let group = groupIDs[first.window.number] {
                    try await selectR4(0, group: group, visible: [first.window.number], phase: "yellowButtonRestore")
                    report["yellowButtonRouting"] = "PASS"
                    record("yellowButtonRouting", ["retiredIntoHiddenSpace": true, "restored": true])
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
            if let feed = modules.windowPreviews.currentDesktop {
                report["r4DispatchStateAtFailure"] = dispatchState(targets, in: feed)
            }
        }
        report["dispatchAttempted"] = startedWrites
        report["statusBeforeCleanup"] = report["status"]
        report["reasonBeforeCleanup"] = report["reason"]
        report["windowPreviewMetrics"] = modules.windowPreviewMetrics
        if let created = lifecycleCreated {
            _ = await ownerCommand(created, action: "close", nonce: config.nonce)
            let gone = await waitForLifecycleAbsence(created, processExit: false, seconds: 3)
            record("lifecycleExtraWindowCleanup", ["number": created.window.number, "observations": gone ?? []])
            if gone != nil { targets.removeAll { $0.key == created.key }; lifecycleCreated = nil }
        }
        if lifecycleCreationUnresolved, let first = targets.first {
            // Cancel the bounded create command even when no authoritative new
            // window identity was obtained. Unknown cleanup stays unknown.
            _ = await ownerCommand(first, action: "close", nonce: config.nonce, index: 2)
        }
        let released = await modules.prepareStageWindowShutdown()
        let returned = await waitForState(targets, visible: Set(targets.map { $0.window.number }), focus: nil, seconds: 4)
        let clean = released && returned != nil && lifecycleCreated == nil && !lifecycleCreationUnresolved
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

    private static func dispatchState(_ targets: [Target], in feed: CurrentDesktopWindows) -> [String: Any] {
        var result: [String: Any] = ["navigationIssue": NativeSidebarNavigation.shared.issue ?? "none",
            "navigationDispatchAvailable": NativeSidebarNavigation.shared.dispatchAvailable,
            "groupIssue": feed.groupIssue ?? "none", "groupLoadIssue": feed.groups.loadIssue ?? "none",
            "consentRequestPresent": feed.stageEngine.consentRequest != nil,
            "routesGroupChoice": feed.stageEngine.routesGroupChoice, "holdsDispatch": feed.stageEngine.holdsDispatch,
            "snapshotAvailable": feed.snapshot != nil]
        if let sample = feed.snapshot {
            result["revision"] = sample.revision
            result["fresh"] = sample.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime)
            result["catalogComplete"] = sample.native?.catalogComplete ?? false
            if let native = sample.native {
                result["sampleAgeSeconds"] = ProcessInfo.processInfo.systemUptime - native.beganUptime
                result["sampleDurationSeconds"] = native.endedUptime - native.beganUptime
            }
        }
        var rows = [[String: Any]]()
        for target in targets {
            let key = DesktopWindowKey(pid: target.fixture.pid, birth: target.fixture.birth, number: target.window.number)
            var row: [String: Any] = ["pid": target.fixture.pid, "number": target.window.number,
                "ordinaryLifetime": feed.lifetime(of: key)?.uuidString ?? "none",
                "groupLifetime": feed.groupLifetime(of: key)?.uuidString ?? "none", "visibleGroupBound": false]
            if let sample = feed.snapshot,
               let observed = sample.windows.first(where: { DesktopWindowKey($0) == key }),
               let screen = sample.displays.first(where: { $0.id == observed.displayID }) {
                let group = feed.visibleGroups(in: sample, on: screen)[target.key]
                row["visibleGroupBound"] = group != nil
                row["visibleGroup"] = group?.id.uuidString ?? "none"
                row["visibleGroupMembers"] = group?.members.count ?? 0
            }
            rows.append(row)
        }
        result["targets"] = rows
        return result
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
                                     allAtHome: Bool = false, preservingFrames: Bool = true,
                                     diagnostic: (([String: Any]) -> Void)? = nil) async -> [[String: Any]]? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        var consecutive = [[String: Any]]()
        while ContinuousClock.now < until {
            var valid = true
            var observations = [[String: Any]]()
            for target in targets {
                let number = target.window.number
                guard let image = try? NearpaneCore.OrdinaryProcessImage.read(target.fixture.pid), image.launch == target.fixture.birth,
                      image.executable == URL(fileURLWithPath: target.fixture.executable).resolvingSymlinksInPath() else {
                    observations.append(["number": number, "pid": target.fixture.pid, "failure": "processIdentityUnavailableOrChanged"])
                    valid = false; break
                }
                guard let observed = cg(number), observed.pid == target.fixture.pid else {
                    observations.append(["number": number, "pid": target.fixture.pid, "failure": "physicalWindowUnavailableOrChanged"])
                    valid = false; break
                }
                guard let membership = NPReadWindowSpacesIncludingHidden(number) as? [UInt64], membership.count == 1,
                      let space = membership.first else {
                    observations.append(["number": number, "pid": target.fixture.pid, "failure": "singleMembershipUnavailable"])
                    valid = false; break
                }
                guard let members = NPReadCatalogSpaceWindowNumbers(space) as? [UInt32], members.filter({ $0 == number }).count == 1 else {
                    observations.append(["number": number, "pid": target.fixture.pid, "space": space, "failure": "reverseMembershipUnconfirmed"])
                    valid = false; break
                }
                let shouldShow = visible?.contains(number)
                let matchingFrame = abs(observed.frame.minX - target.frame.minX) <= 1 && abs(observed.frame.minY - target.frame.minY) <= 1 &&
                    abs(observed.frame.width - target.frame.width) <= 1 && abs(observed.frame.height - target.frame.height) <= 1
                let onScreenMatches = shouldShow.map { $0 == observed.visible } ?? true
                let expectedAtHome = allAtHome || shouldShow == true
                valid = valid && onScreenMatches && (expectedAtHome ? space == target.home : space != target.home) &&
                    (!preservingFrames || matchingFrame)
                observations.append(["number": number, "pid": target.fixture.pid, "space": space,
                    "home": target.home, "homeRequired": expectedAtHome, "onScreen": observed.visible,
                    "visibilityMatched": onScreenMatches, "framePreserved": matchingFrame, "frameRequired": preservingFrames])
            }
            var focusRead: [String: Any] = ["required": focus != nil]
            if let focus {
                let app = AXUIElementCreateApplication(focus.fixture.pid)
                _ = AXUIElementSetMessagingTimeout(app, 0.1)
                var focused: CFTypeRef?
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
                let number = focused.map { NPReadAXWindowNumber($0) }
                let confirmed = front == focus.fixture.pid && error == .success && number == focus.window.number
                focusRead = ["required": true, "expectedPID": focus.fixture.pid, "expectedWindow": focus.window.number,
                    "frontPID": front ?? -1, "focusedWindow": number ?? 0, "focusedWindowRead": error.rawValue, "verified": confirmed]
                valid = valid && confirmed
            }
            diagnostic?(["uptime": ProcessInfo.processInfo.systemUptime, "windows": observations, "focus": focusRead, "verified": valid])
            if valid {
                consecutive.append(["uptime": ProcessInfo.processInfo.systemUptime, "windows": observations])
                if consecutive.count == 2 { return consecutive }
            } else { consecutive.removeAll() }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return nil
    }

    private static func pressR4Externally(_ ids: Set<String>, panel: NSWindow, helper: String,
                                         configuration: URL, config: Configuration,
                                         targets: [Target], output: URL) async -> [String: Any] {
        guard let first = targets.first, panel.isVisible, let number = UInt32(exactly: panel.windowNumber), number > 0,
              let host = try? NearpaneCore.OrdinaryProcessImage.read(getpid()) else {
            return ["status": "BLOCKED", "issued": false, "reason": "parentPanelIdentityUnavailable"]
        }
        var kit = URL(fileURLWithPath: first.fixture.executable).resolvingSymlinksInPath()
        for _ in 0..<4 { kit.deleteLastPathComponent() }
        let binary = URL(fileURLWithPath: helper).resolvingSymlinksInPath()
        let expected = kit.appendingPathComponent("Controller.app/Contents/MacOS/Controller").resolvingSymlinksInPath()
        guard binary.path == expected.path else {
            return ["status": "BLOCKED", "issued": false, "reason": "fixtureScopedControllerRequired"]
        }
        let stem = "r4-press-" + UUID().uuidString.lowercased()
        let requestURL = output.appendingPathComponent(stem + ".request.json")
        let resultURL = output.appendingPathComponent(stem + ".result.json")
        let request: [String: Any] = ["schema": 1, "nonce": config.nonce.uuidString.lowercased(),
            "configuration": configuration.resolvingSymlinksInPath().path, "result": resultURL.path,
            "host": ["pid": getpid(), "birth": host.launch, "executable": host.executable.path, "number": number],
            "identifiers": ids.sorted()]
        let child = Process(); child.executableURL = binary; child.arguments = ["--press-r4", requestURL.path]
        let logURL = output.appendingPathComponent(stem + ".log"), errorURL = output.appendingPathComponent(stem + ".stderr.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: Data())
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: Data())
        let log = try? FileHandle(forWritingTo: logURL), error = try? FileHandle(forWritingTo: errorURL)
        child.standardOutput = log ?? FileHandle.nullDevice; child.standardError = error ?? FileHandle.nullDevice
        defer { try? log?.close(); try? error?.close() }
        var launched = false
        do {
            try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL, options: .withoutOverwriting)
            try child.run(); launched = true
            let until = ContinuousClock.now.advanced(by: .seconds(12))
            while child.isRunning, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(40)) }
            guard !child.isRunning else {
                child.terminate()
                return ["status": "UNKNOWN", "reason": "externalR4PressTimedOut", "request": requestURL.lastPathComponent]
            }
            guard let data = try? Data(contentsOf: resultURL),
                  var result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (result["nonce"] as? String).flatMap(UUID.init(uuidString:)) == config.nonce else {
                return ["status": "UNKNOWN", "reason": "externalR4PressReceiptUnavailable", "request": requestURL.lastPathComponent]
            }
            result["processExit"] = child.terminationStatus; result["receipt"] = resultURL.lastPathComponent
            if child.terminationReason != .exit || child.terminationStatus != 0 { result["status"] = "UNKNOWN" }
            return result
        } catch {
            if child.isRunning { child.terminate() }
            var result: [String: Any] = ["status": launched ? "UNKNOWN" : "BLOCKED", "reason": "externalR4PressFailed",
                                         "detail": String(describing: error), "request": requestURL.lastPathComponent]
            if !launched { result["issued"] = false }
            return result
        }
    }

    private static func waitButton(_ ids: Set<String>, panel: NSWindow?,
                                   diagnostic: (([String: Any]) -> Void)? = nil) async -> (any NSAccessibilityProtocol)? {
        guard let panel else { return nil }
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < until {
            if let button = button(ids, panel: panel, diagnostic: diagnostic) { return button }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }
    private static func button(_ ids: Set<String>, panel: NSWindow,
                               diagnostic: (([String: Any]) -> Void)? = nil) -> (any NSAccessibilityProtocol)? {
        guard panel.isVisible else {
            diagnostic?(["panelVisible": false, "expectedIDs": ids.sorted()]); return nil
        }
        var queue: [AnyObject] = [panel], visited = Set<ObjectIdentifier>()
        var matches = [any NSAccessibilityProtocol]()
        var rows = [[String: Any]](), nonProtocol = [String: Int](), protocolCount = 0, complete = true
        while let object = queue.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 1024 else { complete = false; break }
            let type = String(reflecting: Swift.type(of: object))
            guard let node = object as? any NSAccessibilityProtocol else {
                nonProtocol[type, default: 0] += 1; continue
            }
            protocolCount += 1
            let role = node.accessibilityRole(), id = node.accessibilityIdentifier(), owner = node.accessibilityWindow()
            let frame = node.accessibilityFrame(), enabled = node.isAccessibilityEnabled()
            let sameWindow = owner as? NSWindow === panel, intersects = panel.frame.intersects(frame)
            if role == .button, enabled, ids.contains(id ?? ""), sameWindow, intersects { matches.append(node) }
            let children = node.accessibilityChildren() ?? []
            if rows.count < 128 {
                rows.append(["class": type, "role": role?.rawValue ?? "nil", "identifier": id ?? "nil",
                    "enabled": enabled, "windowClass": owner.map { String(reflecting: Swift.type(of: $0)) } ?? "nil",
                    "samePanelWindow": sameWindow, "frame": NSStringFromRect(frame), "intersectsPanel": intersects,
                    "children": children.count])
            }
            guard children.count <= 128 else { complete = false; break }
            queue.append(contentsOf: children.map { $0 as AnyObject })
        }
        diagnostic?(["panelVisible": panel.isVisible, "panelNumber": panel.windowNumber,
            "panelFrame": NSStringFromRect(panel.frame), "expectedIDs": ids.sorted(), "visited": visited.count,
            "protocolNodes": protocolCount, "nonProtocolClasses": nonProtocol, "completeTraversal": complete,
            "matchingButtons": matches.count, "nodes": rows])
        guard complete else { return nil }
        // Prefer the group selector when a member and its group both have an input.
        if let group = matches.first(where: { ($0.accessibilityIdentifier() ?? "").hasPrefix("stage-group-select:") }) { return group }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func ownerState(_ target: Target, nonce: UUID) -> [String: Any]? {
        let path = URL(fileURLWithPath: target.fixture.directory).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["nonce"] as? String).flatMap(UUID.init(uuidString:)) == nonce,
              value["pid"] as? Int32 == target.fixture.pid, value["birth"] as? UInt64 == target.fixture.birth else { return nil }
        return value
    }

    private static func waitForCreatedWindow(_ owner: Target, nonce: UUID, after sequence: Int,
                                             excluding originalNumbers: Set<UInt32>) async -> Target? {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < until {
            if let state = ownerState(owner, nonce: nonce), let createdSequence = state["lastCreatedSequence"] as? Int,
               createdSequence > sequence, state["commandSequence"] as? Int == createdSequence,
               state["lastCreatedIndex"] as? Int == 2, let rows = state["windows"] as? [[String: Any]], rows.count == 3,
               let row = rows.first(where: { $0["index"] as? Int == 2 }), let number = row["number"] as? UInt32,
               number > 0, !originalNumbers.contains(number),
               let image = try? NearpaneCore.OrdinaryProcessImage.read(owner.fixture.pid), image.launch == owner.fixture.birth,
               image.executable == URL(fileURLWithPath: owner.fixture.executable).resolvingSymlinksInPath(),
               let observed = cg(number), observed.pid == owner.fixture.pid {
                return .init(fixture: owner.fixture, window: .init(index: 2, number: number), frame: observed.frame, home: owner.home)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return nil
    }

    private static func waitForLifecyclePicture(_ target: Target, in feed: CurrentDesktopWindows, scope: StageGroupScope,
                                                gallery: DesktopWindowGallery, seconds: Double) async
        -> (group: UUID, target: DesktopWindowTarget, sequence: UInt64, width: Int, height: Int)? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        while ContinuousClock.now < until {
            feed.changed()
            if let sample = feed.snapshot, sample.native?.catalogComplete == true,
               sample.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime),
               let row = sample.windows.first(where: { $0.metadata?.pid == target.fixture.pid &&
                   $0.metadata?.number == target.window.number && $0.metadata?.launchMicroseconds == target.fixture.birth }),
               let picture = DesktopWindowTarget.preview(row, in: sample),
               let group = feed.groups.groups(in: scope).first(where: { $0.members.count == 1 && $0.members.first?.windowHint == target.key }),
               gallery.frameSequence(for: picture) > 0,
               let image = gallery.image(for: picture, permitted: true), image.width > 0, image.height > 0 {
                return (group.id, picture, gallery.frameSequence(for: picture), image.width, image.height)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private static func waitForLifecycleAbsence(_ target: Target, processExit: Bool, seconds: Double) async -> [[String: Any]]? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        var consecutive = [[String: Any]]()
        while ContinuousClock.now < until {
            var observation: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
                "pid": target.fixture.pid, "birth": target.fixture.birth, "number": target.window.number]
            let image = try? NearpaneCore.OrdinaryProcessImage.read(target.fixture.pid)
            let sameOwner = image?.launch == target.fixture.birth &&
                image?.executable == URL(fileURLWithPath: target.fixture.executable).resolvingSymlinksInPath()
            var ownerExited = image.map { $0.launch != target.fixture.birth } ?? false
            if !ownerExited {
                errno = 0
                ownerExited = kill(target.fixture.pid, 0) == -1 && errno == ESRCH
            }
            let cgPresence = NPReadWindowNumberPresence(target.window.number)
            observation["cgPresence"] = cgPresence
            observation["originalOwnerGenerationExited"] = ownerExited
            let app = AXUIElementCreateApplication(target.fixture.pid)
            _ = AXUIElementSetMessagingTimeout(app, 0.1)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            observation["axWindowsRead"] = error.rawValue
            var completeAXAbsence = false
            if error == .success, let windows = value as? [AXUIElement], windows.count <= 16 {
                var numbers = [UInt32](), complete = true
                for window in windows {
                    var pid: pid_t = 0
                    let number = NPReadAXWindowNumber(window)
                    if AXUIElementGetPid(window, &pid) != .success || pid != target.fixture.pid || number == 0 {
                        complete = false; break
                    }
                    numbers.append(number)
                }
                observation["axWindowNumbers"] = numbers
                observation["axWindowsComplete"] = complete
                completeAXAbsence = complete && !numbers.contains(target.window.number)
            }
            // After positive process-generation exit, the original AX server
            // no longer exists. An AX timeout alone is never disappearance.
            observation["axAbsenceBasis"] = processExit ? "originalOwnerGenerationExited" : "completeLiveOwnerAXWindows"
            observation["axWindowAbsentInCompleteRead"] = completeAXAbsence
            let valid = cgPresence == 0 && (processExit ? ownerExited : sameOwner && !ownerExited && completeAXAbsence)
            if valid {
                consecutive.append(observation)
                if consecutive.count == 2 { return consecutive }
            } else { consecutive.removeAll() }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private static func waitForLifecycleRetirement(_ target: Target, picture: DesktopWindowTarget?, in feed: CurrentDesktopWindows,
                                                   scope: StageGroupScope, gallery: DesktopWindowGallery,
                                                   seconds: Double) async -> [[String: Any]]? {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        let key = DesktopWindowKey(pid: target.fixture.pid, birth: target.fixture.birth, number: target.window.number)
        var consecutive = [[String: Any]]()
        while ContinuousClock.now < until {
            guard let sample = await feed.readAfterAction(), sample.native?.catalogComplete == true,
                  sample.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else {
                consecutive.removeAll(); try? await Task.sleep(for: .milliseconds(80)); continue
            }
            let catalogGone = !sample.windows.contains { $0.metadata?.pid == target.fixture.pid &&
                $0.metadata?.number == target.window.number && $0.metadata?.launchMicroseconds == target.fixture.birth }
            let groupGone = !feed.groups.groups(in: scope).contains { $0.members.contains { $0.windowHint == target.key } }
            let heldGone = !feed.stageEngine.heldGroups.contains { $0.state.window == target.key ||
                $0.departure?.members.contains(where: { $0.before.window == target.key }) == true }
            let lifetimeGone = feed.lifetime(of: key) == nil && feed.groupLifetime(of: key) == nil
            let thumbnailGone = picture.map { gallery.frameSequence(for: $0) == 0 &&
                gallery.image(for: $0, permitted: true) == nil && gallery.previousImage(for: $0, permitted: true) == nil } ?? true
            if catalogGone && groupGone && heldGone && lifetimeGone && thumbnailGone {
                consecutive.append(["uptime": ProcessInfo.processInfo.systemUptime, "revision": sample.revision,
                    "catalogAbsent": catalogGone, "groupAbsent": groupGone, "heldCardAbsent": heldGone,
                    "lifetimeRetired": lifetimeGone, "thumbnailUnavailable": thumbnailGone,
                    "thumbnailPreviouslyObserved": picture != nil])
                if consecutive.count == 2 { return consecutive }
            } else { consecutive.removeAll() }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private static func ownerCommand(_ target: Target, action: String, nonce: UUID, index: Int? = nil) async -> Bool {
        let directory = URL(fileURLWithPath: target.fixture.directory)
        guard let before = ownerState(target, nonce: nonce), let previous = before["commandSequence"] as? Int else { return false }
        let sequence = previous + 1
        let command: [String: Any] = ["nonce": nonce.uuidString.lowercased(), "sequence": sequence,
                                     "index": index ?? target.window.index, "action": action]
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              (try? data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)) != nil else { return false }
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < until {
            if let reply = ownerState(target, nonce: nonce), reply["commandSequence"] as? Int == sequence { return true }
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
