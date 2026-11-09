import AppKit
import NearpaneCore
import WindowLab

// Only passive ordering is used. Keep ordinary NSWindow semantics so AX reports the native subrole.
private struct Command: Decodable { let sequence: Int, action: String, index: Int }
@MainActor private final class Owner {
    let directory: URL, run: Run, birth: ProcessBirth
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var panel: PassivePanel?
    let gate = ReadOnlyGate()
    var windows = [Int: (Member, NSWindow)](), sequence = 0, revision = 0, activations = 0
    init(_ directory: URL) throws {
        self.directory = directory; run = try .checked(directory); birth = try .read(getpid())
    }
    func create(_ index: Int) throws {
        let (map, screen) = try Screens.read()
        try require(map == run.screens && (1...5).contains(index) && windows[index] == nil, "invalid enrollment")
        let safe = screen.visibleFrame
        let f = CGRect(x: safe.minX + 20 + Double(index * 10), y: safe.minY + 60 + Double(index * 26),
                       width: 240, height: 160).integral
        try require(safe.contains(f), "fixture exceeds secondary")
        let w = NSWindow(contentRect: f, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: true, screen: screen)
        let element = UUID()
        w.isRestorable = false; w.isReleasedWhenClosed = false
        w.title = "Nearpane test W\(index)"
        w.setAccessibilityIdentifier(run.session.uuidString + "/" + element.uuidString)
        w.minSize = .init(width: 144, height: 96)
        w.ignoresMouseEvents = true; w.hasShadow = false; w.animationBehavior = .none
        w.collectionBehavior = [.managed, .ignoresCycle]
        w.backgroundColor = [.systemTeal, .systemOrange, .systemIndigo, .systemGreen, .systemBrown][index - 1]
        // The only AppKit frame assignment in this fixture is initial placement before ordering.
        w.setFrame(f, display: false)
        try require(w.frame == f && screen.frame.contains(w.frame) && (try Screens.read().0) == map,
                    "could not place new fixture safely")
        try require(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground,
                    "focus changed before passive ordering")
        w.orderFrontRegardless()
        let number = w.windowNumber
        guard number > 0, number <= Int(UInt32.max), screen.frame.contains(w.frame), !w.isKeyWindow, !w.isMainWindow
        else { w.close(); throw Refusal("unsafe initial window") }
        let id = ManagedWindowID(pid: birth.pid, launch: birth.start, number: UInt32(number), element: element)
        windows[index] = (Member(index: index, id: id, width: w.minSize.width, height: w.minSize.height, session: run.session), w)
    }
    func finish(_ code: Int32) -> Never {
        gate.stop(); panel?.close()
        for (_, w) in windows.values { w.orderOut(nil); w.close() }
        exit(code)
    }
    func tick() throws {
        try require(try Run.checked(directory) == run, "session changed")
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.json").path) {
            let c: Command = try readJSON(directory, "command.json")
            if c.sequence != sequence {
                try require(c.sequence == sequence + 1, "command out of order")
                switch c.action {
                case "create": try create(c.index)
                case "close":
                    guard let (_, w) = windows.removeValue(forKey: c.index) else { throw Refusal("fixture missing") }
                    w.orderOut(nil); w.close()
                case "gate-read":
                    guard let (m, w) = windows[c.index] else { throw Refusal("gate fixture missing") }
                    if try !gate.sample(member: m, window: w, sequence: c.sequence, run: run, directory: directory) { return }
                case "panel-show", "panel-hide", "panel-expand", "panel-collapse", "panel-tools-off":
                    if panel == nil { panel = PassivePanel() }
                    guard let panel, panel.host.isRunning else { return }
                    try panel.apply(c.action, sequence: c.sequence, run: run, directory: directory)
                case "quit": finish(0)
                default: throw Refusal("unsupported fixture command")
                }
                if c.action == "create" || c.action == "close" { revision += 1 }
                sequence = c.sequence
            }
        }
        let ordered = windows.values.sorted { $0.0.index < $1.0.index }
        try require(ordered.allSatisfy { m, w in w.minSize.width == m.minimum.width && w.minSize.height == m.minimum.height && w.styleMask.contains([.titled, .resizable]) &&
                    !w.styleMask.contains(.fullScreen) && !w.isMiniaturized && w.level == .normal && w.attachedSheet == nil },
                    "fixture ordinary-window attestation failed")
        let primaryTop = NSScreen.screens[0].frame.maxY
        let frames = ordered.map { (_, w) in SurfaceRect(x: w.frame.minX, y: primaryTop - w.frame.maxY,
                                                         width: w.frame.width, height: w.frame.height) }
        let currentForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foregroundMatches = originalForeground != nil && currentForeground == originalForeground
        let ownedKeyOrMain = panel?.window?.isKeyWindow == true || ordered.contains { $0.1.isKeyWindow || $0.1.isMainWindow }
        let badFocus = !foregroundMatches || NSApp.isActive || ownedKeyOrMain
        if badFocus || activations != 0 {
            try writeJSON(["foregroundMatches": foregroundMatches, "foregroundKnown": currentForeground != nil,
                           "fixtureActive": NSApp.isActive, "ownedKeyOrMain": ownedKeyOrMain, "activationNotified": activations != 0],
                          directory, "focus-stop.json")
        }
        try writeJSON(OwnerState(session: run.session, owner: birth, revision: revision, command: sequence,
                      members: ordered.map(\.0), frames: frames, keyOrMain: badFocus, activations: activations), directory, "owner.json")
        try require(!badFocus && activations == 0, "focus boundary changed; see focus-stop.json")
    }
}
do {
    guard CommandLine.arguments.count == 2 else { throw Refusal("expected a private session directory") }
    let app = NSApplication.shared
    if app.activationPolicy() != .accessory { _ = app.setActivationPolicy(.accessory) }
    guard app.activationPolicy() == .accessory else { throw Refusal("cannot run passive fixture") }
    let o = try Owner(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    let focus = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: app, queue: .main) { _ in
        MainActor.assumeIsolated { o.activations += 1 }
    }
    let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
        MainActor.assumeIsolated {
            do { try o.tick() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); o.finish(1) }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    app.run()
    withExtendedLifetime(focus) {}
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
