import AppKit
import ApplicationServices

func currentFocus(
  frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
  read: (AXUIElement, String) -> CFTypeRef? = attr
) throws -> (pid_t, AXUIElement) {
  guard let pid = frontmostPID(),
    let systemApp = read(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
    CFGetTypeID(systemApp) == AXUIElementGetTypeID()
  else { throw Refusal("system keyboard focus unavailable") }
  let app = systemApp as! AXUIElement
  var appPID: pid_t = 0
  guard AXUIElementGetPid(app, &appPID) == .success, appPID == pid else {
    throw Refusal("system keyboard focus and frontmost application disagree")
  }
  guard let value = read(app, kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { throw Refusal("no exact AX focus") }
  let element = value as! AXUIElement
  var owner: pid_t = 0
  guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
        let finalApp = read(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
        CFEqual(finalApp, app), frontmostPID() == pid else {
    throw Refusal("focus owner conflict")
  }
  return (pid, element)
}

func frame(_ el: AXUIElement) -> CGRect? {
  guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
    CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
  else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
    AXValueGetValue(s as! AXValue, .cgSize, &size),
    point.x.isFinite && point.y.isFinite && size.width.isFinite && size.height.isFinite
      && size.width > 0 && size.height > 0
  else { return nil }
  return CGRect(origin: point, size: size)
}

struct FocusAnchor {
  let owner: NSRunningApplication
  let birth: Date
  let element: AXUIElement
  let number: UInt32
  let axFrame: CGRect
  let cgFrame: CGRect
  let homeDisplay: String
  let homeDesktop: UInt64

  init() throws {
    let (pid, focused) = try currentFocus()
    let number = NPReadAXWindowNumber(focused)
    guard number > 0, let owner = NSRunningApplication(processIdentifier: pid),
      let birth = owner.launchDate,
      attr(focused, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
      attr(focused, kAXMinimizedAttribute) as? Bool == false,
      let ax = frame(focused), let cg = Self.geometry(number, pid)
    else { throw Refusal("no stable ordinary AX/CG return anchor") }
    self.owner = owner
    self.birth = birth
    element = focused
    self.number = number
    axFrame = ax
    cgFrame = cg
    let screens = NSScreen.screens.compactMap { screen -> String? in
      guard let display = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
            CGDisplayIsInMirrorSet(display) == 0, CGDisplayBounds(display).contains(ax),
            CGDisplayBounds(display).contains(cg),
            let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
      return CFUUIDCreateString(nil, uuid) as String
    }
    guard screens.count == 1, let display = screens.first,
          let desktop = Self.currentHome(number, display) else {
      throw Refusal("original focused window is not proven on its display's current ordinary desktop")
    }
    homeDisplay = display
    homeDesktop = desktop
    guard isIntact && isFocused else { throw Refusal("original focus changed at enrollment") }
  }

  static func currentHome(_ number: UInt32, _ display: String) -> UInt64? {
    guard let scopes = NPReadInventory() as? [[String: Any]],
          let memberships = NPReadWindowSpaces(number) as? [NSNumber] else { return nil }
    return homeDesktopID(in: scopes, display: display, memberships: memberships)
  }

  static func homeDesktopID(in scopes: [[String: Any]], display: String, memberships: [NSNumber]) -> UInt64? {
    let matched = scopes.filter { $0["Display Identifier"] as? String == display }
    guard matched.count == 1, let scope = matched.first,
          let current = (scope["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
          current.uint64Value > 0, current.stringValue == String(current.uint64Value),
          memberships == [current], let records = scope["Spaces"] as? [[String: Any]] else { return nil }
    let recordsForCurrent = records.filter { $0["id64"] as? NSNumber == current }
    guard recordsForCurrent.count == 1, recordsForCurrent[0]["type"] as? Int == 0 else { return nil }
    return current.uint64Value
  }

  static func geometry(_ number: UInt32, _ pid: pid_t) -> CGRect? {
    guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
      rows.count == 1, let row = rows.first,
      row[kCGWindowNumber as String] as? UInt32 == number,
      row[kCGWindowOwnerPID as String] as? Int32 == pid,
      let bounds = row[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
  }

  var logicalFrameIntact: Bool {
    !owner.isTerminated && owner.launchDate == birth && NPReadAXWindowNumber(element) == number
      && frame(element) == axFrame && Self.currentHome(number, homeDisplay) == homeDesktop
  }
  var isIntact: Bool {
    logicalFrameIntact && Self.geometry(number, owner.processIdentifier) == cgFrame
  }
  var isFocused: Bool {
    guard let (pid, focused) = try? currentFocus() else { return false }
    return pid == owner.processIdentifier && CFEqual(focused, element)
      && NPReadAXWindowNumber(focused) == number
  }
  var environment: [String: String] {
    [
      "NEARPANE_RETURN_PID": String(owner.processIdentifier),
      "NEARPANE_RETURN_BIRTH": String(birth.timeIntervalSince1970.bitPattern),
      "NEARPANE_RETURN_WINDOW": String(number),
      "NEARPANE_RETURN_DISPLAY": homeDisplay,
      "NEARPANE_RETURN_DESKTOP": String(homeDesktop),
    ]
  }
}

// Called only after the fixture passed a unique AX/object, CG/frame and Space membership check.
enum OrderedFocus { case original, owned, refused }
func orderedFocus(original: Bool, ownedElement: Bool, ownedKey: Bool) -> OrderedFocus {
  if original && !ownedElement { return .original }
  if ownedElement && ownedKey && !original { return .owned }
  return .refused
}
