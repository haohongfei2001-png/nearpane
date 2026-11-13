// Hold the cursor over the frozen trial's own A window during calibration. No clicks or keys.
import AppKit
import ApplicationServices

struct Stop: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
func required(_ value: Bool, _ reason: String) throws { if !value { throw Stop(reason) } }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func pointer() throws -> CGPoint {
  guard let p = CGEvent(source: nil)?.location else { throw Stop("pointer unavailable") }
  return p
}
func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
  var raw: CFTypeRef?
  return AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success ? raw : nil
}
func heldButtons() -> Bool {
  NSEvent.pressedMouseButtons != 0
    || !CGEventSource.flagsState(.combinedSessionState).intersection([
      .maskControl, .maskAlternate, .maskShift, .maskCommand,
    ]).isEmpty
}
struct PointerDisplay: Equatable {
  let id: CGDirectDisplayID, uuid: String, bounds: CGRect
  init(_ id: CGDirectDisplayID) throws {
    guard let raw = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
      CGDisplayIsInMirrorSet(id) == 0
    else { throw Stop("ambiguous pointer display") }
    self.id = id
    uuid = CFUUIDCreateString(nil, raw) as String
    bounds = CGDisplayBounds(id)
  }
  init(point: CGPoint) throws {
    var ids = [CGDirectDisplayID](repeating: 0, count: 2)
    var count: UInt32 = 0
    try required(
      CGGetDisplaysWithPoint(point, 2, &ids, &count) == .success && count == 1,
      "pointer has no unique display")
    try self.init(ids[0])
  }
  func move(to global: CGPoint) throws {
    try required(
      try PointerDisplay(id) == self && bounds.contains(global), "pointer display changed")
    let local = CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
    try required(
      CGDisplayMoveCursorToPoint(id, local) == .success, "display-local cursor placement refused")
  }
}
func hardwareIdle(since start: Double) -> Bool {
  let age = now() - start
  let types: [CGEventType] = [
    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown,
    .rightMouseDown, .otherMouseDown, .scrollWheel,
  ]
  return types.allSatisfy {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= age
  }
}
func note(_ action: String, _ p: CGPoint) {
  print("\(action) x=\(p.x) y=\(p.y)")
  fflush(stdout)
}
func run() throws {
  let a = Array(CommandLine.arguments.dropFirst())
  let currentDisplay = a.count == 6 && a.last == "--current-display"
  guard a.count == 5 || currentDisplay, let pid = Int32(a[0]), let run = UUID(uuidString: a[1]),
    let end = ISO8601DateFormatter().date(from: a[4]),
    end.timeIntervalSinceNow > 10 && end.timeIntervalSinceNow <= 900
  else { throw Stop("invalid witness arguments or interval") }
  guard AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1 else { throw Stop("pointer observer AX or Space reader unavailable") }
  guard let app = FrozenWitnessOwner.enroll(pid,executable:URL(fileURLWithPath:a[2]),before:end) else {
    throw Stop("frozen witness kernel generation, executable or live signature unconfirmed")
  }
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Caches/Nearpane-P431-" + run.uuidString)
  let original = try pointer()
  let originalDisplay = try PointerDisplay(point: original)
  note("original", original)
  let start = now()
  func locate() throws -> (PointerDisplay, CGRect, UInt32)? {
    guard app.sameProcess, let c = try? Data(contentsOf: dir.appendingPathComponent("unattended-consent.ready")),
      let grant = try JSONSerialization.jsonObject(with: c) as? [String: Any],
      grant["run"] as? String == run.uuidString, grant["ends"] as? String == a[4],
      grant["secondaryDisplay"] as? String == a[3],
      grant["currentDisplayID"] as? String == (currentDisplay ? a[3] : nil),
      grant["permitsTemporarySecondaryFocus"] as? Bool == true,
      grant["permitsCalibrationAndThreeRoundTrips"] as? Bool == true,
      let ax = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
      CFGetTypeID(ax) == AXUIElementGetTypeID(),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else { return nil }
    let el = ax as! AXUIElement
    guard attribute(el, kAXIdentifierAttribute) as? String == run.uuidString + "/A" else {
      return nil
    }
    let n = NPReadAXWindowNumber(el)
    let side = NSScreen.screens.compactMap {
      ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
    }.filter {
      guard (currentDisplay ? NSScreen.screens.count == 1 && $0 == CGMainDisplayID() : $0 != CGMainDisplayID()),
        let id = CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue()
      else { return false }
      return CFUUIDCreateString(nil, id) as String == a[3]
    }
    guard side.count == 1, NSScreen.screensHaveSeparateSpaces, n > 0,
      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, n) as? [[String: Any]],
      rows.count == 1, rows[0][kCGWindowOwnerPID as String] as? Int32 == pid,
      rows[0][kCGWindowIsOnscreen as String] as? Bool == true,
      let b = rows[0][kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: b), CGDisplayBounds(side[0]).contains(rect),
      let source = grant["source"] as? String,
      (NPReadWindowSpaces(n) as? [NSNumber])?.map(\.stringValue) == [source]
    else { return nil }
    return (try PointerDisplay(side[0]), rect, n)
  }
  var target: (PointerDisplay, CGRect, UInt32)?
  while app.sameProcess && end.timeIntervalSinceNow > 10 && now() - start < 40 {
    if let found = try locate() {
      target = found
      break
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow:0.025))
  }
  guard let (side, rect, number) = target else {
    // The route may refuse before showing A. No placement call is reachable above
    // this point. Attest unchanged cursor only after the fixture has really exited.
    // The kernel may expose a zombie briefly while the parent reaps the witness.
    // This is read-only; a reused or still-live PID never proves absence.
    let reapDeadline = min(end, Date(timeIntervalSinceNow: 1))
    while !app.confirmedAbsent && Date() < reapDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
    }
    guard app.confirmedAbsent else { throw Stop("A did not acquire the expected foreground window or its owner changed") }
    for index in 0..<2 {
      let p = try pointer()
      guard p == original, try PointerDisplay(point: p) == originalDisplay else {
        throw Stop("cursor changed before a loan could be established")
      }
      if index == 0 { Thread.sleep(forTimeInterval: 0.05) }
    }
    print("original pointer unchanged; no loan")
    return
  }
  let dest = CGPoint(x: rect.midX.rounded(), y: rect.midY.rounded())
  try required(
    app.verified && !heldButtons() && (try pointer()) == original, "witness, pointer or modifiers changed before loan")
  let spent = now()
  try side.move(to: dest)
  var sampled: CGPoint?
  var observationError: Error?
  do {
    let limit = now() + 0.6
    repeat {
      let p = try pointer()
      if sampled != p { note("placement", p) }
      if let prior = sampled,
        prior == p, rect.contains(p), (try PointerDisplay(point: p)) == side
      {
        if let live = try locate() {
          try required(
            live.0 == side && live.1 == rect && live.2 == number,
            "enrolled fixture changed during placement")
        } else {
          throw Stop("source focus or membership changed during pointer placement")
        }
        break
      }
      sampled = p
      try required(now() < limit, "stable landing on owned window not confirmed")
      Thread.sleep(forTimeInterval: 0.04)
    } while true
    while app.sameProcess && end.timeIntervalSinceNow > 2 { RunLoop.current.run(until: Date(timeIntervalSinceNow:0.05)) }
  } catch { observationError = error }
  let current = try pointer()
  note("before-return", current)
  if current != original {
    try required(
      hardwareIdle(since: spent) && !heldButtons() && sampled == current
        && end.timeIntervalSinceNow > 0,
      "pointer changed outside the observed loan; return withheld")
    try originalDisplay.move(to: original)
    let limit = now() + 0.5
    var firstMatch: CGPoint?
    var verified = false
    while now() < limit {
      let p = try pointer()
      let screen = try PointerDisplay(point: p)
      if screen == originalDisplay, abs(p.x - original.x) <= 1, abs(p.y - original.y) <= 1 {
        if firstMatch == p { verified = true; note("returned", p); break }
        firstMatch = p
      } else {
        firstMatch = nil
      }
      Thread.sleep(forTimeInterval: 0.04)
    }
    try required(verified, "original pointer not restored")
  }
  if let observationError { throw observationError }
  print("original pointer restored")
}
do { try run() } catch {
  FileHandle.standardError.write(
    Data(("\((error as? Stop)?.reason ?? String(describing:error))\n").utf8))
  exit(2)
}
