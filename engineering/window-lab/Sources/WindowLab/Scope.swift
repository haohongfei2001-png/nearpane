import AppKit
import ApplicationServices
import Darwin
import NearpaneCore
import Security
import WindowGeometryCore

package struct Refusal: Error, CustomStringConvertible {
    package let description: String
    package init(_ message: String) { description = message }
}
package func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw Refusal(reason) }
}

package struct ProcessBirth: Codable, Equatable {
    package let pid: Int32, parent: Int32, start: UInt64
    package static func read(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        try require(pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_pid == UInt32(pid) && info.pbi_uid == getuid(), "process incarnation unavailable")
        return Self(pid: pid, parent: Int32(info.pbi_ppid), start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
}

// Resolve only the already enrolled sibling fixture executable. A bundle ID or PID alone is insufficient.
package func verifyFixtureCode(_ peer: ProcessBirth, supervisor: ProcessBirth) throws {
    let current = try ProcessBirth.read(peer.pid)
    try require(current == peer && peer.parent == supervisor.pid && peer.pid != getpid(), "fixture owner changed")
    try verifySiblingCode(peer, name: "NearpaneFixtureWindows")
}

// LaunchServices supplies a PID, not a parent-child relationship. Compare the actual
// new instance to its installed signed sibling and the launch receipt on every action.
package func verifySiblingCode(_ peer: ProcessBirth, name: String) throws {
    try require(["NearpaneRegularFixture", "NearpaneFrameController", "NearpaneFixtureWindows"].contains(name)
                && peer == (try ProcessBirth.read(peer.pid)) && peer.pid != getpid(), "changed sibling incarnation")
    let expected = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("\(name).app/Contents/MacOS/\(name)").resolvingSymlinksInPath()
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    try require(proc_pidpath(peer.pid, &path, UInt32(path.count)) > 0
        && URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)).resolvingSymlinksInPath().path == expected.path,
        "fixture executable path mismatch")
    var guest: SecCode?, disk: SecStaticCode?, running: SecStaticCode?
    let flags = SecCSFlags()
    let attrs = [kSecGuestAttributePid as String: peer.pid] as CFDictionary
    try require(SecCodeCopyGuestWithAttributes(nil, attrs, flags, &guest) == errSecSuccess, "fixture code unavailable")
    guard let guest else { throw Refusal("missing live fixture code") }
    try require(SecCodeCheckValidity(guest, flags, nil) == errSecSuccess
        && SecCodeCopyStaticCode(guest, flags, &running) == errSecSuccess
        && SecStaticCodeCreateWithPath(expected as CFURL, flags, &disk) == errSecSuccess, "fixture signature invalid")
    func cdhash(_ code: SecStaticCode?) throws -> Data {
        var info: CFDictionary?
        guard let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], dict[kSecCodeInfoIdentifier as String] as? String == "org.nearpane.lab." + name,
              let hash = dict[kSecCodeInfoUnique as String] as? Data else { throw Refusal("fixture code identity mismatch") }
        return hash
    }
    try require(try cdhash(running) == cdhash(disk), "live fixture code differs from signed fixture")
}

package struct Screens: Codable, Equatable {
    package let main, secondary: String
    package let mainFrame, frame, usable: SurfaceRect
    package let rotation: Int, scale: Double, separateSpaces: Bool
    package let consoleSet: Int
    @MainActor package static func read() throws -> (Self, NSScreen) {
        let screens = NSScreen.screens
        var session: SecuritySessionId = 0, flags = SessionAttributeBits()
        guard screens.count == 2,
              let login = CGSessionCopyCurrentDictionary() as? [String: Any],
              login[kCGSessionOnConsoleKey as String] as? Bool == true,
              login[kCGSessionLoginDoneKey as String] as? Bool == true,
              login[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
              login["CGSSessionScreenIsLocked"] as? Bool != true,
              SessionGetInfo(callerSecuritySession, &session, &flags) == errSecSuccess, session != 0 else {
            throw Refusal("requires an unlocked local login and exactly two displays")
        }
        func observe(_ screen: NSScreen) throws -> (CGDirectDisplayID, DisplayCoordinateTransform) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  CGDisplayIsInMirrorSet(number.uint32Value) == 0, CGDisplayIsActive(number.uint32Value) != 0,
                  let turn = QuarterTurn(rawValue: Int(CGDisplayRotation(number.uint32Value).rounded()) % 360)
            else { throw Refusal("unusable display") }
            let id = number.uint32Value
            return (id, try .init(displayID: CFUUIDCreateString(nil, uuid) as String, appKitFrame: rect(screen.frame),
                cgBounds: rect(CGDisplayBounds(id)), backingScale: screen.backingScaleFactor, rotation: turn))
        }
        let (primary, a) = try observe(screens[0]), (other, b) = try observe(screens[1])
        let usable = try b.appKitToCG(rect(screens[1].visibleFrame))
        try require(primary == CGMainDisplayID() && other != primary && a.displayID != b.displayID
            && a.cgBounds.intersection(b.cgBounds) == nil && b.cgBounds.intersection(usable) == usable, "unsafe display arrangement")
        return (Self(main: a.displayID, secondary: b.displayID, mainFrame: SurfaceRect(a.cgBounds), frame: SurfaceRect(b.cgBounds),
                     usable: SurfaceRect(usable), rotation: b.rotation.rawValue, scale: b.backingScale, separateSpaces: NSScreen.screensHaveSeparateSpaces,
                     consoleSet: Int(session)), screens[1])
    }
}
package func rect(_ r: CGRect) -> Rect { Rect(r.minX, r.minY, r.width, r.height) }

