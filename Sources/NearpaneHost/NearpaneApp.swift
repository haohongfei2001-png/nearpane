import AppKit
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
                    let blank = CandidateProfile.selected && args[1] == "--native-acceptance-prepare-draft"
                    guard blank || args[1] == "--native-acceptance-prepare" else { exit(2) }
                    let session = try NativeAcceptanceSession(id: args[2], prepare: true)
                    if CandidateProfile.selected {
                        Task {
                            do {
                                _ = try await CandidateProfile.prepare(in: session.directory, acceptance: true, includeExamples: !blank)
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
                case "--native-acceptance-secondary", "--native-acceptance-secondary-desktop":
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
    var acceptanceSession: NativeAcceptanceSession?
    var requestsDesktopFixture = false
    private var desktopFixture: DesktopAcceptanceFixture?
    private var managementProbe: NativeManagementAcceptance?
    private var managementTrial: Bool {
        guard requestsDesktopFixture, let acceptanceSession else { return false }
        return ProcessInfo.processInfo.environment["NEARPANE_MANAGEMENT_ACCEPTANCE"] == acceptanceSession.directory.lastPathComponent
    }
    private var acceptanceProbe: NativeAcceptanceProbe?
    #endif
    private var host: HostSession?
    private var modules: EmbeddedModules?
    private var panels: DisplayPanels?
    private var screenAsleep = false, sessionInactive = false
    private var surface: EdgeWindowController?
    private var settings: NSWindowController?
    private var statusItem: NSStatusItem?
    private var startupTask: Task<Void, Never>?
    // A passive material observation must not create a menu, move the pointer, or fall back to the main display.
    var passiveDisplayID: String?

    private func placementScreens() -> [ScreenGeometry] {
        let screens = SystemScreens.geometry()
        guard let passiveDisplayID else { return screens }
        return screens.dropFirst().filter { $0.id == passiveDisplayID }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if passiveDisplayID != nil {
            // Passive runs have no menu or key window. Close through the ordinary shutdown barrier.
            var duration = 25.0
            #if canImport(SaytileKit)
            if managementTrial { duration = 100 }
            #endif
            let timer = Timer(timeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
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
            do { support = try await CandidateProfile.prepare(in: acceptanceSession?.directory ?? support, acceptance: acceptanceSession != nil) }
            catch {
                if acceptanceSession == nil { NSApp.presentError(error) }
                else { FileHandle.standardError.write(Data("Candidate profile initialization failed: \(error)\n".utf8)) }
                NSApp.terminate(nil)
                return
            }
        }
        #endif
        guard !Task.isCancelled else { return }
        let store = FileConfigurationStore(url: support.appendingPathComponent("Nearpane/host-configuration.json"))
        #if canImport(SaytileKit)
        let candidate = CandidateProfile.selected
        #else
        let candidate = false
        #endif
        // A browser-before binding in an explicit interactive acceptance session is the only
        // candidate route that can ask the domain to verify an asset and acquire a target.
        let boundDraft = passiveDisplayID == nil && testSession.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("target-binding.json").path)
        } == true
        let modules = EmbeddedModules(support: support.appendingPathComponent("Nearpane"), testSession: testSession,
                                      candidate: candidate, boundDraft: boundDraft)
        self.modules = modules
        modules.workRect?.start()
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
        await session.start()
        guard !Task.isCancelled else { return }
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if (passiveDisplayID != nil && acceptanceSession != nil) || (candidate && acceptanceSession == nil && session.configuration.candidateTrayConnected) {
            // Show the explicitly scoped fixture's gallery without opening Settings on the user's desktop.
            await modules.tray.connect()
            guard !Task.isCancelled else { return }
        }
        #endif
        let controller = EdgeWindowController(host: session, modules: modules)
        surface = controller
        if passiveDisplayID != nil { controller.window?.ignoresMouseEvents = true }
        controller.place(screens: placementScreens())
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if let acceptanceSession {
            desktopFixture?.observe(session)
            do {
                if managementTrial, let display = passiveDisplayID, let manager = modules.workRect {
                    managementProbe = try NativeManagementAcceptance(session: acceptanceSession, display: display, host: session, manager: manager)
                }
                acceptanceProbe = try NativeAcceptanceProbe(session: acceptanceSession, host: session, modules: modules,
                    surface: controller, screens: { [weak self] in self?.placementScreens() ?? [] })
            }
            catch { NSApp.terminate(nil); return }
        }
        #endif
        panels = DisplayPanels(host:session,primary:controller)
        session.presentationChanged = { [weak self] in self?.updatePanels() }
        updatePanels()
        if passiveDisplayID == nil { installMenu() }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        host?.stop()
        guard let modules else { return .terminateNow }
        Task {
            await modules.finishStopping()
            await host?.waitForDesktopStop()
            #if canImport(RiftletCore) && canImport(SaytileKit)
            managementProbe?.stop()
            acceptanceProbe?.finish()
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        host?.stop()
        panels?.stop()
        #if canImport(SaytileKit)
        desktopFixture?.stop()
        #endif
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Nearpane controls")
        let menu = NSMenu()
        for (title, action) in [("显示或隐藏侧栏", #selector(toggleSurface)), ("设置…", #selector(showSettings)), ("退出 Nearpane", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func desktopChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: screenAsleep = true
        case NSWorkspace.screensDidWakeNotification: screenAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: break
        }
        panels?.setSuspended(screenAsleep || sessionInactive)
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: host?.setDesktopPause(.screensAsleep, paused: true)
        case NSWorkspace.screensDidWakeNotification: host?.setDesktopPause(.screensAsleep, paused: false)
        case NSWorkspace.sessionDidResignActiveNotification: host?.setDesktopPause(.inactiveSession, paused: true)
        case NSWorkspace.sessionDidBecomeActiveNotification: host?.setDesktopPause(.inactiveSession, paused: false)
        default: host?.invalidateDesktop()
        }
    }

    private func updatePanels() {
        guard host?.isRunning == true else { return }
        panels?.update(screens:placementScreens())
    }

    @objc private func screensChanged() {
        host?.invalidateDesktop()
        updatePanels()
        // Rebuild the settings list on its next explicit opening.
        if settings?.window?.isVisible == true { updateSettingsContent() }
    }

    @objc private func toggleSurface() {
        guard let host else { return }
        host.setSurfaceHidden(!host.configuration.surfaceHidden)
        updatePanels()
    }

    @objc private func showSettings() {
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
        }
        updateSettingsContent()
        settings?.showWindow(nil)
        // Only an explicit Settings click may activate the application.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateSettingsContent() {
        guard let host else { return }
        settings?.window?.contentView = NSHostingView(rootView: SettingsView(host:host,screens:SystemScreens.geometry(),domains:modules,
            requestSecondary: { [weak self] id in self?.panels?.request(id); self?.updatePanels() },
            dismissSpaces: { [weak self] id in self?.panels?.dismiss(id); self?.updatePanels() },
            placementChanged: { [weak self] in self?.updatePanels() }))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
