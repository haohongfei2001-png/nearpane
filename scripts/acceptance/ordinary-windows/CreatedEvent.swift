import AppKit
import ApplicationServices
import CReadOnlySpaces
import Foundation
import NearpaneCore

// Compile the same CreatedWindowWatch, SystemEvidence and OwnerIdentity used by the installed worker.
// This fixture reads only its own parent process; it has no AX window-writing code.
func executablePath(_ pid: pid_t) -> URL? {
  var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
  guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
  return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
}

final class Small: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
final class Events {
  var elements: [AXUIElement] = []
}
func cg(_ n: UInt32, owner: pid_t) -> Bool {
  guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, n) as? [[String: Any]],
    rows.count == 1,
    let r = rows.first
  else { return false }
  return (r[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner
    && (r[kCGWindowNumber as String] as? NSNumber)?.uint32Value == n
    && (r[kCGWindowIsOnscreen as String] as? Bool) == true
    && (r[kCGWindowLayer as String] as? Int) == 0
}
func child() throws {
  let a = CommandLine.arguments
  guard a.count == 6, let parent = Int32(a[2]), let prior = UInt32(a[3]),
    let expectedLaunch = UInt64(a[5])
  else { throw Refusal("fixture-arguments") }
  guard parent > 1, parent == getppid() else { throw Refusal("not-an-immediate-test-parent") }
  let ownerImage = try OrdinaryProcessImage.read(parent)
  let childImage = try OrdinaryProcessImage.read(getpid())
  guard ownerImage.launch == expectedLaunch, expectedLaunch > 0, childImage.launch >= expectedLaunch
  else {
    throw Refusal("bsd-process-generation")
  }
  guard ownerImage.executable == childImage.executable,
    ownerImage.device == childImage.device, ownerImage.inode == childImage.inode
  else { throw Refusal("different-process-images") }
  let seal = try OrdinaryProcessImage.signingDigest(parent)
  guard try seal == OrdinaryProcessImage.signingDigest(getpid()) else {
    throw Refusal("different-signing-digests")
  }
  let appURL = ownerImage.executable.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  guard let packaged = Bundle(url: appURL),
    packaged.bundleIdentifier == "org.nearpane.acceptance.NewWindowEvent",
    packaged.executableURL?.resolvingSymlinksInPath() == ownerImage.executable
  else { throw Refusal("unrecognized-signed-test-bundle") }
  do {
    guard try ownerImage == OrdinaryProcessImage.read(parent),
      try childImage == OrdinaryProcessImage.read(getpid()),
      parent == getppid()
    else { throw Refusal("changed-before-subscription") }
  }
  guard AXIsProcessTrusted() else { throw Refusal("existing-AX-access-unavailable") }
  guard cg(prior, owner: parent) else { throw Refusal("anchor-CG-id-owner-layer-onscreen") }
  let hand = URL(fileURLWithPath: a[4], isDirectory: true)
  guard hand.standardizedFileURL.path == hand.resolvingSymlinksInPath().path,
    UUID(uuidString: hand.lastPathComponent) != nil,
    hand.deletingLastPathComponent().path
      == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
  else { throw Refusal("handshake-directory-identity") }
  let events = Events()
  let app = AXUIElementCreateApplication(parent)
  var observer: AXObserver?
  let callback: AXObserverCallback = { _, element, name, p in
    if let p, name as String == kAXWindowCreatedNotification {
      Unmanaged<Events>.fromOpaque(p).takeUnretainedValue().elements.append(element)
    }
  }
  let created = AXObserverCreate(parent, callback, &observer)
  guard created == .success, let observer else {
    throw Refusal("AXObserverCreate " + String(created.rawValue))
  }
  let installed = AXObserverAddNotification(
    observer, app, kAXWindowCreatedNotification as CFString,
    Unmanaged.passUnretained(events).toOpaque())
  guard installed == .success else {
    throw Refusal("AXObserverAddNotification " + String(installed.rawValue))
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
  defer {
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
  }
  let base = try windows(parent)
  guard base.count == 1, number(base[0]) == prior else {
    throw Refusal("anchor must be uniquely visible before subscribing")
  }
  let anchor = ManagedWindowID(
    pid: parent, launch: ownerImage.launch, number: prior, element: UUID())
  let watch = try CreatedWindowWatch(anchor: anchor, grant: UUID())
  let oldAbsent = try watch.take() == nil
  try Data().write(to: hand.appendingPathComponent("armed"), options: .withoutOverwriting)
  var got = [UInt32]()
  let end = ProcessInfo.processInfo.systemUptime + 2
  while ProcessInfo.processInfo.systemUptime < end {
    CFRunLoopRunInMode(.defaultMode, 0.03, false)
    if let (_, n) = try watch.take() { got.append(n) }
  }
  let final = try windows(parent)
  let raw = events.elements.compactMap(number)
  let matches = events.elements.filter { e in
    final.filter { CFEqual($0, e) && number($0) == number(e) }.count == 1
  }.compactMap(number)
  let ids = final.compactMap(number)
  guard try ownerImage == OrdinaryProcessImage.read(parent),
    try seal == OrdinaryProcessImage.signingDigest(parent),
    try childImage == OrdinaryProcessImage.read(getpid()), parent == getppid()
  else { throw Refusal("changed-after-subscription") }
  let result: [String: Any] = [
    "parentProcessImageAndUIDStable": true, "sameSignedExecutableAndInode": true,
    "parentLaunchMicroseconds": ownerImage.launch, "childLaunchMicroseconds": childImage.launch,
    "existingAX": base.compactMap(number), "registered": true, "oldAbsentBeforeCreation": oldAbsent,
    "rawAXWindowCreatedIDs": raw, "rawEventCount": events.elements.count,
    "rawObjectsMatchingFinalAXByEqualityAndID": matches,
    "productionWatchTakenIDs": got, "finalAX": ids,
    "independentCGVisible": ids.filter { cg($0, owner: parent) }, "AXWrites": 0,
  ]
  try JSONSerialization.data(withJSONObject: result).write(
    to: hand.appendingPathComponent("result"), options: .atomic)
}
@MainActor final class D: NSObject, NSApplicationDelegate {
  let front: pid_t
  init(_ front: pid_t) { self.front = front }
  func applicationDidFinishLaunching(_ n: Notification) {
    Task {
      await run()
      exit(0)
    }
  }
  func run() async {
    var proof = [String: Any]()
    var owned = [Small]()
    var changed = false
    let center = NSWorkspace.shared.notificationCenter
    let obs = center.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { n in
      if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.processIdentifier != self.front
      {
        changed = true
      }
    }
    func focusOK() -> Bool {
      !changed && !NSApp.isActive
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == front
        && !owned.contains { $0.isKeyWindow || $0.isMainWindow }
    }
    let hand = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let process = Process()
    defer {
      for w in owned {
        w.orderOut(nil)
        w.close()
      }
      proof["focusReturned"] = focusOK()
      proof["ownerResidual"] = owned.filter(\.isVisible).count
      proof["AXWrites"] = 0
      proof["externalChildExited"] = !process.isRunning
      center.removeObserver(obs)
      try? FileManager.default.removeItem(at: hand)
      if let bytes = try? JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]) {
        print(String(decoding: bytes, as: UTF8.self))
      }
    }
    do {
      guard let state = CGSessionCopyCurrentDictionary() as? [String: Any],
        state[kCGSessionOnConsoleKey as String] as? Bool == true,
        state["CGSSessionScreenIsLocked"] as? Bool != true,
        let screen = NSScreen.screens.last, focusOK(), NSApp.activationPolicy() == .accessory,
        AXIsProcessTrusted()
      else { throw Refusal("initial-focus/console/permission") }
      try FileManager.default.createDirectory(
        at: hand, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      func order(_ index: Int) throws -> UInt32 {
        guard focusOK() else { throw Refusal("focus-before-order") }
        let b = screen.visibleFrame
        let w = Small(
          contentRect: CGRect(
            x: b.minX + 8 + CGFloat(index * 124), y: b.minY + 8, width: 120, height: 72),
          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.title = "Nearpane synthetic"
        owned.append(w)
        guard b.contains(w.frame) else { throw Refusal("does-not-fit") }
        w.orderBack(nil)
        w.display()
        guard focusOK(), let n = UInt32(exactly: w.windowNumber), n > 0 else {
          throw Refusal("ordered-focus-or-number")
        }
        return n
      }
      let first = try order(0)
      proof["old"] = first
      try await Task.sleep(for: .milliseconds(200))
      guard focusOK(), cg(first, owner: getpid()) else { throw Refusal("CG-before-watch") }
      process.executableURL = Bundle.main.executableURL
      process.arguments = [
        "--watch", String(getpid()), String(first), hand.path,
        String(try OrdinaryProcessImage.read(getpid()).launch),
      ]
      try process.run()
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while process.isRunning
        && !FileManager.default.fileExists(atPath: hand.appendingPathComponent("armed").path)
        && focusOK() && ProcessInfo.processInfo.systemUptime < deadline
      { try await Task.sleep(for: .milliseconds(25)) }
      guard process.isRunning,
        FileManager.default.fileExists(atPath: hand.appendingPathComponent("armed").path), focusOK()
      else { throw Refusal("child-not-armed") }
      let second = try order(1)
      proof["new"] = second
      let end = ProcessInfo.processInfo.systemUptime + 3
      while process.isRunning && focusOK() && ProcessInfo.processInfo.systemUptime < end {
        try await Task.sleep(for: .milliseconds(30))
      }
      guard !process.isRunning, process.terminationStatus == 0, focusOK() else {
        throw Refusal("child-result-or-focus")
      }
      let read =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: hand.appendingPathComponent("result"))) as! [String: Any]
      proof["external"] = read
      proof["productionEventExact"] =
        read["productionWatchTakenIDs"] as? [UInt32] == [second]
        && read["rawObjectsMatchingFinalAXByEqualityAndID"] as? [UInt32] == [second]
    } catch {
      proof["stopped"] = (error as? Refusal)?.message ?? error.localizedDescription
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
  }
}
@main struct Main {
  @MainActor static func main() {
    if CommandLine.arguments.dropFirst().first == "--watch" {
      do {
        try child()
        return
      } catch {
        fputs((error as? Refusal)?.message ?? "observer refused", stderr)
        exit(3)
      }
    }
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front > 1,
      front != getpid()
    else { exit(2) }
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)
    let d = D(front)
    app.delegate = d
    withExtendedLifetime(d) { app.run() }
  }
}
