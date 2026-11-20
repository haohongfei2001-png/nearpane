import Darwin
import Foundation
import NearpaneCore
import os

/// Opt-in diagnostics for two signed fixtures in the installed Host's isolated home.
final class PreviewPipelineAudit: Sendable {
    enum Lane: Int, CaseIterable, Sendable {
        case stream, admission, membership, lookup, cache, card, lifecycle, owner
        var label: String { String(describing: self) }
    }
    enum Reason: String, Sendable {
        case enrolled, capacityReached, complete, started, idle, blank, suspended, stopped, invalidMetadata, invalidBuffer, unknownStatus, streamError
        case allowed, leaseChanged, notPermitted, notVisible, incarnationChanged, sessionUnavailable, screenDenied, snapshotChanged, staleSnapshot
        case rosterMismatch, ownerUnavailable, publicListMissing, metadataMissing, surfaceMismatch, notDrawn, sharingDenied, offscreen, frameChanged
        case ownerChanged, kernelReadMissing, kernelReadRecovered, applicationLookupMissing, applicationLookupRecovered, bundleReadMissing, bundleReadRecovered
        case publicMembership, freshMembership, membershipUnconfirmed, streamEpochChanged
        case noFrame, streamInactive, stillMismatch, conversionFailed, invalidPixelCost, notStored, removed, current, previous, recent, mapOnly
        case liveImage, selectedImage, previousImage, outline, mounted, unmounted, created, cleared, targetChanged, ended
    }
    struct Request: Codable, Equatable {
        let token: UUID
        let hostPID: Int32, hostBirth: UInt64, hostHash: String, fixtureHash: String
    }
    struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, changed: timespec
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino; size = s.st_size; changed = s.st_ctimespec }
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size &&
                a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }
    private final class Session {
        let request: Request, targets: [NativeSpaceWindow], stamp: Stamp
        var feed, epoch: UUID
        var revision, count: UInt64
        var last = [Reason?](repeating: nil, count: Lane.allCases.count * 2)
        init(_ request: Request, _ targets: [NativeSpaceWindow], _ stamp: Stamp, _ feed: UUID, _ epoch: UUID, _ revision: UInt64) {
            self.request = request; self.targets = targets; self.stamp = stamp; self.feed = feed; self.epoch = epoch
            self.revision = revision; self.count = 0
        }
    }
    private struct Record: Encodable, Sendable {
        let stage = "preview-transition"
        let writerPID: Int32, hostBirth: UInt64, window: NativeSpaceWindow, token: UUID, feed: UUID, epoch: UUID
        let revision, ordinal: UInt64, uptime: Double, lane, reason: String
        let streamEpoch, frameSequence: UInt64?
    }
    static let limit: UInt64 = 512
    private let session = OSAllocatedUnfairLock<Session?>(uncheckedState: nil)
    private let queue = DispatchQueue(label: "com.holdsnow.nearpane.fixture-preview-audit", qos: .utility)
    private let directory: Int32
    private let verify: @Sendable (Request, [NativeSpaceWindow]) -> Bool
    init?(directory: Int32, verify: @escaping @Sendable (Request, [NativeSpaceWindow]) -> Bool = verifyGenerations) {
        let d = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard d >= 0 else { return nil }
        self.directory = d; self.verify = verify
    }
    deinit { close(directory) }

    static func verifyGenerations(_ request: Request, _ targets: [NativeSpaceWindow]) -> Bool {
        guard let key = targets.first, request.hostPID == getpid(),
              let host = try? OrdinaryProcessImage.read(getpid()), host.launch == request.hostBirth,
              host.executable.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              let fixture = try? OrdinaryProcessImage.read(key.pid), fixture.launch == key.birth,
              fixture.executable.lastPathComponent == "FieldNotes" else { return false }
        let bundle = fixture.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let kit = bundle.deletingLastPathComponent()
        var directory = stat()
        guard bundle.lastPathComponent == "Field Notes.app", fixture.executable.path == bundle.appendingPathComponent("Contents/MacOS/FieldNotes").path,
              kit.lastPathComponent.hasPrefix("nearpane-d01."), lstat(kit.path, &directory) == 0,
              directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o077 == 0,
              kit.deletingLastPathComponent().resolvingSymlinksInPath().path == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
              Bundle(url: bundle)?.bundleIdentifier == "net.example.spaces-document" else { return false }
        func digest(_ pid: pid_t) -> String? {
            (try? OrdinaryProcessImage.signingDigest(pid))?.map { String(format: "%02x", $0) }.joined()
        }
        return digest(host.pid) == request.hostHash && digest(fixture.pid) == request.fixtureHash &&
            (try? OrdinaryProcessImage.read(host.pid)) == host && (try? OrdinaryProcessImage.read(fixture.pid)) == fixture
    }

    func revoke() { session.withLockUnchecked { $0 = nil } }
    func enroll(_ request: Request?, targets: [NativeSpaceWindow], stamp: Stamp, feed: UUID, epoch: UUID, revision: UInt64) {
        guard let request, targets.count == 2, targets[0].pid == targets[1].pid, targets[0].birth == targets[1].birth,
              targets[0].number != targets[1].number else { revoke(); return }
        let already = session.withLockUnchecked { s in
            guard let s, s.request == request, s.targets == targets, s.stamp == stamp else { return false }
            if s.feed != feed || s.epoch != epoch {
                s.last = .init(repeating: nil, count: Lane.allCases.count * 2)
                s.feed = feed; s.epoch = epoch
            }
            s.revision = revision
            return true
        }
        guard !already else { return }
        revoke()
        guard verify(request, targets) else { return }
        session.withLockUnchecked { $0 = Session(request, targets, stamp, feed, epoch, revision) }
        for key in targets {
            record(.init(pid: key.pid, birth: key.birth, number: key.number), .lifecycle, .enrolled)
        }
    }
    func record(_ key: DesktopWindowKey, _ lane: Lane, _ reason: Reason, epoch: UInt64? = nil,
                sequence: UInt64? = nil, uptime: Double? = nil) {
        session.withLockUnchecked { value in
            guard let s = value, s.count <= Self.limit,
                  let i = s.targets.firstIndex(where: { $0.pid == key.pid && $0.birth == key.birth && $0.number == key.number }) else { return }
            let slot = i * Lane.allCases.count + lane.rawValue
            guard s.last[slot] != reason else { return }
            s.last[slot] = reason
            s.count += 1
            let entry = Record(writerPID: getpid(), hostBirth: s.request.hostBirth, window: s.targets[i], token: s.request.token,
                               feed: s.feed, epoch: s.epoch, revision: s.revision, ordinal: s.count,
                               uptime: uptime ?? ProcessInfo.processInfo.systemUptime, lane: lane.label,
                               reason: (s.count > Self.limit ? .capacityReached : reason).rawValue, streamEpoch: epoch, frameSequence: sequence)
            let stamp = s.stamp
            queue.async { [self] in append(entry, stamp: stamp) }
        }
    }
    private func append(_ row: Record, stamp: Stamp) {
        var s = stat()
        guard fstatat(directory, "p0-window-audit-targets.json", &s, AT_SYMLINK_NOFOLLOW) == 0, Stamp(s) == stamp,
              s.st_nlink == 1, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG, s.st_mode & 0o077 == 0,
              session.withLockUnchecked({ $0?.request.token == row.token && $0?.stamp == stamp }),
              var data = try? JSONEncoder().encode(row) else { return }
        data.append(10)
        let fd = openat(directory, "p0-preview-transitions.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }; defer { close(fd) }
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & S_IFMT == S_IFREG, s.st_mode & 0o077 == 0,
              s.st_size >= 0, s.st_size + Int64(data.count) <= 384 * 1024 else { return }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    func drainForTesting() { queue.sync {} }
}
