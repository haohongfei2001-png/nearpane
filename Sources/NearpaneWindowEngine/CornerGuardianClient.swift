import Darwin
import Foundation
import NearpaneCore
import Security

/// One live, independently signed recovery witness per outstanding Corner hide.
/// A restarted client never turns persisted window numbers into an actionable lease.
@MainActor final class CornerGuardianClient {
    private enum Failure: Error { case unavailable, changedLease, pendingRecovery }
    private final class Lease {
        let original: NativeStageEngineRequest
        let epoch: UInt64
        let process: Process
        let writer, reader: FileHandle
        var result: NativeStageEngineReceipt?
        var sealed = false
        init(_ original: NativeStageEngineRequest, epoch: UInt64, process: Process, writer: FileHandle, reader: FileHandle) {
            self.original = original
            self.epoch = epoch
            self.process = process
            self.writer = writer
            self.reader = reader
        }
    }
    private let profile: URL
    private var leases: [NativeSpaceWindow: Lease] = [:]
    init(profile: URL) { self.profile = profile }

    private static let helper = URL(fileURLWithPath: "/Applications/Nearpane.app/Contents/Helpers/NearpaneCornerGuardian")
    private static let identifier = "com.holdsnow.nearpane.alpha.corner-guardian"

    private static func signedHelper() -> Bool {
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Nearpane.app",
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              helper.resolvingSymlinksInPath().path == helper.path else { return false }
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        var requirement: SecRequirement?, code: SecStaticCode?
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
            SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess &&
            code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess } == true
    }

    private func same(_ a: NativeStageEngineRequest, _ b: NativeStageEngineRequest) -> Bool {
        a.backend == b.backend && a.group == b.group && a.member == b.member && a.lifetime == b.lifetime &&
            a.generation == b.generation && a.scope == b.scope && a.window == b.window && a.nativeID == b.nativeID
    }

    private func groupDirectory() throws -> URL {
        let dir = profile.appendingPathComponent(".corner-guardians", isDirectory: true)
        if mkdir(dir.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
        return dir
    }

    private static func frame(_ r: SurfaceRect) -> [Double] { [r.x, r.y, r.width, r.height] }

    private func exchange(_ data: Data, ack: UInt8, lease: Lease) async throws {
        let read = lease.reader, write = lease.writer
        try await Task.detached {
            guard data.count <= 8192 else { throw Failure.unavailable }
            try write.write(contentsOf: data)
            var p = pollfd(fd: read.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let end = ProcessInfo.processInfo.systemUptime + 5
            while true {
                let ms = Int32(max(0, (end - ProcessInfo.processInfo.systemUptime) * 1000))
                guard ms > 0 else { throw Failure.unavailable }
                let observed = poll(&p, 1, ms)
                if observed < 0 && errno == EINTR { continue }
                guard observed > 0, (try read.read(upToCount: 1)) == Data([ack]) else { throw Failure.unavailable }
                return
            }
        }.value
    }

    private func packet(_ fields: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard payload.count <= 8000 else { throw Failure.unavailable }
        var count = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + payload
    }

    func prepare(_ r: NativeStageEngineRequest, epoch: UInt64) async throws {
        guard r.backend == 1, r.operation == 3, epoch > 0, let w = r.window, let group = r.group,
              let member = r.member, let lifetime = r.lifetime, let generation = r.generation,
              let scope = r.scope, let original = r.frame, r.nativeID > 0,
              leases[w] == nil, leases.count < 32, Self.signedHelper() else { throw Failure.unavailable }
        let directory = try groupDirectory().appendingPathComponent(r.intent.uuidString.lowercased(), isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.pendingRecovery }
        let data = try packet(["phase": "prepare", "epoch": epoch, "intent": r.intent.uuidString, "group": group.uuidString,
            "member": member.uuidString, "generation": generation.uuidString, "lifetime": lifetime.uuidString,
            "display": scope.display.uuidString, "space": scope.nativeSpace.uuidString, "native": r.nativeID,
            "pid": w.pid, "birth": w.birth, "number": w.number, "frame": Self.frame(original)])
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Self.helper
        process.arguments = ["--watch", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let lease = Lease(r, epoch: epoch, process: process, writer: input.fileHandleForWriting, reader: output.fileHandleForReading)
        leases[w] = lease
        do { try await exchange(data, ack: 82, lease: lease) }
        catch {
            // prepare has not returned to the Host. No engine write can have been submitted for this intent.
            try? lease.writer.close()
            leases.removeValue(forKey: w)
            throw error
        }
    }

    func observe(_ r: NativeStageEngineRequest, receipt: NativeStageEngineReceipt) throws {
        guard r.operation == 3 else { return }
        guard let w = r.window, let l = leases[w], same(l.original, r), r.intent == l.original.intent,
              !l.sealed, l.result == nil, receipt.intent == r.intent, receipt.epoch == l.epoch,
              receipt.status == 0, receipt.nativeID == r.nativeID, receipt.flags & 190 == 190 else {
            throw Failure.pendingRecovery
        }
        l.result = receipt
    }

    func confirm(_ r: NativeStageEngineRequest, verifiedFrame: SurfaceRect) async throws {
        guard let w = r.window, let l = leases[w], same(l.original, r), l.original.intent == r.intent,
              !l.sealed, let raw = l.result, zip(Self.frame(raw.frame), Self.frame(verifiedFrame)).allSatisfy({ $0.isFinite && $1.isFinite && abs($0 - $1) <= 0.75 }) else { throw Failure.pendingRecovery }
        let data = try packet(["phase": "confirm", "intent": raw.intent.uuidString, "epoch": raw.epoch,
            "native": raw.nativeID, "status": raw.status, "flags": raw.flags, "owned": raw.owned,
            "frame": Self.frame(raw.frame), "verified": Self.frame(verifiedFrame)])
        try await exchange(data, ack: 80, lease: l)
        l.sealed = true
    }

    func disarm(_ r: NativeStageEngineRequest) async throws {
        guard [4, 5].contains(r.operation), let w = r.window, let l = leases[w], same(l.original, r), l.sealed else {
            throw Failure.pendingRecovery
        }
        try await exchange(Data([68]), ack: 68, lease: l)
        try l.writer.close()
        try l.reader.close()
        leases.removeValue(forKey: w)
    }

    func finish() async throws {
        guard leases.isEmpty else { throw Failure.pendingRecovery }
    }
}
