import AppKit
import NearpaneCore
import WindowLab

// Test-only. Setup directions must have been demonstrated by the isolated GUI
// controller on these endpoints. Input uses the current login session tap only.
@MainActor final class Trial {
  let dir: URL, kit: URL, run = UUID()
  private let lease: Int32
  let birth: ProcessBirth
  var revision: UInt64 = 0
  var windows: [String: NSWindow] = [:], elements: [String: AXUIElement] = [:]
  struct Position: Equatable, Codable {
    let scope: String, record: String, currents: [String: String], frame: SurfaceRect
    let number: UInt32, frontPID: Int32, topology: String, build: String, recordOrder: [String]
  }
  var baseline: [String: Position] = [:], focus: [String: AXUIElement] = [:]
  var initialFocus: (Int32, AXUIElement)?
  struct SessionIdentity: Decodable, Equatable {
    let uid, consoleUID, securityID: UInt32
    let boot: String, displays: [String]
  }
  private var admitted: SessionIdentity?
  var originDisplay: String?
  let deadline = ProcessInfo.processInfo.systemUptime + 600
  init() throws {
    kit = Bundle.main.bundleURL.deletingLastPathComponent()
    let base = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    lease = open(
      base.appendingPathComponent("Nearpane-P431-writer.lock").path,
      O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o600)
    try require(
      lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0,
      "another test controller or no private lease")
    dir = base.appendingPathComponent("Nearpane-P431-" + run.uuidString)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    birth = try .read(getpid())
  }
  func helper(_ url: URL, _ args: [String], output: URL) throws {
    let p = Process()
    p.executableURL = url
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    try Data().write(to: output, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    p.standardOutput = handle
    try p.run()
    let end = ProcessInfo.processInfo.systemUptime + 5
    while p.isRunning && ProcessInfo.processInfo.systemUptime < end { pump() }
    if p.isRunning {
      p.terminate()
      throw Refusal("observer timeout")
    }
    try require(p.terminationStatus == 0, "observer refused: " + output.lastPathComponent)
  }
  func scope() throws {
    try require(ProcessInfo.processInfo.systemUptime < deadline, "trial expired")
    let url = dir.appendingPathComponent("scope-" + UUID().uuidString + ".json")
    try helper(
      kit.appendingPathComponent("SessionProbe"),
      ["check", kit.appendingPathComponent("protected.json").path], output: url)
    struct Check: Decodable { let caller: SessionIdentity, verdict: String }
    let check = try JSONDecoder().decode(Check.self, from: Data(contentsOf: url))
    try require(
      check.verdict == "ISOLATED_GUI_CANDIDATE" && (admitted == nil || admitted == check.caller),
      "session binding changed")
    admitted = check.caller
  }
  private var gui: NSApplication?
  private var clicked = Set<String>()
  func pump() {
    if let gui {
      while let event = gui.nextEvent(
        matching: .any, until: .distantPast, inMode: .default, dequeue: true)
      {
        if event.type == .leftMouseDown, let target = event.window,
          let label = windows.first(where: { $0.value === target })?.key
        {
          clicked.insert(label)
        }
        gui.sendEvent(event)
      }
      gui.updateWindows()
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
  }
  func announce(_ message: String) {
    print(message)
    fflush(stdout)
  }
  func screen() throws -> (NSScreen, String) {
    guard NSScreen.screens.count == 2,
      let secondary = NSScreen.screens.first(where: {
        ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
          != CGMainDisplayID()
      }), let n = secondary.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { throw Refusal("two test displays required") }
    let display = CFUUIDCreateString(nil, uuid) as String
    try require(originDisplay == nil || originDisplay == display, "test display changed")
    originDisplay = display
    return (secondary, display)
  }
  func create(_ label: String) throws {
    try scope()
    let (s, _) = try screen()
    let visible = s.visibleFrame
    let r = CGRect(x: visible.midX - 140, y: visible.midY - 90, width: 280, height: 180).integral
    try require(visible.contains(r) && windows[label] == nil, "invalid enrollment")
    let w = NSWindow(
      contentRect: .init(origin: .zero, size: r.size), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: true, screen: s)
    w.isRestorable = false
    w.isReleasedWhenClosed = false
    w.ignoresMouseEvents = false
    w.title = "Nearpane test " + label
    w.setAccessibilityIdentifier(run.uuidString + "/" + label)
    w.contentView = NSTextField(labelWithString: "P4.3 " + label + " " + run.uuidString)
    w.setFrame(r, display: false)
    try require(w.frame == r && s.visibleFrame.contains(w.frame), "unsafe fixture frame")
    windows[label] = w
    w.orderFrontRegardless()
  }
  // The window is retained for the entire run. Independently bind its AX identifier
  // to one live AX object; one-shot DesktopReader UUIDs are not cross-process handles.
  func ownedAX(_ label: String) throws {
    let list =
      labAttribute(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement]
    let matches = list?.filter {
      labAttribute($0, kAXIdentifierAttribute) as? String == run.uuidString + "/" + label
    }
    guard matches?.count == 1, let w = matches?.first,
      labAttribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
      labAttribute(w, kAXMinimizedAttribute) as? Bool == false
    else { throw Refusal("missing enrolled AX window") }
    if let prior = elements[label] { try require(CFEqual(prior, w), "AX window rebuilt") }
    elements[label] = w
  }
  func focusedWindow() throws -> (Int32, AXUIElement) {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let raw = labAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { throw Refusal("focus unavailable") }
    let el = raw as! AXUIElement
    var owner: Int32 = 0
    try require(AXUIElementGetPid(el, &owner) == .success && owner == pid, "invalid focus owner")
    if let initialFocus {
      let original = initialFocus.0 == pid && CFEqual(initialFocus.1, el)
      let enrolled = pid == birth.pid && elements.values.contains { CFEqual($0, el) }
      try require(original || enrolled, "focus left the enrolled test session targets")
    }
    return (pid, el)
  }
  func sample(_ label: String) throws -> Position {
    try scope()
    guard let w = windows[label] else { throw Refusal("unknown window") }
    try ownedAX(label)
    let (screen, display) = try screen()
    func placement() throws -> SurfaceRect {
      try require(
        w.isOnActiveSpace && w.isVisible && !w.isMiniaturized && w.screen == screen
          && !w.collectionBehavior.contains(.canJoinAllSpaces) && screen.frame.contains(w.frame)
          && windows.allSatisfy { $0.key == label || !$0.value.isOnActiveSpace },
        "ambiguous visible membership")
      let top = CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
      return .init(
        x: w.frame.minX, y: top - w.frame.maxY, width: w.frame.width, height: w.frame.height)
    }
    let frame = try placement()
    let number = UInt32(w.windowNumber)
    let (pid, el) = try focusedWindow()
    if let expected = focus[label] {
      try require(CFEqual(expected, el), "unexpected focus at endpoint")
    }
    revision += 1
    let req = DesktopReadRequest(
      session: run, revision: revision, parentPID: getpid(), fixtureWindows: [number],
      anchors: [.init(number: number, displayID: display, globalFrame: frame)],
      experimentalSpaces: true)
    let url = dir.appendingPathComponent("snapshot-\(revision).json")
    try helper(
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
      ["--read-encoded", try JSONEncoder().encode(req).base64EncodedString()], output: url)
    let s = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: url))
    guard s.isStructurallyValid,
      s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
      s.sessionID == run, s.revision == revision, s.separateSpaces == true,
      s.native?.accessibility == .available,
      s.native?.population == .markedFixture, s.native?.spaces == .observed,
      s.native?.windowLimitReached == false,
      s.native?.rows.count == 1, let row = s.native?.rows.first, row.displayID == display,
      row.anchor.number == number,
      row.anchor.witness == .ownedWindow, row.anchor.globalFrame == frame, s.windows.count == 1,
      let obs = s.windows.first, let id = ManagedWindowID(obs), id.pid == birth.pid,
      id.launch == birth.start, id.number == number,
      obs.membership == .known(recordIDs: [row.recordID]), obs.metadata?.globalFrame == frame
    else { throw Refusal("no independent Space/window witness") }
    var currents = [String: String]()
    for scope in s.scopes {
      let active = scope.records.filter(\.isCurrent)
      guard active.count == 1, currents[scope.displayID] == nil else {
        throw Refusal("ambiguous display current")
      }
      currents[scope.displayID] = active[0].id
    }
    try require(
      currents.count == 2 && currents[display] == row.recordID && (try placement()) == frame,
      "unstable frame or scopes")
    try ownedAX(label)
    let (after, focusAfter) = try focusedWindow()
    try require(after == pid && CFEqual(el, focusAfter), "focus changed during read")
    focus[label] = el
    return .init(
      scope: row.scopeID, record: row.recordID, currents: currents, frame: frame, number: number,
      frontPID: pid,
      topology: s.topologyFingerprint, build: s.sourceBuild,
      recordOrder: s.scopes.first(where: { $0.id == row.scopeID })?.records.map(\.id) ?? [])
  }
  func stable(_ label: String, _ checkpoint: String) throws -> Position {
    let first = try sample(label)
    let until = ProcessInfo.processInfo.systemUptime + 0.25
    while ProcessInfo.processInfo.systemUptime < until { pump() }
    let second = try sample(label)
    try require(
      first == second && (baseline[label] == nil || baseline[label] == second),
      "endpoint differs from frozen baseline")
    try writeJSON(second, dir, checkpoint + ".json")
    return second
  }
  // Rendezvous with the controller running in the isolated GUI. The unique
  // directory is mode 0700. A checkpoint file alone never attests a transition.
  func awaitCheckpoint(_ name: String) throws {
    let url = dir.appendingPathComponent(name + ".ready")
    try require(
      !FileManager.default.fileExists(atPath: url.path), "checkpoint arrived before request")
    try writeJSON(
      ["checkpoint": name, "run": run.uuidString, "afterRevision": String(revision)], dir,
      "request-" + name + ".json")
    announce("WAIT " + name)
    while !FileManager.default.fileExists(atPath: url.path) {
      try require(ProcessInfo.processInfo.systemUptime < deadline, "checkpoint timeout")
      pump()
    }
    try scope()
  }
  enum Direction: String, Codable { case left, right }
  func demonstrated(_ checkpoint: String) throws -> Direction {
    struct Calibration: Decodable {
      let run: UUID, checkpoint: String, demonstratedControlArrow: Direction
    }
    let c: Calibration = try readJSON(dir, checkpoint + ".ready")
    try require(
      c.run == run && c.checkpoint == checkpoint,
      "missing session-specific demonstrated system shortcut")
    return c.demonstratedControlArrow
  }

