// This CLI retains the original window handle across the entire lifetime of its child.
// It does not create an NSWindow, activate any app or set focus.
import AppKit
import ApplicationServices
import CryptoKit

@main enum FocusReturn {
  static func record(_ values: [String: Any]) {
    var row = values
    row["at"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) {
      FileHandle.standardOutput.write(data + Data([10]))
    }
  }
  static func testSystemFocus() throws {
    // Opaque handles only. Both the AppKit query and all AX attribute reads are injected.
    let pid = getpid(), otherPID = getppid()
    let ours = AXUIElementCreateApplication(pid), other = AXUIElementCreateApplication(otherPID)
    let system = AXUIElementCreateSystemWide()
    func sample(_ front: [pid_t], _ apps: [AXUIElement], window: AXUIElement?) -> (pid_t, AXUIElement)? {
      var fronts = front.makeIterator(), focusedApps = apps.makeIterator()
      return try? currentFocus(frontmostPID: { fronts.next() }, read: { receiver, name in
        if name == kAXFocusedApplicationAttribute && CFEqual(system, receiver) {
          return focusedApps.next()
        }
        if name == kAXFocusedWindowAttribute && CFEqual(ours, receiver) {
          return window
        }
        return nil
      })
    }
    let matched = sample([pid, pid], [ours, ours], window: ours)
    let cases = [
      ("matched system focus", matched.map { $0.0 == pid && CFEqual($0.1, ours) } == true),
      ("frontmost disagrees", sample([otherPID, otherPID], [ours, ours], window: ours) == nil),
      ("frontmost changed", sample([pid, otherPID], [ours, ours], window: ours) == nil),
      ("system application changed", sample([pid, pid], [ours, other], window: ours) == nil),
      ("no system focus", sample([pid, pid], [], window: ours) == nil),
      ("system focus disappeared", sample([pid, pid], [ours], window: ours) == nil),
      ("no focused window", sample([pid, pid], [ours, ours], window: nil) == nil),
      ("window belongs to another process", sample([pid, pid], [ours, ours], window: other) == nil),
    ]
    for (label, passed) in cases where !passed { throw Refusal("system focus self-test: " + label) }
    print("\(cases.count) system focus identity cases passed")
  }
  static func main() {
    if CommandLine.arguments.dropFirst().elementsEqual(["--self-test"]) {
      let cases: [(Bool, Bool, Bool, OrderedFocus)] = [
        (true, false, false, .original), (false, true, true, .owned),
        (false, false, true, .refused),
        (false, true, false, .refused), (false, false, false, .refused),
        (true, true, true, .refused),
      ]
      guard
        cases.allSatisfy({
          orderedFocus(original: $0.0, ownedElement: $0.1, ownedKey: $0.2) == $0.3
        })
      else { exit(2) }
      print("6 ordered focus ownership cases passed")
      return
    }
    if CommandLine.arguments.dropFirst().elementsEqual(["--test-return-desktop"]) {
      let primary: [String: Any] = ["Display Identifier":"primary", "Current Space":["id64":1309],
                                    "Spaces":[["id64":1130,"type":0],["id64":1309,"type":0]]]
      let side: [String: Any] = ["Display Identifier":"secondary", "Current Space":["id64":4568],
                                 "Spaces":[["id64":4568,"type":0]]]
      let invalid: [[String: Any]] = [
        ["Display Identifier":"primary", "Current Space":["id64":1309], "Spaces":[["id64":1309,"type":4]]],
        ["Display Identifier":"primary", "Current Space":["id64":1309], "Spaces":[]],
        ["Display Identifier":"primary", "Current Space":["id64":1309], "Spaces":[["id64":1309,"type":0],["id64":1309,"type":0]]]
      ]
      let scopes = [primary, side]
      guard FocusAnchor.homeDesktopID(in: scopes, display: "primary", memberships: [1309]) == 1309,
            FocusAnchor.homeDesktopID(in: scopes, display: "secondary", memberships: [4568]) == 4568,
            [[], [1130], [4568], [1130,1309], [1309,1309]].allSatisfy({
              FocusAnchor.homeDesktopID(in: scopes, display: "primary", memberships: $0) == nil
            }), (invalid.map { [$0] } + [[side], [primary, primary]]).allSatisfy({
              FocusAnchor.homeDesktopID(in: $0, display: "primary", memberships: [1309]) == nil
            }) else { exit(2) }
      print("12 original focus desktop membership cases passed")
      return
    }
    do {
      if CommandLine.arguments.dropFirst().elementsEqual(["--test-unfocused-return"]) {
        let errors: [AXError] = [.success, .noValue, .cannotComplete, .attributeUnsupported,
                                 .apiDisabled, .invalidUIElement, .illegalArgument]
        for error in errors {
          guard UnfocusedMainWindow.explicitlyEmpty(error, value:nil) == (error == .noValue),
                !UnfocusedMainWindow.explicitlyEmpty(error, value:NSNumber(value:true)) else {
            throw Refusal("unfocused desktop accepted an ambiguous AX result")
          }
        }
        print("\(errors.count * 2) explicit AX absence cases passed")
        return
      }
      if CommandLine.arguments.dropFirst().elementsEqual(["--check-desktop-return"]) {
        guard AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1 else {
          throw Refusal("read-only AX or desktop information unavailable")
        }
        let original = try OriginalDesktopReturn.capture()
        RunLoop.current.run(until: Date(timeIntervalSinceNow:0.20))
        guard original.intact && original.restored else { throw Refusal("desktop return state changed during sampling") }
        record(["event":"desktopReturnState", "identity":original.identity, "restored":true, "systemInputs":0])
        return
      }
      if CommandLine.arguments.dropFirst().elementsEqual(["--test-system-focus"]) {
        try testSystemFocus()
        return
      }
      if CommandLine.arguments.dropFirst().elementsEqual(["--check-focus-home"]) {
        guard AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1 else {
          throw Refusal("read-only focus or desktop information unavailable")
        }
        let anchor = try FocusAnchor()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard anchor.isFocused && anchor.isIntact else {
          throw Refusal("original focus changed during desktop confirmation")
        }
        record(["event":"focusHome", "pid":anchor.owner.processIdentifier,
                "window":anchor.number, "birth":String(anchor.birth.timeIntervalSince1970.bitPattern),
                "display":anchor.homeDisplay, "desktop":String(anchor.homeDesktop)])
        return
      }
      try run()
    } catch {
      record([
        "event": "externalRefusal",
        "reason": (error as? Refusal)?.reason ?? String(describing: error),
      ])
      exit(2)
    }
  }
  static func run() throws {
    let supplied = Array(CommandLine.arguments.dropFirst())
    let currentDisplay = supplied.first == "--current-display"
    let args = Array(supplied.dropFirst(currentDisplay ? 1 : 0))
    guard args.count >= 4, let display = UUID(uuidString: args[0]),
      let from = ISO8601DateFormatter().date(from: args[2]),
      let until = ISO8601DateFormatter().date(from: args[3]),
      from <= Date(), until.timeIntervalSinceNow > 30, until.timeIntervalSince(from) <= 900
    else { throw Refusal("missing current timed grant") }
    let kit = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .resolvingSymlinksInPath().deletingLastPathComponent()
    let name = "Nearpane Secondary Overview.app/Contents/MacOS/Overview"
    let exe = kit.appendingPathComponent(name)
    let bytes = try Data(contentsOf: exe)
    let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let lines = try String(contentsOf: kit.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
      .components(separatedBy: .newlines)
    guard lines.filter({ $0 == sha + "  " + name }).count == 1 else {
      throw Refusal("frozen fixture fingerprint missing")
    }
    let app = NSApplication.shared
    guard app.activationPolicy() == .prohibited || app.setActivationPolicy(.prohibited),
      AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1,
      try observe(display, currentDisplay:currentDisplay)["state"] as? String == "overviewNotExposed"
    else { throw Refusal("read-only external observer unavailable") }
    // The system approval panel or a person can still be using the pointer when this CLI starts.
    // Wait before opening any test window, and give up without taking focus on a busy console.
    let idleDeadline = min(ProcessInfo.processInfo.systemUptime + 16,
                            ProcessInfo.processInfo.systemUptime + until.timeIntervalSinceNow - 35)
    let events: [CGEventType] = [.mouseMoved,.leftMouseDown,.rightMouseDown,.leftMouseDragged,.keyDown]
    func quiet() -> Bool {
      NSEvent.pressedMouseButtons == 0 && events.allSatisfy {
        CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) >= 4
      }
    }
    while !quiet() && ProcessInfo.processInfo.systemUptime < idleDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
    }
    guard quiet() else { throw Refusal("physical input still active; fixture not launched") }
    let anchor = try FocusAnchor()
    let env = ProcessInfo.processInfo.environment
    if let parentPID = env["NEARPANE_SESSION_BOUND_PID"] {
      guard String(anchor.owner.processIdentifier) == parentPID,
            env["NEARPANE_SESSION_BOUND_WINDOW"] == String(anchor.number),
            env["NEARPANE_SESSION_BOUND_BIRTH"] == String(anchor.birth.timeIntervalSince1970.bitPattern),
            env["NEARPANE_SESSION_BOUND_DESKTOP"] == String(anchor.homeDesktop),
            env["NEARPANE_SESSION_BOUND_DISPLAY"] == anchor.homeDisplay,
            display.uuidString == anchor.homeDisplay,
            let run = env["NEARPANE_SESSION_BOUND_RUN"], UUID(uuidString: run) != nil,
            attr(anchor.element, kAXIdentifierAttribute) as? String == run
      else { throw Refusal("focus no longer belongs to the enrolled secondary session window") }
    }
    if args.count == 6 && args[4] == "create", let window = env["NEARPANE_REHEARSED_WINDOW"] {
      guard UInt32(window) == anchor.number, Int32(env["NEARPANE_REHEARSED_PID"] ?? "") == anchor.owner.processIdentifier,
            Double(env["NEARPANE_REHEARSED_BIRTH"] ?? "") == anchor.birth.timeIntervalSince1970
      else { throw Refusal("original window or process changed after the overview rehearsal") }
    }
    let uuid = UUID().uuidString
    record([
      "event": "externalFocusArmed", "observer": getpid(), "run": uuid,
      "originalPID": anchor.owner.processIdentifier,
      "originalWindow": anchor.number, "originalProcessStart": anchor.birth.timeIntervalSince1970,
      "originalDisplay": anchor.homeDisplay, "originalDesktop": String(anchor.homeDesktop),
      "fixtureSHA256": sha,
    ])
    let child = Process()
    child.executableURL = exe
    child.arguments = supplied
    child.standardInput = FileHandle.nullDevice
    var childEnvironment = env
    for (k, v) in anchor.environment { childEnvironment[k] = v }
    childEnvironment["NEARPANE_RETURN_RUN"] = uuid
    childEnvironment["NEARPANE_RETURN_OBSERVER"] = String(getpid())
    child.environment = childEnvironment
    guard anchor.isIntact && anchor.isFocused else {
      throw Refusal("original focus changed before fixture launch")
    }
    try child.run()
    let deadline = ProcessInfo.processInfo.systemUptime + until.timeIntervalSinceNow
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
    }
    if child.isRunning {
      child.terminate()
      let cleanupEnd = ProcessInfo.processInfo.systemUptime + 2
      while child.isRunning && ProcessInfo.processInfo.systemUptime < cleanupEnd {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
      }
      guard !child.isRunning else { throw Refusal("fixture exit unconfirmed at deadline") }
    }
    child.waitUntilExit()
    let cutoff = ProcessInfo.processInfo.systemUptime + 2.5
    var first: Double?
    var stable = false
    repeat {
      let now = ProcessInfo.processInfo.systemUptime
      if anchor.isIntact && anchor.isFocused {
        if let first, now - first >= 0.15 {
          stable = true
          break
        }
        if first == nil { first = now }
      } else {
        first = nil
      }
      // AppKit can refresh running-application state between stable focus samples.
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < cutoff
    record([
      "event": "externalAfterExit", "observer": getpid(), "run": uuid,
      "childPID": child.processIdentifier,
      "childExited": !child.isRunning, "childStatus": child.terminationStatus,
      "originalPID": anchor.owner.processIdentifier,
      "originalWindow": anchor.number, "originalIdentityAndGeometry": anchor.isIntact,
      "sameAXObjectFocusedAfterExit": stable,
    ])
    guard stable else { throw Refusal("original focus not verified after fixture exit") }
    guard child.terminationReason == .exit && child.terminationStatus == 0 else {
      throw Refusal("original focus returned; fixture did not complete its operation")
    }
  }
}
