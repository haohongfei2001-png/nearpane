// One signed system-overview lifecycle on an existing empty ordinary lease. No tile, window or key input.
import AppKit
import ApplicationServices
import Foundation
import Security

private typealias Fields = [String: Any]
private var stopping = false
private let uptime = { ProcessInfo.processInfo.systemUptime }
private func emit(_ event: String, _ values: Fields = [:]) {
    var row = values
    row["event"] = event; row["uptime"] = uptime()
    if let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
private enum HandoffError: Error { case refuse(String), mismatch(String) }
private func why(_ error: Error) -> String {
    switch error {
    case let HandoffError.refuse(value), let HandoffError.mismatch(value): return value
    case let e as Refusal: return String(e.reason.prefix(220))
    default: return "scopedReadUnavailable"
    }
}

private func scope(_ request: WorkspaceRequest, _ dock: OverviewProcess, restore: Bool = false) throws {
    if stopping && !restore { throw HandoffError.refuse("terminationRequested") }
    try guardState(request, stage: "handoff")
    try dock.verify()
    try demand(try SystemDock.identity() == dock, "enrolledDockGenerationChanged")
    let flag = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
    guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil,
          getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }) == NSHomeDirectory(),
          flag.map(CFGetTypeID) == CFBooleanGetTypeID(), flag as? Bool == false else { throw HandoffError.refuse("actualLoginStageOffUnconfirmed") }
}

// An absent AX identifier alone does not establish a normal Dock. Verify the ordinary list role and exact owner.
private func root(_ dock: OverviewProcess) throws -> AXUIElement? {
    if let held = try overviewGroup() {
        try demand(dock.owns(held), "overviewRootHasUnexpectedOwner")
        return held
    }
    let app = AXUIElementCreateApplication(dock.pid)
    _ = AXUIElementSetMessagingTimeout(app, 0.3)
    guard dock.owns(app), let children = attr(app, kAXChildrenAttribute) as? [AXUIElement],
          (1...32).contains(children.count), children.allSatisfy(dock.owns),
          children.contains(where: { attr($0, kAXRoleAttribute) as? String == kAXListRole }),
          try overviewGroup() == nil else { throw HandoffError.refuse("ordinarySignedDockListUnconfirmed") }
    for child in children {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &value)
        if status == .success {
            guard let identifier = value as? String, identifier != "mc" else { throw HandoffError.refuse("dockTreeChangedBetweenReads") }
        } else if status != .noValue && status != .attributeUnsupported { throw HandoffError.refuse("dockChildIdentifierUnconfirmed") }
    }
    return nil
}

// An AX rebuild is not proof of absence. Retry only reads on the same live lease.
private func settledRoot(_ r: WorkspaceRequest, _ dock: OverviewProcess, restore: Bool = false) throws -> AXUIElement? {
    let deadline = uptime() + 0.9
    var last = "dockRootUnavailable"
    repeat {
        try scope(r, dock, restore: restore)
        do { return try root(dock) } catch { last = why(error) }
        usleep(70_000)
    } while uptime() < deadline
    throw HandoffError.refuse(last)
}

private func sameRoot(_ actual: AXUIElement?, _ expected: AXUIElement?) -> Bool {
    switch (actual, expected) {
    case (nil, nil): return true
    case let (a?, b?): return CFEqual(a, b)
    default: return false
    }
}

private func readTool(_ url: URL, _ args: [String], _ input: Fields? = nil, timeout: Double = 2.8) throws -> Fields {
    let task = Process(), output = Pipe(), incoming = Pipe()
    task.executableURL = url; task.arguments = args; task.standardOutput = output
    task.standardError = FileHandle.nullDevice; task.standardInput = input == nil ? FileHandle.nullDevice : incoming.fileHandleForReading
    try task.run()
    if let input {
        try incoming.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: input))
        try incoming.fileHandleForWriting.close()
    }
    let end = uptime() + timeout
    while task.isRunning && uptime() < end { usleep(15_000) }
    guard !task.isRunning else { task.terminate(); throw HandoffError.refuse("boundedReadToolTimeout") }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    guard task.terminationStatus == 0, bytes.count < 32768,
          let facts = try JSONSerialization.jsonObject(with: bytes) as? Fields else { throw HandoffError.refuse("readToolDidNotReturnEnrolledEvidence") }
    return facts
}

