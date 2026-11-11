#if canImport(SaytileKit)
import AppKit
import NearpaneCore
import NearpaneUI
import SwiftUI

private final class PassiveManagementPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Explicit, marked secondary-only acceptance runs drive the same service and Settings content as Finder launches.
@MainActor final class NativeManagementAcceptance {
    private let panel: NSPanel
    private var timer: Timer?
    private var sequence = 0
    private struct Request: Decodable { let run: String, sequence: Int, action: String }

    init(session: NativeAcceptanceSession, display: String, host: HostSession, manager: CandidateWorkRect) throws {
        guard let epoch = ProcessInfo.processInfo.environment["NEARPANE_ACCEPTANCE_RUN"],
              UUID(uuidString: epoch) != nil, NSScreen.screens.count == 2, let screen = NSScreen.screens.last,
              SystemScreens.geometry().last?.id == display,
              screen.frame.intersection(NSScreen.screens[0].frame).isEmpty else { throw CocoaError(.featureUnsupported) }
        let sizing = ProcessInfo.processInfo.environment["NEARPANE_SIZE_ACCEPTANCE"] == session.directory.lastPathComponent
        let admission = ProcessInfo.processInfo.environment["NEARPANE_ADMISSION_ACCEPTANCE"] == session.directory.lastPathComponent
        guard !(sizing && admission) else { throw CocoaError(.featureUnsupported) }
        // On this rotated display the OS can move a newly ordered panel inward (the live
        // witness was x=-681 for a 690 pt window). Leave space at both edges and
        // keep the continuous, independent containment check after ordering.
        let safeAdmissionWidth = min(580, screen.visibleFrame.width - 2 * 100)
        guard !admission || safeAdmissionWidth >= 480 else { throw CocoaError(.featureUnsupported) }
        let width = admission ? safeAdmissionWidth : sizing ? min(610, screen.visibleFrame.width) : 540
        let height = admission ? min(1080, screen.visibleFrame.height) : sizing ? min(900, screen.visibleFrame.height) : 400
        let rect = CGRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2,
                          width: width, height: height).integral
        guard screen.visibleFrame.contains(rect) else { throw CocoaError(.featureUnsupported) }
        panel = PassiveManagementPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: true)
        panel.title = sizing ? "Nearpane 设置 · 尺寸与呈现" : "Nearpane 设置 · 窗口管理"
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        if sizing, let target = SystemScreens.geometry().first(where: { $0.id == display }) {
            panel.contentView = NSHostingView(rootView: WorkspaceDisplaySettings(host: host, screens: [target],
                request: { _ in }, dismiss: { _ in }))
        } else {
            let content = NSHostingView(rootView: CandidateWorkRectView(session: manager, host: host, admissionFixtureOnly: admission))
            if admission { content.sizingOptions = [] }
            panel.contentView = content
        }
        panel.setFrame(rect, display: false)
        guard screen.visibleFrame.contains(panel.frame) else { throw CocoaError(.featureUnsupported) }
        panel.orderFrontRegardless()
        let directory = session.directory
        let id = panel.windowNumber
        try JSONEncoder().encode(id).write(to: directory.appendingPathComponent("management-panel-" + epoch + ".json"), options: .withoutOverwriting)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSScreen.screens.count == 2, SystemScreens.geometry().last?.id == display,
                      NSScreen.screens.last?.visibleFrame.contains(self.panel.frame) == true, !self.panel.isKeyWindow, !self.panel.isMainWindow
                else {
                    if admission {
                        struct Refusal: Encodable { let count: Int, expectedDisplay: Bool, contained: Bool, key: Bool, main: Bool, frame: CGRect }
                        let proof = Refusal(count: NSScreen.screens.count, expectedDisplay: SystemScreens.geometry().last?.id == display,
                            contained: NSScreen.screens.last?.visibleFrame.contains(self.panel.frame) == true,
                            key: self.panel.isKeyWindow, main: self.panel.isMainWindow, frame: self.panel.frame)
                        try? JSONEncoder().encode(proof).write(to: directory.appendingPathComponent("settings-refusal-" + epoch + ".json"), options: .withoutOverwriting)
                    }
                    self.stop(); NSApp.terminate(nil); return
                }
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("management-request.json")),
                      let req = try? JSONDecoder().decode(Request.self, from: data), req.run == epoch, req.sequence == self.sequence + 1 else { return }
                self.sequence = req.sequence
                // Rehearsal can create/close only the separately registered synthetic fixtures.
                // Never grant, enable, retry or invoke the AX frame writer in this mode.
                if admission && !["open", "close", "exclude-last", "include-last", "hide", "show", "quit"].contains(req.action) {
                    self.stop(); NSApp.terminate(nil); return
                }
                switch req.action {
                case "enable","disable","pause","resume","retry","open","close","adopt","pair 62 original":
                    manager.send(req.action)
                case "hide","show": host.setSurfaceHidden(req.action == "hide")
                case "docked", "floating":
                    guard let main = SystemScreens.geometry().first?.id, main != display else { return }
                    host.setPlacement(edge: host.configuration.edge, displayID: main)
                    var settings = host.configuration.displays[display] ?? .init()
                    settings.placement = req.action == "floating" ? .floating : .docked
                    host.setDisplaySettings(settings, id: display)
                case "tight-reserve", "reset-reserve":
                    var settings = host.configuration.displays[display] ?? .init()
                    settings.measures[.reservedWidth] = req.action == "tight-reserve" ? Measure(95, .percent) : nil
                    host.setDisplaySettings(settings, id: display)
                case "exclude-last", "include-last":
                    if let id = manager.windows.last {
                        var prefs = host.configuration.workspaces
                        prefs.windows[id] = req.action == "exclude-last" ? .exclude : nil
                        host.setWorkspacePreferences(prefs)
                    }
                case "quit": NSApp.terminate(nil)
                default: break
                }
                try? JSONEncoder().encode(req.sequence).write(to: directory.appendingPathComponent("management-ack-" + epoch + ".json"), options: .atomic)
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); panel.orderOut(nil); panel.close() }
}
#endif
