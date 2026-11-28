import AppKit
import NearpaneCore
import WindowLab

// Exercise the same per-display presentation and persistent layout planners used by the Host.
// The observers remain external to the ordinary windows. This test does not order a Host panel.
@MainActor func presentation(_ adapter: FixtureAdapter) throws -> [ActionReceipt] {
    let x = try Experiment(adapter.directory), observed = try x.observations(), state = try x.state(at: observed), m = adapter.run.screens
    var options = DisplaySettings(); options.policy = .pinned
    let prefs = [m.secondary: options]
    let primary = ScreenGeometry(id: m.main, frame: m.mainFrame, visibleFrame: m.mainFrame)
    let secondary = ScreenGeometry(id: m.secondary, frame: m.frame, visibleFrame: m.usable)
    let area = try DesktopWorkArea(display: m.secondary, screen: m.frame, usable: m.usable, primary: false, settings: options, fallbackEdge: .left)
    var panel = MultiDisplayPresentationCoordinator(), tiler = WorkAreaLayoutPlanner()
    _ = try tiler.update(area: area, layout: state.layout)
    let before = observed.map(\.cg)
    var results = [ActionReceipt]()
    for (name, hide, voice, tray) in [("shown",false,true,true), ("hidden",true,true,true), ("restored",false,true,true),
                                        ("voice-collapsed",false,false,true), ("tools-collapsed",false,false,false)] {
        let plans = panel.resolve(screens: [primary, secondary], preferred: m.main, settings: prefs,
                                  demand: [m.secondary: .init(spaces: 2, windows: 2, complete: true)],
                                  hidden: hide, voice: voice, tray: tray, spacesEnabled: true, uptime: ProcessInfo.processInfo.systemUptime)
        try require(plans.first { $0.id == m.secondary }?.content == (hide ? .hidden : .spacesOnly), "unexpected presentation")
        let next = try tiler.update(area: area, layout: state.layout)
        try require(next == nil && (try x.observations().map(\.cg)) == before, "presentation changed layout")
        results.append(try x.picture(name, area: area.ordinary))
    }
    return results
}

struct PanelReceipt: Codable {
    let action: String, number: Int, visible, expanded: Bool, frame: SurfaceRect
}
@MainActor func panelObservation(_ a: FixtureAdapter) throws -> PanelReceipt {
    let r: PanelReceipt = try readJSON(a.directory, "panel-\(a.ticket.command).json")
    try require(r.number > 0 && r.number <= Int(UInt32.max), "invalid fixture panel number")
    let until = ProcessInfo.processInfo.systemUptime + 1.0
    var found: SurfaceRect?, onScreen = false, identity = false
    repeat {
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, UInt32(r.number)) as? [[String: Any]]
        if let rows, rows.isEmpty && !r.visible { return r }
        if let rows, rows.count == 1, let row = rows.first {
            identity = row[kCGWindowOwnerPID as String] as? Int32 == a.ticket.owner.pid && row[kCGWindowNumber as String] as? Int == r.number
            if identity, let fields = row[kCGWindowBounds as String] as? NSDictionary, let f = CGRect(dictionaryRepresentation: fields) {
                found = SurfaceRect(rect(f)); onScreen = row[kCGWindowIsOnscreen as String] as? Bool == true
                if found == r.frame && onScreen == r.visible && a.run.screens.frame.geometry.intersection(r.frame.geometry) == r.frame.geometry {
                    return r
                }
            }
        }
        usleep(25_000)
    } while ProcessInfo.processInfo.systemUptime < until
    throw Refusal("fixture panel CG mismatch; identity=\(identity) visible=\(onScreen) observed=\(String(describing: found)) expected=\(r.frame)")

}

@MainActor func confirmExit(_ dir: URL) throws -> [String: Int] {
    let run = try Run.checked(dir), ticket: OwnerState = try readJSON(dir, "ticket.json")
    try require(ticket.session == run.session && ticket.owner.parent == run.parent.pid
        && (try? ProcessBirth.read(ticket.owner.pid)) != ticket.owner, "fixture is still alive or wrong parent")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("enroll-") && $0.hasSuffix(".json") }
    var ids = Set<UInt32>()
    for name in names {
        let enrollment: OwnerState = try readJSON(dir, name)
        if enrollment.session == run.session && enrollment.owner == ticket.owner { ids.formUnion(enrollment.members.map(\.id.number)) }
    }
    try require(!ids.isEmpty, "no enrolled windows for exit verification")
    for id in ids {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { throw Refusal("CG cleanup unavailable") }
        try require(!rows.contains { $0[kCGWindowOwnerPID as String] as? Int32 == ticket.owner.pid }, "fixture WindowServer record survived exit")
    }
    return ["confirmedGone": ids.count]
}
