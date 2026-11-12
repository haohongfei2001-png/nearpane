// Device-lab only: no product linkage. Open Apple's overview exclusively from our own
// enrolled secondary fixture, observe the secondary Dock bar, and return focus passively.
import AppKit
import ApplicationServices
import Darwin

func need(_ test: Bool, _ reason: String) throws { if !test { throw Refusal(reason) } }
func spin(_ seconds: Double) {
  let end = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    while let e = NSApp.nextEvent(
      matching: .any, until: .distantPast, inMode: .default, dequeue: true)
    { NSApp.sendEvent(e) }
    NSApp.updateWindows()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.015))
  } while ProcessInfo.processInfo.systemUptime < end
}
func currentFocus() throws -> (pid_t, AXUIElement) {
  guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    let value = attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { throw Refusal("no exact AX focus") }
  let el = value as! AXUIElement
  var owner: pid_t = 0
  try need(AXUIElementGetPid(el, &owner) == .success && owner == pid, "focus owner conflict")
  return (pid, el)
}
func frame(_ el: AXUIElement) -> CGRect? {
  guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
    CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
  else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
    AXValueGetValue(s as! AXValue, .cgSize, &size)
  else { return nil }
  return CGRect(origin: point, size: size)
}
func scoped(_ display: String, _ origin: String) throws -> [String] {
  guard let rows = NPReadInventory() as? [[String: Any]], rows.count == 2 else {
    throw Refusal("inventory unavailable")
  }
  let liveIDs = try NSScreen.screens.map { screen -> String in
    guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { throw Refusal("missing display UUID") }
    return CFUUIDCreateString(nil, id) as String
  }
  try need(
    Set(liveIDs).count == 2 && liveIDs.contains(display)
      && Set(rows.compactMap { $0["Display Identifier"] as? String }) == Set(liveIDs),
    "unbound display inventory")
  return try rows.map { row in
    guard let d = row["Display Identifier"] as? String,
      let current = (row["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
      let records = row["Spaces"] as? [[String: Any]], !records.isEmpty
    else { throw Refusal("incomplete display inventory") }
    if d == display {
      try need(
        current.stringValue == origin
          && records.contains {
            ($0["id64"] as? NSNumber) == current && ($0["type"] as? Int) == 0
          }, "not on authorized ordinary source")
    }
    return d + ":" + current.stringValue + ":"
      + records.map {
        String(describing: $0["id64"] ?? "?") + "/" + String(describing: $0["type"] ?? "?")
      }.joined(separator: ",")
  }.sorted()
}
func point() throws -> CGPoint {
  guard let p = CGEvent(source: nil)?.location else { throw Refusal("pointer unavailable") }
  return p
}
func emit(_ fields: [String: Any]) {
  var f = fields
  f["at"] = ISO8601DateFormatter().string(from: Date())
  if let d = try? JSONSerialization.data(withJSONObject: f, options: .sortedKeys) {
    FileHandle.standardOutput.write(d + Data([10]))
  }
}
// This uses the installed /System application, not a private Dock notification.
func toggleOverview() throws {
  let p = Process()
  p.executableURL = URL(
    fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
  p.standardInput = FileHandle.nullDevice
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try p.run()
}
func live(_ args: [String]) throws {
  guard args.count == 4, let display = UUID(uuidString: args[0]),
    let start = ISO8601DateFormatter().date(from: args[2]),
    let end = ISO8601DateFormatter().date(from: args[3]), start <= Date(),
    end.timeIntervalSince(start) <= 900,
    end.timeIntervalSinceNow > 30
  else {
    throw Refusal("expected secondary UUID, ordinary source, current start/end of timed grant")
  }
  let sideID = display.uuidString
  let source = args[1]
  let app = NSApplication.shared
  try need(
    app.setActivationPolicy(.accessory) || app.activationPolicy() == .accessory,
    "accessory policy unavailable")
  try need(NSScreen.screensHaveSeparateSpaces, "AppKit reports shared Spaces")
  let opened = NPReadOnlySpacesOpen()
  try need(opened == 1, "build-bound read-only observer unavailable (" + String(opened) + ")")
  let side = try onlyScreen(sideID)
  try need(
    try observe(display)["state"] as? String == "overviewNotExposed",
    "preexisting overview or permission unavailable")
  let inv = try scoped(sideID, source)
  let focus = try currentFocus()
  guard let orig = frame(focus.1), CGDisplayBounds(CGMainDisplayID()).contains(orig),
    let owner = NSRunningApplication(processIdentifier: focus.0), let birth = owner.launchDate,
    let width = (side.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
  else { throw Refusal("no stable ordinary focus return object") }
  try need(
    attr(focus.1, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
      && NPReadAXWindowNumber(focus.1) > 0, "ordinary original window required")
  let pointer = try point()
  let run = UUID().uuidString
  let originalNumber = NPReadAXWindowNumber(focus.1)
  emit([
    "event": "original", "run": run, "process": focus.0,
    "processBirth": birth.timeIntervalSince1970,
    "window": originalNumber, "source": source, "side": sideID,
  ])
  app.finishLaunching()
  let rect = CGRect(
    x: side.visibleFrame.midX - 140, y: side.visibleFrame.midY - 90, width: 280, height: 180
  ).integral
  let w = NSWindow(
    contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: true,
    screen: side)
  w.isRestorable = false
  w.isReleasedWhenClosed = false
  w.title = "Nearpane · A"
  w.setAccessibilityIdentifier(run)
  w.contentView = NSTextField(labelWithString: "Nearpane — secondary desktop test")
  w.setFrame(rect, display: false)
  var movedPointer = false
  var toggled = false
  var verifiedClosed = false
  var failure: Error?
  let here = CGRect(
    x: CGDisplayBounds(width).midX, y: CGDisplayBounds(width).midY, width: 1, height: 1
  ).origin
  func originalUnchanged() throws {
    try need(
      !owner.isTerminated && owner.launchDate == birth
        && NPReadAXWindowNumber(focus.1) == originalNumber && frame(focus.1) == orig,
      "original focus owner or geometry changed")
  }
  func isOriginal() -> Bool {
    guard let now = try? currentFocus() else { return false }
    return now.0 == focus.0 && CFEqual(now.1, focus.1)
  }
  func within() throws {
    try need(Date() >= start && end.timeIntervalSinceNow > 8, "time expired")
    try originalUnchanged()
    try need(try scoped(sideID, source) == inv, "display state changed")
  }
  var num: UInt32 = 0
  do {
    try within()
    try need(
      isOriginal() && w.screen == side && side.visibleFrame.contains(w.frame),
      "initial focus or placement changed")
    w.orderFrontRegardless()
    spin(0.30)
    num = UInt32(w.windowNumber)
    func exactWindow() throws {
      guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, num) as? [[String: Any]],
        rows.count == 1,
        let r = rows.first, r[kCGWindowOwnerPID as String] as? Int32 == getpid(),
        r[kCGWindowIsOnscreen as String] as? Bool == true,
        let b = r[kCGWindowBounds as String] as? NSDictionary,
        let cg = CGRect(dictionaryRepresentation: b),
        let windows = attr(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute)
          as? [AXUIElement]
      else { throw Refusal("no on-screen owned window") }
      let ax = try only(
        windows.filter {
          attr($0, kAXIdentifierAttribute) as? String == run && NPReadAXWindowNumber($0) == num
        }, "own AX window")
      try need(
        frame(ax) == cg && CGDisplayBounds(width).contains(cg) && cg.contains(here)
          && w.isOnActiveSpace && w.screen == side
          && (NPReadWindowSpaces(num) as? [NSNumber])?.map(\.stringValue) == [source],
        "own geometry or membership not confirmed")
    }
    try exactWindow()
    try within()
    let observed = try? currentFocus()
    emit([
      "event": "ordered", "run": run, "window": num, "process": getpid(), "source": source,
      "originalStillFocused": isOriginal(),
      "fixtureFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "axFocusReadable": observed != nil, "fixtureKey": w.isKeyWindow,
      "fixtureMain": w.isMainWindow,
    ])
    try need(isOriginal(), "original focus changed before loan")
    app.activate()
    w.makeKeyAndOrderFront(nil)
    spin(0.45)
    try exactWindow()
    let key = try currentFocus()
    try need(
      key.0 == getpid() && NPReadAXWindowNumber(key.1) == num && w.isKeyWindow,
      "fixture did not receive focus")
    // Verify passive return before invoking any system overview.
    w.orderOut(nil)
    app.hide(nil)
    spin(0.55)
    try within()
    try need(isOriginal(), "passive return rehearsal failed")
    app.unhideWithoutActivation()
    w.orderFrontRegardless()
    spin(0.25)
    try exactWindow()
    try need(isOriginal(), "return anchor lost")
    app.activate()
    w.makeKeyAndOrderFront(nil)
    spin(0.4)
    try exactWindow()
    let key2 = try currentFocus()
    try need(
      key2.0 == getpid() && CFEqual(key2.1, key.1) && w.isKeyWindow, "secondary focus changed")
    try within()
    try need(
      CGEventSource.buttonState(.combinedSessionState, button: .left) == false
        && CGEventSource.flagsState(.combinedSessionState).intersection([
          .maskControl, .maskShift, .maskAlternate, .maskCommand,
        ]).isEmpty, "input already in use")
    try need((try point()) == pointer, "pointer changed before loan")
    try need(CGWarpMouseCursorPosition(here) == .success, "could not position pointer on fixture")
    movedPointer = true
    try within()
    try exactWindow()
    let finalFocus = try currentFocus()
    try need(
      (try point()) == here && finalFocus.0 == getpid() && CFEqual(finalFocus.1, key.1)
        && w.isKeyWindow && NSScreen.main == side, "secondary pointer, active display or focus lost"
    )
    try need(
      try observe(display)["state"] as? String == "overviewNotExposed", "overview predated action")
    emit([
      "event": "enrolled", "run": run, "window": num, "source": source,
      "focusReturnRehearsed": true,
    ])
    try toggleOverview()
    toggled = true
    let cutoff = Date().addingTimeInterval(2.5)
    var evidence: [String: Any]?
    repeat {
      spin(0.08)
      try within()
      if let s = try? observe(display), s["state"] as? String == "secondaryAddControlObserved" {
        evidence = s
        break
      }
    } while Date() < cutoff
    guard let evidence else { throw Refusal("secondary add control not independently identified") }
    emit(evidence)
  } catch { failure = error }
  // Dismiss only our known overview; never post an Escape or activate the previous user app.
  if toggled, end.timeIntervalSinceNow > 3, (try? originalUnchanged()) != nil,
    (try? scoped(sideID, source)) == inv,
    (try? point()) == here,
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first,
    let m = try? children(AXUIElementCreateApplication(dock.processIdentifier), named: "mc"),
    m.count == 1,
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    [getpid(), dock.processIdentifier].contains(front)
  {
    do {
      try toggleOverview()
      spin(0.55)
      verifiedClosed = (try observe(display)["state"] as? String == "overviewNotExposed")
    } catch {}
  }
  w.orderOut(nil)
  w.close()
  // orderFrontRegardless or AppKit startup can alter focus before an explicit activate(). Relinquish
  // only our own process, even on that early refusal; never raise the user's original window.
  if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { app.hide(nil) }
  let passiveEnd = ProcessInfo.processInfo.systemUptime + 2
  repeat { spin(0.08) } while !isOriginal() && ProcessInfo.processInfo.systemUptime < passiveEnd
  if movedPointer && (try? point()) == here { _ = CGWarpMouseCursorPosition(pointer) }
  let ret = isOriginal() && (try? originalUnchanged()) != nil
  let topology = (try? scoped(sideID, source)) == inv
  let absent = num == 0 || NPReadWindowNumberPresence(num) == 0
  emit([
    "event": "cleanup", "originalFocus": ret, "originalWindow": originalNumber, "window": num,
    "originalPointer": (try? point()) == pointer, "originalScopes": topology,
    "windowAbsent": absent, "overviewInvoked": toggled, "overviewDismissed": verifiedClosed,
    "spaceMutations": 0,
  ])
  if let failure { throw failure }
  try need(
    ret && absent && topology && verifiedClosed && (try point()) == pointer, "cleanup not confirmed"
  )
}
func onlyScreen(_ uuid: String) throws -> NSScreen {
  let list = NSScreen.screens.filter { s in
    guard let n = s.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      n.uint32Value != CGMainDisplayID(),
      let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { return false }
    return CFUUIDCreateString(nil, id) as String == uuid
  }
  guard list.count == 1 else { throw Refusal("secondary display absent") }
  return list[0]
}
do { try live(Array(CommandLine.arguments.dropFirst())) } catch {
  emit(["event": "refused", "reason": (error as? Refusal)?.reason ?? String(describing: error)])
  exit(2)
}
