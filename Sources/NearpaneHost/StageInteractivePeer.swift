import AppKit
import Darwin
import Foundation
import NearpaneCore
import Security

struct StagePairRefusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

/// One signed, nonce-named fixture and one kernel-authenticated socket. Request data never selects a PID or path.
@MainActor final class StageInteractivePeer {
    static let identifier = "com.holdsnow.nearpane.stage-interactive-fixture"
    let nonce: UUID, directory: URL, app: URL, executable: URL, digest: String
    let hostBirth: UInt64, hostHash: String, login: UInt32
    private(set) var process: NSRunningApplication?
    private(set) var image: OrdinaryProcessImage?
    private var fd: Int32 = -1
    private var sequence = 0
    private let rule: SecRequirement

    init(_ nonce: UUID, pin: Data, hostBirth: UInt64, hostHash: String, login: UInt32) throws {
        struct Pin: Decodable { let challenge: UUID, kind: String, cdhash: String }
        let p = try JSONDecoder().decode(Pin.self, from: pin)
        guard p.challenge == nonce, p.kind == "interactiveWindowPair", p.cdhash.utf8.count == 40,
              p.cdhash.allSatisfy({ ("0123456789abcdef").contains($0) }) else { throw StagePairRefusal("invalidFixturePin") }
        self.nonce = nonce; self.hostBirth = hostBirth; self.hostHash = hostHash; self.login = login; digest = p.cdhash
        directory = URL(fileURLWithPath: "/private/tmp/nearpane-membership." + nonce.uuidString.lowercased(), isDirectory: true)
        app = directory.appendingPathComponent("Interactive Windows.app", isDirectory: true)
        executable = app.appendingPathComponent("Contents/MacOS/InteractiveWindows")
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR,
              st.st_mode & 0o777 == 0o700, let resolved = realpath(executable.path, nil) else { throw StagePairRefusal("unsafeFixtureDirectory") }
        defer { free(resolved) }
        let req = "anchor apple generic and identifier \"\(Self.identifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        var requirement: SecRequirement?, code: SecStaticCode?
        guard String(cString: resolved) == executable.path, Bundle(url: app)?.bundleIdentifier == Self.identifier,
              SecRequirementCreateWithString(req as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              Self.hash(code) == p.cdhash else { throw StagePairRefusal("staticFixtureSignatureMismatch") }
        rule = requirement
    }
    private static func hash(_ code: SecStaticCode) -> String? {
        var data: CFDictionary?
        guard SecCodeCopySigningInformation(code, .init(rawValue: kSecCSSigningInformation), &data) == errSecSuccess,
              let digest = (data as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return digest.map { String(format:"%02x", $0) }.joined()
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func disconnect() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    func launch() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier).isEmpty else {
            throw StagePairRefusal("anotherInteractiveFixtureIsRunning")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false; cfg.promptsUserIfNeeded = false; cfg.addsToRecentItems = false
        cfg.allowsRunningApplicationSubstitution = false; cfg.createsNewApplicationInstance = false
        cfg.arguments = ["--interactive-fixture", nonce.uuidString.lowercased()]
        let started = try await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        process = started
        let owner = try OrdinaryProcessImage.read(started.processIdentifier)
        var s = stat()
        guard started.bundleIdentifier == Self.identifier, started.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath(),
              lstat(executable.path,&s) == 0, owner.device == s.st_dev, owner.inode == s.st_ino,
              (try OrdinaryProcessImage.signingDigest(owner.pid)).map({ String(format:"%02x", $0) }).joined() == digest else {
            throw StagePairRefusal("launchedFixtureIdentityChanged")
        }
        image = owner
        let path = directory.appendingPathComponent("interactive.sock").path
        let ready = directory.appendingPathComponent("interactive-ready.json").path
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        var admitted = false
        while !started.isTerminated, ContinuousClock.now < end {
            let marker = open(ready, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if marker >= 0 {
                let file = FileHandle(fileDescriptor: marker, closeOnDealloc: true)
                guard fstat(marker, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(),
                      s.st_nlink == 1, s.st_mode & 0o777 == 0o600 else { throw StagePairRefusal("unsafeFixtureReadyFile") }
                if s.st_size > 0, s.st_size <= 4096, let data = try file.read(upToCount: 4097),
                   let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (r["challenge"] as? String).flatMap(UUID.init(uuidString:)) == nonce,
                   let b = r["owner"] as? [String: Any], b["identifier"] as? String == Self.identifier,
                   b["pid"] as? Int32 == owner.pid, b["birth"] as? UInt64 == owner.launch, b["cdhash"] as? String == digest {
                    admitted = true; break
                }
            } else if errno != ENOENT { throw StagePairRefusal("unreadableFixtureReadyFile") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard admitted, lstat(path, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFSOCK, s.st_mode & 0o077 == 0
        else { throw StagePairRefusal("privateFixtureSocketUnavailable") }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(), one: Int32 = 1, limit = timeval(tv_sec: 2, tv_usec: 0)
        let bytes = path.utf8CString
        guard fd >= 0, bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout.size(ofValue:one))) == 0,
              setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,socklen_t(MemoryLayout.size(ofValue:limit))) == 0,
              setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,socklen_t(MemoryLayout.size(ofValue:limit))) == 0 else {
            throw StagePairRefusal("cannotBoundFixtureSocket")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(2 + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let size = socklen_t(address.sun_len)
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard rc == 0 else { throw StagePairRefusal("fixtureSocketConnectFailed") }
        try verify()
    }
    func verify() throws {
        guard fd >= 0, let image, process?.isTerminated == false, (try? OrdinaryProcessImage.read(image.pid)) == image else {
            throw StagePairRefusal("fixtureProcessGenerationChanged")
        }
        var token = audit_token_t(), len = socklen_t(MemoryLayout<audit_token_t>.size), live: SecCode?, disk: SecStaticCode?
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0, len == MemoryLayout.size(ofValue: token),
              token.val.1 == getuid(), token.val.5 == UInt32(image.pid), token.val.6 == login else {
            throw StagePairRefusal("fixturePeerAuditTokenChanged")
        }
        let audit = withUnsafeBytes(of: token) { Data($0) }
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: audit] as CFDictionary, [], &live) == errSecSuccess, let live,
              SecCodeCheckValidity(live,.init(rawValue:kSecCSStrictValidate),rule) == errSecSuccess,
              SecCodeCopyStaticCode(live, [], &disk) == errSecSuccess, let disk, Self.hash(disk) == digest else {
            throw StagePairRefusal("fixtureSocketSignerChanged")
        }
    }
    func exchange(_ op: String, _ args: [String: Any] = [:], beforeSend: () throws -> Void = {}) throws -> [String: Any] {
        try verify()
        guard let image else { throw StagePairRefusal("fixtureNotConnected") }
        var message = args
        message["op"] = op; message["seq"] = sequence + 1; message["challenge"] = nonce.uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) + Data([10])
        guard data.count <= 2048 else { throw StagePairRefusal("fixtureRequestTooLarge") }
        try beforeSend()
        sequence += 1
        guard data.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == data.count else {
            throw StagePairRefusal("fixtureRequestDeliveryUnknown")
        }
        var answer = Data(), bytes = [UInt8](repeating: 0, count: 2048)
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while answer.count <= 16_384, ContinuousClock.now < limit {
            let n = recv(fd, &bytes, bytes.count, 0)
            guard n > 0 else { throw StagePairRefusal("fixtureReplyUnavailable") }
            answer.append(contentsOf: bytes.prefix(n))
            if answer.contains(10) { break }
        }
        guard answer.count <= 16_384, answer.last == 10, answer.dropLast().contains(10) == false,
              let row = try JSONSerialization.jsonObject(with: answer) as? [String: Any],
              row["schema"] as? Int == 1, row["seq"] as? Int == sequence, row["op"] as? String == op,
              (row["challenge"] as? String).flatMap(UUID.init(uuidString:)) == nonce,
              let owner = row["owner"] as? [String: Any], owner["identifier"] as? String == Self.identifier,
              owner["pid"] as? Int32 == image.pid, owner["birth"] as? UInt64 == image.launch, owner["cdhash"] as? String == digest,
              let host = row["host"] as? [String: Any], host["pid"] as? Int32 == getpid(),
              host["birth"] as? UInt64 == hostBirth, host["cdhash"] as? String == hostHash, host["securitySession"] as? UInt32 == login
        else { throw StagePairRefusal("fixtureReplyIdentityOrSequenceChanged") }
        return row
    }
}
