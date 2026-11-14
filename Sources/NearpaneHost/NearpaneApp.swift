import AppKit
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
                    if args.count == 4, args[1] == "--native-browser-identity", let pid = Int32(args[3]) {
                        _ = try NativeAcceptanceSession(id: args[2], prepare: false)
                        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").filter { !$0.isTerminated }
                        guard running.count == 1, running[0].processIdentifier == pid, let identity = ChromeProcessIdentity.read(pid: pid)
                        else { throw CocoaError(.validationMissingMandatoryProperty) }
                        print(identity.session)
                        return
                    }
                    guard args.count == 3 else { exit(2) }
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

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
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
    private var screenAsleep = false, sessionInactive = false, screenLocked = false
    private var hasAwakeDisplay = false
    private var desktopAsleep: Bool { screenAsleep || !hasAwakeDisplay }
    private var sessionUnavailable: Bool { desktopAsleep || sessionInactive || screenLocked }
    private var surface: EdgeWindowController?
    private let settingsScreens = SettingsScreenInventory()
    private let settingsPreview = SettingsPreviewExposure()
    private var settingsWindowOpen = false
    private var settings: NSWindowController?
    private var statusItem: NSStatusItem?
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
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopChanged(_:)), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(lockChanged(_:)), name: .init(name), object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        sessionInactive = console?[kCGSessionOnConsoleKey as String] as? Bool != true ||
            console?[kCGSessionLoginDoneKey as String] as? Bool != true
        screenLocked = console?["CGSSessionScreenIsLocked"] as? Bool == true
        refreshAwakeDisplays()
    }

    private func refreshAwakeDisplays() {
        hasAwakeDisplay = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsAsleep(id.uint32Value) == 0
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        session.setDesktopPause(.screensAsleep, paused: desktopAsleep)
        session.setDesktopPause(.inactiveSession, paused: sessionInactive || screenLocked)
        traceFullscreenStartup("starting-host")
        await session.start()
        traceFullscreenStartup("host-started")
        guard !Task.isCancelled else { return }
        let updater = ApplicationUpdater(allowNetwork: testSession == nil && candidate) { [weak self] in
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
        panels.managementChanged = { [weak modules] id, state, deadline in
            guard UUID(uuidString: id) != nil else { return }
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
        if passiveDisplayID == nil { installMenu() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The existing termination owns the drain. A second terminate while AppKit is
        // waiting for our reply can bypass the remaining work.
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            #if canImport(SaytileKit)
            if let feedback, !(await feedback.prepareForTermination()) {
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            #endif
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
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Nearpane controls")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("显示或隐藏侧栏", #selector(toggleSurface)), ("设置…", #selector(showSettings)), ("退出 Nearpane", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = false
        menu.insertItem(update, at: 2)
        item.menu = menu
        statusItem = item
        if let updater {
            updateMenuObservation = updater.$offeredVersion.combineLatest(updater.$canCheck).sink { [weak item, weak update] version, canCheck in
                update?.title = version.map { "查看 Nearpane \($0) 更新…" } ?? "检查更新…"
                update?.isEnabled = canCheck
                item?.length = version == nil ? NSStatusItem.squareLength : 38
                item?.button?.imagePosition = .imageLeading
                item?.button?.title = version == nil ? "" : "•"
                item?.button?.toolTip = version.map { "Nearpane \($0) 可用，点击菜单查看更新。" } ?? "Nearpane"
            }
        }
    }

    @objc private func checkForUpdates() { updater?.check() }

    @objc private func lockChanged(_ note: Notification) {
        screenLocked = note.name.rawValue == "com.apple.screenIsLocked"
        applyDesktopSessionState()
    }

    private func applyDesktopSessionState() {
        refreshSettingsExposure()
        modules?.workRect?.setOrdinaryHold("session", active: sessionUnavailable)
        panels?.setSuspended(sessionUnavailable)
        host?.setDesktopPause(.screensAsleep, paused: desktopAsleep)
        host?.setDesktopPause(.inactiveSession, paused: sessionInactive || screenLocked)
        updatePanels()
    }

    @objc private func desktopChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: screenAsleep = true
        case NSWorkspace.screensDidWakeNotification:
            screenAsleep = false
            refreshAwakeDisplays()
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default:
            host?.invalidateDesktop()
            return
        }
        applyDesktopSessionState()
    }

    private func updatePanels() {
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
        let wasAvailable = hasAwakeDisplay
        refreshAwakeDisplays()
        if wasAvailable != hasAwakeDisplay {
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 632, height: 572),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
            window.title = "Nearpane 设置"
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
            updateSettingsContent()
        }
        settingsScreens.update(SystemScreens.geometry())
        settingsWindowOpen = true
        settings?.showWindow(nil)
        refreshSettingsExposure()
        // Only an explicit Settings click may activate the application.
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsClosing(_ note: Notification) {
        settingsWindowOpen = false
        settingsPreview.withdraw()
    }
    @objc private func settingsWithdrawing(_ note: Notification) { settingsPreview.withdraw() }
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
        settings?.window?.contentView = NSHostingView(rootView: SettingsView(host:host,inventory:settingsScreens,previewExposure:settingsPreview,domains:modules,profileImport:importer,applicationServices:AnyView(applicationServices),
            requestSecondary: { [weak self] id in self?.panels?.request(id); self?.updatePanels() },
            dismissSpaces: { [weak self] id in self?.panels?.dismiss(id); self?.updatePanels() },
            placementChanged: { [weak self] in self?.updatePanels() }))
    }

    private var applicationServices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