private func empty(_ r: WorkspaceRequest, _ packet: Fields, observer: URL) throws {
    guard let all = NPContractMemberReport([NSNumber(value: r.current)] as CFArray, r.hostPID) as? Fields,
          let set = all[String(r.current)] as? Fields, set["unresolved"] as? Int == 0,
          let other = set["otherDetails"] as? [Fields], other.count == set["otherMembers"] as? Int,
          other.allSatisfy({ row in
              if row["installedHost"] as? Int == 1 { return true }
              guard let code = row["code"] as? Fields, code["apple"] as? Bool == true,
                    let owner = code["identifier"] as? String else { return false }
              return ["com.apple.dock","com.apple.WindowServer","com.apple.WindowManager"].contains(owner)
          }), let ordinary = set["ordinary"] as? [Fields], ordinary.count <= 8,
          var query = packet["scope"] as? Fields, let enrolled = packet["enrolled"] as? [Fields] else { throw HandoffError.refuse("unknownMemberOnOrdinaryLease") }
    let numbers = try ordinary.map { member -> UInt32 in
        guard let n = member["number"] as? UInt32, let p = member["pid"] as? pid_t,
              enrolled.contains(where: { $0["number"] as? UInt32 == n && $0["pid"] as? pid_t == p }) else { throw HandoffError.refuse("unregisteredWindowOnLease") }
        return n
    }
    query["enrolled"] = enrolled; query["present"] = numbers.sorted()
    let looked = try readTool(observer, ["p2-stage-surface"], query, timeout: 4.5)
    guard looked["status"] as? String == "READ", looked["stageEnabled"] as? Bool == false,
          let seen = looked["surfaces"] as? [Fields], seen.count == numbers.count else { throw HandoffError.refuse("offscreenSignedWindowManagerReadbackUnconfirmed") }
}