  func navigate(
    from origin: Position, source: String, to target: Position, label: String,
    direction: Direction, checkpoint: String
  ) throws {
    let (s, _) = try screen()
    guard let held = elements[source], let sourceWindow = windows[source],
      let targetWindow = windows[label],
      origin.frontPID == birth.pid, target.frontPID == birth.pid,
      origin.recordOrder == target.recordOrder,
      let i = origin.recordOrder.firstIndex(of: origin.record),
      let j = origin.recordOrder.firstIndex(of: target.record),
      j == i + (direction == .right ? 1 : -1)
    else { throw Refusal("unbound or nonadjacent calibrated route") }
    let op = UUID()
    struct Attempt: Codable {
      let run, operation: UUID, beforeRevision: UInt64, source, target: Position,
        direction: Direction
    }
    try writeJSON(
      Attempt(
        run: run, operation: op, beforeRevision: revision, source: origin, target: target,
        direction: direction), dir, checkpoint + "-intent.json")
    try scope()
    let (pid, currentFocus) = try focusedWindow()
    let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    try require(
      pid == birth.pid && CFEqual(held, currentFocus) && sourceWindow.isKeyWindow
        && sourceWindow.isOnActiveSpace
        && !targetWindow.isOnActiveSpace && s.frame.contains(NSEvent.mouseLocation)
        && CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
        && CGPreflightPostEventAccess(), "focus, pointer, modifier or input permission changed")
    let key: CGKeyCode = direction == .right ? 124 : 123
    guard let input = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: input, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: input, virtualKey: key, keyDown: false)
    else { throw Refusal("unable to produce system shortcut") }
    down.flags = .maskControl
    up.flags = .maskControl
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    try writeJSON(
      ["operation": op.uuidString, "postedUptime": String(ProcessInfo.processInfo.systemUptime)],
      dir, checkpoint + "-posted.json")
    let end = ProcessInfo.processInfo.systemUptime + 4
    repeat {
      let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
      try require(
        foreground == birth.pid || foreground == initialFocus?.0, "focus escaped during transition")
      if targetWindow.isOnActiveSpace && !sourceWindow.isOnActiveSpace && targetWindow.isKeyWindow {
        break
      }
      pump()
    } while ProcessInfo.processInfo.systemUptime < end
    _ = try stable(label, checkpoint)
    try writeJSON(
      ["operation": op.uuidString, "afterRevision": String(revision)], dir,
      checkpoint + "-confirmed.json")
  }
  func runTrial() throws {
    announce("RUN " + dir.path)
    try scope()  // Gate before NSApplication initialization and before window creation.
    let app = NSApplication.shared
    try require(
      app.setActivationPolicy(.accessory) && AXIsProcessTrusted(),
      "test GUI Accessibility unavailable")
    let original = try focusedWindow()
    initialFocus = original
    try writeJSON(["frontPID": original.0], dir, "initial-focus.json")
    gui = app
    app.finishLaunching()
    try create("A")
    try awaitCheckpoint("enroll-A")
    try require(clicked.contains("A"), "no GUI click witnessed on enrolled A")
    baseline["A"] = try stable("A", "origin-A")
    try awaitCheckpoint("enroll-B")
    try require(
      windows["A"]?.isOnActiveSpace == false, "A still active; B not independently arranged")
    try create("B")
    try awaitCheckpoint("observe-B")
    try require(clicked.contains("B"), "no GUI click witnessed on enrolled B")
    let b = try stable("B", "origin-B")
    guard let a = baseline["A"], a.scope == b.scope, a.record != b.record, a.topology == b.topology,
      a.build == b.build
    else { throw Refusal("distinct A/B not witnessed") }
    baseline["B"] = b
    try awaitCheckpoint("return-A")
    _ = try stable("A", "initial-A")
    let forward = try demonstrated("enroll-B")
    let back = try demonstrated("return-A")
    try require(forward != back, "no distinct demonstrated return shortcut")
    for round in 1...3 {
      for label in ["B", "A"] {
        let name = "round-\(round)-" + label
        let source = label == "A" ? "B" : "A"
        let origin = try stable(source, "before-" + name)
        guard let target = baseline[label] else { throw Refusal("missing target baseline") }
        try navigate(
          from: origin, source: source, to: target, label: label,
          direction: label == "B" ? forward : back, checkpoint: name)
      }
    }
  }
  func restoredFocus() throws {
    guard let initialFocus else { throw Refusal("initial focus missing") }
    let (pid, el) = try focusedWindow()
    try require(pid == initialFocus.0 && CFEqual(el, initialFocus.1), "original focus not restored")
  }
  func checkFinalScopes() throws {
    guard let a = baseline["A"] else { throw Refusal("missing original endpoint") }
    revision += 1
    let request = DesktopReadRequest(
      session: run, revision: revision, parentPID: getpid(),
      fixtureWindows: [], anchors: [], experimentalSpaces: true)
    let url = dir.appendingPathComponent("after-cleanup.json")
    try helper(
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
      ["--read-encoded", try JSONEncoder().encode(request).base64EncodedString()], output: url)
    let s = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: url))
    try require(
      s.isStructurallyValid
        && s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        && s.native?.population == .markedFixture && s.native?.spaces == .observed
        && s.sessionID == run && s.revision == revision && s.topologyFingerprint == a.topology
        && s.sourceBuild == a.build
        && s.separateSpaces == true && s.windows.isEmpty && s.scopes.count == 2
        && Set(s.scopes.map(\.displayID)) == Set(a.currents.keys)
        && s.scopes.allSatisfy { scope in
          let active = scope.records.filter(\.isCurrent)
          return active.count == 1 && active[0].id == a.currents[scope.displayID]
        }, "original display scopes not restored after cleanup")
  }
  func closeOwned() throws {
    let ids = windows.values.map { UInt32($0.windowNumber) }
    for w in windows.values {
      w.orderOut(nil)
      w.close()
    }
    let end = ProcessInfo.processInfo.systemUptime + 2
    repeat {
      if ids.allSatisfy({ id in
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        else { return false }
        return !rows.contains { $0[kCGWindowOwnerPID as String] as? Int32 == birth.pid }
      }) {
        try writeJSON(["remaining": 0, "enrolled": ids.count], dir, "cleanup.json")
        return
      }
      pump()
    } while ProcessInfo.processInfo.systemUptime < end
    throw Refusal("fixture cleanup unconfirmed")
  }
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  try require(
    args == ["--check"] || args == ["--three-rounds"], "expected --check or --three-rounds")
  let trial = try Trial()
  if args == ["--check"] {
    trial.announce("RUN " + trial.dir.path)
    try trial.scope()
    trial.announce("ISOLATED_GUI_CANDIDATE")
    exit(0)
  }
  do { try trial.runTrial() } catch {
    try writeJSON(["reason": String(describing: error)], trial.dir, "stopped.json")
    try trial.closeOwned()
    throw error
  }
  try trial.closeOwned()
  try trial.scope()
  try trial.checkFinalScopes()
  try trial.restoredFocus()
  try writeJSON(["observedRoundTrips": 3], trial.dir, "completed.json")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
