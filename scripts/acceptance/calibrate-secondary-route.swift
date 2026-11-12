// Test controller for the two calibration legs of the frozen console Space witness.
// Build with swiftc. Usage: calibrate-secondary-route <frozen-kit> <live-run-uuid> enroll-B|return-A
// Each invocation spends exactly one independent calibration attempt. A failed/unknown leg is never retried.
import AppKit
import ApplicationServices
import CryptoKit
import Darwin

struct Refusal: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }
func check(_ condition: Bool, _ message: String) throws { if !condition { throw Refusal(message) } }

typealias Object = [String: Any]
func json(_ data: Data) throws -> Object {
    guard let result = try JSONSerialization.jsonObject(with: data) as? Object else { throw Refusal("invalid receipt") }
    return result
}
func load(_ url: URL) throws -> Object {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Refusal("missing receipt " + url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    try check(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() &&
              info.st_size <= 1_048_576 && info.st_nlink == 1, "unsafe receipt file")
    return try json(handle.readToEnd() ?? Data())
}
func publishOnce(_ url: URL, _ receipt: Object) throws {
    let data = try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Refusal("attempt already exists or cannot be recorded") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    try file.write(contentsOf: data)
    try file.synchronize()
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw Refusal("cannot open receipt directory") }
    defer { close(parent) }
    try check(fsync(parent) == 0, "cannot persist receipt directory")
}
func runCommand(_ url: URL, _ args: [String], timeout: Double) throws -> Data {
    let p = Process(), output = Pipe()
    p.executableURL = url; p.arguments = args; p.standardInput = FileHandle.nullDevice; p.standardOutput = output
    try p.run()
    let until = ProcessInfo.processInfo.systemUptime + timeout
    while p.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.015) }
    if p.isRunning { p.terminate(); throw Refusal("bounded observer timed out") }
    try check(p.terminationStatus == 0, "frozen helper refused " + url.lastPathComponent)
    return try output.fileHandleForReading.readToEnd() ?? Data()
}
func ax(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &result) == .success ? result : nil
}
func windowNumber(_ el: AXUIElement) -> UInt32? {
    if let n = ax(el, "AXWindowNumber") as? NSNumber { return UInt32(exactly: n.int64Value) }
    // Same read-only fallback as CReadOnlySpaces, restricted to the frozen fixture's validated OS build.
    typealias ReadNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    guard ProcessInfo.processInfo.operatingSystemVersionString.hasSuffix("(Build 26A428)"),
          let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    var n: UInt32 = 0
    return unsafeBitCast(fn, to: ReadNumber.self)(el, &n) == 0 && n > 0 ? n : nil
}
func bounds(_ data: Object) throws -> CGRect {
    guard let x = data["x"] as? Double, let y = data["y"] as? Double,
          let w = data["width"] as? Double, let h = data["height"] as? Double,
          w > 0, h > 0, [x,y,w,h].allSatisfy(\.isFinite) else { throw Refusal("invalid frame") }
    return CGRect(x: x, y: y, width: w, height: h)
}
struct Snapshot: Decodable {
    struct Scope: Decodable, Equatable {
        struct Record: Decodable, Equatable { let id: String, isCurrent: Bool }
        let displayID: String, records: [Record]
    }
    struct Native: Decodable { let spaces, population: String; let beganUptime, endedUptime: Double }
    let source, freshness, topologyFingerprint, sessionID: String
    let topologyConsistent, separateSpaces: Bool
    let revision: Int; let scopes: [Scope]; let ordinaryRecordsByDisplay: [String:[String]]; let native: Native
    func validate(_ initial: Self, secondary: String, endpoint: String, session: String, serial: Int, began: Double) throws {
        let age = ProcessInfo.processInfo.systemUptime - native.endedUptime
        try check(source == "macos-window-server" && freshness == "fresh" && topologyConsistent && separateSpaces &&
                  native.spaces == "observed" && native.population == "markedFixture" &&
                  sessionID == session && revision == serial && native.beganUptime >= began &&
                  native.endedUptime >= native.beganUptime && age >= 0 && age < 2 &&
                  topologyFingerprint == initial.topologyFingerprint && !topologyFingerprint.isEmpty &&
                  ordinaryRecordsByDisplay == initial.ordinaryRecordsByDisplay && scopes.count == 2, "live scope proof unavailable")
        for original in initial.scopes {
            let matches = scopes.filter { $0.displayID == original.displayID }
            guard matches.count == 1, let here = matches.first,
                  here.records.map(\.id) == original.records.map(\.id) else { throw Refusal("scope order changed") }
            let expected = original.displayID == secondary ? [endpoint] : original.records.filter(\.isCurrent).map(\.id)
            try check(expected.count == 1 && here.records.filter(\.isCurrent).map(\.id) == expected, "unexpected current Space")
        }
    }
}

