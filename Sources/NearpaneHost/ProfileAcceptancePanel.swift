#if canImport(SaytileKit)
import AppKit
import SwiftUI
import NearpaneUI

/// Exposes the real Settings controls to a signed, marked, secondary-only session.
@MainActor final class ProfileAcceptancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private var safetyTimer: Timer?

    static func present(options: ProfileImportOptions, session: NativeAcceptanceSession, displayID: String) throws -> NSWindowController {
        try present(contents: AnyView(ScrollView {
            ProfileImportSettings(options: options, initiallyExpanded: true).padding(18)
        }), session: session, displayID: displayID, recordPrefix: "profile-settings-")
    }

    static func present(contents: AnyView, session: NativeAcceptanceSession, displayID: String,
                        recordPrefix: String) throws -> NSWindowController {
        guard ["profile-settings-", "application-services-"].contains(recordPrefix) else { throw CocoaError(.featureUnsupported) }
        let screens = NSScreen.screens, geometry = SystemScreens.geometry()
        guard screens.count == 2, geometry.count == 2, geometry.last?.id == displayID,
              let side = screens.last, let primary = screens.first, !side.frame.intersects(primary.frame),
              side.visibleFrame.width >= 536, side.visibleFrame.height >= 448,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != getpid() else {
            throw CocoaError(.featureUnsupported)
        }
        let work = side.visibleFrame
        let frame = NSRect(x: work.midX - 260, y: work.midY - 212, width: 520, height: 424)
        let panel = ProfileAcceptancePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: contents)
        panel.setFrame(frame, display: false)
        guard side.visibleFrame.contains(panel.frame), !NSApp.isActive else { throw CocoaError(.featureUnsupported) }
        panel.orderFrontRegardless()
        let controller = NSWindowController(window: panel)
        guard panel.isVisible, !panel.isKeyWindow, !panel.isMainWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == front else {
            panel.orderOut(nil)
            throw CocoaError(.featureUnsupported)
        }
        let info: [String: Any] = ["pid": getpid(), "windowNumber": panel.windowNumber, "display": displayID, "frontPID": front]
        let data = try JSONSerialization.data(withJSONObject: info)
        try data.write(to: session.directory.appendingPathComponent(recordPrefix + UUID().uuidString.lowercased() + ".json"),
                       options: .withoutOverwriting)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                let now = NSScreen.screens
                guard now.count == 2, SystemScreens.geometry().last?.id == displayID,
                      now[1].visibleFrame.contains(panel.frame), !now[0].frame.intersects(panel.frame), !NSApp.isActive,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == front else {
                    panel.orderOut(nil)
                    panel.safetyTimer?.invalidate()
                    NSApp.terminate(nil)
                    return
                }
            }
        }
        panel.safetyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return controller
    }
}
#endif
