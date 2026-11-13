import AppKit
import ApplicationServices

// Retains the outer window only to detect changes. It is never an input target.
struct ProtectedReturnWindow {
  private let owner: NSRunningApplication
  private let birth: UInt64
  private let number: UInt32
  private let element: AXUIElement
  private let display: CGDirectDisplayID
  private let displayUUID: String
  private let screen: CGRect
  private let desktop: UInt64
  private let axFrame, cgFrame: CGRect

  private static func rect(_ fields: [String: String], _ prefix: String) -> CGRect? {
    let values = ["X", "Y", "Width", "Height"].compactMap { fields[prefix + $0].flatMap(Double.init) }
    guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }

  private static func mainUUID(_ display: CGDirectDisplayID) -> String? {
    guard display == CGMainDisplayID(), CGDisplayIsActive(display) != 0, CGDisplayIsInMirrorSet(display) == 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  static func fromEnvironment(_ env: [String: String]) throws -> Self? {
    let original = env["NEARPANE_SESSION_BOUND_ORIGINAL"]
    guard let parent = env["NEARPANE_SESSION_BOUND_PID"] else {
      guard original == nil else { throw Refusal("unbound original window record") }
      return nil
    }
    guard let parentPID = pid_t(parent), parentPID > 1, let original, original.utf8.count <= 4096,
          let fields = try? JSONDecoder().decode([String: String].self, from: Data(original.utf8)),
          let mode = fields["mode"], ["focusedWindow", "unfocusedMainWindow"].contains(mode),
          let pid = fields["pid"].flatMap(pid_t.init), pid > 1, pid != parentPID,
          let birth = fields["birth"].flatMap(UInt64.init), let number = fields["window"].flatMap(UInt32.init), number > 0,
          let uuid = fields["display"], let desktop = fields["desktop"].flatMap(UInt64.init), desktop > 0,
          let ax = rect(fields, "ax"), let cg = rect(fields, "cg"),
          mode != "unfocusedMainWindow" || ax == cg else { throw Refusal("invalid original window baseline") }
    let display = CGMainDisplayID(), bounds = CGDisplayBounds(display)
    guard mainUUID(display) == uuid, bounds.contains(ax), bounds.contains(cg),
          let owner = NSRunningApplication(processIdentifier: pid), !owner.isTerminated,
          owner.returnAnchorBirth?.timeIntervalSince1970.bitPattern == birth,
          let windows = attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement],
          windows.count <= 128 else { throw Refusal("original window process or display changed") }
    let candidates = windows.filter { NPReadAXWindowNumber($0) == number }
    guard candidates.count == 1, let element = candidates.first else { throw Refusal("original window no longer unique") }
    let bound = Self(owner: owner, birth: birth, number: number, element: element, display: display, displayUUID: uuid,
                     screen: bounds, desktop: desktop, axFrame: ax, cgFrame: cg)
    guard bound.intact(overview: false) else { throw Refusal("original window changed since session enrollment") }
    return bound
  }

  func intact(overview: Bool) -> Bool {
    var pid: pid_t = 0
    guard !owner.isTerminated, owner.returnAnchorBirth?.timeIntervalSince1970.bitPattern == birth,
          Self.mainUUID(display) == displayUUID, CGDisplayBounds(display) == screen,
          AXUIElementGetPid(element, &pid) == .success, pid == owner.processIdentifier,
          NPReadAXWindowNumber(element) == number,
          attr(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          attr(element, kAXMinimizedAttribute) as? Bool == false, frame(element) == axFrame,
          FocusAnchor.currentHome(number, displayUUID) == desktop,
          let actual = FocusAnchor.geometry(number, pid), actual.size.width > 0, actual.size.height > 0,
          !actual.isInfinite, !actual.isNull, screen.contains(actual) else { return false }
    return actual == cgFrame || overview
  }
}