#if !CALIBRATION_READBACK_TEST
func perform(kit: URL, run: UUID, step: String) throws {
    let forward = step == "enroll-B", label = forward ? "A" : "B", id = run.uuidString
    try check(forward || step == "return-A", "expected enroll-B or return-A")
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Nearpane-P431-" + id)
    var info = stat()
    try check(lstat(dir.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
              info.st_uid == getuid() && info.st_mode & 0o077 == 0, "missing private live run")
    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    let lock = open(file("checkpoint-controller.lock").path, O_NOFOLLOW | O_CLOEXEC | O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw Refusal("controller lock unavailable") }
    defer { close(lock) }
    try check(flock(lock, LOCK_EX | LOCK_NB) == 0, "another checkpoint controller is active")
    let consent = try load(file("unattended-consent.ready")), context = try load(file("console-scope.json"))
    let clock = ISO8601DateFormatter()
    guard let from = consent["starts"] as? String, let to = consent["ends"] as? String,
          let starts = clock.date(from: from), let ends = clock.date(from: to),
          consent["run"] as? String == id, context["run"] as? String == id,
          let boot = context["boot"] as? String, consent["boot"] as? String == boot,
          let securityID = context["securityID"] as? String, let expectedSecurityID = Int(securityID),
          consent["securityID"] as? Int == expectedSecurityID,
          context["procedure"] as? String == "route", consent["permitsCalibrationAndThreeRoundTrips"] as? Bool == true,
          consent["permitsTemporarySecondaryFocus"] as? Bool == true, consent["permitsSingleWindowFullscreen"] as? Bool == false,
          let secondary = consent["secondaryDisplay"] as? String, context["secondaryDisplay"] as? String == secondary,
          let a = consent["source"] as? String, let b = consent["target"] as? String, a != b,
          Date() >= starts, ends.timeIntervalSince(starts) <= 900, ends.timeIntervalSinceNow > 30
    else { throw Refusal("missing current route and focus grant with return time") }
    let source = forward ? a : b, target = forward ? b : a
    let witness = "NearpaneSpaceWitness.app/Contents/MacOS/NearpaneSpaceWitness"
    let reader = "NearpaneSpaceWitness.app/Contents/Helpers/NearpaneDesktopReader"
    let hashes = [witness:"6aafe8228517e97ca223b8b1f665fd313a77e5b5cef3f0d7e250f3d3f48a98c8",
                  reader:"a294d6baf1c981bd6a8a0509ca175cd32dc81d0deb54d9ac3b0db3bb63145be1",
                  "SessionProbe":"264a9392061250325c919e75601fbd38d92ea86e5f1bcb2e37e4d54550fa55fe",
                  "space-checkpoint.py":"ad729bc032263e2e27cd5c53c2335ef286bbbdd8700a54ee930ec404579ce72f"]
    for (name, expected) in hashes {
        let data = try Data(contentsOf: kit.appendingPathComponent(name))
        try check(SHA256.hash(data: data).map { String(format:"%02x", $0) }.joined() == expected, "frozen helper changed")
    }
    let original = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: load(file("scope-snapshot-1.json"))))
    let own = original.scopes.filter { $0.displayID == secondary }
    guard original.sessionID == id, original.scopes.count == 2, Set(original.scopes.map(\.displayID)).count == 2, own.count == 1,
          let order = own.first?.records.map(\.id), order.count == 2, Set(order) == Set([a,b]),
          original.ordinaryRecordsByDisplay[secondary] == order, own.first?.records.filter(\.isCurrent).map(\.id) == [a],
          let i = order.firstIndex(of: source), let j = order.firstIndex(of: target)
    else { throw Refusal("two adjacent ordinary test desktops required") }
    let direction = j > i ? "right" : "left"
    let enrolled = try load(file("enrolled-" + label + ".json")), origin = try load(file("origin-" + label + ".json"))
    guard let pid = origin["frontPID"] as? Int32, let n = origin["number"] as? UInt32, let frame = origin["frame"] as? Object,
          enrolled["window"] as? String == String(n), enrolled["frontPID"] as? String == String(pid),
          enrolled["run"] as? String == id, enrolled["label"] as? String == label, origin["record"] as? String == source,
          let app = NSRunningApplication(processIdentifier: pid), let birth = app.launchDate,
          app.bundleIdentifier == "org.nearpane.lab.NearpaneSpaceWitness",
          app.executableURL?.resolvingSymlinksInPath().path == kit.appendingPathComponent(witness).resolvingSymlinksInPath().path,
          let screen = NSScreen.screens.first(where: { s in
              guard let d = (s.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
                    d != CGMainDisplayID(), CGDisplayIsInMirrorSet(d) == 0,
                    let uuid = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() else { return false }
              return CFUUIDCreateString(nil, uuid) as String == secondary
          }), NSScreen.screens.count == 2
    else { throw Refusal("enrolled live secondary fixture not confirmed") }
    let expectedFrame = try bounds(frame)
    let originalFocus = try load(file("initial-focus.json"))
    let originalPID = (originalFocus["frontPID"] as? Int32) ?? (originalFocus["frontPID"] as? String).flatMap(Int32.init)
    guard let originalPID, originalPID > 1 else { throw Refusal("original focus owner missing") }
    if originalFocus["region"] as? String == "protected-main" {
        let rehearsal = try load(file("focus-return-rehearsal.json"))
        guard let token = originalFocus["focusToken"] as? String, UUID(uuidString: token) != nil,
              let birth = originalFocus["processBirth"] as? String, (UInt64(birth) ?? 0) > 0,
              rehearsal["run"] as? String == id, rehearsal["owner"] as? String == String(originalPID),
              rehearsal["focusToken"] as? String == token, rehearsal["processBirth"] as? String == birth,
              rehearsal["originalFrameUnchanged"] as? String == "true", rehearsal["sameAXFocus"] as? String == "true",
              rehearsal["retiredAXAndCGAbsent"] as? String == "true" else { throw Refusal("original focus return not rehearsed") }
    }
    var serial = 0
    @discardableResult func observe(allowed: Set<String>) throws -> String {
        serial += 1
        let request: Object = ["version":1, "session":id, "revision":serial, "parentPID":getpid(),
                               "fixtureWindows":[], "anchors":[], "experimentalSpaces":true]
        let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
        let began = ProcessInfo.processInfo.systemUptime
        let data = try runCommand(kit.appendingPathComponent(reader), ["--read-enrolled-console",encoded], timeout: 4)
        let actual = try JSONDecoder().decode(Snapshot.self, from: data)
        guard let endpoint = actual.scopes.first(where: { $0.displayID == secondary })?.records.first(where: \.isCurrent)?.id,
              allowed.contains(endpoint) else { throw Refusal("unexpected secondary current") }
        try actual.validate(original, secondary: secondary, endpoint: endpoint, session: id, serial: serial, began: began)
        try publishOnce(file("external-" + step + "-sample-" + String(serial) + ".json"), try json(data))
        return endpoint
    }
    func pending() throws {
        let r = try load(file("request-" + step + ".json"))
        let liveGrant = try load(file("unattended-consent.ready"))
        try check((liveGrant as NSDictionary).isEqual(to: consent) &&
                  r["run"] as? String == id && r["checkpoint"] as? String == step && Date() >= starts && ends.timeIntervalSinceNow > 15 &&
                  !["stopped.json","completed.json",step + ".ready",step + ".observe"].contains(where: {
                      FileManager.default.fileExists(atPath: file($0).path)
                  }), "witness stopped, request spent, or permission expired")
    }
    let modifiers: CGEventFlags = [.maskControl,.maskAlternate,.maskCommand,.maskShift,.maskSecondaryFn]
    func focused() throws -> AXUIElement {
        try pending()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !app.isTerminated, NSEvent.pressedMouseButtons == 0,
              app.launchDate == birth, screen.frame.contains(NSEvent.mouseLocation), CGPreflightPostEventAccess(), AXIsProcessTrusted(),
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
              let state = CGSessionCopyCurrentDictionary() as? [String:Any], state["CGSSessionScreenIsLocked"] as? Bool != true,
              state[kCGSessionOnConsoleKey as String] as? Bool == true,
              let focusedApp = ax(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute), CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
              let window = ax(focusedApp as! AXUIElement, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID()
        else { throw Refusal("focus, pointer, permission or console changed") }
        let el = window as! AXUIElement
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(el,&actualPID) == .success, actualPID == pid, windowNumber(el) == n,
              ax(el,kAXIdentifierAttribute) as? String == id + "/" + label,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [Object], rows.count == 1, let row = rows.first,
              row[kCGWindowOwnerPID as String] as? Int32 == pid, row[kCGWindowNumber as String] as? UInt32 == n,
              row[kCGWindowIsOnscreen as String] as? Bool == true, row[kCGWindowLayer as String] as? Int == 0,
              let rect = row[kCGWindowBounds as String] as? NSDictionary, CGRect(dictionaryRepresentation: rect) == expectedFrame
        else { throw Refusal("focus differs from enrolled AX/CG window") }
        return el
    }
    try pending()
    let keys = try json(runCommand(kit.appendingPathComponent("SessionProbe"), ["control-arrows"], timeout: 3))
    try check(keys["left"] as? Bool == true && keys["right"] as? Bool == true, "system shortcuts unavailable")
    let first = try focused()
    try observe(allowed: [source])
    Thread.sleep(forTimeInterval: 0.25)
    try observe(allowed: [source])
    guard let events = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: events, virtualKey: j > i ? 124 : 123, keyDown: true),
          let up = CGEvent(keyboardEventSource: events, virtualKey: j > i ? 124 : 123, keyDown: false)
    else { throw Refusal("system input unavailable") }
    down.flags = .maskControl; up.flags = .maskControl
    let operation = UUID().uuidString
    let receipt: Object = ["run":id,"checkpoint":step,"operation":operation,"window":n,"pid":pid,
                           "source":source,"target":target,"direction":direction,"ownerLaunch":birth.timeIntervalSince1970]
    try publishOnce(file("external-" + step + "-intent.json"), receipt)
    try check(CFEqual(first, try focused()), "focused AX object changed before input")
    down.post(tap:.cgSessionEventTap); up.post(tap:.cgSessionEventTap)
    try publishOnce(file("external-" + step + "-posted.json"), receipt)
    // Only observe after the single chord. An existing animation can report the source for several samples.
    func checkForeground() throws {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try check(front == pid || front == originalPID, "focus escaped enrolled pair during calibration")
    }
    let settle = ProcessInfo.processInfo.systemUptime + 4
    var reached = false
    while ProcessInfo.processInfo.systemUptime < settle {
        try checkForeground()
        let endpoint = try observe(allowed: reached ? [target] : [source,target])
        if reached && endpoint == target { break }
        reached = endpoint == target
        let pause = ProcessInfo.processInfo.systemUptime + 0.25
        repeat {
            try checkForeground()
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < pause
    }
    try check(reached && ProcessInfo.processInfo.systemUptime < settle, "stable target not confirmed; input remains spent")
    try checkForeground()
    try pending()
    // The frozen Python supervisor takes this same lock and issues its own independent challenge.
    try check(flock(lock, LOCK_UN) == 0, "cannot transfer the checkpoint lock")
    _ = try runCommand(URL(fileURLWithPath:"/usr/bin/python3"),
                       [kit.appendingPathComponent("space-checkpoint.py").path,id,"ack",step,"--observed-chord",direction],
                       timeout: 24)
    let ready = try load(file(step + ".ready"))
    let attested = try load(file("attested-" + step + ".json"))
    guard ready["run"] as? String == id, ready["demonstratedControlArrow"] as? String == direction,
          let token = ready["token"] as? String, token == attested["token"] as? String, attested["endpoint"] as? String == target
    else { throw Refusal("endpoint not acknowledged") }
    var final = receipt
    final["attestationToken"] = token
    try publishOnce(file("external-" + step + "-confirmed.json"), final)
    print("confirmed \(step) \(source) -> \(target) \(operation)")
}

do {
    let args = CommandLine.arguments
    guard args.count == 4, let run = UUID(uuidString: args[2]) else { throw Refusal("expected FROZEN_KIT RUN_UUID enroll-B|return-A") }
    try perform(kit:URL(fileURLWithPath:args[1]).standardizedFileURL,run:run,step:args[3])
} catch { FileHandle.standardError.write(Data("REFUSED: \(error)\n".utf8)); exit(2) }
#else
// Run with: swift -D CALIBRATION_READBACK_TEST scripts/acceptance/calibrate-secondary-route.swift
// This compilation excludes perform(), system input and the live command entry point.
func readbackFixture(_ primary: String, _ secondary: String, serial: Int, run: String, time: Double,
                     extraRecord: Bool = false) -> Snapshot {
    func scope(_ display: String, records: [String], current: String) -> Snapshot.Scope {
        .init(displayID: display, records: records.map { .init(id: $0, isCurrent: $0 == current) })
    }
    return .init(source: "macos-window-server", freshness: "fresh", topologyFingerprint: "fixture", sessionID: run,
                 topologyConsistent: true, separateSpaces: true, revision: serial,
                 scopes: [scope("main", records: ["10", "11"], current: primary),
                          scope("side", records: extraRecord ? ["20", "21", "22"] : ["20", "21"], current: secondary)],
                 ordinaryRecordsByDisplay: ["main": ["10", "11"], "side": ["20", "21"]],
                 native: .init(spaces: "observed", population: "markedFixture", beganUptime: time, endedUptime: time))
}
let start = ProcessInfo.processInfo.systemUptime, run = UUID().uuidString
let origin = readbackFixture("10", "20", serial: 1, run: run, time: start)
let cases: [(String, Snapshot, Bool)] = [
    ("target reached on secondary", readbackFixture("10", "21", serial: 2, run: run, time: start), true),
    ("still at source", readbackFixture("10", "20", serial: 2, run: run, time: start), false),
    ("primary Desktop changed", readbackFixture("11", "21", serial: 2, run: run, time: start), false),
    ("replayed revision", readbackFixture("10", "21", serial: 1, run: run, time: start), false),
    ("different run", readbackFixture("10", "21", serial: 2, run: UUID().uuidString, time: start), false),
    ("stale sample", readbackFixture("10", "21", serial: 2, run: run, time: start - 30), false),
    ("secondary order changed", readbackFixture("10", "21", serial: 2, run: run, time: start, extraRecord: true), false),
    ("future sample", readbackFixture("10", "21", serial: 2, run: run, time: start + 30), false)
]
for (name, sample, expected) in cases {
    let accepted: Bool
    do {
        try sample.validate(origin, secondary: "side", endpoint: "21", session: run, serial: 2, began: start)
        accepted = true
    } catch { accepted = false }
    guard accepted == expected else {
        FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8))
        exit(1)
    }
    print("passed: \(name)")
}
#endif
