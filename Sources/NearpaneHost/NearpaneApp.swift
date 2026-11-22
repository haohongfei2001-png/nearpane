import AppKit
import OSLog
import Combine
import SwiftUI
import NearpaneCore
import NearpaneUI
#if canImport(SaytileKit) && canImport(RiftletAdapters)
import SaytileKit
import RiftletAdapters
import NearpaneTray
#endif

@main
struct NearpaneApp {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--read-stage-engine-scope" {
            guard (2...5).contains(args.count), let challenge = UUID(uuidString: args[1]) else { exit(2) }
            let options = Set(args.dropFirst(2))
            let deferred = options.contains("--await-registered-window")
            let spacesCycle = options.contains("--enrolled-spaces-cycle")
            let ownCanary = options.contains("--installed-spaces-canary")
            let interactiveSpaces = options.contains("--interactive-spaces-cycle")
            let interactive = options.contains("--interactive-window-pair") || interactiveSpaces
            guard options.count == args.count-2,
                  options.isSubset(of: ["--registered-window","--private-receipt","--await-registered-window","--enrolled-spaces-cycle","--installed-spaces-canary","--interactive-window-pair","--interactive-spaces-cycle"]),
                  !deferred || (options.contains("--private-receipt") && !options.contains("--registered-window")),
                  !ownCanary || options == ["--private-receipt","--installed-spaces-canary"],
                  !interactive || options == ["--private-receipt", interactiveSpaces ? "--interactive-spaces-cycle" : "--interactive-window-pair"],
                  !spacesCycle || deferred,
                  !(spacesCycle || ownCanary || interactive) || (Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/Nearpane.app" &&
                      Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha") else { exit(2) }
            let channel: StageScopeReply?
            let fixture: StageEngineHostScope.Fixture?
            do {
                channel = options.contains("--private-receipt") ? try StageScopeReply(challenge) : nil
                fixture = options.contains("--registered-window") ? try StageEnginePackageProbe.enrolledFixture(channel) : nil
            } catch { exit(2) }
            let application = NSApplication.shared
            if application.activationPolicy() != .prohibited { _ = application.setActivationPolicy(.prohibited) }
            guard application.activationPolicy() == .prohibited else { exit(3) }
            Task { exit(await StageEnginePackageProbe.readScope(challenge: challenge, fixture: fixture, channel: channel,
                                                                awaitRegistration: deferred, enrolledSpacesCycle: spacesCycle,
                                                                ownSpacesCanary: ownCanary, interactivePair: interactive, interactiveSpaces: interactiveSpaces)) }
            RunLoop.main.run()
            return
        }
        if args.first == "--verify-stage-window-engine" || args.first == "--probe-stage-window-engine" {
            let observe = args.first == "--probe-stage-window-engine"
            let challenge = args.count == 2 ? UUID(uuidString: args[1]) : nil
            guard args.count == 1 || (observe && challenge != nil) else { exit(2) }
            Task { exit(await StageEnginePackageProbe.run(observeSystem: observe, challenge: challenge)) }
            RunLoop.main.run()
            return
        }
        if args == ["--check-helper-runtime"] {
            do {
                let child = Process()
                child.executableURL = try BundledAutomation.executable()
                child.arguments = ["--self-check"]
                try child.run()
                child.waitUntilExit()
                exit(child.terminationStatus)
            } catch {
                print(error.localizedDescription)
                exit(3)
            }
        }
        #if canImport(SaytileKit)
        if args.first == "--upgrade-staged-voice" {
            guard CandidateProfile.selected, args.count == 2 else { exit(2) }
            let stage = URL(fileURLWithPath: args[1]).standardizedFileURL
            let work = stage.deletingLastPathComponent()
            let transactions = work.deletingLastPathComponent()
            let root = transactions.deletingLastPathComponent()
            guard stage.lastPathComponent == "generation", transactions.lastPathComponent == "transactions",
                  root.lastPathComponent == CandidateProfile.containerName,
                  UUID(uuidString: work.lastPathComponent)?.uuidString.lowercased() == work.lastPathComponent else { exit(2) }
            Task {
                do {
                    try ProfileLease.checkPath(stage)
                    let owned = try Data(contentsOf: work.appendingPathComponent("ownership.json"))
                    guard owned == (try Data(contentsOf: root.appendingPathComponent("transaction.json"))),
                          let tx = try JSONSerialization.jsonObject(with: owned) as? [String: Any],
                          tx["next"] as? String == work.lastPathComponent,
                          try CandidateProfile.inspectStores(in: stage)["voiceSchema"] == 5 else { exit(3) }
                    let store = try SaytileStore(directory: stage.appendingPathComponent("Nearpane/Voice"))
                    try await store.close()
                    guard try CandidateProfile.inspectStores(in: stage)["voiceSchema"] == 6 else { exit(3) }
                    exit(0)
                } catch { exit(3) }
            }
            dispatchMain()
        }
        if args.first == "--validate-import-configuration" {
            guard CandidateProfile.selected, args.count == 2 else { exit(2) }
            let file = URL(fileURLWithPath: args[1])
            let components = file.pathComponents
            guard components.count >= 7, Array(components.suffix(3)) == ["generation", "Nearpane", "host-configuration.json"],
                  components[components.count - 5] == "transactions",
                  components[components.count - 6] == CandidateProfile.containerName,
                  UUID(uuidString: components[components.count - 4])?.uuidString.lowercased() == components[components.count - 4] else { exit(2) }
            do {
                try ProfileLease.checkPath(file)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else { exit(3) }
                let configuration = try FileConfigurationStore(url: file).load()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(configuration))
                return
            } catch { exit(3) }
        }
        #endif
        if args.first == "--verify-bundled-resources" {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                FileHandle.standardError.write(Data("Resource check requires a packaged app.\n".utf8))
                exit(1)
            }
            #if canImport(SaytileKit) && canImport(RiftletAdapters)
            do {
                // Read and validate packaged files. No GUI, store, target, device or transport is created.
                _ = try CloudConnectionVerifier.bundledSample()
                // Apple Speech uses installed system resources; only optional engines ship catalog manifests.
                for id in LocalASRID.allCases where id != .apple { _ = try LocalModelManifest.load(id) }
                _ = try LegacyWebObservationProgram.wrapping(ChatGPTWebPageProgram.load())
                print("Packaged Saytile and Riftlet resources verified.")
                if args.count > 1 {
                    if args.count == 4, args[1] == "--native-zh-assets", ["status", "prepare"].contains(args[3]) {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        Task { await session.reportChineseAssets(prepare: args[3] == "prepare") }
                        dispatchMain()
                    }
                    if args == ["--verify-bundled-resources", "--native-receipt-policy"] {
                        let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
                        guard data.count <= 1_048_576, try TestReceiptPolicy.admits(data) else { exit(3) }
                        print("Domain receipt admitted.")
                        return
                    }
                    if #available(macOS 15.2, *), CandidateProfile.selected, args.count == 5, args[1] == "--selected-window-readback",
                       let pid = Int32(args[3]), let number = UInt32(args[4]) {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        _ = NSApplication.shared.setActivationPolicy(.prohibited)
                        guard let owner = NativeManagementAcceptance.ownedStandardFixture(pid: pid, kind: .documents) else {
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                        Task { @MainActor in
                            do {
                                let receipt = try await SelectedPreviewReadback.run(owner: owner, number: number, support: session.support)
                                try receipt.write(to: session.directory.appendingPathComponent("selected-preview.json"), options: .withoutOverwriting)
                                exit(0)
                            } catch {
                                FileHandle.standardError.write(Data("Selected-window readback failed: \(error.localizedDescription)\n".utf8)); exit(3)
                            }
                        }
                        RunLoop.main.run()
                        return
                    }
                    if args.count == 4, args[1] == "--native-browser-identity", let pid = Int32(args[3]) {
                        _ = try NativeAcceptanceSession(id: args[2], prepare: false)
                        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").filter { !$0.isTerminated }
                        guard running.count == 1, running[0].processIdentifier == pid, let identity = ChromeProcessIdentity.read(pid: pid)
                        else { throw CocoaError(.validationMissingMandatoryProperty) }
                        print(identity.session)
                        return
                    }
                    guard args.count == 3 else { exit(2) }
                    if CandidateProfile.selected, args[1] == "--desktop-tiling-readiness" {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        _ = NSApplication.shared.setActivationPolicy(.prohibited)
                        Task { @MainActor in
                            do {
                                let proof = await CandidateWorkRect.desktopTilingReadiness()
                                try JSONEncoder().encode(proof).write(to: session.directory.appendingPathComponent("desktop-tiling-readiness.json"), options: .withoutOverwriting)
                                exit(0)
                            } catch { exit(3) }
                        }
                        RunLoop.main.run()
                        return
                    }
                    if CandidateProfile.selected, args[1] == "--selected-window-readiness" {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        _ = NSApplication.shared.setActivationPolicy(.prohibited)
                        let result = ["capture": CGPreflightScreenCaptureAccess(), "single": NSScreen.screens.count == 1]
                        try JSONEncoder().encode(result).write(to: session.directory.appendingPathComponent("preview-readiness.json"), options: .withoutOverwriting)
                        return
                    }
                    if CandidateProfile.selected, args[1] == "--native-settings-readback" {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        Task { @MainActor in
                            do { try await HostAppDelegate().renderSettingsReadback(session); exit(0) }
                            catch { FileHandle.standardError.write(Data("Native product window readback failed: \(error)\n".utf8)); exit(3) }
                        }
                        RunLoop.main.run()
                        return
                    }
                    if CandidateProfile.selected, args[1] == "--profile-acceptance-open" {
                        let session = try NativeAcceptanceSession(id: args[2], prepare: false)
                        Task {
                            var phase = "profile open"
                            do {
                                let (lease, generation) = try await CandidateProfile.open(in: session.directory)
                                phase = "profile readback"
                                let config = try FileConfigurationStore(url: generation.appendingPathComponent("Nearpane/host-configuration.json"), activeProfile: true).load()
                                let counts = try CandidateProfile.inspectStores(in: generation, counts: true)
                                let result: [String: Any] = ["generation": generation.lastPathComponent, "path": generation.path, "counts": counts,
                                                             "configurationReadable": true, "hidden": config.surfaceHidden,
                                                             "clockTimeZoneID": config.clockTimeZoneID as Any? ?? NSNull()]
                                let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                                try withExtendedLifetime(lease) { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
                                exit(0)
                            } catch { FileHandle.standardError.write(Data("Isolated \(phase) failed: \(error)\n".utf8)); exit(3) }
                        }
                        dispatchMain()
                    }
                    let blank = CandidateProfile.selected && args[1] == "--native-acceptance-prepare-draft"
                    guard blank || args[1] == "--native-acceptance-prepare" else { exit(2) }
                    let session = try NativeAcceptanceSession(id: args[2], prepare: true)
                    if CandidateProfile.selected {
                        Task {
                            do {
                                _ = try await CandidateProfile.prepareFixture(in: session.directory, examples: !blank)
                                print(session.directory.path)
                                exit(0)
                            } catch { FileHandle.standardError.write(Data("Candidate initialization: \(error)\n".utf8)); exit(3) }
                        }
                        dispatchMain()
                    }
                    print(session.directory.path)
                }
            } catch {
                FileHandle.standardError.write(Data("Unable to verify packaged resources or prepare the requested fixture.\n".utf8))
                exit(1)
            }
            #else
            print("Foundation-only resource check; no embedded domains.")
            #endif
            return
        }
        let delegate = HostAppDelegate()
        if let command = args.first, command.hasPrefix("--native-acceptance") {
            #if canImport(RiftletCore) && canImport(SaytileKit)
            guard args.count == 2 else { exit(2) }
            do {
                delegate.acceptanceSession = try NativeAcceptanceSession(id: args[1], prepare: false)
                switch command {
                case "--native-acceptance-session": break
                case "--native-acceptance-single-ordinary":
                    let env = ProcessInfo.processInfo.environment
                    let screens = SystemScreens.geometry()
                    guard CandidateProfile.selected, screens.count == 1, let id = screens.first?.id,
                          UUID(uuidString: id) != nil,
                          ["NEARPANE_ORDINARY_ACCEPTANCE", "NEARPANE_ADMISSION_ACCEPTANCE", "NEARPANE_MANAGEMENT_ACCEPTANCE"].allSatisfy({ env[$0] == args[1] }),
                          let pid = env["NEARPANE_ORDINARY_PID"].flatMap(Int32.init), pid > 1 else { exit(2) }
                    delegate.passiveDisplayID = id
                case "--native-acceptance-secondary", "--native-acceptance-secondary-desktop", "--native-acceptance-secondary-fullscreen":
                    delegate.enrolledFullscreenTrial = command == "--native-acceptance-secondary-fullscreen"
                    delegate.requestsDesktopFixture = command == "--native-acceptance-secondary-desktop"
                    let secondary = SystemScreens.geometry().dropFirst()
                    guard secondary.count == 1, let id = secondary.first?.id, UUID(uuidString: id) != nil else { exit(2) }
                    delegate.passiveDisplayID = id
                default: exit(2)
                }
            } catch {
                FileHandle.standardError.write(Data("Invalid or inaccessible isolated acceptance session.\n".utf8))
                exit(1)
            }
            #else
            exit(2)
            #endif
        }
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

enum HostOpenIntent: String {
    case unmarked, service, login, background

    init(event: NSAppleEventDescriptor?, backgroundLaunch: Bool = false) {
        if event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) != nil { self = .service }
        else if event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil { self = .login }
        else if backgroundLaunch { self = .background }
        else { self = .unmarked }
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    #if canImport(RiftletCore) && canImport(SaytileKit)
    private var profileTrial: Bool {
        guard CandidateProfile.selected, passiveDisplayID != nil, !requestsDesktopFixture, let acceptanceSession else { return false }
        return ProcessInfo.processInfo.environment["NEARPANE_PROFILE_ACCEPTANCE"] == acceptanceSession.directory.lastPathComponent
    }
    private var profileLease: ProfileLease?
    private var profileOptions: ProfileImportOptions?
    private var profileSwitch: Task<ProfileReply, Error>?
    private var feedback: ProductFeedbackController?
    private var servicesTrial: Bool {
        guard CandidateProfile.selected, passiveDisplayID != nil, let acceptanceSession else { return false }
        return ProcessInfo.processInfo.environment["NEARPANE_SERVICES_ACCEPTANCE"] == acceptanceSession.directory.lastPathComponent
    }
    var acceptanceSession: NativeAcceptanceSession?
    var requestsDesktopFixture = false
    private var desktopFixture: DesktopAcceptanceFixture?
    private var managementProbe: NativeManagementAcceptance?
    private var fullscreenFixture: FullscreenAcceptanceFixture?
    var enrolledFullscreenTrial = false
    private var enrolledFullscreen: EnrolledFullscreenFixture?
    private var fullscreenStartupStage: StaticString = "launch"
    private var fullscreenTrial: Bool {
        guard requestsDesktopFixture, passiveDisplayID != nil, let acceptanceSession else { return false }
        return ProcessInfo.processInfo.environment["NEARPANE_FULLSCREEN_ACCEPTANCE"] == acceptanceSession.directory.lastPathComponent
    }
    private var managementTrial: Bool {
        guard let acceptanceSession, passiveDisplayID != nil else { return false }
        let id = acceptanceSession.directory.lastPathComponent
        let env = ProcessInfo.processInfo.environment
        // Admission and Settings-only sizing need no desktop fixture windows.
        return env["NEARPANE_MANAGEMENT_ACCEPTANCE"] == id &&
            (requestsDesktopFixture || env["NEARPANE_ADMISSION_ACCEPTANCE"] == id || env["NEARPANE_SIZE_ACCEPTANCE"] == id)
    }
    private var acceptanceProbe: NativeAcceptanceProbe?
    #endif
    /// The timed witness controller captures stderr in its isolated session. A deadline records
    /// the last reached stage even when startup never gets as far as opening the event log.
    private func traceFullscreenStartup(_ stage: StaticString? = nil, error: Error? = nil) {
        #if canImport(RiftletCore) && canImport(SaytileKit)
        guard enrolledFullscreenTrial else { return }
        if let stage { fullscreenStartupStage = stage }
        let outcome = error.map { "rejected code=\(($0 as NSError).code)" } ?? (stage == nil ? "deadline" : "reached")
        let record = "fullscreen-startup uptime=\(ProcessInfo.processInfo.systemUptime) stage=\(fullscreenStartupStage) \(outcome)\n"
        FileHandle.standardError.write(Data(record.utf8))
        #endif
    }

    private var host: HostSession?
    private var modules: EmbeddedModules?
    private var panels: DisplayPanels?
    private var desktopAvailability = DesktopSessionAvailability()
    private var wakeReadback: Task<Void, Never>?
    private var sessionUnavailable: Bool { desktopAvailability.unavailable }
    private var surface: EdgeWindowController?
    private let settingsScreens = SettingsScreenInventory()
    private let settingsNavigation = SettingsNavigation()
    private let settingsPreview = SettingsPreviewExposure()
    private var settingsWindowOpen = false
    private var settings: NSWindowController?
    private var statusItem: NSStatusItem?
    private var pendingMainWindow = false

    // Finder can deliver the open or reopen event before the asynchronous profile lease is ready.
    // A background relaunch used for an update must stay out of the foreground.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard permitsSettingsOpen(reopen: false) else { return false }
        return requestMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permitsSettingsOpen(reopen: true) { _ = requestMainWindow() }
        return false
    }

    private func permitsSettingsOpen(reopen: Bool) -> Bool {
        let intent = HostOpenIntent(event: NSAppleEventManager.shared().currentAppleEvent,
                                    backgroundLaunch: !reopen && CommandLine.arguments.contains("--background"))
        // Monotonic phase evidence for whether Services delivery actually passed through the Host open delegate.
        // No Apple event contents, source application, window, or document is logged.
        let phase = reopen ? "reopen" : "open"
        Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "HostOpen")
            .notice("hostOpen phase=\(phase, privacy: .public) marker=\(intent.rawValue, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
        return intent == .unmarked
    }

    @discardableResult private func requestMainWindow() -> Bool {
        guard passiveDisplayID == nil, terminationTask == nil else { return false }
        #if canImport(SaytileKit)
        guard acceptanceSession == nil else { return false }
        if profileSwitch != nil { showSettings(); return true }
        #endif
        guard panels != nil else { pendingMainWindow = true; return true }
        showSettings()
        return true
    }
    private var passiveShutdownTimer: Timer?
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var updater: ApplicationUpdater?
    private var updateMenuObservation: AnyCancellable?
    // A passive material observation must not create a menu, move the pointer, or fall back to the main display.
    var passiveDisplayID: String?

    private func placementScreens() -> [ScreenGeometry] {
        let screens = SystemScreens.geometry()
        guard let passiveDisplayID else { return screens }
        return screens.dropFirst().filter { $0.id == passiveDisplayID }
    }

    private func observeDesktopSession() {
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopChanged(_:)), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(readPreviewMetrics(_:)),
            name: .init("com.holdsnow.nearpane.preview-metrics.request"), object: String(getpid()))
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(lockChanged(_:)), name: .init(name), object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        readDesktopAvailability(.sample)
    }

    private var lastPermissionDiagnostic: TimeInterval = -.infinity
    private var draftQualificationPending = false
    private var overviewObservationPending = false
    private var lastOverviewObservation: TimeInterval = -.infinity

    @objc private func readPreviewMetrics(_ notification: Notification) {
        guard let value = notification.userInfo?["nonce"] as? String, let nonce = UUID(uuidString: value) else { return }
        if notification.userInfo?["check"] as? String == "mission-control-read-v1" {
            let now = ProcessInfo.processInfo.systemUptime
            guard !overviewObservationPending, now - lastOverviewObservation >= 0.08, let panels else { return }
            overviewObservationPending = true
            lastOverviewObservation = now
            Task {
                defer { overviewObservationPending = false }
                guard let sample = await panels.observeMissionControl() else { return }
                DistributedNotificationCenter.default().postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.reply"),
                    object: nonce.uuidString, userInfo: ["pid": getpid(), "checked": "mission-control-read-v1",
                        "missionControlPresented": sample.mode, "missionControlObservation": sample.evidence,
                        "missionControlReadStartUptime": sample.start, "missionControlReadEndUptime": sample.end],
                    deliverImmediately: true)
            }
            return
        }
        #if canImport(RiftletAdapters) && canImport(SaytileKit)
        if notification.userInfo?["check"] as? String == "draft-qualification-read-only-v1" {
            guard !draftQualificationPending, let privateHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
                  let pw = getpwuid(getuid()), let lease = profileLease else { return }
            let home = URL(fileURLWithPath:privateHome), base = home.deletingLastPathComponent()
            let caches = URL(fileURLWithPath:String(cString:pw.pointee.pw_dir)).appendingPathComponent("Library/Caches")
            guard home.path == home.resolvingSymlinksInPath().path, home.lastPathComponent == "home",
                  base.deletingLastPathComponent().path == caches.path, base.lastPathComponent.hasPrefix("nearpane-native-acceptance."),
                  lease.root.path == home.appendingPathComponent("Library/Application Support").appendingPathComponent(CandidateProfile.containerName).path,
                  ProcessInfo.processInfo.systemUptime - lastPermissionDiagnostic >= 1 else { return }
            lastPermissionDiagnostic = ProcessInfo.processInfo.systemUptime
            draftQualificationPending = true
            Task {
                defer { draftQualificationPending = false }
                let state = await TrayModule.existingChromeAutomation()
                Logger(subsystem:"com.holdsnow.nearpane.alpha",category:"PermissionCheck")
                    .notice("Draft qualification \(nonce.uuidString, privacy: .public) chrome=\(state, privacy: .public)")
                DistributedNotificationCenter.default().postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.reply"),
                    object:nonce.uuidString, userInfo:["pid":NSNumber(value:getpid()),"checked":"draft-qualification-read-only-v1"],deliverImmediately:true)
            }
            return
        }
        #endif
        #if NEARPANE_P0_DIAGNOSTIC && canImport(RiftletCore) && canImport(SaytileKit)
        if notification.userInfo?["check"] as? String == "p0-space-probe-read-only-v1" {
            guard let profile = profileLease?.root, let panels else { return }
            Task {
                guard await P0HostProbe.run(nonce:nonce, profile:profile, stageOwnsDispatch:panels.systemManagesWindows) else { return }
                DistributedNotificationCenter.default().postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.reply"),
                    object:nonce.uuidString, userInfo:["pid":NSNumber(value:getpid()),"checked":"p0-space-probe-read-only-v1"],deliverImmediately:true)
            }
            return
        }
        #endif
        if notification.userInfo?["check"] as? String == "permissions" {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPermissionDiagnostic >= 1 else { return }
            lastPermissionDiagnostic = now
            let screen = CGPreflightScreenCaptureAccess()
            let accessibility = AXIsProcessTrusted()
            let postEvent = CGPreflightPostEventAccess()
            let listenEvent = CGPreflightListenEventAccess()
            // Keep privacy status in the Host log. The distributed reply only acknowledges sampling.
            Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "PermissionCheck")
                .notice("Permission check \(nonce.uuidString, privacy: .public) screen=\(screen, privacy: .public) accessibility=\(accessibility, privacy: .public) postEvent=\(postEvent, privacy: .public) listenEvent=\(listenEvent, privacy: .public)")
            DistributedNotificationCenter.default().postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.reply"),
                object: nonce.uuidString, userInfo: ["pid": NSNumber(value: getpid()), "checked": "permissions"], deliverImmediately: true)
            return
        }
        guard var metrics = modules?.windowPreviewMetrics, let host else { return }
        metrics["stageManagerOwnsDispatch"] = NSNumber(value: panels?.systemManagesWindows == true)
        metrics["windowDispatchEligible"] = NSNumber(value: overviewAvailable)
        metrics["overviewShortcutRegistered"] = NSNumber(value: DesktopOverviewShortcut.shared.registered)
        let missionControl = panels?.missionControlDispatchState
        metrics["missionControlPresented"] = NSNumber(value: missionControl == "ordinary" ? 0 : missionControl == "exposed" ? 1 : -1)
        if let interval = panels?.missionControlReadInterval {
            metrics["missionControlReadStartUptime"] = NSNumber(value: interval.start)
            metrics["missionControlReadEndUptime"] = NSNumber(value: interval.end)
        }
        metrics["surfaceHidden"] = NSNumber(value: host.configuration.surfaceHidden)
        metrics["visibilityRevision"] = NSNumber(value: host.surfaceVisibilityRevision)
        DistributedNotificationCenter.default().postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.reply"),
            object: nonce.uuidString, userInfo: (metrics as [String: Any]).merging([
                "pid": NSNumber(value: getpid()),
                "missionControlObservation": panels?.missionControlDispatchEvidence ?? "unavailable"
            ]) { a, _ in a },
            deliverImmediately: true)
    }

    private func readDesktopAvailability(_ event: DesktopSessionAvailability.Event) {
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        let active = console?[kCGSessionOnConsoleKey as String] as? Bool == true
            && console?[kCGSessionLoginDoneKey as String] as? Bool == true
        let awake = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsAsleep(id.uint32Value) == 0
        }
        desktopAvailability.observe(event, hasAwakeDisplay: awake, consoleActive: active,
                                    consoleLocked: console?["CGSSessionScreenIsLocked"] as? Bool == true)
    }

    // On wake / unlock WindowServer can publish the notification before both
    // the display and the console are ready. Re-read without synthesizing an unlock.
    private func desktopAvailabilityChanged(_ event: DesktopSessionAvailability.Event, settling: Bool = false) {
        wakeReadback?.cancel()
        readDesktopAvailability(event)
        applyDesktopSessionState()
        guard settling, sessionUnavailable else { return }
        wakeReadback = Task { [weak self] in
            for delay in [300, 1_500] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, terminationTask == nil else { return }
                let before = desktopAvailability
                readDesktopAvailability(.sample)
                if before != desktopAvailability { applyDesktopSessionState() }
                if !sessionUnavailable { return }
            }
        }
    }

    private var selectionService: SelectionTranslation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if CandidateProfile.selected, acceptanceSession == nil,
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let service = SelectionTranslation(support: support)
            selectionService = service
            service.register()
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Report the permissions of the installed Host itself. No window identities or content.
        let canPreview = CGPreflightScreenCaptureAccess()
        let canSelect = AXIsProcessTrusted()
        Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowOverview")
            .notice("Window overview access: screen=\(canPreview, privacy: .public) accessibility=\(canSelect, privacy: .public)")
        observeDesktopSession()
        if passiveDisplayID != nil {
            // Passive runs have no menu or key window. Close through the ordinary shutdown barrier.
            var duration = 25.0
            #if canImport(SaytileKit)
            if managementTrial || profileTrial || servicesTrial { duration = 100 } else if fullscreenTrial || enrolledFullscreenTrial { duration = 65 }
            if managementTrial, let id = acceptanceSession?.directory.lastPathComponent,
               ProcessInfo.processInfo.environment["NEARPANE_ORDINARY_ACCEPTANCE"] == id,
               ProcessInfo.processInfo.environment["NEARPANE_ORDINARY_IDLE_ACCEPTANCE"] == id { duration = 225 }
            #endif
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.traceFullscreenStartup()
                    NSApp.terminate(nil)
                }
            }
            passiveShutdownTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        startupTask = Task { [weak self] in
            await self?.openHost()
        }
    }

    private func openHost() async {
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var testSession: URL?
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if let acceptanceSession { support = acceptanceSession.support; testSession = acceptanceSession.directory }
        if CandidateProfile.selected {
            do {
                if let acceptanceSession, !profileTrial {
                    traceFullscreenStartup("preparing-profile")
                    support = try await CandidateProfile.prepareFixture(in: acceptanceSession.directory)
                    traceFullscreenStartup("profile-ready")
                } else {
                    let (lease, active) = try await CandidateProfile.open(in: acceptanceSession?.directory ?? support)
                    profileLease = lease
                    support = active
                    profileOptions = ProfileImportOptions(root: lease.root) { [weak self] action, source, groups, token in
                        guard let self else { throw CancellationError() }
                        return try await switchProfile(action, source: source, groups: groups, token: token)
                    }
                }
            }
            catch {
                if acceptanceSession == nil { NSApp.presentError(error) }
                else { FileHandle.standardError.write(Data("Candidate profile initialization failed: \(error)\n".utf8)) }
                NSApp.terminate(nil)
                return
            }
        }
        #endif
        guard !Task.isCancelled else { return }
        #if canImport(SaytileKit)
        let candidate = CandidateProfile.selected
        let activeProfile = profileLease != nil
        #else
        let candidate = false
        let activeProfile = false
        #endif
        let store = FileConfigurationStore(url: support.appendingPathComponent("Nearpane/host-configuration.json"),
                                           activeProfile: activeProfile)
        // A live acceptance session can attach only with its explicit browser-before binding.
        let boundDraft = passiveDisplayID == nil && testSession.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("target-binding.json").path)
        } == true
        traceFullscreenStartup("constructing-modules")
        let modules = EmbeddedModules(support: support.appendingPathComponent("Nearpane"), testSession: testSession,
                                      candidate: candidate, boundDraft: boundDraft)
        self.modules = modules
        if let selectionService, testSession == nil, candidate, let id = UUID(uuidString: support.lastPathComponent) {
            modules.bindSelectionService(selectionService, generation: id)
        }
        modules.workRect?.setOrdinaryHold("session", active: sessionUnavailable)
        #if canImport(SaytileKit)
        if !profileTrial && !enrolledFullscreenTrial { modules.workRect?.start() }
        #else
        modules.workRect?.start()
        #endif
        let provider: any DesktopObservationProvider
        if testSession == nil { provider = NativeDesktopProvider.packaged() }
        else {
            #if canImport(RiftletCore) && canImport(SaytileKit)
            if requestsDesktopFixture, let acceptanceSession, let passiveDisplayID {
                do { desktopFixture = try DesktopAcceptanceFixture(session: acceptanceSession, displayID: passiveDisplayID) }
                catch { NSApp.terminate(nil); return }
                if candidate {
                    modules.tray.reviewCaptureWindow = { [weak self] in
                        guard let fixture = self?.desktopFixture else { throw CocoaError(.featureUnsupported) }
                        return try fixture.captureWindow()
                    }
                }
                provider = NativeDesktopProvider.packaged(fixtureWindows: { [weak self] in self?.desktopFixture?.windows ?? [] })
            } else { provider = UnavailableDesktopProvider() }
            #else
            provider = UnavailableDesktopProvider()
            #endif
        }
        let session = modules.makeHost(store: store, provider: provider)
        host = session
        session.setDesktopPause(.screensAsleep, paused: desktopAvailability.desktopAsleep)
        session.setDesktopPause(.inactiveSession, paused: desktopAvailability.sessionRestricted)
        traceFullscreenStartup("starting-host")
        await session.start()
        traceFullscreenStartup("host-started")
        guard !Task.isCancelled else { return }
        if candidate, testSession == nil { modules.workRect?.restoreCleanDesktopPermission() }
        let updater = ApplicationUpdater(allowNetwork: testSession == nil && candidate, activityBlock: { [weak modules] in
            guard let modules else { return "暂时无法核对运行状态，请稍后安装。" }
            return await modules.updateRelaunchBlock()
        }) { [weak self] in
            guard let self, self.host?.isRunning == true else { return "Nearpane 正在启动或停止，请稍后更新。" }
            #if canImport(SaytileKit)
            if self.profileSwitch != nil { return "资料切换正在进行，请完成后重新打开 Nearpane 再更新。" }
            if self.feedback?.busy == true { return "反馈操作正在完成，请稍后更新。" }
            #endif
            return nil
        }
        self.updater = updater
        updater.start()
        #if canImport(RiftletCore) && canImport(SaytileKit)
        let feedbackRoot = (profileLease?.root ?? testSession ?? support).appendingPathComponent("Feedback", isDirectory: true)
        feedback = ProductFeedbackController(directory: feedbackRoot,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版",
            networkAllowed: testSession == nil && candidate)
        if servicesTrial, let acceptanceSession, let display = passiveDisplayID, let feedback {
            // Only a binary-bound synthetic session seeds this text. The same public
            // editor and preview controls are shown with transport disabled.
            await feedback.start()
            feedback.expanded = true
            feedback.edit { $0.text = "Nearpane 合成反馈预览，仅用于本机界面验收。" }
            do {
                settings = try ProfileAcceptancePanel.present(contents: AnyView(VStack(spacing: 0) {
                    applicationServices
                    Button("结束隔离验收") { NSApp.terminate(nil) }
                        .accessibilityIdentifier("np.services.quit").padding(8)
                }),
                    session: acceptanceSession, displayID: display, recordPrefix: "application-services-")
            } catch { NSApp.terminate(nil) }
            return
        }
        #endif
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if (passiveDisplayID != nil && acceptanceSession != nil) || (candidate && acceptanceSession == nil && session.configuration.candidateTrayConnected) {
            // Show the explicitly scoped fixture's gallery without opening Settings on the user's desktop.
            traceFullscreenStartup("connecting-tray")
            await modules.tray.connect()
            traceFullscreenStartup("tray-connect-returned")
            guard !Task.isCancelled else { return }
        }
        #endif
        #if canImport(SaytileKit)
        if !enrolledFullscreenTrial, profileTrial, let options = profileOptions, let acceptanceSession, let display = passiveDisplayID {
            // A marked fixture selects the version without opening an AppKit pop-up over the desktop.
            // Reading this synthetic source still requires the same explicit Preview and Confirm controls.
            options.version = "P5.2"
            do { settings = try ProfileAcceptancePanel.present(options: options, session: acceptanceSession, displayID: display) }
            catch { NSApp.terminate(nil) }
            return
        }
        #endif
        traceFullscreenStartup("creating-edge")
        let controller = EdgeWindowController(host: session, modules: modules)
        surface = controller
        if passiveDisplayID != nil { controller.window?.ignoresMouseEvents = true }
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if enrolledFullscreenTrial, let acceptanceSession, let display = passiveDisplayID {
            do {
                traceFullscreenStartup("binding-witness")
                enrolledFullscreen = try EnrolledFullscreenFixture(session: acceptanceSession, display: display,
                    domains: modules, edge: controller.window)
                traceFullscreenStartup("witness-bound")
            } catch {
                traceFullscreenStartup("binding-witness", error: error)
                NSApp.terminate(nil); return
            }
        }
        #endif
        controller.place(screens: placementScreens())
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if let acceptanceSession {
            if !fullscreenTrial { desktopFixture?.observe(session) }
            do {
                if managementTrial, let display = passiveDisplayID, let manager = modules.workRect {
                    managementProbe = try NativeManagementAcceptance(session: acceptanceSession, display: display, host: session, manager: manager)
                }
                traceFullscreenStartup("opening-event-log")
                acceptanceProbe = try NativeAcceptanceProbe(session: acceptanceSession, host: session, modules: modules,
                    surface: controller, screens: { [weak self] in self?.placementScreens() ?? [] })
                traceFullscreenStartup("event-log-ready")
            }
            catch {
                traceFullscreenStartup("opening-event-log", error: error)
                NSApp.terminate(nil); return
            }
        }
        #endif
        let panels = DisplayPanels(host: session, primary: controller, domains: modules)
        self.panels = panels
        panels.setSuspended(sessionUnavailable)
        panels.refresh = { [weak self] in self?.updatePanels() }
        panels.topologyChanged = { [weak modules] displays in
            let ids = displays.compactMap { UUID(uuidString: $0)?.uuidString }.sorted()
            modules?.workRect?.send((["topology"] + ids).joined(separator: " "))
        }
        panels.managementChanged = { [weak self, weak modules] id, state, deadline in
            guard UUID(uuidString: id) != nil else { return }
            #if canImport(SaytileKit)
            if state == "hold", let self {
                let screens = MultiDisplayPresentationCoordinator.identifiedScreens(placementScreens())
                let resident = screens.first { $0.id == self.host?.configuration.preferredDisplayID } ?? screens.first
                if resident?.id == id { modules?.voice.interruptForHost(.fullscreen) }
            }
            #endif
            let expiry = deadline.map { " " + String($0) } ?? ""
            modules?.workRect?.ordinaryPresentation(state, display: id, deadline: deadline)
            modules?.workRect?.send("presentation " + state + " " + id + expiry)
        }
        #if canImport(SaytileKit)
        if let enrolledFullscreen {
            panels.fixtureFullscreen = { [weak enrolledFullscreen] display in enrolledFullscreen?.sample(display) }
            enrolledFullscreen.start { [weak self] in self?.updatePanels() }
        } else if fullscreenTrial, let acceptanceSession, let display = passiveDisplayID, let desktopFixture {
            do {
                let fixture = try FullscreenAcceptanceFixture(session: acceptanceSession, displayID: display,
                    ownedWindow: { try desktopFixture.fixtureWindowNumber() }, refresh: { [weak self] in self?.updatePanels() })
                fullscreenFixture = fixture
                if ProcessInfo.processInfo.environment["NEARPANE_TOPOLOGY_ACCEPTANCE"] == acceptanceSession.directory.lastPathComponent {
                    fixture.topologyHost = session
                }
                let sessionID = UUID()
                var revision: UInt64 = 0
                panels.fixtureFullscreen = { [weak fixture] id in
                    guard id == display, let fixture else { return nil }
                    let reading: DesktopFullscreenObservation
                    if !fixture.safe { reading = .unknown }
                    else if fixture.native { reading = fixture.witness.map { .native(window: $0) } ?? .unknown }
                    else { reading = .ordinary(workspace: nil) }
                    revision += 1
                    let begun = ProcessInfo.processInfo.systemUptime
                    return .init(session: sessionID, revision: revision, validUntil: begun + 12,
                                 observation: reading, beganUptime: begun)
                }
            } catch { NSApp.terminate(nil); return }
        }
        #endif
        session.presentationChanged = { [weak self] in self?.updatePanels() }
        updatePanels()
        traceFullscreenStartup("panels-updated")
        if passiveDisplayID == nil {
            installMenu()
            if ProcessInfo.processInfo.environment["NEARPANE_NATIVE_ACCEPTANCE"] == nil, testSession == nil {
                DesktopOverviewShortcut.shared.start(session.configuration.overviewShortcut,
                    eligible: { [weak self] in self?.overviewAvailable == true },
                    open: { [weak self] in self?.openWindowOverview() == true })
                Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowOverview").notice("Shortcut: \(DesktopOverviewShortcut.shared.status, privacy: .public)")
            }
            if pendingMainWindow { pendingMainWindow = false; showSettings() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The existing termination owns the drain. A second terminate while AppKit is
        // waiting for our reply can bypass the remaining work.
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            defer { DesktopOverviewShortcut.shared.refreshOwnership() }
            if let updater, !(await updater.permitsTermination()) {
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            #if canImport(SaytileKit)
            if let feedback, !(await feedback.prepareForTermination()) {
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            #endif
            if let updater, !(await updater.permitsTermination()) {
                #if canImport(SaytileKit)
                await feedback?.resumeAfterDeferredUpdate()
                #endif
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            wakeReadback?.cancel()
            updater?.stop()
            passiveShutdownTimer?.invalidate()
            passiveShutdownTimer = nil
            settingsPreview.withdraw()
            #if canImport(SaytileKit)
            if let profileSwitch {
                _ = await profileSwitch.result
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            #endif
            startupTask?.cancel()
            await modules?.prepareStageWindowShutdown()
            panels?.stop()
            host?.stop()
            await modules?.finishStopping()
            await host?.waitForDesktopStop()
            #if canImport(RiftletCore) && canImport(SaytileKit)
            fullscreenFixture?.stop()
            enrolledFullscreen?.stop()
            managementProbe?.stop()
            acceptanceProbe?.finish()
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        DesktopOverviewShortcut.shared.refreshOwnership()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DesktopOverviewShortcut.shared.stop()
        updater?.stop()
        updateMenuObservation?.cancel()
        passiveShutdownTimer?.invalidate()
        passiveShutdownTimer = nil
        startupTask?.cancel()
        host?.stop()
        panels?.stop()
        #if canImport(SaytileKit)
        desktopFixture?.stop()
        #endif
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func installMenu() {
        let (menu, update) = makeStatusMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Nearpane")
        item.button?.toolTip = "Nearpane"
        item.menu = menu
        statusItem = item
        item.isVisible = host?.configuration.showsMenuBarIcon ?? true
        if let updater {
            updateMenuObservation = updater.$offeredVersion.combineLatest(updater.$canCheck).sink { [weak item, weak update] version, canCheck in
                update?.title = version.map { "查看 Nearpane \($0) 更新…" } ?? (canCheck ? "检查更新…" : "更新状态…")
                item?.length = version == nil ? NSStatusItem.squareLength : 38
                item?.button?.imagePosition = .imageLeading
                item?.button?.title = version == nil ? "" : "•"
                item?.button?.toolTip = version.map { "Nearpane \($0) 可用，点击菜单查看更新。" } ?? "Nearpane"
            }
        }
    }

    private func makeStatusMenu() -> (NSMenu, NSMenuItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        func action(_ title: String, _ selector: Selector) -> NSMenuItem {
            let entry = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            entry.target = self
            return entry
        }
        _ = action("显示本屏窗口总览", #selector(showWindowOverview))
        _ = action("窗口管理…", #selector(showWindowManagement))
        _ = action("打开 Nearpane", #selector(openMainWindow))
        _ = action("隐藏侧栏", #selector(toggleSurface))
        menu.addItem(.separator())
        let update = action("更新状态…", #selector(checkForUpdates))
        _ = action("隐藏菜单栏图标", #selector(hideStatusIcon))
        menu.addItem(.separator())
        _ = action("退出 Nearpane", #selector(quit))
        return (menu, update)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let overview = menu.items.first(where: { $0.action == #selector(showWindowOverview) }) {
            let managed = panels?.systemManagesWindows == true
            overview.title = managed ? "本屏窗口由台前调度管理" : "显示本屏窗口总览"
            overview.isEnabled = overviewAvailable
        }
        guard let entry = menu.items.first(where: { $0.action == #selector(toggleSurface) }) else { return }
        entry.title = host?.configuration.surfaceHidden == true ? "显示侧栏" : "隐藏侧栏"
        entry.isEnabled = host?.isRunning == true
    }

    @objc private func openMainWindow() { requestMainWindow() }

    @objc private func showWindowManagement() {
        settingsNavigation.showWindowManagement()
        showSettings()
    }

    private var overviewAvailable: Bool {
        guard let host, host.isRunning, !sessionUnavailable, terminationTask == nil, passiveDisplayID == nil,
              panels?.windowDispatchEligible == true else { return false }
        return host.registry.preferences.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }
    }

    @objc private func showWindowOverview() { _ = openWindowOverview() }

    private func openWindowOverview() -> Bool {
        guard overviewAvailable, let host, let panels else { return false }
        let point = NSEvent.mouseLocation
        let hits = SystemScreens.geometry().filter { screen in
            let r = screen.frame
            return NSPointInRect(point, NSRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
        guard hits.count == 1, let screen = hits.first else { return false }
        Task { @MainActor [weak self] in
            guard await panels.confirmWindowDispatch(), let self, self.host === host,
                  self.panels === panels, overviewAvailable,
                  SystemScreens.geometry().contains(where: { $0.id == screen.id }) else { return }
            host.setSurfaceHidden(false)
            panels.request(screen.id)
            updatePanels()
        }
        return true
    }

    @objc private func hideStatusIcon() {
        guard host?.setShowsMenuBarIcon(false) == true else {
            settingsNavigation.showGeneral()
            showSettings()
            return
        }
        statusItem?.isVisible = false
    }

    @objc private func checkForUpdates() {
        if let updater, updater.canCheck { updater.check(); return }
        settingsNavigation.showApplicationServices()
        showSettings()
    }

    @objc private func lockChanged(_ note: Notification) {
        let locked = note.name.rawValue == "com.apple.screenIsLocked"
        desktopAvailabilityChanged(locked ? .locked : .unlocked, settling: !locked)
    }

    private func applyDesktopSessionState() {
        if sessionUnavailable { selectionService?.invalidateSelectionContext() }
        if sessionUnavailable { modules?.stopWindowContentPreview(reason: "session-unavailable") }
        #if canImport(SaytileKit)
        if sessionUnavailable {
            modules?.voice.stopArchivePlayback()
            modules?.voice.interruptForHost(.session)
        }
        #endif
        refreshSettingsExposure()
        modules?.workRect?.setOrdinaryHold("session", active: sessionUnavailable)
        panels?.setSuspended(sessionUnavailable)
        host?.setDesktopPause(.screensAsleep, paused: desktopAvailability.desktopAsleep)
        host?.setDesktopPause(.inactiveSession, paused: desktopAvailability.sessionRestricted)
        updatePanels()
    }

    @objc private func desktopChanged(_ note: Notification) {
        if note.name == NSWorkspace.didDeactivateApplicationNotification {
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.systempreferences" {
                DesktopOverviewShortcut.shared.refreshOwnership(recheckReservation: true)
            }
            return
        }
        if note.name == NSWorkspace.didActivateApplicationNotification {
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            selectionService?.foregroundChanged(to: app?.processIdentifier)
        }
        switch note.name {
        case NSWorkspace.willSleepNotification: desktopAvailabilityChanged(.willSleep)
        case NSWorkspace.didWakeNotification: desktopAvailabilityChanged(.didWake, settling: true)
        case NSWorkspace.screensDidSleepNotification: desktopAvailabilityChanged(.screensSleep)
        case NSWorkspace.screensDidWakeNotification: desktopAvailabilityChanged(.screensWake, settling: true)
        case NSWorkspace.sessionDidResignActiveNotification: desktopAvailabilityChanged(.resigned)
        case NSWorkspace.sessionDidBecomeActiveNotification: desktopAvailabilityChanged(.becameActive, settling: true)
        case NSWorkspace.activeSpaceDidChangeNotification:
            selectionService?.invalidateSelectionContext()
            modules?.stopWindowContentPreview(spaceChanged: true, reason: "active-space")
            host?.invalidateDesktop()
        default:
            modules?.desktopWindowsChanged()
            host?.refreshAfterWindowChange()
        }
    }

    private func updatePanels() {
        DesktopOverviewShortcut.shared.refreshOwnership()
        guard host?.isRunning == true else { return }
        #if canImport(SaytileKit)
        if CandidateProfile.selected, requestsDesktopFixture || enrolledFullscreenTrial, let passiveDisplayID {
            let screens = SystemScreens.geometry()
            guard screens.count == 2, screens.last?.id == passiveDisplayID,
                  screens.first?.id != passiveDisplayID,
                  screens[0].frame.geometry.intersection(screens[1].frame.geometry) == nil
            else { panels?.update(screens: []); return }
            let projected = fullscreenFixture?.omitsPrimary == true ? [screens[1]] : screens
            panels?.update(screens: projected, presentingOnly: passiveDisplayID)
            return
        }
        #endif
        panels?.update(screens: placementScreens())
    }

    @objc private func screensChanged() {
        selectionService?.invalidateSelectionContext()
        modules?.stopWindowContentPreview(reason: "screen-parameters")
        let before = desktopAvailability
        readDesktopAvailability(.sample)
        if before != desktopAvailability {
            applyDesktopSessionState()
        } else {
            host?.invalidateDesktop()
            updatePanels()
        }
        if settings != nil { settingsScreens.update(SystemScreens.geometry()) }
    }

    @objc private func toggleSurface() {
        #if canImport(SaytileKit)
        guard profileSwitch == nil else { return }
        #endif
        guard let host else { return }
        host.setSurfaceHidden(!host.configuration.surfaceHidden)
        updatePanels()
    }

    @objc private func showSettings() {
        #if canImport(SaytileKit)
        if profileSwitch != nil { settings?.showWindow(nil); return }
        #endif
        guard host != nil, passiveDisplayID == nil else { return }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 752, height: 572),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
            window.contentMinSize = NSSize(width: 640, height: 476)
            window.title = "Nearpane"
            window.identifier = .init("nearpane-main-window")
            window.isReleasedWhenClosed = false
            if let screen = surface?.window?.screen {
                let f = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
            } else { window.center() }
            settings = NSWindowController(window: window)
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(settingsClosing(_:)), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(settingsWithdrawing(_:)), name: NSWindow.willMiniaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(settingsWithdrawing(_:)), name: NSApplication.willHideNotification, object: NSApp)
            for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                center.addObserver(self, selector: #selector(settingsVisibilityChanged(_:)), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(settingsVisibilityChanged(_:)), name: NSApplication.didUnhideNotification, object: NSApp)
        }
        if !settingsWindowOpen {
            updateSettingsContent()
        }
        settingsScreens.update(SystemScreens.geometry())
        settingsWindowOpen = true
        if NSApp.isHidden { NSApp.unhide(nil) }
        if settings?.window?.isMiniaturized == true { settings?.window?.deminiaturize(nil) }
        settings?.showWindow(nil)
        refreshSettingsExposure()
        // Only the product window requested by an open action needs keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsClosing(_ note: Notification) {
        #if canImport(SaytileKit)
        modules?.voice.stopArchivePlayback()
        #endif
        settingsWindowOpen = false
        settingsPreview.withdraw()
        #if canImport(SaytileKit)
        guard profileSwitch == nil else { return }
        #endif
        // Closing the product window cancels archive view tasks and releases any selected media.
        settings?.window?.contentView = nil
    }
    @objc private func settingsWithdrawing(_ note: Notification) {
        #if canImport(SaytileKit)
        modules?.voice.stopArchivePlayback()
        #endif
        settingsPreview.withdraw()
    }
    @objc private func settingsVisibilityChanged(_ note: Notification) { refreshSettingsExposure() }
    private func refreshSettingsExposure() {
        guard settingsWindowOpen, let window = settings?.window, host?.isRunning == true else {
            settingsPreview.withdraw()
            return
        }
        settingsPreview.update(visible: window.isVisible && window.occlusionState.contains(.visible),
                               miniaturized: window.isMiniaturized, appHidden: NSApp.isHidden,
                               sessionUnavailable: sessionUnavailable)
    }

    private func updateSettingsContent() {
        #if canImport(SaytileKit)
        guard profileSwitch == nil else { return }
        let importer = profileOptions.map { AnyView(ProfileImportSettings(options: $0)) }
        #else
        let importer: AnyView? = nil
        #endif
        guard let host else { return }
        settings?.window?.contentView = NSHostingView(rootView: SettingsView(host:host,inventory:settingsScreens,previewExposure:settingsPreview,navigation:settingsNavigation,domains:modules,profileImport:importer,applicationServices:AnyView(applicationServices),
            requestSecondary: { [weak self] id in self?.panels?.request(id); self?.updatePanels() },
            dismissSpaces: { [weak self] id in self?.panels?.dismiss(id); self?.updatePanels() },
            menuVisibilityChanged: { [weak self] visible in self?.statusItem?.isVisible = visible },
            placementChanged: { [weak self] in self?.updatePanels() }))
    }

    #if canImport(SaytileKit)
    /// Render the Finder candidate's Settings in an executable-bound fixture. Never order or activate a window.
    func renderSettingsReadback(_ session: NativeAcceptanceSession) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let embedded = EmbeddedModules(support: session.support.appendingPathComponent("Nearpane"),
                                       testSession: session.directory, candidate: true)
        modules = embedded
        let host = embedded.makeHost(store: MemoryConfigurationStore())
        self.host = host
        await host.start()
        await embedded.voice.waitForTransition()
        await embedded.tray.connect()
        updater = ApplicationUpdater(allowNetwork: false)
        let size = SurfaceRect(width: 1470, height: 956)
        settingsScreens.update([ScreenGeometry(id: "fixture", frame: size, visibleFrame: size)])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 752, height: 572),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        settings = NSWindowController(window: window)
        settingsNavigation.showAppearance()
        updateSettingsContent()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-appearance.png"))
        settingsNavigation.showDesktop()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-desktop.png"))
        settingsNavigation.showWindowManagement()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-window-management.png"))
        settingsNavigation.showGeneral()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-general.png"))
        settingsNavigation.showVoiceArchive()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-voice-archive.png"))
        settingsNavigation.showScreenshotArchive()
        try await renderHiddenSettings(window, to: session.directory.appendingPathComponent("settings-screenshot-archive.png"))
        let (menu, _) = makeStatusMenu()
        let entries = menu.items.filter { !$0.isSeparatorItem }
        guard entries.allSatisfy({ $0.target === self && $0.action.map { self.responds(to: $0) } == true }) else {
            throw CocoaError(.featureUnsupported)
        }
        let titles = entries.map(\.title)
        hideStatusIcon()
        guard !host.configuration.showsMenuBarIcon, host.setShowsMenuBarIcon(true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try JSONEncoder().encode(titles).write(to: session.directory.appendingPathComponent("status-menu.json"), options: .withoutOverwriting)
        window.close()
        await embedded.prepareStageWindowShutdown()
        host.stop()
        await embedded.finishStopping()
    }

    private func renderHiddenSettings(_ window: NSWindow, to url: URL) async throws {
        guard let view = window.contentView else { throw CocoaError(.validationMissingMandatoryProperty) }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard !window.isVisible, !window.isMainWindow, !window.isKeyWindow,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.featureUnsupported) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try image.write(to: url, options: .withoutOverwriting)
    }
    #endif

    private var applicationServices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BundledDomainVersions()
                if let updater { ApplicationUpdateSettings(updater: updater) }
                #if canImport(RiftletCore) && canImport(SaytileKit)
                if let feedback {
                    Divider()
                    ProductFeedbackSettings(controller: feedback)
                }
                #endif
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    #if canImport(SaytileKit)
    private func switchProfile(_ action: String, source: URL?, groups: [String], token: String) async throws -> ProfileReply {
        guard updater?.canSwitchProfile != false else {
            throw NSError(domain: "com.holdsnow.nearpane.profile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先完成或取消应用更新，再切换资料。"])
        }
        guard profileSwitch == nil, let root = profileLease?.root, let host, let modules else { throw CancellationError() }
        let operation = Task { @MainActor () throws -> ProfileReply in
            // Retire every action surface before releasing the global writer lease.
            guard await modules.prepareStageWindowShutdown() else { throw StageSwitchError.ownership }
            settingsPreview.withdraw()
            panels?.stop()
            surface?.window?.orderOut(nil)
            host.stop()
            replaceProfileContent(ProgressView("正在保存资料并停止模块…").padding())
            await modules.finishStopping()
            await host.waitForDesktopStop()
            self.host = nil
            self.modules = nil
            self.panels = nil
            self.surface = nil
            profileLease = nil
            do {
                if let source {
                    let name = source.lastPathComponent
                    guard name.hasPrefix("Nearpane Alpha ") else { throw CocoaError(.fileReadInvalidFileName) }
                    try ProfileImportOptions.requireClosed(String(name.dropFirst("Nearpane Alpha ".count)))
                }
                let result = try await ProfileHelper.run(action, root: root, source: source, sections: groups, token: token)
                showSwitchResult(result.message)
                return result
            } catch {
                showSwitchResult(error.localizedDescription)
                throw error
            }
        }
        profileSwitch = operation
        return try await operation.value
    }

    private func replaceProfileContent(_ contents: some View) {
        guard let window = settings?.window else { return }
        let frame = window.frame
        let view = NSHostingView(rootView: contents)
        view.sizingOptions = []
        view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: frame).size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func showSwitchResult(_ message: String) {
        replaceProfileContent(VStack(alignment: .leading, spacing: 12) {
            Text(message).textSelection(.enabled)
            Text("请退出后重新打开 Nearpane。启动时会核对上次切换的结果；可在「设置 → 模块」中再次导入或恢复上一份资料。").font(.callout)
            Button("退出 Nearpane") { NSApp.terminate(nil) }.accessibilityIdentifier("np.profile.quit")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24))
    }
    #endif

    @objc private func quit() { NSApp.terminate(nil) }
}
