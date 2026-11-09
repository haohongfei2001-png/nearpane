import AppKit
import NearpaneCore
import NearpaneUI
import WindowLab

@MainActor final class PassivePanel {
    let host = HostSession(store: MemoryConfigurationStore())
    private lazy var edge = EdgeWindowController(host: host)
    var window: NSWindow? { edge.window }
    private var coordinator = MultiDisplayPresentationCoordinator()
    init() { Task { await host.start() } }

    func apply(_ action: String, sequence: Int, run: Run, directory: URL) throws {
        let (screens, secondary) = try Screens.read()
        guard screens == run.screens, let target = SystemScreens.geometry().first(where: { $0.id == screens.secondary }),
              let w = edge.window, w.styleMask.contains(.nonactivatingPanel) else { throw Refusal("unsafe panel target") }
        w.ignoresMouseEvents = true
        host.setPlacement(edge: .left, displayID: screens.secondary)
        switch action {
        case "panel-hide": host.setSurfaceHidden(true)
        case "panel-show": host.setSurfaceHidden(false)
        case "panel-expand":
            let card = BuiltinCatalog.notes
            try require(host.handle(.setEnabled(card, true)) == .accepted && host.handle(.setPinned(card, true)) == .accepted
                && host.handle(.expand(card)) == .accepted, "module expansion refused")
        case "panel-collapse": try require(host.handle(.collapse) == .accepted, "module collapse refused")
        case "panel-tools-off":
            try require(host.handle(.setEnabled(BuiltinCatalog.voice, false)) == .accepted
                && host.handle(.setEnabled(BuiltinCatalog.screenshots, false)) == .accepted, "module setting refused")
        default: throw Refusal("unknown panel command")
        }
        let prefs = host.registry.preferences
        func enabled(_ id: String) -> Bool { prefs.contains { $0.id == id && $0.enabled } }
        // Just like --native-acceptance-secondary, the only candidate for the full test surface is the secondary.
        let plan = coordinator.resolve(screens: [target], preferred: screens.secondary, settings: host.configuration.displays,
            demand: [target.id: .init(spaces: 2, windows: 2, complete: true)], hidden: host.configuration.surfaceHidden,
            voice: enabled(BuiltinCatalog.voice), tray: enabled(BuiltinCatalog.screenshots), spacesEnabled: enabled(BuiltinCatalog.desktop),
            uptime: ProcessInfo.processInfo.systemUptime)
        guard let content = plan.first?.content else { throw Refusal("missing panel plan") }
        edge.place(on: target, primary: target.id, content: content)
        try require(secondary.visibleFrame.contains(w.frame) && !NSApp.isActive, "unsafe panel placement")
        edge.presentIfNeeded()
        try require(!w.isKeyWindow && !w.isMainWindow && secondary.visibleFrame.contains(w.frame)
            && w.isVisible == (content != .hidden), "panel did not reach the requested state")
        struct Receipt: Codable { let action: String, number: Int, visible, expanded: Bool, frame: SurfaceRect }
        try writeJSON(Receipt(action: action, number: w.windowNumber, visible: w.isVisible,
                              expanded: host.registry.expandedID != nil, frame: .init(x: w.frame.minX,
                              y: NSScreen.screens[0].frame.maxY - w.frame.maxY, width: w.frame.width, height: w.frame.height)), directory, "panel-\(sequence).json")
    }
    func close() { edge.close(); host.stop() }
}
