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
  var retiredRehearsal: (number: UInt32, element: AXUIElement)?
  var initialFocus: (Int32, AXUIElement)?
  var focusLoan: ConsoleFocusLoan?
  struct SessionIdentity: Decodable, Equatable {
    let uid, consoleUID, securityID: UInt32
    let boot: String, displays: [String]
  }
  private var admitted: SessionIdentity?
  var consoleBoot: String? { admitted?.boot }
  var authorizedUntil: Double { min(deadline, consentExpiresUptime ?? deadline) }
  var originDisplay: String?
  let deadline = ProcessInfo.processInfo.systemUptime + 600
  let consoleTrial: Bool
  let fullscreenOnly, observeTools: Bool
  var toolObservationResult: String?
  private var originScopes: TrialDisplayState?
  private var cleanupAttempted = false
  private var cleanupVerified = false
  private var focusVerified = false
  private var scopesVerified = false
  private var pendingInput: UUID?
  private var postedInputs = 0
  private var confirmedInputs = 0
  private var consoleConsent: ConsoleSpaceConsent?
  private var consentExpiresUptime: Double?
  var enrolledRead: String { consoleTrial ? "--read-enrolled-console" : "--read-encoded" }

  init(consoleTrial: Bool, fullscreenOnly: Bool = false, observeTools: Bool = false) throws {
    self.consoleTrial = consoleTrial
    self.fullscreenOnly = fullscreenOnly
    self.observeTools = observeTools
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
  func scope(cleanupRead: Bool = false) throws {
    try require(cleanupRead || ProcessInfo.processInfo.systemUptime < deadline, "trial expired")
    let url = dir.appendingPathComponent("scope-" + UUID().uuidString + ".json")
    try helper(
      kit.appendingPathComponent("SessionProbe"),
      [consoleTrial ? "check-console" : "check", kit.appendingPathComponent("protected.json").path], output: url)
    struct Check: Decodable { let caller: SessionIdentity, verdict: String }
    let check = try JSONDecoder().decode(Check.self, from: Data(contentsOf: url))
    try require(
      check.verdict == (consoleTrial ? "CONSOLE_SCOPE_ONLY" : "ISOLATED_GUI_CANDIDATE") && (admitted == nil || admitted == check.caller),
      "session binding changed")
    admitted = check.caller
    if !cleanupRead { try checkConsentExpiry() }
  }
  func checkConsentExpiry() throws {
    try focusLoan?.verifyOriginal()
    if let consent = consoleConsent {
      guard let caller = admitted, let end = consentExpiresUptime, ProcessInfo.processInfo.systemUptime < end,
            let display = originDisplay,
            consent.allows(run: run, boot: caller.boot, securityID: caller.securityID, display: display, at: Date(), fullscreenOnly: fullscreenOnly, observeTools: observeTools)
      else { throw Refusal("console authorization expired or no longer matches") }
    }
  }
  func requireFullscreenTime(_ seconds: TimeInterval) throws {
    try scope()
    guard fullscreenOnly, consoleConsent?.permitsSingleWindowFullscreen == true,
          let end = consentExpiresUptime, min(end, deadline) - ProcessInfo.processInfo.systemUptime > seconds
    else { throw Refusal("insufficient authorized time for fullscreen and return") }
  }
  func toolObservationCutoff() throws -> Double {
    try checkConsentExpiry()
    guard observeTools, consoleConsent?.permitsFullscreenToolObservation == true,
          let end = consentExpiresUptime else { throw Refusal("missing timed fullscreen tool grant") }
    // Reserve enough time for two independent reads, the AppKit return and cleanup.
    let now = ProcessInfo.processInfo.systemUptime
    return min(now + 90, min(end, deadline) - 35)
  }
  private var gui: NSApplication?
  private var clicked = Set<String>()
  private var enrolledByAppKit = Set<String>()
  func pump() {
    if let gui {
      while let event = gui.nextEvent(
        matching: .any, until: .distantPast, inMode: .default, dequeue: true)
      {
        if event.type == .leftMouseDown, let target = event.window,
          let label = windows.first(where: { $0.value === target })?.key
        {
          if clicked.insert(label).inserted {
            // This receipt is only for the two retained test windows.
            try? writeJSON(["run": run.uuidString, "label": label, "window": String(target.windowNumber)],
                           dir, "click-" + label + ".json")
          }
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
  // Scope-only snapshot. No AX tree or WindowServer descriptions are requested.
  func consoleScopes() throws -> DesktopSnapshot {
    try consoleScopeObservation().0
  }
  func consoleScopeObservation() throws -> (DesktopSnapshot, OrdinaryConsoleScope) {
    revision += 1
    let request = DesktopReadRequest(session: run, revision: revision, parentPID: getpid(),
                                    fixtureWindows: [], anchors: [], experimentalSpaces: true)
    let file = dir.appendingPathComponent("scope-snapshot-\(revision).json")
    try helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
               [enrolledRead, try JSONEncoder().encode(request).base64EncodedString()], output: file)
    let bytes = try Data(contentsOf: file), decoder = JSONDecoder()
    let s = try decoder.decode(DesktopSnapshot.self, from: bytes)
    guard s.isStructurallyValid, s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
          s.sessionID == run, s.revision == revision, s.windows.isEmpty, s.native?.population == .markedFixture,
          s.native?.spaces == .observed, s.scopes.count == 2,
          s.scopes.allSatisfy({ $0.records.filter(\.isCurrent).count == 1 })
    else { throw Refusal("scope-only observation unavailable") }
    try require(s.separateSpaces == true, "shared Spaces: independent secondary A/B cannot be attested")
    guard let types = try? decoder.decode(OrdinaryConsoleScope.self, from: bytes) else {
      throw Refusal("frozen Reader did not attest ordinary record types for this sample")
    }
    return (s, types)
  }
  func consoleEndpoint(_ label: String, display: String) throws -> DesktopSnapshot {
    let (s, types) = try consoleScopeObservation()
    guard let scope = s.scopes.first(where: { $0.displayID == display }),
          let current = scope.records.first(where: \.isCurrent)?.id else { throw Refusal("unknown test display") }
    try require(["A", "B", "focus-rehearsal"].contains(label), "unknown endpoint")
    let onSource = label != "B"
    let other = fullscreenOnly ? nil : consoleConsent.map { onSource ? $0.target : $0.source }
    try require(types.admits(scope, current: current, fullscreenOnly: fullscreenOnly, other: other),
                fullscreenOnly ? "current secondary record is not an observed ordinary desktop"
                               : "adjacent ordinary secondary records not observed in the complete system order")
    if let consent = consoleConsent {
      let required = onSource ? consent.source : consent.target
      try require(scope.records.first(where: \.isCurrent)?.id == required, "console is not at the specified test desktop")
      if let originScopes {
        try require(try originScopes.permits(TrialDisplayState(s), secondary: display, endpoint: required),
                    "display topology, record order or protected current changed during calibration")
      }
    }
    return s
  }

  func awaitConsoleConsent() throws {
    guard let session = admitted else { throw Refusal("missing console identity") }
    let (_, display) = try screen()
    originScopes = try TrialDisplayState(consoleEndpoint("A", display: display))
    try writeJSON(["run": run.uuidString, "boot": session.boot, "securityID": String(session.securityID),
                   "secondaryDisplay": display, "focusLoanProtocol": "1", "procedure": observeTools ? "fullscreen-tools" : fullscreenOnly ? "fullscreen" : "route"], dir, "console-scope.json")
    try awaitCheckpoint("unattended-consent")
    let file = dir.appendingPathComponent("unattended-consent.ready")
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Refusal("cannot open console authorization") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
          info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size <= 4096
    else { throw Refusal("unsafe console authorization file") }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let consent = try decoder.decode(ConsoleSpaceConsent.self, from: try handle.read(upToCount: 4097) ?? Data())
    let now = Date()
    guard consent.allows(run: run, boot: session.boot, securityID: session.securityID, display: display, at: now, fullscreenOnly: fullscreenOnly, observeTools: observeTools)
    else { throw Refusal("missing current consent for these two test desktops") }
    consoleConsent = consent
    consentExpiresUptime = ProcessInfo.processInfo.systemUptime + consent.ends.timeIntervalSince(now)
    _ = try consoleEndpoint("A", display: display)
  }

  func create(_ label: String) throws {
    try scope()
    let (s, display) = try screen()
    if consoleTrial { _ = try consoleEndpoint(label, display: display) }
    let visible = s.visibleFrame
    let r = CGRect(x: visible.midX - 140, y: visible.midY - 90, width: 280, height: 180).integral
    try require(visible.contains(r) && windows[label] == nil, "invalid enrollment")
    let w = NSWindow(
      contentRect: .init(origin: .zero, size: r.size), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: true, screen: s)
    w.isRestorable = false
    if fullscreenOnly { w.collectionBehavior.insert(.fullScreenPrimary) }
    w.isReleasedWhenClosed = false
    w.ignoresMouseEvents = false
    w.title = "Nearpane test " + label
    w.setAccessibilityIdentifier(run.uuidString + "/" + label)
    w.contentView = NSTextField(labelWithString: "P4.3 " + label + " " + run.uuidString)
    w.setFrame(r, display: false)
    try require(w.frame == r && s.visibleFrame.contains(w.frame), "unsafe fixture frame")
    if label != "B", let focusLoan {
      try checkConsentExpiry()
      try focusLoan.requireFocused(focusedWindow())
      try checkConsentExpiry()
    }
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
    if let retiredRehearsal, label != "focus-rehearsal" {
      try require(!CFEqual(retiredRehearsal.element, w) && windows[label]?.windowNumber != Int(retiredRehearsal.number),
                  "new fixture reused a retired rehearsal identity")
    }
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
  // AX window frames use global Quartz points. Only the display classification leaves this check.
  func focusRegion(_ element: AXUIElement, secondary: NSScreen) -> String {
    guard let display = secondary.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
          let frame = ConsoleFocusLoan.frame(element) else { return "unknown" }
    if CGDisplayBounds(display.uint32Value).contains(frame) { return "secondary" }
    if CGDisplayBounds(CGMainDisplayID()).contains(frame) { return "protected-main" }
    return "unknown"
  }

  func sample(_ label: String, beforeAcquiringFocus: Bool = false) throws -> Position {
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
    if !beforeAcquiringFocus, let expected = focus[label] {
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
      [enrolledRead, try JSONEncoder().encode(req).base64EncodedString()], output: url)
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
      obs.metadata?.presentation == .confirmed, obs.membership == .known(recordIDs: [row.recordID]), obs.metadata?.globalFrame == frame
    else { throw Refusal("no independent Space/window witness") }
    if let consent = consoleConsent {
      guard let originScopes, row.recordID == (label == "B" ? consent.target : consent.source),
            try originScopes.permits(TrialDisplayState(s), secondary: display, endpoint: row.recordID)
      else { throw Refusal("test endpoint or protected display departed the authorized baseline") }
    }
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
    if !beforeAcquiringFocus {
      try require(w.isKeyWindow && elements[label].map { CFEqual($0, el) } == true, "actual focus is not the enrolled endpoint window")
      focus[label] = el
    }
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
    try checkConsentExpiry()
    let url = dir.appendingPathComponent(name + ".ready")
    try require(
      !FileManager.default.fileExists(atPath: url.path), "checkpoint arrived before request")
    try writeJSON(
      ["checkpoint": name, "run": run.uuidString, "afterRevision": String(revision)], dir,
      "request-" + name + ".json")
    announce("WAIT " + name)
    var checkedToken: UUID?
    while !FileManager.default.fileExists(atPath: url.path) {
      let probe = dir.appendingPathComponent(name + ".observe")
      if consoleTrial, consoleConsent != nil, checkedToken == nil, FileManager.default.fileExists(atPath: probe.path) {
        struct Request: Decodable { let run, token: UUID; let checkpoint: String }
        let probe: Request = try readJSON(dir, name + ".observe")
        try require(probe.run == run && probe.checkpoint == name, "wrong observation request")
        guard let display = originDisplay else { throw Refusal("missing secondary display") }
        let destination = (name == "observe-B" || name == "enroll-B") ? "B" : "A"
        try scope()
        if name == "enroll-B" {
          try require(windows["A"]?.isOnActiveSpace == false, "source window still on active Space")
        } else {
          try require(clicked.contains(destination) || enrolledByAppKit.contains(destination), "endpoint foreground not witnessed")
          _ = try stable(destination, "observed-" + name)
        }
        let first = try TrialDisplayState(consoleEndpoint(destination, display: display))
        let until = ProcessInfo.processInfo.systemUptime + 0.25
        while ProcessInfo.processInfo.systemUptime < until { pump() }
        let latest = try TrialDisplayState(consoleEndpoint(destination, display: display))
        try require(first == latest, "calibration observation was unstable")
        try writeJSON(["run": run.uuidString, "checkpoint": name, "token": probe.token.uuidString,
                       "endpoint": latest.currents[display], "revision": String(revision)],
                      dir, "attested-" + name + ".json")
        checkedToken = probe.token
      }
      try require(ProcessInfo.processInfo.systemUptime < deadline, "checkpoint timeout")
      try checkConsentExpiry()
      pump()
    }
    if consoleTrial && consoleConsent != nil {
      struct Release: Decodable { let run, token: UUID; let checkpoint: String }
      let release: Release = try readJSON(dir, name + ".ready")
      try require(release.run == run && release.token == checkedToken && release.checkpoint == name,
                  "missing witnessed calibration release")
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

  private func checkControlArrows(_ filename: String) throws {
    let url = dir.appendingPathComponent(filename)
    try helper(kit.appendingPathComponent("SessionProbe"), ["control-arrows"], output: url)
    struct Registrations: Decodable { let left, right: Bool }
    let keys = try JSONDecoder().decode(Registrations.self, from: Data(contentsOf: url))
    try require(keys.left && keys.right, "forward or return chord is not registered")
  }

  private func requestCalibration(_ name: String, from source: String) throws {
    if consoleTrial {
      try checkControlArrows(name + "-available-shortcuts.json")
      let (screen, display) = try screen()
      _ = try consoleEndpoint(source, display: display)
      let (pid, el) = try focusedWindow()
      try require(pid == birth.pid && windows[source]?.isKeyWindow == true
                  && elements[source].map { CFEqual($0, el) } == true
                  && screen.frame.contains(NSEvent.mouseLocation),
                  "calibration requires the focused secondary fixture and pointer")
    }
    try awaitCheckpoint(name)
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
    guard let display = originDisplay,
          UInt32(sourceWindow.windowNumber) == origin.number,
          UInt32(targetWindow.windowNumber) == target.number else { throw Refusal("window generation changed") }
    let proof = dir.appendingPathComponent(checkpoint + "-route.json")
    try helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
               ["--enrolled-route", display, String(origin.number), String(target.number)], output: proof)
    let evidence = try JSONDecoder().decode(NativeRouteEvidence.self, from: Data(contentsOf: proof))
    try require(evidence.validates(display: display, source: origin.record, sourceWindow: origin.number,
                                   target: target.record, targetWindow: target.number,
                                   sourceCurrents: origin.currents, targetCurrents: target.currents,
                                   frozenOrder: origin.recordOrder, frozenTopology: origin.topology, right: direction == .right,
                                   isolatedDisplays: !consoleTrial),
                "inactive target, other display, or calibrated order changed")
    try checkControlArrows(checkpoint + "-shortcuts.json")
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
    try checkConsentExpiry()
    pendingInput = op
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    postedInputs += 1
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
    confirmedInputs += 1
    pendingInput = nil
  }
  /// The explicit temporary-focus grant permits activating this retained fixture on its own desktop.
  /// The read-only snapshot before the activation is never used as proof of the resulting focus.
  func enroll(_ label: String, checkpoint: String) throws -> Position {
    guard consoleConsent?.permitsTemporarySecondaryFocus == true else {
      try awaitCheckpoint(checkpoint)
      try require(clicked.contains(label), "no GUI click witnessed on the enrolled endpoint")
      return try stable(label, "origin-" + label)
    }
    guard let window = windows[label], let display = originDisplay else { throw Refusal("missing own window") }
    let before = try sample(label, beforeAcquiringFocus: true)
    let independently = try sample(label, beforeAcquiringFocus: true)
    try require(before == independently, "fixture membership, identity, focus or geometry changed before activation")
    _ = try consoleEndpoint(label, display: display)
    try ownedAX(label)
    let (secondary, _) = try screen()
    try require(window.screen == secondary && window.isOnActiveSpace && secondary.frame.contains(window.frame)
                && UInt32(exactly: window.windowNumber) == before.number && windows[label] === window,
                "enrollment window has left the authorized desktop")
    let (front, _) = try focusedWindow()
    try require(front == before.frontPID, "foreground changed before fixture enrollment")
    try checkConsentExpiry()
    if !window.isKeyWindow || front != birth.pid {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
    let until = ProcessInfo.processInfo.systemUptime + 2
    while !window.isKeyWindow || NSWorkspace.shared.frontmostApplication?.processIdentifier != birth.pid {
      let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
      try checkConsentExpiry()
      try require((pid == before.frontPID || pid == birth.pid) && ProcessInfo.processInfo.systemUptime < until,
                  "could not enroll the fixture as foreground")
      pump()
    }
    let here = try stable(label, "origin-" + label)
    try require(here.record == before.record && here.scope == before.scope && here.currents == before.currents &&
                here.number == before.number && here.frame == before.frame && here.recordOrder == before.recordOrder &&
                here.topology == before.topology && here.build == before.build, "desktop changed during fixture enrollment")
    try writeJSON(["run": run.uuidString, "window": String(here.number), "label": label, "method": "appkit-key-window",
                   "frontPID": String(here.frontPID), "revision": String(revision)], dir, "enrolled-" + label + ".json")
    enrolledByAppKit.insert(label)
    return here
  }
  func runTrial() throws {
    announce("RUN " + dir.path)
    try scope()  // Gate before NSApplication initialization and before window creation.
    if consoleTrial { try awaitConsoleConsent() }
    let app = NSApplication.shared
    let initialPolicy = app.activationPolicy()
    let setResult = initialPolicy == .accessory ? nil : app.setActivationPolicy(.accessory)
    let effectivePolicy = app.activationPolicy()
    let accessibilityTrusted = AXIsProcessTrusted()
    struct GUIAdmission: Encodable {
      let initialPolicy: Int, effectivePolicy: Int, setRequested: Bool, setResult: Bool?
      let accessibilityTrusted: Bool
    }
    try writeJSON(GUIAdmission(initialPolicy: initialPolicy.rawValue, effectivePolicy: effectivePolicy.rawValue,
                               setRequested: setResult != nil, setResult: setResult, accessibilityTrusted: accessibilityTrusted),
                  dir, "gui-admission.json")
    try require(effectivePolicy == .accessory, "test GUI did not acquire accessory activation policy")
    try require(accessibilityTrusted, "frozen witness lacks Accessibility for test GUI")
    let original = try focusedWindow()
    if consoleTrial {
      let (secondary, _) = try screen()
      let region = focusRegion(original.1, secondary: secondary)
      guard let consent = consoleConsent, consent.acceptsFocusRegion(region) else {
        throw Refusal("protected or unlocated focus without an applicable owner grant")
      }
      if region == "protected-main" { focusLoan = try ConsoleFocusLoan(original) }
    }
    initialFocus = original
    if let focusLoan {
      try writeJSON(["frontPID": String(original.0), "processBirth": String(focusLoan.owner.start),
                     "focusToken": focusLoan.token.uuidString, "region": "protected-main", "mode": "temporary"],
                    dir, "initial-focus.json")
    } else {
      try writeJSON(["frontPID": original.0], dir, "initial-focus.json")
    }
    gui = app
    app.finishLaunching()
    if let focusLoan { try rehearsePassiveReturn(focusLoan) }
    try create("A")
    baseline["A"] = try enroll("A", checkpoint: "enroll-A")
    if fullscreenOnly {
      try fullscreenRoundTrip()
      return
    }
    try requestCalibration("enroll-B", from: "A")
    try require(
      windows["A"]?.isOnActiveSpace == false, "A still active; B not independently arranged")
    try create("B")
    let b = try enroll("B", checkpoint: "observe-B")
    guard let a = baseline["A"], a.scope == b.scope, a.record != b.record, a.topology == b.topology,
      a.build == b.build
    else { throw Refusal("distinct A/B not witnessed") }
    baseline["B"] = b
    try requestCalibration("return-A", from: "B")
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
    if let focusLoan { try observePassiveReturn(focusLoan) }
    let (pid, el) = try focusedWindow()
    try require(pid == initialFocus.0 && CFEqual(el, initialFocus.1), "original focus not restored")
    var receipt = ["run": run.uuidString, "frontPID": String(pid), "sameAXFocus": "true"]
    if let focusLoan {
      try focusLoan.requireFocused((pid, el))
      receipt["processBirth"] = String(focusLoan.owner.start)
      receipt["focusToken"] = focusLoan.token.uuidString
      receipt["originalFrameUnchanged"] = "true"
    }
    try writeJSON(receipt, dir, "restored-focus.json")
    focusVerified = true
  }
  func checkFinalScopes() throws {
    guard originScopes != nil || baseline["A"] != nil else { throw Refusal("missing original endpoint") }
    revision += 1
    let request = DesktopReadRequest(
      session: run, revision: revision, parentPID: getpid(),
      fixtureWindows: [], anchors: [], experimentalSpaces: true)
    let original = dir.appendingPathComponent("after-cleanup.json")
    let url = FileManager.default.fileExists(atPath: original.path)
      ? dir.appendingPathComponent("after-stop-" + String(revision) + ".json") : original
    try helper(
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
      [enrolledRead, try JSONEncoder().encode(request).base64EncodedString()], output: url)
    let s = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: url))
    try require(
      s.isStructurallyValid
        && s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        && s.native?.population == .markedFixture && s.native?.spaces == .observed
        && s.sessionID == run && s.revision == revision && s.windows.isEmpty,
      "final scope observation unavailable")
    let final = try TrialDisplayState(s)
    if let original = originScopes {
      try require(final == original, "original display scopes not restored after cleanup")
    } else if let a = baseline["A"] {
      try require(final.topology == a.topology && final.build == a.build && final.currents == a.currents,
                  "original display scopes not restored after cleanup")
    }
    scopesVerified = true
  }
  func closeOwned() throws {
    cleanupAttempted = true
    let ids = windows.values.map { UInt32($0.windowNumber) } + [retiredRehearsal?.number].compactMap { $0 }
    for w in windows.values {
      w.orderOut(nil)
      w.close()
    }
    if focusLoan != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == birth.pid {
      NSApp.hide(nil)
    }
    let end = ProcessInfo.processInfo.systemUptime + 2
    repeat {
      if ids.allSatisfy({ id in
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        else { return false }
        return !rows.contains { $0[kCGWindowOwnerPID as String] as? Int32 == birth.pid }
      }) {
        try writeJSON(["remaining": 0, "enrolled": ids.count], dir, "cleanup.json")
        cleanupVerified = true
        return
      }
      pump()
    } while ProcessInfo.processInfo.systemUptime < end
    throw Refusal("fixture cleanup unconfirmed")
  }
  // Never issue another shortcut on failure. Window cleanup, Space return and
  // AX focus return are independent facts; record them even when one fails.
  func recordStop(_ cause: Error) throws {
    var result = ["run": run.uuidString, "reason": String(describing: cause),
                  "postedInputs": String(postedInputs), "confirmedInputs": String(confirmedInputs),
                  "pendingInput": pendingInput?.uuidString ?? "none"]
    if fullscreenOnly {
      for action in ["enter", "exit"] {
        let prefix = dir.appendingPathComponent("fullscreen-" + action).path
        result["fullscreen-" + action] = FileManager.default.fileExists(atPath: prefix + "-confirmed.json") ? "confirmed" :
          (FileManager.default.fileExists(atPath: prefix + "-intent.json") ? "intent-unconfirmed" : "not-requested")
      }
    }
    if !cleanupAttempted {
      do { try closeOwned() } catch { result["cleanupError"] = String(describing: error) }
    }
    result["cleanup"] = cleanupVerified ? "verified" : "unverified"
    if initialFocus != nil {
      do {
        try scope(cleanupRead: true)
        if !scopesVerified {
          do { try checkFinalScopes() } catch { result["scopeError"] = String(describing: error) }
        }
        if !focusVerified {
          do { try restoredFocus() } catch { result["focusError"] = String(describing: error) }
        }
      } catch { result["observationError"] = String(describing: error) }
    }
    result["scopeReturn"] = scopesVerified ? "verified" : "unverified"
    result["focusReturn"] = focusVerified ? "verified" : "unverified"
    try writeJSON(result, dir, "stopped.json")
  }
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  try require(
    args.count == 1 && ["--check", "--three-rounds", "--check-console", "--three-rounds-console", "--check-fullscreen-console", "--fullscreen-console", "--check-fullscreen-tools-console", "--fullscreen-tools-console"].contains(args[0]), "unknown witness command")
  let trial = try Trial(consoleTrial: args[0].hasSuffix("-console"), fullscreenOnly: args[0].contains("fullscreen"),
                        observeTools: args[0].contains("fullscreen-tools"))
  if args[0].hasPrefix("--check") {
    trial.announce("RUN " + trial.dir.path)
    struct CheckReceipt: Encodable {
      let run: UUID, outcome: String, reason: String?
      let accessibilityTrusted: Bool, initialFocusAvailable: Bool?, initialFocusRegion: String?
      let returnAnchorAvailableForTimedLoan: Bool?
      let windowsCreated = 0, inputsPosted = 0
    }
    var initialFocusAvailable: Bool?, initialFocusRegion: String?, loanAnchorAvailable: Bool?
    func record(_ outcome: String, reason: String? = nil) throws {
      try writeJSON(CheckReceipt(run: trial.run, outcome: outcome, reason: reason, accessibilityTrusted: AXIsProcessTrusted(),
                                 initialFocusAvailable: initialFocusAvailable, initialFocusRegion: initialFocusRegion,
                                 returnAnchorAvailableForTimedLoan: loanAnchorAvailable), trial.dir, "preflight.json")
    }
    do {
      try trial.scope()
      if trial.consoleTrial {
        let (secondary, display) = try trial.screen()
        _ = try trial.consoleEndpoint("A", display: display)
        // Exercise the same read-only prerequisites as runTrial before reporting readiness.
        // No prompt, enrollment, app activation or focus change occurs in check mode.
        try require(AXIsProcessTrusted(), "frozen witness lacks Accessibility for the original focus check")
        initialFocusAvailable = false
        let original = try trial.focusedWindow()
        let element = original.1
        initialFocusAvailable = true
        let region = trial.focusRegion(element, secondary: secondary)
        initialFocusRegion = region
        if region == "protected-main" {
          loanAnchorAvailable = (try? ConsoleFocusLoan(original).requireFocused(trial.focusedWindow())) != nil
        }
        try require(region == "secondary", region == "protected-main"
                    ? "protected main: explicitly timed secondary focus loan and passive-return rehearsal required"
                    : "unable to bind original focus to a single display")
      }
      let result = trial.consoleTrial ? "CONSOLE_SCOPE_ONLY" : "ISOLATED_GUI_CANDIDATE"
      try record(result)
      trial.announce(result)
    } catch {
      try record("REFUSED", reason: String(describing: error))
      throw error
    }
    exit(0)
  }
  do {
    try trial.runTrial()
    try trial.closeOwned()
    try trial.scope(cleanupRead: true)
    try trial.checkFinalScopes()
    try trial.restoredFocus()
    if trial.fullscreenOnly {
      struct Complete: Encodable {
        let observedFullscreenRoundTrips = 1, observedRoundTrips = 0
        let toolObservationCheckpoint: String?
      }
      try writeJSON(Complete(toolObservationCheckpoint: trial.toolObservationResult), trial.dir, "completed.json")
    } else {
      try writeJSON(["observedRoundTrips": 3], trial.dir, "completed.json")
    }
  } catch {
    try trial.recordStop(error)
    throw error
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
