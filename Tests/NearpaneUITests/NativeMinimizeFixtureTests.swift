import AppKit
import ApplicationServices
import CReadOnlySpaces
import Darwin
import NearpaneCore
import Security
import Testing
@testable import NearpaneUI

/// Explicit single-use development fixture. The regular CI test suite opens no windows.
@MainActor struct NativeMinimizeFixtureTests {
    private struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private func require(_ yes: Bool, _ reason: String) throws { if !yes { throw Refusal(reason) } }
    private func pause() async throws { try await Task.sleep(for: .milliseconds(25)) }
    private func until(_ body: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !body() { if ProcessInfo.processInfo.systemUptime > end { throw Refusal("readbackDeadline") }; try await pause() }
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success else { return nil }; return v
    }
    private func focus() -> (DesktopWindowKey, AXUIElement)? {
        guard let owner = NSWorkspace.shared.frontmostApplication, owner.activationPolicy == .regular,
              let image = try? OrdinaryProcessImage.read(owner.processIdentifier) else { return nil }
        let app = AXUIElementCreateApplication(image.pid)
        guard AXUIElementSetMessagingTimeout(app, 0.12) == .success, let raw = value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement, number = NPReadAXWindowNumber(window)
        guard number > 0, value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
        return (.init(pid: image.pid, birth: image.launch, number: number), window)
    }
    private func ordinary() -> String? {
        guard NSScreen.screens.count == 1, NPProbeReadOnlyCatalog() == 1, let rows = NPReadInventory() as? [[String:Any]], rows.count == 1,
              let row = rows.first?["Current Space"] as? [String:Any], row["type"] as? Int == 0,
              let uuid = (row["uuid"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return uuid.uuidString
    }
    private func hid() -> [UInt32] {
        let events: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .mouseMoved]
        return events.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }
    private func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path,nil) else { return nil }; defer { free(resolved) }; return String(cString:resolved)
    }
    private func verifyFixture(_ app: URL) throws {
        guard canonical(app.path) == app.path, app.lastPathComponent == "Interactive Windows.app",
              app.deletingLastPathComponent().deletingLastPathComponent().path == "/private/tmp",
              app.deletingLastPathComponent().lastPathComponent.hasPrefix("nearpane-mini-owner.") else { throw Refusal("fixturePath") }
        var code: SecStaticCode?, req: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.holdsnow.nearpane.stage-interactive-fixture\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &req) == errSecSuccess,
              let req, SecStaticCodeCheckValidity(code, .init(rawValue: kSecCSStrictValidate), req) == errSecSuccess else { throw Refusal("fixtureSignature") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEARPANE_NATIVE_MINIMIZE_RECEIPT"] != nil))
    func observeSignedInactiveSiblingAcrossItsOwnMinimizeAndRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEARPANE_NATIVE_MINIMIZE_RECEIPT"], let kit = env["NEARPANE_NATIVE_MINIMIZE_KIT"] else { throw Refusal("enrollmentArguments") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let nonce = String(folder.lastPathComponent.dropFirst("nearpane-mini.".count))
        var dir = stat()
        try require(canonical(path) == path && folder.deletingLastPathComponent().path == "/private/tmp" && folder.lastPathComponent == "nearpane-mini." + nonce && UUID(uuidString: nonce)?.uuidString.lowercased() == nonce && lstat(folder.path, &dir) == 0 && (dir.st_mode & S_IFMT) == S_IFDIR && (dir.st_mode & 0o777) == 0o700 && dir.st_uid == getuid(), "privateEnrollment")
        let dest = folder.appendingPathComponent("result.json"), app = URL(fileURLWithPath: kit).appendingPathComponent("Interactive Windows.app")
        try require(!FileManager.default.fileExists(atPath: dest.path), "oneReceiptOnly")
        var facts: [String:Any] = ["scope":"independent AX minimize observer only", "nativeStageQualification":"NOT_RUN", "fixtureLaunched":false,
                                   "observerTrusted": AXIsProcessTrusted(), "observerPID":getpid(), "nonce":nonce, "status":"BLOCKED"]
        let observer = AppleStageMinimizeObserver(), process = Process(), input = Pipe(), output = Pipe()
        var buffer = Data(), timeline = [[String:Any]](), started = false, closed = false
        func checkpoint(_ stage: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["stage":stage,"nonce":nonce,"uptime":ProcessInfo.processInfo.systemUptime,"fixtureTimeline":timeline] as [String:Any],options: [.sortedKeys])
            try data.write(to: folder.appendingPathComponent("progress.json"),options: .atomic)
        }
        func save() throws {
            facts["fixtureTimeline"] = timeline
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted,.sortedKeys]).write(to: dest, options: .withoutOverwriting)
        }
        func send(_ name: String) throws { try input.fileHandleForWriting.write(contentsOf: Data("\(nonce) \(name)\n".utf8)) }
        func message(_ name: String) async throws -> [String:Any] {
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let end = ProcessInfo.processInfo.systemUptime + 3
            while !buffer.contains(10) {
                if poll(&fd, 1, 0) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 2048); let n = Darwin.read(fd.fd, &bytes, bytes.count)
                    guard n > 0, buffer.count + n <= 8192 else { throw Refusal("fixtureEOF") }; buffer.append(contentsOf: bytes.prefix(n))
                } else { guard ProcessInfo.processInfo.systemUptime < end else { throw Refusal("fixtureReplyDeadline") }; try await pause() }
            }
            let line = buffer.prefix(while: { $0 != 10 }); let raw = try JSONSerialization.jsonObject(with: line)
            buffer.removeFirst(line.count + 1)
            guard let json = raw as? [String:Any], json["nonce"] as? String == nonce, json["phase"] as? String == name else { throw Refusal("fixturePhase-" + name) }
            timeline.append(json); try checkpoint(name); return json
        }
        do {
            try verifyFixture(app)
            guard AXIsProcessTrusted() else { throw Refusal("observerAXPermissionUnavailable") }
            guard let space = ordinary(), let original = focus() else { throw Refusal("ordinaryDeskOrOriginalFocusUnavailable") }
            let counts = hid()
            func safe() -> Bool { guard let current = focus() else { return false }; return current.0 == original.0 && CFEqual(current.1, original.1) && hid() == counts && ordinary() == space }
            try await pause(); try require(safe(), "originalFocusDesktopOrHIDChanged")
            process.executableURL = app.appendingPathComponent("Contents/MacOS/InteractiveWindows"); process.arguments = ["--self-minimize", nonce]
            process.standardInput = input; process.standardOutput = output; try process.run(); started=true; facts["fixtureLaunched"]=true
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            let owner = try await message("process"); let pid = process.processIdentifier
            guard owner["pid"] as? Int32 == pid, let birth = owner["birth"] as? UInt64, (try? OrdinaryProcessImage.read(pid).launch) == birth,
                  let hash = owner["cdhash"] as? String, let digest = try? OrdinaryProcessImage.signingDigest(pid), digest.map({String(format:"%02x",$0)}).joined() == hash,
                  safe() else { throw Refusal("ownerOrForegroundMismatch") }
            try send("open"); let w = try await message("windows")
            guard let first = w["sibling"] as? UInt32, let second = w["target"] as? UInt32, first > 0, second > 0, first != second else { throw Refusal("fixtureWindows") }
            let sibling = DesktopWindowKey(pid:pid,birth:birth,number:first), target = DesktopWindowKey(pid:pid,birth:birth,number:second)
            let appAX = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(appAX, 0.12)
            guard let windows = value(appAX,kAXWindowsAttribute) as? [AXUIElement], windows.count == 2,
                  let a = windows.first(where:{ NPReadAXWindowNumber($0) == first }), let b = windows.first(where:{ NPReadAXWindowNumber($0) == second }) else { throw Refusal("unconfirmedFixtureAXPair") }
            func confirm(_ state: Bool) -> Bool {
                safe() && (try? OrdinaryProcessImage.read(pid).launch) == birth && NPReadAXWindowNumber(a) == first && NPReadAXWindowNumber(b) == second &&
                value(a,kAXMinimizedAttribute) as? Bool == false && value(b,kAXMinimizedAttribute) as? Bool == state
            }
            var changes = 0
            observer.update(targets:[sibling,target]) { changes += 1 }
            try await until { observer.observes(sibling) && observer.observes(target) }; try require(confirm(false),"originalWindowState")
            let before = changes; try send("mini"); _ = try await message("minimized")
            try await until { changes > before && confirm(true) }; facts["miniNotificationAndReadback"]="PASS"
            let afterMini = changes; try send("restore"); _ = try await message("restored")
            try await until { changes > afterMini && confirm(false) }; facts["deminiNotificationAndReadback"]="PASS"
            try send("close"); let ended = try await message("closed"); closed=true
            try await until { !process.isRunning }
            try require(process.terminationStatus == 0 && ended["ownWindowsClosed"] as? Bool == true && ended["originalForegroundUnchanged"] as? Bool == true && safe(), "cleanupAndOriginalFocus")
            facts["status"]="PASS"; facts["fixtureCleaned"]=true
        } catch {
            facts["status"] = started ? "UNKNOWN" : "BLOCKED"; facts["reason"]=(error as? Refusal)?.reason ?? String(describing:error)
            try? input.fileHandleForWriting.close()
            if started && !closed { let end=ProcessInfo.processInfo.systemUptime + 5; while process.isRunning && ProcessInfo.processInfo.systemUptime < end { try? await pause() }; facts["fixtureExited"]=(!process.isRunning) }
            observer.stop(); try save(); throw error
        }
        observer.stop(); try save()
    }
}
