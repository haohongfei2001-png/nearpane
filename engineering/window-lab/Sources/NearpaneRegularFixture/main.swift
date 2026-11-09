import AppKit
import WindowLab

// A regular Dock app, without a delegate that opens untargeted windows on launch/reopen.
@MainActor final class RegularOwner {
  let dir: URL, run: RegularEnrollment, owner: ProcessBirth
  var owned: [(String, NSWindow)] = [], seq = 0, events = 0
  init(_ directory: URL) throws {
    dir = directory
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    try require(
      dir.standardizedFileURL.path == dir.resolvingSymlinksInPath().standardizedFileURL.path
        && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "invalid private enrollment")
    run = try readJSON(dir, "enrollment.json")
    owner = try .read(getpid())
    try verifySiblingCode(run.controller, name: "NearpaneFrameController")
    try guardScope()
  }
  func guardScope() throws {
    let now = ProcessInfo.processInfo.systemUptime
    try require(
      now < run.deadline && run.deadline - now <= 120
        && run.controller == (try ProcessBirth.read(run.controller.pid))
        && (try Screens.read().0) == run.screens
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == run.front
        && NSApp.activationPolicy() == .regular && !NSApp.isActive && events == 0,
      "regular owner focus, session or display changed")
  }
  func newWindow() throws {
    let (_, screen) = try Screens.read()
    let i = owned.count
    let safe = screen.visibleFrame
    let frame = CGRect(
      x: safe.minX + 40, y: safe.minY + 60 + Double(i) * 210, width: 260 + Double(i) * 16,
      height: 160)
    try require(i < 3 && safe.contains(frame), "window outside secondary")
    let w = NSWindow(
      contentRect: .init(origin: .zero, size: frame.size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true,
      screen: screen)
    // Keep the subject a normal document. A second independent, equally
    // miniaturizable settings-style window must not displace it in Stage Manager.
    w.collectionBehavior = i == 0 ? [.primary] : [.auxiliary]
    w.isRestorable = false
    w.isReleasedWhenClosed = false
    w.ignoresMouseEvents = true
    w.setFrame(frame, display: false)
    w.title = "Nearpane regular fixture W\(i+1)"
    w.contentView = NSTextField(labelWithString: "Synthetic window \(i+1)")
    let token = run.session.uuidString + "/" + UUID().uuidString
    w.setAccessibilityIdentifier(token)
    try guardScope()
    try require(w.frame == frame && screen.visibleFrame.contains(w.frame), "unsafe start frame")
    owned.append((token, w))
    w.orderFrontRegardless()
  }
  func tick() throws {
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("stop").path) { finish(0) }
    try guardScope()
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("command.json").path) {
      let c: RegularCommand = try readJSON(dir, "command.json")
      if c.seq != seq {
        try require(c.session == run.session && c.seq == seq + 1, "stale command")
        if c.action == "enroll" {
          try newWindow()
        } else {
          guard let (token, w) = owned.first, c.token == token,
            w.screen == NSScreen.screens[1] || w.isMiniaturized
          else { throw Refusal("wrong owner target") }
          if c.action == "mini" && !w.isMiniaturized {
            w.miniaturize(nil)
          } else if c.action == "restore" && w.isMiniaturized {
            w.deminiaturize(nil)
          } else {
            throw Refusal("invalid baseline action")
          }
        }
        seq = c.seq
      }
    }
    let windows = owned.map {
      RegularWindow($0.1, token: $0.0, primaryTop: NSScreen.screens[0].frame.maxY)
    }
    try writeJSON(
      RegularHeartbeat(
        run: run, owner: owner, sequence: seq, focusEvents: events, windows: windows), dir,
      "heartbeat.json")
    try require(!windows.contains { $0.key || $0.main }, "test window took focus")
  }
  func finish(_ status: Int32) -> Never {
    for (_, w) in owned {
      w.orderOut(nil)
      w.close()
    }
    exit(status)
  }
}
do {
  guard let index = CommandLine.arguments.firstIndex(of: "--regular-study"),
    index + 1 < CommandLine.arguments.count,
    Bundle.main.bundleIdentifier == "org.nearpane.lab.NearpaneRegularFixture",
    Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == false
  else { throw Refusal("no regular fixture enrollment") }
  let app = NSApplication.shared
  let o = try RegularOwner(
    URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
  for name in [
    NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
    NSWindow.didBecomeMainNotification,
  ] {
    _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        o.events += 1
        try? writeJSON(["event": name.rawValue], o.dir, "focus-stop.json")
      }
    }
  }
  let timer = Timer(timeInterval: 0.04, repeats: true) { _ in
    MainActor.assumeIsolated {
      do { try o.tick() } catch {
        try? writeJSON(["error": String(describing: error)], o.dir, "owner-stop.json")
        o.finish(1)
      }
    }
  }
  RunLoop.main.add(timer, forMode: .common)
  app.run()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
