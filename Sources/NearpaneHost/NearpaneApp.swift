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
                    guard args.count == 3, args[1] == "--native-acceptance-prepare" else { exit(2) }
                    let session = try NativeAcceptanceSession(id: args[2], prepare: true)
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
            guard args.count == 2, command == "--native-acceptance-session" else { exit(2) }
            do {
                delegate.acceptanceSession = try NativeAcceptanceSession(id: args[1], prepare: false)
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
    private var acceptanceProbe: NativeAcceptanceProbe?
    #endif
    private var host: HostSession?
    private var modules: EmbeddedModules?
    private var surface: EdgeWindowController?
    private var settings: NSWindowController?
    private var statusItem: NSStatusItem?
    private var startupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var testSession: URL?
        #if canImport(RiftletCore) && canImport(SaytileKit)
        if let acceptanceSession { support = acceptanceSession.support; testSession = acceptanceSession.directory }
        #endif
        let store = FileConfigurationStore(url: support.appendingPathComponent("Nearpane/host-configuration.json"))
        let modules = EmbeddedModules(support: support.appendingPathComponent("Nearpane"), testSession: testSession)
        self.modules = modules
        let session = modules.makeHost(store: store)
        host = session
        startupTask = Task { [weak self] in
            await session.start()
            guard !Task.isCancelled, let self else { return }
            let controller = EdgeWindowController(host: session, modules: modules)
            surface = controller
            controller.place(screens: SystemScreens.geometry())
            #if canImport(RiftletCore) && canImport(SaytileKit)
            if let acceptanceSession {
                do { acceptanceProbe = try NativeAcceptanceProbe(session: acceptanceSession, host: session, modules: modules, surface: controller) }
                catch { NSApp.terminate(nil); return }
            }
            #endif
            controller.presentIfNeeded()
            installMenu()
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        host?.stop()
        guard let modules else { return .terminateNow }
        Task {
            await modules.finishStopping()
            #if canImport(RiftletCore) && canImport(SaytileKit)
            acceptanceProbe?.finish()
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        host?.stop()
        surface?.hide()
        NotificationCenter.default.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Nearpane controls")
        let menu = NSMenu()
        for (title, action) in [("Show / Hide Surface", #selector(toggleSurface)), ("Settings…", #selector(showSettings)), ("Quit Nearpane", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func screensChanged() {
        surface?.place(screens: SystemScreens.geometry())
        surface?.presentIfNeeded()
        // Rebuild the settings list on its next explicit opening.
        if settings?.window?.isVisible == true { updateSettingsContent() }
    }

    @objc private func toggleSurface() {
        guard let host else { return }
        host.setSurfaceHidden(!host.configuration.surfaceHidden)
        surface?.place(screens: SystemScreens.geometry())
        surface?.presentIfNeeded()
    }

    @objc private func showSettings() {
        guard host != nil else { return }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 632, height: 572),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
            window.title = "Nearpane Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settings = NSWindowController(window: window)
        }
        updateSettingsContent()
        settings?.showWindow(nil)
        // Only an explicit Settings click may activate the application.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateSettingsContent() {
        guard let host else { return }
        settings?.window?.contentView = NSHostingView(rootView: SettingsView(host: host, screens: SystemScreens.geometry(), domains: modules) { [weak self] in
            self?.surface?.place(screens: SystemScreens.geometry())
        })
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
