import AppKit
import NearpaneCore
import WindowLab

// Bounded comparison only. No Space API, frame setter, focus restoration or other-app input.
@MainActor final class RegularStudy {
  struct Seen: Codable {
    let owner: RegularWindow, axMini: Bool?, settable: Bool?, axFrame: SurfaceRect?,
      cgFrame: SurfaceRect?, onScreen: Bool?
    let axUnique: Bool
    func matches(_ original: RegularWindow, minimized: Bool) -> Bool {
      guard owner.token == original.token, owner.number == original.number, axUnique,
        owner.mini == minimized, axMini == minimized, onScreen == !minimized
      else { return false }
      return minimized
        || (owner.frame == original.frame && axFrame == original.frame && cgFrame == original.frame)
    }
  }
  let dir: URL, run: RegularEnrollment, focused: AXUIElement, file: FileHandle
  var app: NSRunningApplication?, birth: ProcessBirth?, seq = 0, original = [RegularWindow]()
  var phase = "prelaunch", finished = false
  var now: Double { ProcessInfo.processInfo.systemUptime }
  init(_ dir: URL) throws {
    let fm = FileManager.default
    let attrs = try fm.attributesOfItem(atPath: dir.path)
    try require(
      dir.standardizedFileURL.path == dir.resolvingSymlinksInPath().standardizedFileURL.path
        && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700
        && (try fm.contentsOfDirectory(atPath: dir.path)).isEmpty,
      "requires a new private session directory")
    try require(AXIsProcessTrusted(), "controller Accessibility unavailable (no prompt)")
    self.dir = dir
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let w = labAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
      CFGetTypeID(w) == AXUIElementGetTypeID()
    else { throw Refusal("foreground AX window unavailable; no launch") }
    focused = w as! AXUIElement
    run = .init(
      session: UUID(), controller: try .read(getpid()), screens: try Screens.read().0,
      deadline: ProcessInfo.processInfo.systemUptime + 100, front: pid)
    try Data().write(to: dir.appendingPathComponent("timeline.jsonl"), options: .withoutOverwriting)
    file = try FileHandle(forWritingTo: dir.appendingPathComponent("timeline.jsonl"))
    try writeJSON(run, dir, "enrollment.json")
  }
  func log(_ fields: [String: Any]) throws {
    var row = fields
    row["uptime"] = now
    row["phase"] = phase
    try file.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
  }
  func guardScope() throws {
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let w =
      pid == run.front
      ? labAttribute(AXUIElementCreateApplication(run.front), kAXFocusedWindowAttribute) : nil
    let same = w.map { CFEqual(focused, $0) } ?? false
    try log(["frontPID": pid ?? -1, "sameAXFocused": same])
    try require(
      same && now < run.deadline && AXIsProcessTrusted() && (try Screens.read().0) == run.screens,
      "focus, permission or display changed")
    if let birth { try verifySiblingCode(birth, name: "NearpaneRegularFixture") }
  }
  func spin() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04)) }
  func heartbeat() throws -> RegularHeartbeat {
    let b: RegularHeartbeat = try readJSON(dir, "heartbeat.json")
    try require(
      b.owner == birth && b.session == run.session && now - b.stamp < 0.5 && now >= b.stamp
        && b.regular
        && !b.active && b.focusEvents == 0 && !b.windows.contains { $0.main || $0.key },
      "stale owner or focus violation")
    return b
  }
  func command(_ action: String, _ token: String = "") throws {
    try guardScope()
    _ = try secondaryDock(run.screens)
    seq += 1
    try writeJSON(RegularCommand(run.session, seq, action, token), dir, "command.json")
    try log(["ownerCommand": action, "seq": seq])
  }
  func element(_ w: RegularWindow) -> AXUIElement? {
    guard let birth, w.token.hasPrefix(run.session.uuidString + "/") else { return nil }
    let ax = AXUIElementCreateApplication(birth.pid)
    AXUIElementSetMessagingTimeout(ax, 0.25)
    let matches = (labAttribute(ax, kAXWindowsAttribute) as? [AXUIElement])?.filter {
      labAttribute($0, kAXIdentifierAttribute) as? String == w.token
        && labAttribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }
    guard matches?.count == 1, let el = matches?.first else { return nil }
    var pid: Int32 = 0
    return AXUIElementGetPid(el, &pid) == .success && pid == birth.pid ? el : nil
  }
  func read(_ w: RegularWindow) throws -> Seen {
    let e = element(w)
    var flag = DarwinBoolean(false)
    var axFrame: SurfaceRect?
    var cgFrame: SurfaceRect?
    var shown: Bool?
    let writable = e.flatMap {
      AXUIElementIsAttributeSettable($0, kAXMinimizedAttribute as CFString, &flag) == .success
        ? flag.boolValue : nil
    }
    if let e, let p = labAttribute(e, kAXPositionAttribute),
      let s = labAttribute(e, kAXSizeAttribute),
      CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    {
      var pt = CGPoint.zero
      var sz = CGSize.zero
      if AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz)
      {
        axFrame = SurfaceRect(rect(CGRect(origin: pt, size: sz)))
      }
    }
    if let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, w.number) as? [[String: Any]] {
      if rows.isEmpty {
        shown = false
      } else if rows.count == 1, let row = rows.first,
        row[kCGWindowOwnerPID as String] as? Int32 == birth?.pid,
        row[kCGWindowNumber as String] as? UInt32 == w.number,
        row[kCGWindowLayer as String] as? Int == 0
      {
        shown = row[kCGWindowIsOnscreen as String] as? Bool ?? false
        if let d = row[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: d)
        {
          cgFrame = SurfaceRect(rect(r))
        }
      }
    }
    return .init(
      owner: w, axMini: e.flatMap { labAttribute($0, kAXMinimizedAttribute) as? Bool },
      settable: writable, axFrame: axFrame, cgFrame: cgFrame, onScreen: shown, axUnique: e != nil)
  }
  func settle(_ wanted: Bool) throws -> [Seen] {
    let until = now + 3
    var count = 0
    var lastStamp = 0.0
    repeat {
      try guardScope()
      let b = try heartbeat()
      let rows = try b.windows.map(read)
      try log([
        "rows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
        "ownerStamp": b.stamp, "seq": b.sequence,
      ])
      guard rows.count == original.count else { throw Refusal("owner inventory changed") }
      let siblingsStable = rows.indices.dropFirst().allSatisfy {
        rows[$0].matches(original[$0], minimized: false)
      }
      // Newly ordered regular windows can still be animating in WindowServer.
      // Establish the initial baseline before requiring uninterrupted sibling invariance.
      if phase != "baseline" && !siblingsStable {
        // A veto is irreversible for this trial. Keep observing without issuing
        // a recovery setter to explain whether the CG change was transient.
        try observeAfterVeto()
        throw Refusal("sibling changed or became unobservable")
      }
      if siblingsStable && b.sequence == seq && rows[0].matches(original[0], minimized: wanted) {
        if b.stamp > lastStamp { count += 1 }
        if count >= 3 { return rows }
      } else {
        count = 0
      }
      lastStamp = b.stamp
      spin()
    } while now < until
    throw Refusal("no stable owner/AX/CG agreement: " + phase)
  }
  private func observeAfterVeto() throws {
    phase += "-veto-readonly"
    let end = now + 2
    repeat {
      try guardScope()
      let b = try heartbeat()
      let rows = try b.windows.map(read)
      try log([
        "rows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
        "ownerStamp": b.stamp, "seq": b.sequence,
      ])
      spin()
    } while now < end
  }
  func trial() throws {
    let name = "NearpaneRegularFixture"
    let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
      name + ".app")
    try guardScope()
    try writeJSON(try secondaryDock(run.screens), dir, "dock-before.json")
    try require(
      NSRunningApplication.runningApplications(withBundleIdentifier: "org.nearpane.lab." + name)
        .isEmpty, "fixture already running")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    config.createsNewApplicationInstance = true
    config.arguments = ["--regular-study", dir.path]
    NSWorkspace.shared.openApplication(at: url, configuration: config) { instance, _ in
      Task { @MainActor in
        self.app = instance
        self.finished = true
      }
    }
    let limit = now + 8
    while !finished && now < limit {
      spin()
      try guardScope()
    }
    guard let app,
      app.bundleURL?.standardizedFileURL == url.standardizedFileURL
        || app.bundleURL?.path == url.path
    else { throw Refusal("no exact passive launch receipt") }
    birth = try .read(app.processIdentifier)
    try guardScope()
    try writeJSON(birth, dir, "process.json")
    for n in 1...2 {
      try command("enroll")
      let limit = now + 4
      while now < limit {
        spin()
        try guardScope()
        if (try? heartbeat().sequence) == seq { break }
      }
      original = try heartbeat().windows
      try require(
        original.count == n && Set(original.map(\.token)).count == n
          && Set(original.map(\.number)).count == n
          && original.allSatisfy {
            $0.buttonEnabled && $0.number > 0
              && run.screens.usable.geometry.intersection($0.frame.geometry) == $0.frame.geometry
          }, "invalid ordinary window enrollment")
    }
    try writeJSON(original, dir, "original.json")
    phase = "baseline"
    _ = try settle(false)
    for op in ["self-mini", "self-restore", "ax-mini", "ax-restore"] {
      phase = op
      let next = op.hasSuffix("mini")
      let before = try settle(!next)
      _ = try secondaryDock(run.screens)
      if op.hasPrefix("self") {
        try command(next ? "mini" : "restore", original[0].token)
      } else {
        guard before[0].settable == true, let w = element(original[0]) else {
          throw Refusal("AXMinimized not writable")
        }
        try guardScope()
        let result = AXUIElementSetAttributeValue(
          w, kAXMinimizedAttribute as CFString, next ? kCFBooleanTrue : kCFBooleanFalse)
        try log(["axReturn": result.rawValue, "target": original[0].token, "requestedMini": next])
        try require(result == .success, "AXMinimized setter rejected")
      }
      _ = try settle(next)
      try writeJSON(["phase": op, "result": "stable"], dir, op + ".json")
    }
  }
  func close() throws {
    try Data().write(to: dir.appendingPathComponent("stop"))
    let limit = now + 4
    while now < limit && app?.isTerminated == false { spin() }
    try require(app == nil || app?.isTerminated == true, "fixture exit not verified")
    for w in original {
      guard
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, w.number) as? [[String: Any]]
      else { throw Refusal("cleanup unknown") }
      try require(
        !rows.contains { $0[kCGWindowOwnerPID as String] as? Int32 == birth?.pid },
        "fixture CG window survived exit")
    }
    try log([
      "cleanup": app == nil
        ? "no launch receipt; stop marker installed" : "owner exited / enrolled windows absent",
      "enrolled": original.count,
    ])
  }
}
