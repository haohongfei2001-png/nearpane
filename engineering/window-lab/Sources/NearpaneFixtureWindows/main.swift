import AppKit
import NearpaneCore
import WindowLab

// Only passive ordering is used. Keep ordinary NSWindow semantics so AX reports the native subrole.
private struct Command: Decodable { let sequence: Int, action: String, index: Int; let expected: ManagedWindowID? }
@MainActor private final class Owner: NSObject {
    let directory: URL, run: Run, birth: ProcessBirth
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var focusStudy: FocusStudy?
    var panel: PassivePanel?
    private var lastMembers: [Member] = []
    private var resizeID: UUID?, resizedWindow: ManagedWindowID?
    private var resizedFrame: SurfaceRect?, resizeUptime: Double?
    private var hadProductWindow = false
    let gate = ReadOnlyGate()
    var windows = [Int: (Member, NSWindow)](), sequence = 0, revision = 0, activations = 0
    init(_ directory: URL) throws {
        self.directory = directory; run = try .checked(directory); birth = try .read(getpid())
        super.init()
        if run.productManagement == true {
            try require(run.parent == (try ProcessBirth.read(getppid())), "unregistered owner launch")
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(endedResize), name: NSWindow.didEndLiveResizeNotification, object: nil)
            center.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: nil)
        }
        if run.parkingStudy == true { focusStudy = try FocusStudy(directory) }
    }
    @objc private func endedResize(_ note: Notification) {
        guard let w = note.object as? NSWindow, let member = windows.values.first(where: { $0.1 === w })?.0 else { return }
        guard let top = NSScreen.screens.first?.frame.maxY else { return }
        resizeID = UUID(); resizedWindow = member.id
        resizedFrame = .init(x: w.frame.minX, y: top - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        resizeUptime = ProcessInfo.processInfo.systemUptime
    }
    @objc private func closed(_ note: Notification) {
        guard let w = note.object as? NSWindow, let key = windows.first(where: { $0.value.1 === w })?.key else { return }
        windows.removeValue(forKey: key)
    }
    func create(_ index: Int) throws {
        let (map, screen) = try Screens.read()
        try require(map == run.screens && (1...(run.productManagement == true ? 32 : 5)).contains(index) && windows[index] == nil, "invalid enrollment")
        let safe = screen.visibleFrame
        let f = CGRect(x: safe.minX + 20 + Double((index % 6) * 10), y: safe.minY + 60 + Double((index % 6) * 26),
                       width: 240, height: 160).integral
        try require(safe.contains(f), "fixture exceeds secondary")
        var style: NSWindow.StyleMask = [.titled, .resizable, .closable, .miniaturizable]
        if index == 3 && run.parkingStudy == true { style.remove(.miniaturizable) }
        let w = NSWindow(contentRect: f, styleMask: style,
                              backing: .buffered, defer: true, screen: screen)
        let element = UUID()
        w.isRestorable = false; w.isReleasedWhenClosed = false
        w.title = "Nearpane test W\(index)"
        w.setAccessibilityIdentifier(run.session.uuidString + "/" + element.uuidString)
        w.minSize = .init(width: 144, height: 96)
        w.ignoresMouseEvents = run.productManagement != true; w.hasShadow = false; w.animationBehavior = .none
        w.collectionBehavior = [.managed, .ignoresCycle]
        w.backgroundColor = [.systemTeal, .systemOrange, .systemIndigo, .systemGreen, .systemBrown][(index - 1) % 5]
        // The only AppKit frame assignment in this fixture is initial placement before ordering.
        w.setFrame(f, display: false)
        try require(w.frame == f && screen.frame.contains(w.frame) && (try Screens.read().0) == map,
                    "could not place new fixture safely")
        try require(run.productManagement == true || (!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground),
                    "focus changed before passive ordering")
        if run.productManagement == true {
            let button = NSButton(title: "新建窗口", target: self, action: #selector(newCompatibleWindow))
            button.frame.origin = .init(x: 18, y: 18)
            w.contentView?.addSubview(button)
        }
        w.orderFrontRegardless()
        let number = w.windowNumber
        guard number > 0, number <= Int(UInt32.max), screen.frame.contains(w.frame), !w.isKeyWindow, !w.isMainWindow
        else { w.close(); throw Refusal("unsafe initial window") }
        let id = ManagedWindowID(pid: birth.pid, launch: birth.start, number: UInt32(number), element: element)
        windows[index] = (Member(index: index, id: id, width: w.minSize.width, height: w.minSize.height, session: run.session), w)
    }
    @objc private func newCompatibleWindow() {
        guard run.productManagement == true, let i = (1...32).first(where: { windows[$0] == nil }) else { return }
        do { try create(i) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    }
    func finish(_ code: Int32) -> Never {
        gate.stop(); panel?.close()
        for (_, w) in Array(windows.values) { w.orderOut(nil); w.close() }
        exit(code)
    }
    func tick() throws {
        if run.productManagement == true {
            // A changed display topology suspends management; it never closes a live window.
            guard (try? Run.checked(directory)) == run else { return }
        } else { try require(try Run.checked(directory) == run, "session changed") }
        try focusStudy?.sample(windows: windows, panel: panel?.window)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.json").path) {
            let c: Command = try readJSON(directory, "command.json")
            if c.sequence != sequence {
                try require(c.sequence == sequence + 1, "command out of order")
                switch c.action {
                case "create": try create(c.index)
                case "close":
                    guard let (m, w) = windows[c.index], run.productManagement != true || c.expected == m.id else { throw Refusal("fixture missing or replaced") }
                    windows.removeValue(forKey: c.index)
                    w.orderOut(nil); w.close()
                case "resize-leading":
                    // Owner-side counterfactual only in an isolated acceptance session. This never counts as an AX write.
                    let acceptance = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    try require(run.productManagement == true && acceptance.deletingLastPathComponent().lastPathComponent == "native-acceptance"
                        && ProcessInfo.processInfo.environment["NEARPANE_MANAGEMENT_ACCEPTANCE"] == acceptance.lastPathComponent
                        && windows.count == 2, "isolated pair required")
                    guard let (_, w) = windows[c.index], let secondary = NSScreen.screens.last else { throw Refusal("member missing") }
                    var frame = w.frame
                    frame.size.width -= 22
                    try require(frame.width >= w.minSize.width && secondary.visibleFrame.contains(frame), "unsafe resize")
                    w.setFrame(frame, display: true)
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
                if run.productManagement != true && (c.action == "create" || c.action == "close") { revision += 1 }
                sequence = c.sequence
            }
        }
        let candidates = windows.values.filter { _, w in
            run.productManagement != true || (w.isVisible && w.isOnActiveSpace && !w.isMiniaturized
                && !w.styleMask.contains(.fullScreen) && w.attachedSheet == nil && w.level == .normal)
        }
        let ordered = candidates.map { member, window in
            let live = run.productManagement == true
                ? Member(index: member.index, id: member.id, width: window.minSize.width, height: window.minSize.height, session: run.session) : member
            return (live, window)
        }.sorted { $0.0.index < $1.0.index }
        if run.productManagement == true, lastMembers != ordered.map(\.0) {
            lastMembers = ordered.map(\.0)
            revision += 1
        }
        try require(ordered.allSatisfy { m, w in w.minSize.width == m.minimum.width && w.minSize.height == m.minimum.height && w.styleMask.contains([.titled, .resizable]) &&
                    !w.styleMask.contains(.fullScreen) && (!w.isMiniaturized || (run.parkingStudy == true && m.index <= 2)) && w.level == .normal && w.attachedSheet == nil },
                    "fixture ordinary-window attestation failed")
        let primaryTop = NSScreen.screens[0].frame.maxY
        let frames = ordered.map { (_, w) in SurfaceRect(x: w.frame.minX, y: primaryTop - w.frame.maxY,
                                                         width: w.frame.width, height: w.frame.height) }
        let currentForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foregroundMatches = originalForeground != nil && currentForeground == originalForeground
        let ownedKeyOrMain = panel?.window?.isKeyWindow == true || ordered.contains { $0.1.isKeyWindow || $0.1.isMainWindow }
        let badFocus = (run.productManagement != true && !foregroundMatches) || NSApp.isActive || ownedKeyOrMain
        if badFocus || (run.productManagement != true && activations != 0) {
            try writeJSON(["foregroundMatches": foregroundMatches, "foregroundKnown": currentForeground != nil,
                           "fixtureActive": NSApp.isActive, "ownedKeyOrMain": ownedKeyOrMain, "activationNotified": activations != 0],
                          directory, "focus-stop.json")
        }
        var state = OwnerState(session: run.session, owner: birth, revision: revision, command: sequence,
                               members: ordered.map(\.0), frames: frames, keyOrMain: badFocus, activations: activations)
        if run.productManagement == true {
            state.editing = ordered.contains { $0.1.inLiveResize } || NSEvent.pressedMouseButtons != 0
            if !windows.isEmpty { hadProductWindow = true }
            state.resizedFrame = resizedFrame; state.resizeUptime = resizeUptime
            state.lastResize = resizeID; state.resizedWindow = resizedWindow; state.occupied = windows.keys.sorted()
        }
        try writeJSON(state, directory, "owner.json")
        if run.productManagement == true && hadProductWindow && windows.isEmpty { finish(0) }
        if run.productManagement != true { try require(!badFocus && activations == 0, "focus boundary changed; see focus-stop.json") }
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
