// Lab-only foreground window on secondary A. All Space inputs belong to the existing supervisor.
import AppKit
import ApplicationServices
import CryptoKit
import Darwin

@main enum SecondarySession {
  typealias Row = [String: Any]
  static var uptime: Double { ProcessInfo.processInfo.systemUptime }

  static func require(_ ok: Bool, _ reason: String) throws {
    if !ok { throw Refusal(reason) }
  }

  static func pump(_ duration: Double) {
    let end = uptime + duration
    repeat {
      while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
      NSApp.updateWindows()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.015))
    } while uptime < end
  }

  static func save(_ row: Row, _ url: URL) throws {
    let bytes = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Refusal("session receipt exists or cannot be created: " + url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try handle.close()
  }

  static func read(_ url: URL) throws -> Row {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Row else {
      throw Refusal("invalid session receipt")
    }
    return value
  }

  struct PreparedTarget: Equatable {
    let id: String
    let order: [String]
    let digest: String
  }

  static func preparedTarget(display: UUID, source: String) throws -> PreparedTarget? {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["NEARPANE_CREATED_RECEIPT"] else {
      try require(env["NEARPANE_CREATED_SHA256"] == nil, "creation digest without receipt")
      return nil
    }
    let url = URL(fileURLWithPath: path), ledger = url.deletingLastPathComponent(), prior = ledger.deletingLastPathComponent()
    let trials = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("build/verification/secondary-route-followup").standardizedFileURL
    guard let pin = env["NEARPANE_CREATED_SHA256"], pin.count == 64,
          url.path == url.resolvingSymlinksInPath().path, url.lastPathComponent == "created.json",
          ledger.lastPathComponent == "provision", UUID(uuidString: prior.lastPathComponent) != nil,
          prior.deletingLastPathComponent().path == trials.path else { throw Refusal("unbound creation receipt") }
    for name in ["remove-intent.json", "removed.json"] {
      var state = stat()
      guard lstat(ledger.appendingPathComponent(name).path,&state) != 0, errno == ENOENT
      else { throw Refusal("prepared destination has an outstanding removal") }
    }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw Refusal("cannot open preparation receipt") }
    defer { close(fd) }
    var state = stat()
    guard fstat(fd,&state) == 0, state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFREG,
          state.st_nlink == 1, state.st_mode & 0o077 == 0, state.st_size > 0, state.st_size <= 65536
    else { throw Refusal("untrusted creation receipt") }
    let bytes = try FileHandle(fileDescriptor:fd, closeOnDealloc:false).readToEnd() ?? Data()
    let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    guard digest == pin, let row = try JSONSerialization.jsonObject(with:bytes) as? Row,
          let intent = row["intent"] as? Row, let raw = intent["operation"] as? String, UUID(uuidString:raw) != nil,
          (try read(ledger.appendingPathComponent("create-intent.json")) as NSDictionary).isEqual(to:intent),
          intent["display"] as? String == display.uuidString, intent["source"] as? String == source,
          let target = row["target"] as? String, let n = UInt64(target), n > 0, String(n) == target, target != source,
          let before = intent["initial"] as? Row, let after = row["after"] as? Row,
          before["sideOrder"] as? [String] == [source], let order = after["sideOrder"] as? [String],
          order == [source,target] || order == [target,source],
          let primary = before["primaryScope"] as? String, after["primaryScope"] as? String == primary,
          let geometry = before["geometry"] as? [String], geometry.count == 2, after["geometry"] as? [String] == geometry
    else { throw Refusal("creation receipt does not attest a unique adjacent prepared desktop") }
    var boot = [CChar](repeating:0,count:128), size = boot.count
    guard let captured = intent["boot"] as? String, let capturedBoot = UUID(uuidString:captured),
          sysctlbyname("kern.bootsessionuuid",&boot,&size,nil,0) == 0, size > 1,
          let liveBoot = UUID(uuidString:String(cString:boot)), liveBoot == capturedBoot
    else { throw Refusal("prepared desktop belongs to another boot") }
    return PreparedTarget(id:target,order:order,digest:digest)
  }

  static func screen(_ uuid: UUID, _ source: String, prepared: PreparedTarget?) throws -> (NSScreen, CGDirectDisplayID, Data) {
    guard NSWorkspace.shared.frontmostApplication != nil, NSScreen.screensHaveSeparateSpaces,
          NSScreen.screens.count == 2, let scopes = NPReadInventory() as? [Row], scopes.count == 2
    else { throw Refusal("two independent active desktops required") }
    var scopeProof = [String:[String]]()
    var selected: (NSScreen,CGDirectDisplayID)?
    for screen in NSScreen.screens {
      guard let id = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
            CGDisplayIsInMirrorSet(id) == 0, CGDisplayIsAsleep(id) == 0,
            let raw = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { throw Refusal("unstable display") }
      let display = CFUUIDCreateString(nil,raw) as String
      let matches = scopes.filter { $0["Display Identifier"] as? String == display }
      guard matches.count == 1,
            let active = (matches[0]["Current Space"] as? Row)?["id64"] as? NSNumber,
            let records = matches[0]["Spaces"] as? [Row],
            records.filter({ ($0["id64"] as? NSNumber) == active }).count == 1 else { throw Refusal("unbound display scope") }
      if display == uuid.uuidString {
        guard id != CGMainDisplayID(), active.stringValue == source,
              records.filter({ ($0["id64"] as? NSNumber) == active && $0["type"] as? Int == 0 }).count == 1
        else { throw Refusal("source is not the current ordinary secondary desktop") }
        let expected = prepared?.order ?? [source]
        let ids = records.compactMap { ($0["id64"] as? NSNumber)?.stringValue }
        try require(ids == expected && records.allSatisfy { $0["type"] as? Int == 0 },
                    "current secondary order does not match the designated ordinary desktops")
        selected = (screen,id)
      }
      var order = [active.stringValue,NSStringFromRect(CGDisplayBounds(id)),String(CGDisplayRotation(id)),String(Double(screen.backingScaleFactor))]
      for record in records {
        guard let n = record["id64"] as? NSNumber, let t = record["type"] as? Int else { throw Refusal("unknown desktop record") }
        order.append(n.stringValue + "/" + String(t))
      }
      scopeProof[display] = order
    }
    guard scopeProof.count == 2, let selected else { throw Refusal("target display missing") }
    return (selected.0,selected.1,try JSONSerialization.data(withJSONObject:scopeProof,options:.sortedKeys))
  }

  static func inputQuiet(_ seconds: Double) -> Bool {
    let types: [CGEventType] = [.keyDown,.keyUp,.flagsChanged,.mouseMoved,.scrollWheel,.leftMouseDown,
      .rightMouseDown,.otherMouseDown,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
    return NSEvent.pressedMouseButtons == 0 && types.allSatisfy {
      CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) >= seconds
    }
  }

  static func verifyOwned(_ record: Row) throws {
    let focus = try FocusAnchor()
    guard let number = record["window"] as? UInt32, let pid = record["pid"] as? Int32,
          pid == getppid(), focus.owner.processIdentifier == pid, focus.number == number,
          String(focus.birth.timeIntervalSince1970.bitPattern) == record["birth"] as? String,
          focus.homeDisplay == record["display"] as? String, String(focus.homeDesktop) == record["desktop"] as? String,
          attr(focus.element,kAXIdentifierAttribute) as? String == record["run"] as? String,
          focus.axFrame == focus.cgFrame, focus.isIntact && focus.isFocused else {
      throw Refusal("external reader did not confirm exact session window")
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow:0.17))
    try require(focus.isIntact && focus.isFocused,"session window changed during independent sample")
  }

  static func independentRead(_ file: URL) throws {
    let proc = Process()
    proc.executableURL = Bundle.main.executableURL
    proc.arguments = ["--read-anchor",file.path]
    proc.standardInput = FileHandle.nullDevice
    try proc.run()
    let stop = uptime + 5
    while proc.isRunning && uptime < stop { pump(0.03) }
    if proc.isRunning { proc.terminate(); throw Refusal("independent session check timed out") }
    try require(proc.terminationReason == .exit && proc.terminationStatus == 0,"independent session focus check failed")
  }

  static func validateRoute(_ args: [String], display: UUID, source: String, end: Date, now: Date, existing: String? = nil) throws {
    let valued: Set<String> = ["--display","--source","--kit","--witness","--witness-manifest","--starts","--ends"]
    let options = existing == nil ? valued : valued.union(["--existing-target"])
    let flags: Set<String> = ["--allow-primary-overview","--check-overview-first"]
    var values = [String:String](), switches = Set<String>(), iterator = args.makeIterator()
    while let key = iterator.next() {
      if flags.contains(key) {
        try require(switches.insert(key).inserted,"duplicate supervisor flag")
      } else {
        guard options.contains(key), values[key] == nil, let value = iterator.next(), !value.hasPrefix("--")
        else { throw Refusal("unexpected or incomplete supervisor option") }
        values[key] = value
      }
    }
    let clock = ISO8601DateFormatter()
    guard switches == (existing == nil ? flags : []), Set(values.keys) == options, values["--existing-target"] == existing,
          values["--display"].flatMap(UUID.init(uuidString:)) == display, values["--source"] == source,
          let from = values["--starts"].flatMap(clock.date(from:)),
          let until = values["--ends"].flatMap(clock.date(from:)),
          from <= now, now < until, until <= end, until.timeIntervalSince(from) <= 900,
          values["--kit"]?.hasPrefix("/") == true, values["--witness"]?.hasPrefix("/") == true,
          let manifest = values["--witness-manifest"], manifest.count == 64,
          manifest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw Refusal("supervisor scope or deadline differs from secondary session") }
  }

  static func testRoutes() throws {
    let display = UUID(), now = Date(timeIntervalSince1970: 42), end = Date(timeIntervalSince1970: 600)
    let args = ["--starts","1970-01-01T00:00:01Z","--ends","1970-01-01T00:09:59Z","--display",display.uuidString,
                "--source","7","--check-overview-first","--allow-primary-overview","--kit","/lab","--witness","/witness",
                "--witness-manifest",String(repeating:"e",count:64)]
    func accepts(_ input:[String]) -> Bool {
      do { try validateRoute(input,display:display,source:"7",end:end,now:now); return true } catch { return false }
    }
    try require(accepts(args),"valid secondary session was refused")
    for invalid in [args + ["--current-display"], args + ["--existing-target","8"], args + ["--source","7"],
                    args.filter { $0 != "--check-overview-first" }, args.map { $0 == "7" ? "6" : $0 },
                    args.map { $0 == display.uuidString ? UUID().uuidString : $0 },
                    args.map { $0 == "1970-01-01T00:09:59Z" ? "1970-01-01T00:10:01Z" : $0 }] {
      try require(!accepts(invalid),"out-of-scope supervisor arguments accepted")
    }
    let plain = args.filter { $0 != "--allow-primary-overview" && $0 != "--check-overview-first" }
    let prepared = plain + ["--existing-target","8"]
    func acceptsPrepared(_ input: [String]) -> Bool {
      do { try validateRoute(input,display:display,source:"7",end:end,now:now,existing:"8"); return true } catch { return false }
    }
    try require(acceptsPrepared(prepared), "prepared existing-target route refused")
    for invalid in [plain, prepared + ["--allow-primary-overview"], prepared + ["--check-overview-first"],
                    prepared + ["--cleanup-run","/tmp"], plain + ["--existing-target","9"], args] {
      try require(!acceptsPrepared(invalid), "prepared target admitted mutating or wrong-target route")
    }
    print("15 secondary session supervisor scope checks passed")
  }

  // Diagnosis only. None of these samples feed the supervisor, input or cleanup decisions.
  // AX queries run off the AppKit event loop; a busy witness can skip a sample.
  final class ForegroundTrace {
    let queue = DispatchQueue(label:"org.nearpane.lab.foreground-trace")
    let timer: DispatchSourceTimer
    var last: String?, events = [Row](), samples = 0, dropped = 0
    let path: URL, session: String
    init(folder: URL, session: String) {
      path = folder.appendingPathComponent("foreground-trace.json")
      self.session = session
      timer = DispatchSource.makeTimerSource(queue:queue)
    }

    static func witnessLabel(_ element: AXUIElement, pid: pid_t, number: UInt32, display: UUID, source: String, target: String) -> String {
      guard let name = attr(element,kAXIdentifierAttribute) as? String else { return "witnessOtherOrUnknown" }
      let parts = name.components(separatedBy:"/")
      guard parts.count == 2, let run = UUID(uuidString:parts[0]), run.uuidString == parts[0],
            ["A","B"].contains(parts[1]) else { return "witnessOtherOrUnknown" }
      let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Nearpane-P431-" + run.uuidString)
      guard let consent = try? read(folder.appendingPathComponent("unattended-consent.ready")),
            consent["run"] as? String == run.uuidString, consent["source"] as? String == source,
            consent["target"] as? String == target, consent["secondaryDisplay"] as? String == display.uuidString
      else { return "witnessOtherOrUnknown" }
      let label = parts[1]
      let record = try? read(folder.appendingPathComponent("enrolled-" + label + ".json"))
      return enrolledLabel(record,run:run,label:label,pid:pid,number:number)
    }

    static func enrolledLabel(_ record: Row?, run: UUID, label: String, pid: pid_t, number: UInt32) -> String {
      guard ["A","B"].contains(label), let record, record["run"] as? String == run.uuidString, record["label"] as? String == label,
            record["method"] as? String == "appkit-key-window", record["frontPID"] as? String == String(pid),
            record["window"] as? String == String(number) else { return "witness" + label + "BeforeConfirmedEnrollment" }
      return "enrolledWitness" + label
    }

    func start(witness: URL, parent: pid_t, sessionWindow: UInt32, originalState: OriginalDesktopReturn,
               display: UUID, source: String, target: String) {
      let original = originalState.identity
      let originalElement: AXUIElement?
      switch originalState {
      case .focused(let anchor): originalElement = anchor.element
      case .unfocused: originalElement = nil
      }
      let executable = witness.appendingPathComponent("NearpaneSpaceWitness.app/Contents/MacOS/NearpaneSpaceWitness").resolvingSymlinksInPath()
      var knownWitness: FrozenWitnessOwner?
      func classify() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        let pid = front.processIdentifier
        let isOriginal = original["pid"] == String(pid) && original["birth"] == front.returnAnchorBirth.map { String($0.timeIntervalSince1970.bitPattern) }
        let isSelf = pid == getpid()
        if !isOriginal && !isSelf {
          var info = proc_bsdinfo()
          let size = Int32(MemoryLayout.size(ofValue:info))
          guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size, info.pbi_pid == UInt32(pid) else { return "unknown" }
          guard info.pbi_ppid == UInt32(parent) else { return "outsideEnrolledProcesses" }
          if knownWitness?.pid != pid || knownWitness?.sameProcess != true {
            knownWitness = FrozenWitnessOwner.enroll(pid,executable:executable,before:Date())
          }
          guard knownWitness != nil else { return "otherOrUnverifiedSupervisorChild" }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.08)
        guard let raw = attr(app,kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return "unknown" }
        let window = raw as! AXUIElement
        var actual: pid_t = 0
        guard AXUIElementGetPid(window,&actual) == .success, actual == pid, !front.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "unknown" }
        let number = NPReadAXWindowNumber(window)
        guard number > 0 else { return "unknown" }
        if isOriginal {
          guard original["window"] == String(number) else { return "anotherOriginalProcessWindow" }
          guard let originalElement else { return "originalUnfocusedBaselineWindowNumber" }
          return CFEqual(originalElement,window) ? "originalWindow" : "unconfirmedOriginalWindowObject"
        }
        if isSelf { return number == sessionWindow ? "secondarySessionWindow" : "anotherSessionWindow" }
        AXUIElementSetMessagingTimeout(window,0.08)
        return Self.witnessLabel(window,pid:pid,number:number,display:display,source:source,target:target)
      }
      timer.schedule(deadline:.now(),repeating:.milliseconds(80),leeway:.milliseconds(10))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        let label = classify()
        self.samples += 1
        guard label != self.last else { return }
        self.last = label
        guard self.events.count < 128 else { self.dropped += 1; return }
        self.events.append(["uptime":uptime,"foreground":label])
      }
      timer.resume()
    }

    func finish() {
      timer.cancel()
      // Callback timeouts are bounded. Continue servicing a pending AX request to this window.
      let done = DispatchSemaphore(value:0)
      queue.async {
        try? save(["run":self.session,"method":"sampled frontmost owner and its AX focused window",
                   "samples":self.samples,"droppedTransitions":self.dropped,"transitions":self.events],self.path)
        done.signal()
      }
      let until = uptime + 0.6
      while done.wait(timeout:.now()) != .success && uptime < until { pump(0.015) }
    }
  }

  static func run(_ args: [String]) throws {
    guard args.count >= 5, let display = UUID(uuidString:args[1]),
          let sourceID = UInt64(args[2]), sourceID > 0, String(sourceID) == args[2],
          let stamp = TimeInterval(args[4]), stamp.isFinite else { throw Refusal("expected mode, display, source, folder and epoch deadline") }
    let pilot = args[0] == "--pilot", folder = URL(fileURLWithPath:args[3]).standardizedFileURL
    let source = args[2], ends = Date(timeIntervalSince1970: stamp)
    let mode = pilot ? "pilot" : "route"
    try require((pilot && args.count == 5) || (args[0] == "--route" && args.count > 10 && args[5] == "--" &&
      args[6].hasPrefix("/") && Array(args[7...8]) == ["-I","-B"] &&
      URL(fileURLWithPath:args[9]).lastPathComponent == "run-route.py"), "invalid session invocation")
    let start = Date()
    let prepared = try preparedTarget(display:display,source:source)
    if !pilot { try validateRoute(Array(args.dropFirst(10)), display:display, source:source, end:ends, now:start, existing:prepared?.id) }
    try require(ends.timeIntervalSince(start) > 15 && ends.timeIntervalSince(start) <= 900,"invalid session deadline")
    var info = stat()
    try require(lstat(folder.path,&info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
      info.st_mode & 0o777 == 0o700 && info.st_uid == getuid(),"private session folder required")
    let app = NSApplication.shared
    guard AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1 else { throw Refusal("read-only AX and desktop access required") }
    let quietEnd = uptime + min(75, ends.timeIntervalSinceNow - 10)
    while !inputQuiet(3) && uptime < quietEnd { RunLoop.current.run(until: Date(timeIntervalSinceNow:0.08)) }
    try require(inputQuiet(3),"no quiet interval before enrollment; no session window was shown")
    let original = try OriginalDesktopReturn.capture()
    RunLoop.current.run(until: Date(timeIntervalSinceNow:0.18))
    try require(original.restored && original.intact,"original state unstable before session")
    let (side, sideID, initialTopology) = try screen(display,source,prepared:prepared)
    let topo = initialTopology.base64EncodedString()
    if !pilot {
      let proof = try read(folder.appendingPathComponent("pilot-result.json"))
      try require(proof["passed"] as? Bool == true && proof["topology"] as? String == topo &&
        proof["original"] as? [String:String] == original.identity &&
        proof["preparedReceipt"] as? String == prepared?.digest && proof["deadline"] as? Double == stamp,"pilot and live original differ")
    }
    let run = UUID().uuidString
    try save(["run":run,"original":original.identity,"topology":topo,"deadline":stamp],folder.appendingPathComponent(mode + "-start.json"))
    let sessionFrame = CGRect(x:side.visibleFrame.midX - 155,y:side.visibleFrame.midY - 75,width:310,height:150).integral
    try require(side.visibleFrame.contains(sessionFrame),"no safe secondary window rectangle")
    let window = NSWindow(contentRect:sessionFrame,styleMask:[.titled,.closable],backing:.buffered,defer:true,screen:side)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.setAccessibilityIdentifier(run)
    window.title = "Nearpane · Desktop A"
    let field = NSTextField(string:"Nearpane")
    field.frame = NSRect(x:20,y:35,width:250,height:28)
    window.contentView?.addSubview(field)
    window.initialFirstResponder = field
    window.setFrame(sessionFrame,display:false)
    var number: UInt32?
    var acquired = false, independent = false, routePassed = false
    var failure: Error?
    do {
      try require(window.screen == side && side.visibleFrame.contains(window.frame) && original.restored &&
                  inputQuiet(2) && Date() < ends,"original or placement changed before opening session")
      // Launch Services may make a regular application frontmost. Capture the original
      // before adopting this policy and reject any third owner before activating our window.
      try require(app.activationPolicy() == .regular || app.setActivationPolicy(.regular),"regular application unavailable")
      app.finishLaunching()
      let ownOrOriginal = [getpid(),original.pid]
      guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownOrOriginal.contains(front), original.intact, window.screen == side, Date() < ends
      else { throw Refusal("focus or original layout changed before showing session") }
      window.orderFrontRegardless()
      guard let n = UInt32(exactly:window.windowNumber), n > 0 else { throw Refusal("session window number missing") }
      number = n
      let cutoff = uptime + 1.5
      func exactWindow() -> AXUIElement? {
        guard let rows = attr(AXUIElementCreateApplication(getpid()),kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let matches = rows.filter { NPReadAXWindowNumber($0) == n && attr($0,kAXIdentifierAttribute) as? String == run }
        guard matches.count == 1, let ax = matches.first, let logical = frame(ax),
              let cg = FocusAnchor.geometry(n,getpid()), logical == cg, CGDisplayBounds(sideID).contains(cg),
              window.isVisible && window.screen == side && window.isOnActiveSpace,
              FocusAnchor.currentHome(n,display.uuidString) == sourceID else { return nil }
        return ax
      }
      while exactWindow() == nil && uptime < cutoff { pump(0.03) }
      guard let bound = exactWindow(), let owner = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownOrOriginal.contains(owner), (owner == getpid() || original.restored), original.intact,
            inputQuiet(2), Date() < ends else { throw Refusal("unverified session before first activation") }
      app.activate()
      window.makeKeyAndOrderFront(nil)
      _ = window.makeFirstResponder(field)
      let focusEnd = uptime + 2
      var since: Double?
      while uptime < focusEnd && Date() < ends {
        pump(0.04)
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              ownOrOriginal.contains(front), inputQuiet(0.15), original.intact else { throw Refusal("foreground escaped during session enrollment") }
        if window.isKeyWindow, let focus = try? currentFocus(), focus.0 == getpid(), CFEqual(bound,focus.1), exactWindow() != nil {
          if let since, uptime - since >= 0.16 { acquired = true; break }
          if since == nil { since = uptime }
        } else { since = nil }
      }
      guard acquired else { throw Refusal("owned secondary text window did not acquire stable system focus") }
      guard let birth = NSRunningApplication.kernelBirth(pid: getpid()) else { throw Refusal("kernel generation missing for owned session") }
      let file = folder.appendingPathComponent(pilot ? "pilot-anchor.json" : "session-anchor.json")
      try save(["run":run,"pid":getpid(),"birth":String(birth.timeIntervalSince1970.bitPattern),
                "window":n,"display":display.uuidString,"desktop":source,"protectedOriginal":original.identity],file)
      try independentRead(file)
      independent = true
      if !pilot {
        try require(try preparedTarget(display:display, source:source) == prepared, "prepared destination changed before launch")
        let focus = try currentFocus()
        try require(Date() < ends && focus.0 == getpid() && CFEqual(bound, focus.1) && original.intact &&
                    inputQuiet(2) && (try? screen(display,source,prepared:prepared).2) == initialTopology,"session identity changed before route")
        let child = Process()
        child.executableURL = URL(fileURLWithPath:args[6])
        child.arguments = Array(args.dropFirst(7))
        child.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["NEARPANE_SESSION_ANCHOR_FILE"] = file.path
        child.environment = env
        try child.run()
        var trace: ForegroundTrace?
        if let prepared, let wi = args.firstIndex(of:"--witness"), args.indices.contains(wi+1) {
          let observer = ForegroundTrace(folder:folder,session:run)
          observer.start(witness:URL(fileURLWithPath:args[wi+1]),parent:child.processIdentifier,sessionWindow:n,
                         originalState:original,display:display,source:source,target:prepared.id)
          trace = observer
        }
        // The supervisor owns the action and deadline; keep the A window responsive while it cleans up.
        while child.isRunning { pump(0.05) }
        trace?.finish()
        routePassed = child.terminationReason == .exit && child.terminationStatus == 0
        try require(routePassed,"route supervisor stopped before three verified round trips and cleanup")
      }
    } catch { failure = error }
    // Only remove the enrolled synthetic surface. Never activate another application or set its AX focus.
    window.orderOut(nil)
    if app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { app.hide(nil) }
    window.close()
    let finish = uptime + 3
    var stableSince: Double?
    var restored = false
    repeat {
      pump(0.05)
      if original.intact && original.restored {
        if let stableSince, uptime - stableSince >= 0.16 { restored = true; break }
        if stableSince == nil { stableSince = uptime }
      } else { stableSince = nil }
    } while uptime < finish
    let absent = number.map { NPReadWindowNumberPresence($0) == 0 } ?? true
    let topologyMatches = (try? screen(display,source,prepared:prepared).2) == initialTopology
    let ok = failure == nil && acquired && independent && restored && absent && topologyMatches && (pilot || routePassed)
    var receipt: Row = ["passed":ok,"run":run,"deadline":stamp,"original":original.identity,"topology":topo,
                        "ownFocus":acquired,"externalFocus":independent,"originalRestored":restored,
                        "windowAbsent":absent,"initialScopesRestored":topologyMatches]
    if let prepared { receipt["preparedReceipt"] = prepared.digest; receipt["existingTarget"] = prepared.id }
    if let number { receipt["window"] = number }
    if let failure { receipt["reason"] = (failure as? Refusal)?.reason ?? failure.localizedDescription }
    try save(receipt,folder.appendingPathComponent(mode + "-result.json"))
    try require(ok,receipt["reason"] as? String ?? "original desktop state did not return")
  }

  static func main() {
    do {
      umask(0o077)
      let args = Array(CommandLine.arguments.dropFirst())
      if args == ["--self-test-route-scope"] {
        try testRoutes()
      } else if args == ["--test-foreground-trace"] {
        let run = UUID()
        let base: Row = ["run":run.uuidString,"label":"A","method":"appkit-key-window","frontPID":"42","window":"7"]
        func label(_ row: Row?) -> String { ForegroundTrace.enrolledLabel(row,run:run,label:"A",pid:42,number:7) }
        try require(label(base) == "enrolledWitnessA", "valid witness receipt misclassified")
        let invalid: [Row?] = [nil, ["run":"missing"]] + base.keys.map { key in
          var changed = base; changed[key] = "different"; return changed
        }
        try require(invalid.allSatisfy { label($0) == "witnessABeforeConfirmedEnrollment" }, "unbound witness receipt accepted")
        print("8 passive foreground receipt classifications passed")
      } else if args.count == 3, args[0] == "--check-prepared-receipt", let display = UUID(uuidString:args[1]) {
        guard let prepared = try preparedTarget(display:display, source:args[2]) else { throw Refusal("no prepared receipt selected") }
        print("verified prepared desktop " + prepared.id + " from " + prepared.digest)
      } else if args == ["--test-session-generation"] {
        guard let stamp = NSRunningApplication.kernelBirth(pid: getpid()) else { throw Refusal("missing process generation") }
        let reader = Process()
        reader.executableURL = Bundle.main.executableURL
        reader.arguments = ["--verify-parent-generation", String(stamp.timeIntervalSince1970.bitPattern)]
        try reader.run()
        reader.waitUntilExit()
        try require(reader.terminationReason == .exit && reader.terminationStatus == 0, "session generation differs across processes")
        print("Session and independent reader confirmed the same kernel process generation")
      } else if args.count == 2 && args[0] == "--verify-parent-generation" {
        let parent = getppid()
        guard parent > 1, let stamp = NSRunningApplication.kernelBirth(pid: parent),
              String(stamp.timeIntervalSince1970.bitPattern) == args[1], getppid() == parent else { throw Refusal("parent process generation unverified") }
      } else if args.count == 2 && args[0] == "--read-anchor" {
        guard AXIsProcessTrusted(), NPReadOnlySpacesOpen() == 1 else { throw Refusal("independent observer unavailable") }
        try verifyOwned(read(URL(fileURLWithPath:args[1])))
      } else { try run(args) }
    } catch {
      fputs(((error as? Refusal)?.reason ?? error.localizedDescription) + "\n",stderr)
      exit(2)
    }
  }
}
