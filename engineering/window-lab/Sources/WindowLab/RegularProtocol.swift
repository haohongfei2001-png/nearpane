import AppKit
import NearpaneCore

package struct RegularEnrollment: Codable, Equatable {
  package let session: UUID, controller: ProcessBirth, screens: Screens, deadline: Double,
    front: Int32
  package init(
    session: UUID, controller: ProcessBirth, screens: Screens, deadline: Double, front: Int32
  ) {
    self.session = session
    self.controller = controller
    self.screens = screens
    self.deadline = deadline
    self.front = front
  }
}
package struct RegularWindow: Codable {
  package let token: String, number: UInt32, frame: SurfaceRect, mini: Bool, key: Bool, main: Bool,
    buttonEnabled: Bool
  package let style: UInt
  @MainActor package init(_ w: NSWindow, token: String, primaryTop: Double) {
    self.token = token
    number = UInt32(w.windowNumber)
    mini = w.isMiniaturized
    key = w.isKeyWindow
    main = w.isMainWindow
    style = w.styleMask.rawValue
    buttonEnabled = w.standardWindowButton(.miniaturizeButton)?.isEnabled == true
    frame = .init(
      x: w.frame.minX, y: primaryTop - w.frame.maxY, width: w.frame.width, height: w.frame.height)
  }
}
package struct RegularHeartbeat: Codable {
  package let session: UUID, owner: ProcessBirth, stamp: Double, sequence: Int, active: Bool,
    regular: Bool
  package let focusEvents: Int, windows: [RegularWindow]
  @MainActor package init(
    run: RegularEnrollment, owner: ProcessBirth, sequence: Int, focusEvents: Int,
    windows: [RegularWindow]
  ) {
    session = run.session
    self.owner = owner
    stamp = ProcessInfo.processInfo.systemUptime
    self.sequence = sequence
    active = NSApp.isActive
    regular = NSRunningApplication.current.activationPolicy == .regular
    self.focusEvents = focusEvents
    self.windows = windows
  }
}
package struct RegularCommand: Codable {
  package let session: UUID, seq: Int, action: String, token: String
  package init(_ session: UUID, _ seq: Int, _ action: String, _ token: String) {
    self.session = session
    self.seq = seq
    self.action = action
    self.token = token
  }
}
package func labAttribute(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
  var result: CFTypeRef?
  return AXUIElementCopyAttributeValue(el, key as CFString, &result) == .success ? result : nil
}
