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
func scoped(_ display: String, _ origin: String, currentDisplay: Bool = false) throws -> [String] {
  guard let rows = NPReadInventory() as? [[String: Any]], rows.count == (currentDisplay ? 1 : 2) else {
    throw Refusal("inventory unavailable")
  }
  let liveIDs = try NSScreen.screens.map { screen -> String in
    guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { throw Refusal("missing display UUID") }
    return CFUUIDCreateString(nil, id) as String
  }
  try need(
    Set(liveIDs).count == (currentDisplay ? 1 : 2) && liveIDs.contains(display)
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
  let request = Process()
  request.executableURL = URL(fileURLWithPath:"/usr/bin/open")
  // Keep the launcher out of the activation history used by the passive return.
  // The caller verifies the resulting system overview separately.
  request.arguments = ["-g","-a","/System/Applications/Mission Control.app"]
  request.standardInput = FileHandle.nullDevice
  request.standardOutput = FileHandle.nullDevice
  request.standardError = FileHandle.nullDevice
  try request.run()
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  while request.isRunning && ProcessInfo.processInfo.systemUptime < deadline { spin(0.02) }
  try need(!request.isRunning && request.terminationStatus == 0,"system overview open request failed")

}
func overviewOwner(_ pid: pid_t?) -> Bool {
  guard let pid, let host = overviewHost(pid) else { return false }
  return host == "com.apple.dock" || host == "com.apple.WindowManager"
}
// A hover is delivered only to Apple's Spaces bar on the enrolled physical display.
// The resulting mouse position never identifies or presses an Add or Remove button.
private func systemStrip(at point: CGPoint, display: CGDirectDisplayID, currentDisplay: Bool) -> (pid: pid_t, frame: CGRect)? {
  guard CGDisplayBounds(display).contains(point), (currentDisplay || !CGDisplayBounds(CGMainDisplayID()).contains(point)) else { return nil }
  var hit: AXUIElement?
  guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
          == .success, var node = hit else { return nil }
  var pid: pid_t = 0
  guard AXUIElementGetPid(node, &pid) == .success, overviewOwner(pid) else { return nil }
  var strip: CGRect?
  for _ in 0..<8 {
    var owner: pid_t = 0
    guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { return nil }
    let id = attr(node, kAXIdentifierAttribute) as? String
    if id == "mc.spaces", let bounds = frame(node), bounds.contains(point),
       CGDisplayBounds(display).contains(bounds) { strip = bounds }
    if id == "mc.display" {
      guard let strip, (attr(node, "AXDisplayID") as? NSNumber)?.uint32Value == display else { return nil }
      return (pid, strip)
    }
    guard let parent = attr(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
    node = parent as! AXUIElement
  }
  return nil
}
func live(_ supplied: [String]) throws {
  let currentDisplay = supplied.first == "--current-display"
  let args = Array(supplied.dropFirst(currentDisplay ? 1 : 0))
  guard (args.count == 4 || (args.count == 6 && ["create","remove","prepare-and-restore"].contains(args[4]))), let display = UUID(uuidString: args[0]),
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
  let side = try onlyScreen(sideID, currentDisplay:currentDisplay)
  try need(
    try observe(display, currentDisplay:currentDisplay)["state"] as? String == "overviewNotExposed",
    "preexisting overview or permission unavailable")
  let inv = try scoped(sideID, source, currentDisplay:currentDisplay)
  var expectedScopes = inv
  var verifiedOperation: String?
  let mode = args.count == 6 ? args[4] : "observe"
  let kit = Bundle.main.bundleURL.deletingLastPathComponent()
  let anchor = try FocusAnchor()
  let focus = (anchor.owner.processIdentifier, anchor.element)
  let env = ProcessInfo.processInfo.environment
  guard env["NEARPANE_RETURN_OBSERVER"] == String(getppid()),
    let run = env["NEARPANE_RETURN_RUN"], UUID(uuidString:run) != nil,
    anchor.environment.allSatisfy({env[$0.key] == $0.value}),
    let width = (side.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
    [CGMainDisplayID(),width].contains(where:{CGDisplayBounds($0).contains(anchor.axFrame)})
  else { throw Refusal("external focus observer or original identity changed") }
  let allowPrimaryOverview = env["NEARPANE_PRIMARY_OVERVIEW_UNTIL"] == args[3]
    && CGDisplayBounds(CGMainDisplayID()).contains(anchor.axFrame)
    && CGDisplayBounds(CGMainDisplayID()).contains(anchor.cgFrame)
  let baseMembership = (NPReadWindowSpaces(anchor.number) as? [NSNumber])?.map(\.stringValue).sorted()
  let birth = anchor.birth
  let pointer = try point()
  let originalNumber = anchor.number
  emit([
    "event": "original", "run": run, "process": focus.0,
    "processBirth": birth.timeIntervalSince1970,
    "window": originalNumber, "primaryOverviewAllowed":allowPrimaryOverview, "source": source, "side": sideID, "originalPointer":[pointer.x,pointer.y],
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
  let displays = [CGMainDisplayID(),width]
  guard let returnDisplay = displays.first(where:{CGDisplayBounds($0).contains(pointer)}) else {
    throw Refusal("unable to identify original cursor display")
  }
  func place(_ position: CGPoint,on screen: CGDirectDisplayID) -> CGError {
    let bounds = CGDisplayBounds(screen)
    return CGDisplayMoveCursorToPoint(screen,CGPoint(x:position.x-bounds.minX,y:position.y-bounds.minY))
  }
  func near(_ a:CGPoint?,_ b:CGPoint?) -> Bool {
    guard let a, let b else { return false }
    return abs(a.x-b.x) <= 1 && abs(a.y-b.y) <= 1
  }
  var landed: CGPoint?
  var pointerLoanBegan: Double?
  func physicalMouseIdle(since time: Double) -> Bool {
    let elapsed = ProcessInfo.processInfo.systemUptime - time
    let events: [CGEventType] = [.mouseMoved,.leftMouseDown,.rightMouseDown,.otherMouseDown,
                                .leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
    return NSEvent.pressedMouseButtons == 0 && events.allSatisfy {
      CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) > elapsed
    }
  }
  func keyboardAndScrollIdle(since time: Double) -> Bool {
    let elapsed = ProcessInfo.processInfo.systemUptime - time
    return [CGEventType.keyDown, .keyUp, .flagsChanged, .scrollWheel].allSatisfy {
      CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) > elapsed
    }
  }
  var movedPointer = false
  var toggled = false
  var ownedOverview: AXUIElement?
  var verifiedClosed = false
  var failure: Error?
  let here = CGRect(
    x: CGDisplayBounds(width).midX, y: CGDisplayBounds(width).midY, width: 1, height: 1
  ).origin
  func originalUnchanged() throws {
    try need(anchor.isIntact,"original focus owner or geometry changed")
  }
  func protectedPresentation(_ geometry: CGRect?) -> Bool {
    guard anchor.logicalFrameIntact, let geometry else { return false }
    if geometry == anchor.cgFrame { return true }
    guard toggled, allowPrimaryOverview, let baseMembership, !baseMembership.isEmpty,
          geometry.width > 0, geometry.height > 0,
          CGDisplayBounds(CGMainDisplayID()).contains(geometry),
          (NPReadWindowSpaces(anchor.number) as? [NSNumber])?.map(\.stringValue).sorted() == baseMembership
    else { return false }
    return true
  }
  func isOriginal() -> Bool { anchor.isFocused }

  // Exercise exactly the same release sequence before and after Mission Control.
  // Closing the last NSWindow first can change the frontmost app during the handoff.
  func relinquishAndObserve(_ phase: String) -> Bool {
    w.orderOut(nil)
    app.hide(nil)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var since: Double?
    var confirmed = false
    repeat {
      spin(0.04)
      let now = ProcessInfo.processInfo.systemUptime
      if isOriginal() && anchor.isIntact {
        if let since, now - since >= 0.15 { confirmed = true; break }
        if since == nil { since = now }
      } else {
        since = nil
      }
    } while ProcessInfo.processInfo.systemUptime < deadline
    emit(["event":"passiveHandoff","phase":phase,"originalFocusWhileFixtureRetained":confirmed,
          "originalProcessFrontmost":NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.0,
          "fixtureOrderedOut":!w.isVisible])
    return confirmed
  }
  func within() throws {
    try need(Date() >= start && end.timeIntervalSinceNow > 8, "time expired")
    if toggled {
      // The compositor may animate while AX retains the original layout. checkAction
      // separately checks the physical display, membership, and timed presentation grant.
      try need(anchor.logicalFrameIntact, "original AX identity or logical frame changed in overview")
    } else {
      try originalUnchanged()
    }
    try need(try scoped(sideID, source, currentDisplay:currentDisplay) == expectedScopes, "display state changed")
  }
  var num: UInt32 = 0
  var enrolledAX: AXUIElement?
  do {
    try within()
    try need(
      isOriginal() && w.screen == side && side.visibleFrame.contains(w.frame),
      "initial focus or placement changed")
    w.orderFrontRegardless()
    spin(0.30)
    num = UInt32(w.windowNumber)
    @discardableResult func exactWindow() throws -> AXUIElement {
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
      return ax
    }
    enrolledAX = try exactWindow()
    try within()
    let observed = try? currentFocus()
    emit([
      "event": "ordered", "run": run, "window": num, "process": getpid(), "source": source,
      "originalStillFocused": isOriginal(),
      "fixtureFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "axFocusReadable": observed != nil, "fixtureKey": w.isKeyWindow,
      "fixtureMain": w.isMainWindow,
    ])
    // AppKit may make this exact window key as a side effect of ordering. An unrelated
    // window, including another window of the original process, cannot take this branch.
    func acquire() throws -> (pid_t, AXUIElement) {
      let element = try exactWindow()
      try within()
      var published: (pid_t, AXUIElement)?
      let publishLimit = ProcessInfo.processInfo.systemUptime + 1
      repeat {
        try within()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try need(front == focus.0 || front == getpid(), "focus escaped before acquisition")
        published = try? currentFocus()
        if published != nil { break }
        spin(0.04)
      } while ProcessInfo.processInfo.systemUptime < publishLimit
      guard let observed = published else { throw Refusal("original or fixture focus not published") }
      switch orderedFocus(original:observed.0 == focus.0 && CFEqual(observed.1,focus.1),
                          ownedElement:observed.0 == getpid() && CFEqual(observed.1,element),
                          ownedKey:w.isKeyWindow) {
      case .original:
        app.activate()
        w.makeKeyAndOrderFront(nil)
      case .owned:
        break
      case .refused:
        throw Refusal("focus is neither the original window nor the enrolled key window")
      }
      let limit = ProcessInfo.processInfo.systemUptime + 1.5
      repeat {
        spin(0.04)
        try within()
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
          try need(front == focus.0 || front == getpid(),"focus escaped the registered pair")
        }
        if let now = try? currentFocus() {
          if now.0 == getpid() && CFEqual(now.1,element) && w.isKeyWindow {
            try exactWindow()
            return now
          }
          try need(now.0 == focus.0 && CFEqual(now.1,focus.1),"unregistered focus while acquiring fixture")
        }
      } while ProcessInfo.processInfo.systemUptime < limit
      throw Refusal("enrolled window did not take focus")
    }
    _ = try acquire()
    // Verify passive return before invoking any system overview.
    try need(relinquishAndObserve("rehearsal"), "passive return rehearsal failed")
    try within()
    app.unhideWithoutActivation()
    w.orderFrontRegardless()
    spin(0.25)
    try exactWindow()
    let key2 = try acquire()
    try need(
      key2.0 == getpid() && w.isKeyWindow && UInt32(w.windowNumber) == num &&
        CFEqual(key2.1, try exactWindow()), "focused element does not belong to the re-enrolled fixture")
    try within()
    try need(
      CGEventSource.buttonState(.combinedSessionState, button: .left) == false
        && CGEventSource.flagsState(.combinedSessionState).intersection([
          .maskControl, .maskShift, .maskAlternate, .maskCommand,
        ]).isEmpty, "input already in use")
    try need((try point()) == pointer, "pointer changed before loan")
    pointerLoanBegan = ProcessInfo.processInfo.systemUptime
    try need(place(here,on:width) == .success, "could not position pointer on fixture")
    movedPointer = true
    spin(0.06)
    let first = try point()
    spin(0.06)
    let actual = try point()
    if near(first,actual) && CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.mouseMoved) > 0.3 { landed = actual }
    try within()
    try exactWindow()
    let finalFocus = try currentFocus()
    let finalElement = try exactWindow()
    let frontOwned = finalFocus.0 == getpid() && CFEqual(finalFocus.1, finalElement)
    let keyScreen = (w.screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
    let publishedScreen = (NSScreen.main?.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
    emit(["event":"pointerLoan","first":[first.x,first.y],"actual":[actual.x,actual.y],
          "requested":[here.x,here.y],"frontOwned":frontOwned,"key":w.isKeyWindow,
          "keyScreen":keyScreen ?? 0,"publishedMainScreen":publishedScreen ?? 0,"targetDisplay":width])
    try need(near(landed,actual) && abs(actual.x-here.x) < 12 && abs(actual.y-here.y) < 12 &&
        CGDisplayBounds(width).contains(actual) && frontOwned && w.isKeyWindow && keyScreen == width,
        "secondary fixture pointer or focused window not independently confirmed")
    try need(
      try observe(display, currentDisplay:currentDisplay)["state"] as? String == "overviewNotExposed", "overview predated action")
    emit([
      "event": "enrolled", "run": run, "window": num, "source": source,
      "focusReturnRehearsed": true,
    ])
    try toggleOverview()
    toggled = true
    let cutoff = min(Date().addingTimeInterval(8), end.addingTimeInterval(-12))
    var evidence: [String: Any]?
    var lastState = ""
    let overviewSince = ProcessInfo.processInfo.systemUptime
    var hoverStep = 0
    var nextHover = overviewSince + 0.65
    var nextStructure = Date.distantPast
    var previousStructure: Data?
    func recordStructure() {
      guard Date() >= nextStructure else { return }
      nextStructure = Date().addingTimeInterval(0.4)
      let structure = overviewSkeleton(display, currentDisplay:currentDisplay)
      let data = try? JSONSerialization.data(withJSONObject:structure,options:.sortedKeys)
      if data != previousStructure {
        emit(["event":"overviewTree","structure":structure])
        previousStructure = data
      }
    }
    repeat {
      spin(0.08)
      try within()
      if ownedOverview == nil,
         let dock = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first,
         overviewOwner(dock.processIdentifier),
         let groups = try? children(AXUIElementCreateApplication(dock.processIdentifier),named:"mc"),
         groups.count == 1 { ownedOverview = groups[0] }
      recordStructure()
      if hoverStep < 2 && ProcessInfo.processInfo.systemUptime >= nextHover,
         let dock = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first,
         dock.executableURL?.path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
         (try? children(AXUIElementCreateApplication(dock.processIdentifier),named:"mc").count) == 1,
         near(try point(),landed), let spent = pointerLoanBegan, physicalMouseIdle(since:spent) {
        let cgBounds = CGDisplayBounds(width)
        // On a collapsed strip a corner hover alone can leave the bar at 40 pt.
        // First expand it from the middle, then visit the right edge only after
        // the second point actually hits the same display's expanded system bar.
        let probe = CGPoint(x:cgBounds.midX, y:cgBounds.minY + 12)
        let step = hoverStep + 1
        nextHover = ProcessInfo.processInfo.systemUptime + 0.45
        if let strip = systemStrip(at:probe, display:width, currentDisplay:currentDisplay),
           let stripPoint = overviewHoverPoint(in:strip.frame, edge:hoverStep != 0),
           systemStrip(at:stripPoint, display:width, currentDisplay:currentDisplay)?.pid == strip.pid {
          let owner = strip.pid
          hoverStep = step
          try need(protectedPresentation(FocusAnchor.geometry(anchor.number,anchor.owner.processIdentifier)),
                   "original window changed before secondary strip hover")
          try need(place(stripPoint,on:width) == .success,"secondary overview hover positioning failed")
          spin(0.06)
          let stop = try point()
          try need(near(stop,stripPoint),"secondary strip pointer readback differs")
          landed = stop
          try need(systemStrip(at: stop, display: width, currentDisplay:currentDisplay)?.pid == owner, "secondary strip owner changed during hover")
          guard let event = CGEvent(mouseEventSource:nil, mouseType:.mouseMoved, mouseCursorPosition:stop, mouseButton:.left)
          else { throw Refusal("system hover event unavailable") }
          event.postToPid(owner)
          emit(["event":"secondaryStripHover","step":step,"systemOverviewOwner":true])
        }
      }
      let cg = FocusAnchor.geometry(anchor.number,anchor.owner.processIdentifier)
      if !protectedPresentation(cg) {
        emit(["event":"protectedWindowCheck","originalWindow":anchor.number,"cgReadable":cg != nil,
              "cgMatchesOriginal":cg == anchor.cgFrame,"logicalIdentityAndFrameIntact":anchor.logicalFrameIntact])
        throw Refusal("protected window geometry unconfirmed during system overview")
      }
      do {
        let sample = try observe(display, currentDisplay:currentDisplay)
        if sample["state"] as? String == "secondaryAddControlObserved" {
          evidence = sample
          break
        }
        if lastState != "noGroup" {
          emit(["event":"overviewObserved","state":sample,"structure":overviewSkeleton(display, currentDisplay:currentDisplay)])
          lastState = "noGroup"
        }
      } catch {
        let reason = (error as? Refusal)?.reason ?? String(describing:error)
        if reason != lastState {
          emit(["event":"overviewObserved","reason":reason,"structure":overviewSkeleton(display, currentDisplay:currentDisplay)])
          lastState = reason
        }
      }
    } while Date() < cutoff
    guard let evidence else { throw Refusal("secondary add control not independently identified") }
    emit(evidence)
    if mode != "observe" {
      guard let primaryUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else {
        throw Refusal("missing primary display UUID")
      }
      let primary = CFUUIDCreateString(nil,primaryUUID) as String
      guard let originalPrimary = inv.first(where: {$0.hasPrefix(primary + ":")}),
            let originalCurrent = originalPrimary.split(separator: ":").dropFirst().first else {
        throw Refusal("missing primary source record")
      }
      func checkAction() throws {
        try need(start <= Date() && end.timeIntervalSinceNow > 10,"late provision action")
        if currentDisplay {
          guard let since = pointerLoanBegan, physicalMouseIdle(since:since), keyboardAndScrollIdle(since:since)
          else { throw Refusal("physical input resumed during the current-display loan") }
        }
        try need(protectedPresentation(FocusAnchor.geometry(anchor.number,anchor.owner.processIdentifier)),
                 "protected owner, logical layout, membership or overview presentation changed")
        let latest = try scoped(sideID,source, currentDisplay:currentDisplay)
        // In sole-display mode provisionSecondaryDesktop checks the complete before/after order.
        if !currentDisplay { try need(latest.contains(originalPrimary), "protected current or order changed") }
        let sideStillHere = try onlyScreen(sideID, currentDisplay:currentDisplay)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let allowed = front == getpid() || overviewOwner(front)
        try need(sideStillHere == side && near(try point(),landed) && allowed &&
                NSEvent.pressedMouseButtons == 0 &&
                CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskShift,.maskControl,.maskAlternate]).isEmpty,
                "focus, input or display changed during provision")
      }
      func occupancy(_ target: String?) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = kit.appendingPathComponent("occupancy")
        if currentDisplay {
          process.arguments = [target == nil ? "--scoped-current" : "--removal-current",String(getpid()),String(num),sideID,source] + (target.map {[$0]} ?? [])
        } else {
          process.arguments = ["--scoped",String(getpid()),String(num),primary,sideID,String(originalCurrent),source] + (target.map {[$0]} ?? [])
        }
        process.standardOutput = pipe; process.standardInput = FileHandle.nullDevice
        try process.run()
        let until = ProcessInfo.processInfo.systemUptime + 6
        while process.isRunning && ProcessInfo.processInfo.systemUptime < until { spin(0.03) }
        if process.isRunning { process.terminate(); throw Refusal("target occupancy read timed out") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let report = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        emit(["event":"scopedOccupancy","sample":report,"exit":process.terminationStatus])
        try need(process.terminationStatus == 0 && (report["occupancy"] as? String) ==
                 (target == nil ? "SOURCE_WITNESSED" : "NO_RELOCATION_OBSERVED"), "disposable desktop could not be safely verified")
      }
      if mode == "prepare-and-restore" { try need(end.timeIntervalSinceNow > 55,"insufficient time for provision and verified rollback") }
      let firstOperation = mode == "prepare-and-restore" ? "create" : mode
      let destination = try provisionSecondaryDesktop(firstOperation, directory:URL(fileURLWithPath:args[5]), display:display,
          source:source, currentDisplay:currentDisplay, requireAuthorizedAction:checkAction, requireSafeOccupancy:occupancy)
      verifiedOperation = firstOperation
      expectedScopes = try scoped(sideID,source, currentDisplay:currentDisplay)
      emit(["event":"verifiedProvision","operation":firstOperation,"source":source,"target":destination])
      if mode == "prepare-and-restore" {
        try within()
        let removed = try provisionSecondaryDesktop("remove",directory:URL(fileURLWithPath:args[5]),display:display,
            source:source,currentDisplay:currentDisplay,requireAuthorizedAction:checkAction,requireSafeOccupancy:occupancy)
        expectedScopes = try scoped(sideID,source, currentDisplay:currentDisplay)
        try need(removed == destination && expectedScopes == inv,"original test topology did not return")
        verifiedOperation = "createAndRemove"
        emit(["event":"verifiedProvision","operation":"remove","source":source,"target":removed])
      }
    }
  } catch { failure = error }
  // Dismiss only our known overview; never post an Escape or activate the previous user app.
  if toggled, end.timeIntervalSinceNow > 3, anchor.logicalFrameIntact,
    (try? scoped(sideID, source, currentDisplay:currentDisplay)) == expectedScopes,
    NSEvent.pressedMouseButtons == 0,
    let retained = ownedOverview,
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first,
    let m = try? children(AXUIElementCreateApplication(dock.processIdentifier), named: "mc"),
    m.count == 1, CFEqual(retained,m[0]),
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    (front == getpid() || overviewOwner(front) || (front == focus.0 && isOriginal()))
  {
    do {
      try toggleOverview()
      spin(0.75)
      verifiedClosed = (try observe(display, currentDisplay:currentDisplay)["state"] as? String == "overviewNotExposed")
    } catch {}
  }
  if toggled && !verifiedClosed {
    verifiedClosed = (try? observe(display, currentDisplay:currentDisplay)["state"] as? String) == "overviewNotExposed"
    if !verifiedClosed { emit(["event":"overviewAtCleanup","structure":overviewSkeleton(display, currentDisplay:currentDisplay)]) }
  }
  // Dismissal can precede restoration of the original CG frame. Observe that
  // transition before deciding whether a passive handoff is still possible.
  // An unrelated frontmost process ends this wait; it never qualifies for input.
  func returnOwner() -> String {
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return "unknown" }
    if front == getpid() { return "fixture" }
    if front == focus.0 { return "original" }
    return overviewOwner(front) ? "overview" : "other"
  }
  if toggled && verifiedClosed {
    let limit = min(end, Date().addingTimeInterval(1.5))
    while Date() < limit, anchor.logicalFrameIntact, !anchor.isIntact,
          ["original", "fixture", "overview"].contains(returnOwner()) { spin(0.05) }
    let observed = try? currentFocus()
    emit(["event":"dismissedFocus","frontmost":returnOwner(),
          "originalAXFocused":isOriginal(), "fixtureAXFocused":observed.map { now in
            now.0 == getpid() && enrolledAX.map { CFEqual(now.1, $0) } == true
          } ?? false, "axFocusReadable":observed != nil, "fixtureKey":w.isKeyWindow,
          "originalLogicalFrameIntact":anchor.logicalFrameIntact, "originalAXCGIntact":anchor.isIntact,
          "fixtureActiveSpace":w.isOnActiveSpace,
          "pointerAtLoanPosition":near(try? point(),landed),
          "physicalMouseQuiet":pointerLoanBegan.map(physicalMouseIdle(since:)) ?? false])
  }
  // Mission Control can leave keyboard focus with Dock. Let only our retained test window
  // become key again after a verified dismissal, then use the rehearsed passive return.
  if toggled && verifiedClosed && !isOriginal() && Date() < end && anchor.isIntact &&
      (try? scoped(sideID,source, currentDisplay:currentDisplay)) == expectedScopes && w.isOnActiveSpace &&
      (NPReadWindowSpaces(num) as? [NSNumber])?.map(\.stringValue) == [source] {
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier == getpid() || overviewOwner(front?.processIdentifier) {
      // Mission Control may keep its process in front after its overview disappears.
      // Reacquire only our enrolled window before hiding it to hand focus back.
      let appAX = AXUIElementCreateApplication(getpid())
      let owned = (attr(appAX,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
        NPReadAXWindowNumber($0) == num && attr($0,kAXIdentifierAttribute) as? String == run
      }
      if owned.count == 1, let ownFrame = frame(owned[0]),
         FocusAnchor.geometry(num,getpid()) == ownFrame, CGDisplayBounds(width).contains(ownFrame),
         near(try? point(),landed), let since = pointerLoanBegan, physicalMouseIdle(since:since) {
        if overviewOwner(front?.processIdentifier) { app.activate() }
        w.makeKeyAndOrderFront(nil)
        let limit = min(end,Date().addingTimeInterval(0.8))
        var ours = false
        repeat {
          spin(0.04)
          let frontNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
          if frontNow != getpid() && !overviewOwner(frontNow) { break }
          if let now = try? currentFocus(), now.0 == getpid(), CFEqual(now.1,owned[0]), w.isKeyWindow {
            ours = true
            break
          }
        } while Date() < limit
        emit(["event":"beforePassiveReturn","exactFixtureFocus":ours])
      }
    }
  }
  // Revalidate the retained object immediately before releasing focus. Do not hide
  // an unrelated app or activate the original app to manufacture a successful readback.
  if (!toggled || verifiedClosed), Date() < end, let enrolledAX, anchor.isIntact,
     w.isKeyWindow, w.windowNumber == Int(num), NPReadAXWindowNumber(enrolledAX) == num,
     (try? scoped(sideID,source,currentDisplay:currentDisplay)) == expectedScopes,
     (NPReadWindowSpaces(num) as? [NSNumber])?.map(\.stringValue) == [source],
     let exact = try? currentFocus(), exact.0 == getpid(), CFEqual(exact.1,enrolledAX) {
    if !relinquishAndObserve("cleanup"), failure == nil {
      failure = Refusal("original focus not confirmed before closing the hidden fixture")
    }
  } else {
    w.orderOut(nil)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { app.hide(nil) }
  }
  w.close()
  let passiveEnd = ProcessInfo.processInfo.systemUptime + 2
  repeat { spin(0.08) } while !isOriginal() && ProcessInfo.processInfo.systemUptime < passiveEnd
  if movedPointer, let spent = pointerLoanBegan, Date() < end, near(try? point(),landed), physicalMouseIdle(since:spent) {
    _ = place(pointer,on:returnDisplay)
    spin(0.06)
  }
  let ret = isOriginal() && (try? originalUnchanged()) != nil
  let topology = (try? scoped(sideID, source, currentDisplay:currentDisplay)) == expectedScopes
  let absent = num == 0 || NPReadWindowNumberPresence(num) == 0
  emit([
    "event": "cleanup", "originalFocus": ret, "originalWindow": originalNumber, "window": num,
    "originalPointer": near(try? point(),pointer), "scopesMatchVerifiedOperation": topology,
    "windowAbsent": absent, "overviewInvoked": toggled, "overviewDismissed": verifiedClosed,
    "verifiedSpaceMutations": verifiedOperation == "createAndRemove" ? 2 : (verifiedOperation == nil ? 0 : 1),
  ])
  if let failure { throw failure }
  try need(
    absent && topology && verifiedClosed && near(try point(),pointer), "cleanup not confirmed"
  )
}
func onlyScreen(_ uuid: String, currentDisplay: Bool) throws -> NSScreen {
  if currentDisplay { try need(NSScreen.screens.count == 1, "expected only the authorized screen") }
  let list = NSScreen.screens.filter { s in
    guard let n = s.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      (currentDisplay ? n.uint32Value == CGMainDisplayID() && CGDisplayMirrorsDisplay(n.uint32Value) == kCGNullDirectDisplay : n.uint32Value != CGMainDisplayID()),
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
