import AppKit
import ApplicationServices

func currentFocus() throws -> (pid_t, AXUIElement) {
  guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    let value = attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { throw Refusal("no exact AX focus") }
  let element = value as! AXUIElement
  var owner: pid_t = 0
  guard AXUIElementGetPid(element, &owner) == .success && owner == pid else {
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
    guard isIntact && isFocused else { throw Refusal("original focus changed at enrollment") }
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
      && frame(element) == axFrame
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
