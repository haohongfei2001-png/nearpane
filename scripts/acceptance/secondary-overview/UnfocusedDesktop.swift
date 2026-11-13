import AppKit
import ApplicationServices
import Carbon.HIToolbox

// A passive return checkpoint. Only currentFocus() can establish a keyboard target.
enum OriginalDesktopReturn {
  case focused(FocusAnchor)
  case unfocused(UnfocusedMainWindow)

  static func capture() throws -> Self {
    if let focused = try? FocusAnchor() { return .focused(focused) }
    return .unfocused(try UnfocusedMainWindow())
  }

  var pid: pid_t {
    switch self {
    case .focused(let anchor): return anchor.owner.processIdentifier
    case .unfocused(let anchor): return anchor.owner.processIdentifier
    }
  }
  var number: UInt32 {
    switch self {
    case .focused(let anchor): return anchor.number
    case .unfocused(let anchor): return anchor.number
    }
  }
  var identity: [String: String] {
    let mode: String, display: String, desktop: UInt64, birth: Date
    let ax: CGRect, cg: CGRect
    switch self {
    case .focused(let anchor):
      (mode, display, desktop, birth) = ("focusedWindow", anchor.homeDisplay, anchor.homeDesktop, anchor.birth)
      (ax, cg) = (anchor.axFrame, anchor.cgFrame)
    case .unfocused(let anchor):
      (mode, display, desktop, birth) = ("unfocusedMainWindow", anchor.display, anchor.desktop, anchor.birth)
      (ax, cg) = (anchor.originalFrame, anchor.originalFrame)
    }
    return ["mode": mode, "pid": String(pid), "window": String(number), "display": display,
            "desktop": String(desktop), "birth": String(birth.timeIntervalSince1970.bitPattern),
            "axX": String(Double(ax.origin.x)), "axY": String(Double(ax.origin.y)),
            "axWidth": String(Double(ax.width)), "axHeight": String(Double(ax.height)),
            "cgX": String(Double(cg.origin.x)), "cgY": String(Double(cg.origin.y)),
            "cgWidth": String(Double(cg.width)), "cgHeight": String(Double(cg.height))]
  }
  var intact: Bool {
    switch self {
    case .focused(let anchor): return anchor.isIntact
    case .unfocused(let anchor): return anchor.intact
    }
  }
  var restored: Bool {
    switch self {
    case .focused(let anchor): return anchor.isIntact && anchor.isFocused
    case .unfocused(let anchor): return anchor.restored
    }
  }
}

struct UnfocusedMainWindow {
  let owner: NSRunningApplication
  let birth: Date
  let number: UInt32
  let display: String
  let desktop: UInt64
  private let window: AXUIElement
  let originalFrame: CGRect

  // Explicit noValue is distinct from denial, timeout, unsupported and a nil success.
  static func explicitlyEmpty(_ error: AXError, value: CFTypeRef?) -> Bool {
    error == .noValue && value == nil
  }
  private static func absent(_ element: AXUIElement, _ key: String) -> Bool {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return explicitlyEmpty(result, value: value)
  }
  private static func systemReportsNoFocus() -> Bool {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
    let system = AXUIElementCreateSystemWide()
    return absent(system, kAXFocusedApplicationAttribute) && absent(system, kAXFocusedUIElementAttribute)
  }
  private static func axElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let raw = attr(el, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
  }
  private static func mainWindow(_ owner: NSRunningApplication) -> AXUIElement? {
    let pid = owner.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    guard owner.isActive, !owner.isHidden, !owner.isTerminated,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          attr(app, kAXFrontmostAttribute) as? Bool == true, absent(app, kAXFocusedUIElementAttribute),
          let main = axElement(app, kAXMainWindowAttribute), let reported = axElement(app, kAXFocusedWindowAttribute),
          CFEqual(main, reported), attr(main, kAXRoleAttribute) as? String == kAXWindowRole,
          attr(main, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          attr(main, kAXModalAttribute) as? Bool == false, attr(main, kAXMinimizedAttribute) as? Bool == false,
          attr(main, kAXMainAttribute) as? Bool == true, attr(main, kAXFocusedAttribute) as? Bool == false,
          let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 128,
          windows.filter({CFEqual($0, main)}).count == 1 else { return nil }
    var actual: pid_t = 0
    guard AXUIElementGetPid(main, &actual) == .success, actual == pid else { return nil }
    return main
  }

  private static func visibleFrame(_ number: UInt32, _ owner: pid_t) -> CGRect? {
    guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
          rows.count == 1, let row = rows.first,
          row[kCGWindowNumber as String] as? UInt32 == number,
          row[kCGWindowOwnerPID as String] as? Int32 == owner,
          row[kCGWindowLayer as String] as? Int == 0,
          row[kCGWindowIsOnscreen as String] as? Bool == true,
          let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
  }
  private static func containingDisplay(_ rect: CGRect) -> String? {
    let candidates = NSScreen.screens.compactMap { screen -> String? in
      guard let id = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
            CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0, CGDisplayBounds(id).contains(rect),
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
      return CFUUIDCreateString(nil, uuid) as String
    }
    return candidates.count == 1 ? candidates[0] : nil
  }
  init() throws {
    guard Self.systemReportsNoFocus(), let front = NSWorkspace.shared.frontmostApplication,
          let start = front.returnAnchorBirth, let main = Self.mainWindow(front) else {
      throw Refusal("original desktop has neither exact focus nor a verified unfocused main window")
    }
    let n = NPReadAXWindowNumber(main)
    guard n > 0, let bounds = frame(main), Self.visibleFrame(n, front.processIdentifier) == bounds,
          let monitor = Self.containingDisplay(bounds), let space = FocusAnchor.currentHome(n, monitor) else {
      throw Refusal("unfocused main window geometry or active desktop is unconfirmed")
    }
    owner = front
    birth = start
    number = n
    display = monitor
    desktop = space
    window = main
    originalFrame = bounds
    guard restored else { throw Refusal("original unfocused desktop changed at enrollment") }
  }
  var intact: Bool {
    owner.returnAnchorBirth == birth && !owner.isTerminated && NPReadAXWindowNumber(window) == number
      && frame(window) == originalFrame && Self.visibleFrame(number, owner.processIdentifier) == originalFrame
      && Self.containingDisplay(originalFrame) == display && FocusAnchor.currentHome(number, display) == desktop
  }
  var restored: Bool {
    guard Self.systemReportsNoFocus(), intact, let main = Self.mainWindow(owner), CFEqual(main, window)
    else { return false }
    return Self.systemReportsNoFocus() && NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.processIdentifier
  }
}
