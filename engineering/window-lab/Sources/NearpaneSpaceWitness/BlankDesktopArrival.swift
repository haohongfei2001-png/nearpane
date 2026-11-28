import AppKit
import NearpaneCore
import Security
import WindowLab

extension Trial {
  /// A first arrival at a previously empty desktop can have an active application and no AX focused window.
  /// This exception permits activating only our own already visible B. All later checkpoints require exact AX focus.
  func enrollBlankArrivalIfNeeded(_ label: String) throws {
    guard label == "B", let selectedDisplay, baseline["B"] == nil,
          let source = baseline["A"], let a = windows["A"], let b = windows["B"],
          let start = currentRouteCalibrationBegan, let focusLoan else { return }
    if (try? focusedWindow()) != nil { return }
    let display = selectedDisplay.uuidString
    let (screen, _) = try self.screen()
    let target = try consoleEndpoint("B", display: display)
    guard let bID = target.scopes.first?.records.first(where: \.isCurrent)?.id,
          let ai = source.recordOrder.firstIndex(of: source.record),
          let bi = source.recordOrder.firstIndex(of: bID), abs(ai-bi) == 1,
          let n = UInt32(exactly: b.windowNumber), n != 0, n != source.number,
          UInt32(exactly: a.windowNumber) == source.number else { throw Refusal("first-arrival window membership unavailable") }
    try ownedAX("A")
    try ownedAX("B")
    func assertInputQuiet() throws {
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                   .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
      try require(elapsed > 0 && events.allSatisfy { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= elapsed },
                  "user input observed since source calibration")
    }
    func emptyFocusOwner() throws -> ProcessBirth {
      try assertInputQuiet()
      try focusLoan.verifyOriginal()
      let frame = CGRect(x: b.frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - b.frame.maxY,
                         width: b.frame.width, height: b.frame.height)
      guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
            a.screen == screen, !a.isOnActiveSpace, b.screen == screen, b.isVisible, b.isOnActiveSpace,
            !b.isMiniaturized, b.frame.width > 0, screen.visibleFrame.contains(b.frame),
            screen.frame.contains(NSEvent.mouseLocation), windows.count == 2,
            let ax = elements["B"], ConsoleFocusLoan.frame(ax) == frame,
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, n) as? [[String: Any]], rows.count == 1,
            let row = rows.first, row[kCGWindowOwnerPID as String] as? Int32 == birth.pid,
            row[kCGWindowNumber as String] as? UInt32 == n, row[kCGWindowLayer as String] as? Int == 0,
            row[kCGWindowIsOnscreen as String] as? Bool == true,
            let rect = row[kCGWindowBounds as String] as? NSDictionary,
            CGRect(dictionaryRepresentation: rect) == frame else { throw Refusal("first-arrival fixture changed") }
      let owner = try ProcessBirth.read(app.processIdentifier)
      let root = AXUIElementCreateApplication(owner.pid)
      AXUIElementSetMessagingTimeout(root, 0.25)
      var focused: CFTypeRef?
      try require(AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focused) == .noValue && focused == nil,
                  "first-arrival focus is positive, unsupported or ambiguous")
      if owner == birth { return owner }
      var requirement: SecRequirement?, guest: SecCode?
      guard app.bundleIdentifier == "com.apple.finder", app.bundleURL?.resolvingSymlinksInPath().path == "/System/Library/CoreServices/Finder.app",
            SecRequirementCreateWithString("anchor apple and identifier \"com.apple.finder\"" as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: owner.pid] as CFDictionary, [], &guest) == errSecSuccess,
            let guest, SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,
            let finderWindows = labAttribute(root, kAXWindowsAttribute) as? [AXUIElement], finderWindows.count <= 128,
            let onScreen = NSWindow.windowNumbers(options: [.allApplications]) else { throw Refusal("empty system desktop focus unproved") }
      let active = Set(onScreen.map(\.uint32Value))
      for window in finderWindows {
        var pid: Int32 = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == owner.pid,
              let n = arrivalWindowNumber(window), !active.contains(n) else { throw Refusal("visible or unbound Finder window") }
      }
      return owner
    }
    let originalOwner = try emptyFocusOwner()
    let file = dir.appendingPathComponent("first-arrival-route.json")
    try helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
               ["--enrolled-current-route", display, String(n), String(source.number)], output: file)
    let evidence = try JSONDecoder().decode(NativeRouteEvidence.self, from: Data(contentsOf: file))
    let current = [display: bID]
    try require(evidence.validates(display: display, source: bID, sourceWindow: n, target: source.record, targetWindow: source.number,
                                   sourceCurrents: current, targetCurrents: source.currents, frozenOrder: source.recordOrder,
                                   frozenTopology: source.topology, right: ai > bi, isolatedDisplays: false, currentDisplayOnly: true),
                "first-arrival window A or B no longer bound to its desktop")
    _ = try consoleEndpoint("B", display: display)
    try checkConsentExpiry()
    try require(try emptyFocusOwner() == originalOwner, "first-arrival foreground changed")
    try writeJSON(["ownerPID": String(originalOwner.pid), "ownerBirth": String(originalOwner.start),
                   "sourceWindow": String(source.number), "targetWindow": String(n), "target": bID], dir, "first-arrival-enrollment.json")
    try checkConsentExpiry()
    try require(try emptyFocusOwner() == originalOwner, "first-arrival foreground changed before activation")
    NSApp.activate()
    b.makeKeyAndOrderFront(nil)
    let until = ProcessInfo.processInfo.systemUptime + 1.5
    repeat {
      try assertInputQuiet()
      try checkConsentExpiry()
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
      try require(front == originalOwner.pid || front == birth.pid, "first-arrival focus escaped its owner pair")
      if b.isKeyWindow, let focus = try? focusedWindow(), focus.0 == birth.pid,
         let exact = elements["B"], CFEqual(focus.1, exact) { return }
      pump()
    } while ProcessInfo.processInfo.systemUptime < until
    throw Refusal("exact fixture focus missing after first-arrival activation")
  }

  private func arrivalWindowNumber(_ window: AXUIElement) -> UInt32? {
    if let n = labAttribute(window, "AXWindowNumber") as? NSNumber, let number = UInt32(exactly: n.int64Value), number > 0 { return number }
    typealias ReadNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    guard ProcessInfo.processInfo.operatingSystemVersionString.hasSuffix("(Build 26A428)"),
          let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    var n: UInt32 = 0
    return unsafeBitCast(fn, to: ReadNumber.self)(window, &n) == 0 && n > 0 ? n : nil
  }
}
