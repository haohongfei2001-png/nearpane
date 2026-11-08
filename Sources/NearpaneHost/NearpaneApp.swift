import AppKit
import SwiftUI
import NearpaneCore
import NearpaneUI

@main
struct NearpaneApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = HostAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var host: HostSession?
    private var surface: EdgeWindowController?
    private var settings: NSWindowController?
    private var statusItem: NSStatusItem?
    private var startupTask: Task<Void, Never>?
    private var userHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = FileConfigurationStore(url: support.appendingPathComponent("Nearpane/host-configuration.json"))
        let session = HostSession(store: store)
        host = session
        startupTask = Task { [weak self] in
            await session.start()
            guard !Task.isCancelled, let self else { return }
            let controller = EdgeWindowController(host: session)
            surface = controller
            controller.place(screens: SystemScreens.geometry())
            controller.present()
            installMenu()
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
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
        if !userHidden && !SystemScreens.geometry().isEmpty { surface?.present() }
        // Rebuild the settings list on its next explicit opening.
        if settings?.window?.isVisible == true { updateSettingsContent() }
    }

    @objc private func toggleSurface() {
        userHidden.toggle()
        if userHidden { surface?.hide() }
        else { surface?.place(screens: SystemScreens.geometry()); surface?.present() }
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
        settings?.window?.contentView = NSHostingView(rootView: SettingsView(host: host, screens: SystemScreens.geometry()) { [weak self] in
            self?.surface?.place(screens: SystemScreens.geometry())
        })
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
