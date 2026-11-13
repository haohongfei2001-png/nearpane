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
    do { try run() } catch {
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
      Thread.sleep(forTimeInterval:0.12)
    }
    guard quiet() else { throw Refusal("physical input still active; fixture not launched") }
    let anchor = try FocusAnchor()
    let env = ProcessInfo.processInfo.environment
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
      Thread.sleep(forTimeInterval: 0.08)
    }
    if child.isRunning {
      child.terminate()
      let cleanupEnd = ProcessInfo.processInfo.systemUptime + 2
      while child.isRunning && ProcessInfo.processInfo.systemUptime < cleanupEnd {
        Thread.sleep(forTimeInterval: 0.05)
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
      Thread.sleep(forTimeInterval: 0.05)
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