package struct Run: Codable, Equatable {
    package var parkingStudy: Bool?
    package var productManagement: Bool?
    package let session: UUID, parent: ProcessBirth, screens: Screens, deadline: Double
    @MainActor package static func checked(_ directory: URL) throws -> Self {
        let run: Self = try readJSON(directory, "run.json")
        let attr = try FileManager.default.attributesOfItem(atPath: directory.path)
        try require(directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path
            && (attr[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() && (attr[.posixPermissions] as? NSNumber)?.intValue == 0o700,
            "unsafe session directory")
        let now = ProcessInfo.processInfo.systemUptime
        if run.productManagement == true {
            let root = directory.deletingLastPathComponent()
            let profile = root.deletingLastPathComponent()
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(root.lastPathComponent == "WorkRect" && directory.lastPathComponent == run.session.uuidString.lowercased()
                && Bundle(url: app)?.bundleIdentifier == "com.holdsnow.nearpane.alpha"
                && (try String(contentsOf: profile.appendingPathComponent("profile.version"), encoding: .utf8)) == "Nearpane P5.3\n",
                "invalid installed manager or consent profile")
        } else {
            try require(run.parent == (try ProcessBirth.read(getppid())) && run.deadline >= now && run.deadline - now <= 600,
                        "expired session or changed supervisor")
        }
        try require(try Screens.read().0 == run.screens, "display or login changed")
        return run
    }
}
package struct Member: Codable, Equatable {
    package let index: Int, id: ManagedWindowID, minimum: SurfaceRect
    package let identifier: String
    package init(index: Int, id: ManagedWindowID, width: Double, height: Double, session: UUID) {
        self.index = index; self.id = id; minimum = .init(width: width, height: height)
        identifier = session.uuidString + "/" + id.element.uuidString
    }
    package var managed: ManagedMember { .init(id, minimumWidth: minimum.width, minimumHeight: minimum.height, canResize: true) }
}
package struct OwnerState: Codable {
    package let session: UUID, owner: ProcessBirth, revision: Int, command: Int, uptime: Double
    package let members: [Member], frames: [SurfaceRect], keyOrMain: Bool, activations: Int
    package var editTokens: [String: UUID]?
    package var editing: Bool?, lastResize: UUID?, resizedWindow: ManagedWindowID?, resizedFrame: SurfaceRect?, resizeUptime: Double?, occupied: [Int]?
    package init(session: UUID, owner: ProcessBirth, revision: Int, command: Int, members: [Member],
                 frames: [SurfaceRect], keyOrMain: Bool, activations: Int) {
        self.session = session; self.owner = owner; self.revision = revision; self.command = command
        self.members = members; self.frames = frames; self.keyOrMain = keyOrMain; self.activations = activations
        uptime = ProcessInfo.processInfo.systemUptime
    }
}
package func readJSON<T: Decodable>(_ dir: URL, _ name: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
}
package func writeJSON<T: Encodable>(_ object: T, _ dir: URL, _ name: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(object).write(to: dir.appendingPathComponent(name), options: .atomic)
}
package func emit<T: Encodable>(_ object: T) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try enc.encode(object) + Data([10]))
}