private struct Position {
    let pid: pid_t?, birth: UInt64?, point: CGPoint?, window: CGWindowID?, knownWindow: Bool
    init(_ host: pid_t, dock: OverviewProcess) {
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        birth = pid.flatMap(operatorBirth)
        point = CGEvent(source: nil)?.location
        var number: CGWindowID?, known = false
        if let pid, pid == host || pid == dock.pid {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(app, 0.18)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            if status == .noValue { known = true }
            if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                var id: CGWindowID = 0, owner: pid_t = 0
                if AXUIElementGetPid(window, &owner) == .success, owner == pid,
                   handoffWindowNumber(window, &id) == .success, id != 0 { number = id; known = true }
            }
        }
        window = number; knownWindow = known
    }
    func compared(to other: Position) -> Fields {
        let sameFront: Bool? = pid == nil || other.pid == nil || birth == nil || other.birth == nil ? nil : pid == other.pid && birth == other.birth
        let focus = sameFront == false ? "CHANGED" : sameFront == true && knownWindow && other.knownWindow ? (window == other.window ? "UNCHANGED" : "CHANGED") : "UNKNOWN"
        let cursor = point == nil || other.point == nil ? "UNKNOWN" : point == other.point ? "UNCHANGED" : "CHANGED"
        var result: Fields = ["frontProcess": sameFront.map { $0 ? "UNCHANGED" : "CHANGED" } ?? "UNKNOWN",
                              "focus": focus, "pointer": cursor, "focusRestoreIssued": false]
        if let point, let after = other.point { result["pointerBefore"] = [point.x,point.y]; result["pointerAfter"] = [after.x,after.y] }
        return result
    }
}
@_silgen_name("_AXUIElementGetWindow")
private func handoffWindowNumber(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func qualifiedTool(_ url: URL, kitPrefix: String, id: String) -> Bool {
    let dir = url.deletingLastPathComponent()
    guard dir.deletingLastPathComponent().path == "/private/tmp", dir.lastPathComponent.hasPrefix(kitPrefix),
          let real = realpath(url.path, nil) else { return false }
    defer { free(real) }
    var file = stat(), directory = stat()
    guard String(cString: real) == url.path, lstat(dir.path, &directory) == 0, directory.st_uid == getuid(),
          directory.st_mode & 0o777 == 0o700, lstat(url.path, &file) == 0, file.st_nlink == 1,
          file.st_uid == getuid(), file.st_mode & S_IFMT == S_IFREG, file.st_mode & 0o022 == 0 else { return false }
    var code: SecStaticCode?, rule: SecRequirement?
    let text = "anchor apple generic and identifier \"" + id + "\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(text as CFString, [], &rule) == errSecSuccess, let rule else { return false }
    return SecStaticCodeCheckValidity(code, [], rule) == errSecSuccess
}

private func approvedLauncher() -> Bool {
    let path = URL(fileURLWithPath: "/System/Applications/Mission Control.app", isDirectory: true)
    var code: SecStaticCode?, requirement: SecRequirement?
    return SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess &&
        SecRequirementCreateWithString("anchor apple and identifier \"com.apple.exposelauncher\"" as CFString, [], &requirement) == errSecSuccess &&
        code != nil && requirement != nil && SecStaticCodeCheckValidity(code!, [], requirement) == errSecSuccess
}

private func measure(_ phase: HandoffPhase, request: WorkspaceRequest, dock: OverviewProcess, held: AXUIElement?, metrics: URL) throws {
    let until = uptime() + 4
    var last: Fields?, conflicting = 0
    repeat {
        try scope(request, dock)
        try demand(try sameRoot(settledRoot(request,dock), held), "observedOverviewChangedBeforeHostMetrics")
        let fields: Fields
        do { fields = try readTool(metrics, [String(request.hostPID)]) }
        catch { last = nil; conflicting = 0; emit("metricReadUnavailable", ["phase": phase.rawValue]); continue }
        try scope(request, dock)
        try demand(try sameRoot(settledRoot(request,dock), held), "observedOverviewChangedAfterHostMetrics")
        let current = try live(request).0, counters = hardware()
        try demand(current == request.current && counters == request.hid, "spaceOrHIDChangedAfterHostMetrics")
        emit("hostMetrics", ["phase":phase.rawValue, "fields":fields, "sameSignedDockRoot":true,
                             "overviewRootPresent":held != nil, "dockPID":dock.pid, "dockBirth":dock.birth, "currentSpace":current, "hid":counters])
        if handoffMetric(fields, pid: request.hostPID, phase: phase) {
            if let last, handoffQuiescent(last, fields) { return }
            last = fields; conflicting = 0
        } else { last = nil; conflicting += 1 }
        usleep(180_000)
    } while uptime() < until
    if phase != .before && conflicting >= 2 { throw HandoffError.mismatch("installedHostMismatchDuring" + phase.rawValue.capitalized) }
    throw HandoffError.refuse("independentHostReadbacksUnavailableDuring" + phase.rawValue.capitalized)
}

@main enum MissionHandoff {
    static func main() {
        signal(SIGTERM) { _ in stopping = true }
        signal(SIGINT) { _ in stopping = true }
        var status = "BLOCKED", reason = "invalidRequest", cleanup = "NOT_NEEDED"
        var launched = false, readPresented = false, opened: AXUIElement?
        if CommandLine.arguments.dropFirst().first == "--verify-tools" {
            let paths = Array(CommandLine.arguments.dropFirst(2))
            guard (1...3).contains(paths.count) else { exit(2) }
            let tools = [("nearpane-d01.mission-handoff.", "net.example.nearpane.mission-handoff-metrics"),
                         ("nearpane-d01.", "net.example.nearpane.p2-observer"),
                         ("nearpane-overview-chord.", "com.holdsnow.nearpane.acceptance.overview-shortcut-claim")]
            let ok = zip(paths, tools).allSatisfy { qualifiedTool(URL(fileURLWithPath:$0),kitPrefix:$1.0,id:$1.1) }
            emit("signedFilesOnly",["valid":ok,"count":paths.count,"systemInputs":0]); exit(ok ? 0 : 2)
        }
        var result: Fields = ["independentCustomChord": "NOT_RUN", "positiveStreamStop": "NOT_RUN", "media": "NOT_RUN", "qualifiedPhysicalScope": "oneEmptyOrdinaryDesktop"]
        do {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            guard bytes.count <= 32768, let packet = try JSONSerialization.jsonObject(with: bytes) as? Fields,
                  let observerPath = packet["observer"] as? String, let enrolled = packet["scope"] as? Fields else { throw HandoffError.refuse("missingBoundRequest") }
            let r = try JSONDecoder().decode(WorkspaceRequest.self, from: bytes)
            guard r.command == "mission-handoff", r.owned.contains(r.current), r.current != r.original, r.target == nil, r.other == nil,
                  enrolled["space"] as? UInt64 == r.current, enrolled["hostPID"] as? pid_t == r.hostPID,
                  enrolled["hostHash"] as? String == r.hostHash, enrolled["hostBirth"] as? UInt64 == r.hostBirth,
                  enrolled["display"] as? String == r.display,
                  r.records.contains(where: { $0.id == r.current && $0.type == 0 && $0.uuid.lowercased() == (enrolled["spaceUUID"] as? String)?.lowercased() }),
                  approvedLauncher() else { throw HandoffError.refuse("ordinaryLeaseOrSignedSystemLauncherUnconfirmed") }
            let metrics = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("metrics")
            let observer = URL(fileURLWithPath: observerPath)
            guard qualifiedTool(metrics,kitPrefix:"nearpane-d01.mission-handoff.",id:"net.example.nearpane.mission-handoff-metrics"),
                  qualifiedTool(observer,kitPrefix:"nearpane-d01.",id:"net.example.nearpane.p2-observer") else {
                throw HandoffError.refuse("untrustedBoundReadTool")
            }
            if let chord = packet["chord"] as? String {
                guard qualifiedTool(URL(fileURLWithPath:chord),kitPrefix:"nearpane-overview-chord.",
                                    id:"com.holdsnow.nearpane.acceptance.overview-shortcut-claim") else {
                    throw HandoffError.refuse("untrustedCustomChordProbe")
                }
            }
            let dock = try SystemDock.identity()
            result["dock"] = ["pid":dock.pid, "birth":dock.birth, "appleSignature":true]
            result["host"] = ["pid":r.hostPID, "birth":r.hostBirth, "cdhash":r.hostHash]
            try scope(r, dock); try empty(r,packet,observer:observer)
            try measure(.before, request:r, dock:dock, held:nil, metrics:metrics)
            let original = Position(r.hostPID,dock:dock)
            try scope(r, dock); try empty(r,packet,observer:observer)
            try demand(try settledRoot(r,dock) == nil, "aSystemOverviewWasAlreadyOpen")
            try scope(r, dock)
            do {
                emit("systemLaunchRequested"); launched = true; cleanup = "UNKNOWN"
                try runOverviewLauncher()
                let until = uptime() + 4
                repeat {
                    try scope(r, dock)
                    if let group = try? root(dock) { opened = group; break }
                    usleep(90_000)
                } while uptime() < until
                guard let opened else { throw HandoffError.refuse("signedOverviewRootDidNotAppear") }
                emit("enrolledOverview", ["dockPID":dock.pid,"dockBirth":dock.birth])
                try measure(.presented, request:r, dock:dock, held:opened, metrics:metrics)
                readPresented = true
                result["independentCustomChord"] = "NOT_RUN"
                if let chord = packet["chord"] as? String {
                    try scope(r,dock); try demand(try sameRoot(root(dock), opened), "overviewChangedBeforeChordRead")
                    let claim = try readTool(URL(fileURLWithPath:chord),[String(r.hostPID)],timeout:3)
                    try scope(r,dock); try demand(try sameRoot(root(dock), opened), "overviewChangedAfterChordRead")
                    let available = claim["pid"] as? pid_t == r.hostPID && claim["state"] as? String == "available" &&
                        claim["registration"] as? Int == 0 && claim["release"] as? Int == 0 && claim["keyEventsSent"] as? Int == 0
                    emit("isolatedCustomChord", ["evidence":claim,"sameSignedDockRoot":true])
                    result["independentCustomChord"] = available ? "AVAILABLE" : "UNCONFIRMED"
                    try measure(.presented, request:r, dock:dock, held:opened, metrics:metrics)
                    if !available { throw HandoffError.mismatch("customChordSlotReleaseUnconfirmed") }
                }
                status = "PASS"; reason = "systemAndInstalledHostHandoffConfirmed"
            } catch {
                reason = why(error)
                if case HandoffError.mismatch = error { status = "FAIL" }
                emit("observationStopped", ["reason":reason])
            }
            // Restore only the same positively enrolled root, on the same ordinary Space and original hardware lease.
            do {
                try scope(r,dock,restore:true)
                if let current = try settledRoot(r,dock,restore:true) {
                    if opened == nil { throw HandoffError.refuse("openRootWasNeverEnrolled") }
                    try demand(sameRoot(current,opened),"systemOverviewOwnerWasReplaced")
                    usleep(110_000)
                    try scope(r,dock,restore:true)
                    try demand(try sameRoot(settledRoot(r,dock,restore:true),opened),"sameRootNotConfirmedBeforeClosure")
                    emit("systemExitRequested", ["action":"signedSystemLauncher", "sameRoot":true])
                    try runOverviewLauncher()
                }
                try demand(try awaitDismissal(of:opened,request:r,timeout:4),"originalOverviewDidNotClose")
                for _ in 0..<2 {
                    try scope(r,dock,restore:true); try demand(try settledRoot(r,dock,restore:true) == nil,"normalDockDidNotReturn"); usleep(90_000)
                }
                cleanup = "PASS"; result["sameSpaceAndHardwareAfter"] = true
                result["positionAtClosure"] = original.compared(to:Position(r.hostPID,dock:dock))
                try empty(r,packet,observer:observer)
                try measure(.after, request:r, dock:dock, held:nil, metrics:metrics)
                result["normalDispatchReturned"] = true
                let position = original.compared(to:Position(r.hostPID,dock:dock))
                result["originalPosition"] = position
                if status == "PASS" && ["frontProcess", "focus", "pointer"].contains(where: { position[$0] as? String == "CHANGED" }) {
                    status = "FAIL"; reason = "originalFocusOrPointerChanged"
                }
            } catch {
                if status == "PASS" {
                    status = "BLOCKED"
                    if case HandoffError.mismatch = error { status = "FAIL" }
                    reason = why(error)
                }
                result["restoreReason"] = why(error)
                if cleanup != "PASS" { status = "BLOCKED" }
            }
        } catch { reason = why(error) }
        result.merge(["status":status,"reason":reason,"cleanup":cleanup,"launched":launched,"presentedHostVerified":readPresented,
                      "screenCaptures":0,"spaceOrWindowSelections":0,"inputKeys":0]) { _, new in new }
        emit("complete", result)
        exit(status == "PASS" ? 0 : 2)
    }
}
