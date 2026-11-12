import AppKit
import WindowLab

/// Retain the exact AX object without changing it. JSON contains only the run-scoped token and process birth.
@MainActor struct ConsoleFocusLoan {
  let owner: ProcessBirth
  let token = UUID()
  private let window: AXUIElement
  private let originalFrame: CGRect

  init(_ original: (Int32, AXUIElement)) throws {
    owner = try ProcessBirth.read(original.0)
    window = original.1
    guard owner.start > 0, let frame = Self.frame(window), CGDisplayBounds(CGMainDisplayID()).contains(frame) else {
      throw Refusal("original focus has no recoverable ordinary main-display frame")
    }
    originalFrame = frame
    try verifyOriginal()
  }

  static func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = labAttribute(element, kAXPositionAttribute), let s = labAttribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    let position = p as! AXValue, size = s as! AXValue
    var pt = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
          AXValueGetValue(position, .cgPoint, &pt), AXValueGetValue(size, .cgSize, &dimensions),
          pt.x.isFinite, pt.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: pt, size: dimensions)
  }

  func verifyOriginal() throws {
    var pid: Int32 = 0
    try require(try ProcessBirth.read(owner.pid) == owner && AXUIElementGetPid(window, &pid) == .success &&
      pid == owner.pid && labAttribute(window, kAXRoleAttribute) as? String == kAXWindowRole &&
      labAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
      labAttribute(window, kAXMinimizedAttribute) as? Bool == false && Self.frame(window) == originalFrame,
      "original focus owner, window or frame changed")
  }

  func requireFocused(_ current: (Int32, AXUIElement)) throws {
    try verifyOriginal()
    try require(current.0 == owner.pid && CFEqual(current.1, window), "exact original focus not returned")
  }
}

extension Trial {
  func observePassiveReturn(_ loan: ConsoleFocusLoan) throws {
    // Order-out and hide affect our process only. Never issue activate/raise/setFocus against the original app.
    let until = ProcessInfo.processInfo.systemUptime + 2
    var firstRead: Double?
    repeat {
      try loan.verifyOriginal()
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
      if front == loan.owner.pid {
        try loan.requireFocused(focusedWindow())
        if let firstRead, ProcessInfo.processInfo.systemUptime - firstRead >= 0.12 { return }
        if firstRead == nil { firstRead = ProcessInfo.processInfo.systemUptime }
      } else {
        try require(front == birth.pid || front == nil, "focus escaped the registered pair")
        firstRead = nil
      }
      pump()
    } while ProcessInfo.processInfo.systemUptime < until
    throw Refusal("passive return to original focus unconfirmed")
  }

  func rehearsePassiveReturn(_ loan: ConsoleFocusLoan) throws {
    let (secondary, display) = try screen()
    guard let target = windows["A"], let enrolled = focus["A"], let origin = baseline["A"],
          let initial = initialFocus, windows.count == 1 else { throw Refusal("missing enrolled focus pair") }
    try checkConsentExpiry()
    let focusNow = try focusedWindow()
    try require(focusNow.0 == birth.pid && CFEqual(focusNow.1, enrolled) && target.isKeyWindow &&
                target.screen == secondary && target.isOnActiveSpace, "A cannot release a verified foreground loan")
    target.orderOut(nil)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == birth.pid { NSApp.hide(nil) }
    try observePassiveReturn(loan)
    _ = try consoleEndpoint("A", display: display)
    try loan.requireFocused(focusedWindow())
    try writeJSON(["run": run.uuidString, "focusToken": loan.token.uuidString, "owner": String(initial.0),
                   "processBirth": String(loan.owner.start), "sameAXFocus": "true", "originalFrameUnchanged": "true"],
                  dir, "focus-return-rehearsal.json")
    try checkConsentExpiry()
    try require(windows["A"] === target && target.windowNumber == Int(origin.number),
                "secondary fixture changed during focus rehearsal")
    try loan.requireFocused(focusedWindow())
    NSApp.unhideWithoutActivation()
    target.orderFrontRegardless()
    try ownedAX("A")
    try require(target.screen == secondary && secondary.frame.contains(target.frame) && target.isOnActiveSpace,
                "restored fixture is no longer on the source display and Space")
    _ = try consoleEndpoint("A", display: display)
    try checkConsentExpiry()
    try loan.requireFocused(focusedWindow())
    try checkConsentExpiry()
    NSApp.activate()
    target.makeKeyAndOrderFront(nil)
    let until = ProcessInfo.processInfo.systemUptime + 2
    while !target.isKeyWindow || NSWorkspace.shared.frontmostApplication?.processIdentifier != birth.pid {
      try checkConsentExpiry()
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
      try require((front == loan.owner.pid || front == birth.pid) && ProcessInfo.processInfo.systemUptime < until,
                  "fixture did not reacquire its own focus")
      pump()
    }
    _ = try stable("A", "focus-loan-reacquired")
  }
}
