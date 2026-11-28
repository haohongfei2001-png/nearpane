import Darwin
import Foundation
import NearpaneCore

/// Correlates a former private-pipe worker with its durable owner. This record
/// grants no window authority and is never used to reconstruct a native lease.
package enum SpacesWorkerLifecycle {
    package static func trace(_ phase: String, _ fields: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] == "1" else { return }
        var row = fields
        row["event"] = "spacesHostLifecycle"; row["phase"] = phase
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return }
        data.append(10)
        try? FileHandle.standardError.write(contentsOf: data)
    }

    struct ProcessStamp: Codable, Equatable, Sendable {
        let pid: Int32, birth: UInt64, executable: String

        static func read(_ pid: Int32) throws -> Self {
            let image = try OrdinaryProcessImage.read(pid)
            return .init(pid: pid, birth: image.launch, executable: image.executable.path)
        }
    }

    struct Record: Codable, Equatable, Sendable {
        let schema: Int
        let owner: StageEngineOwner
        let nonce, bootID: UUID
        let host, worker: ProcessStamp
        let diagnostic: String
    }

    package struct Completion: Equatable, Sendable {
        fileprivate let record: Record
        package let previousBoot: Bool
    }

    private struct Terminal: Decodable {
        let event, phase: String
        let lifecycleNonce: UUID
        let pid, parentPID: Int32
        let birth, parentBirth: UInt64
        let transport, owned, flags: UInt32
        let engineDestroyed, pendingDrained: Bool
    }

    static func bootID() -> UUID? {
        var value = [CChar](repeating: 0, count: 128), count = 128
        guard sysctlbyname("kern.bootsessionuuid", &value, &count, nil, 0) == 0,
              count > 1, count <= value.count else { return nil }
        return UUID(uuidString: String(decoding: value.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
    }

    static func location(owner: StageEngineOwner, profile: URL) -> URL {
        profile.appendingPathComponent("spaces-lifecycle-" + owner.generation.uuidString.lowercased() + ".json")
    }

    /// Publish before any NP_LAUNCH request can leave the Host. The child has only
    /// opened its empty engine at this point; a failed publication closes its pipe.
    static func publish(owner: StageEngineOwner, profile: URL, nonce: UUID,
                        host: ProcessStamp, worker: ProcessStamp) throws {
        guard let bootID = bootID() else { throw StageSwitchError.recoveryRequired }
        let record = Record(schema: 1, owner: owner, nonce: nonce, bootID: bootID, host: host, worker: worker,
                            diagnostic: "spaces-worker-" + nonce.uuidString.lowercased() + ".jsonl")
        guard valid(record, owner: owner), host == (try ProcessStamp.read(getpid())),
              worker == (try ProcessStamp.read(worker.pid)) else { throw StageSwitchError.ownership }
        try ProfileLease.checkPath(profile)
        let destination = location(owner: owner, profile: profile)
        let temporary = profile.appendingPathComponent(".spaces-lifecycle-" + UUID().uuidString.lowercased() + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        let bytes = try JSONEncoder().encode(record)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        // link() publishes only if this owner's immutable association is still absent.
        guard link(temporary.path, destination.path) == 0, unlink(temporary.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try ProfileLease.syncDirectory(profile)
        guard try read(destination, maximum: 64 * 1024) == bytes else { throw StageSwitchError.recoveryRequired }
    }

    private static func valid(_ record: Record, owner: StageEngineOwner) -> Bool {
        guard record.schema == 1, record.owner == owner, owner.backend == .spaces,
              record.bootID.uuidString != "00000000-0000-0000-0000-000000000000",
              record.nonce.uuidString != "00000000-0000-0000-0000-000000000000",
              record.host.pid > 1, record.worker.pid > 1, record.host.pid != record.worker.pid,
              record.host.birth > 0, record.worker.birth > 0,
              record.host.executable.hasPrefix("/"), record.worker.executable.hasPrefix("/"),
              record.diagnostic == "spaces-worker-" + record.nonce.uuidString.lowercased() + ".jsonl" else { return false }
        let host = URL(fileURLWithPath: record.host.executable)
        let helper = host.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/NearpaneSpacesEngine")
        return host.lastPathComponent == "NearpaneHost" && helper.path == record.worker.executable
    }

    /// No signal is sent. A failed read is unknown unless proc_pidinfo itself
    /// reports ESRCH; a positive different birth also proves the former process ended.
    static func exited(_ stamp: ProcessStamp) -> Bool {
        guard stamp.pid > 1, stamp.birth > 0 else { return false }
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: process))
        errno = 0
        let count = proc_pidinfo(stamp.pid, PROC_PIDTBSDINFO, 0, &process, size), error = errno
        if count == size {
            guard process.pbi_pid == UInt32(stamp.pid), process.pbi_uid == getuid(),
                  process.pbi_start_tvsec > 0, process.pbi_start_tvusec < 1_000_000 else { return false }
            return process.pbi_start_tvsec * 1_000_000 + process.pbi_start_tvusec != stamp.birth
        }
        return count <= 0 && error == ESRCH
    }

    /// An exact previous boot retires the former WindowServer as well as both
    /// processes. On this boot, require both process exits and the terminal record.
    package static func completed(owner: StageEngineOwner, profile: URL) -> Completion? {
        do {
            try ProfileLease.checkPath(profile)
            let bytes = try read(location(owner: owner, profile: profile), maximum: 64 * 1024)
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard valid(record, owner: owner), let currentBoot = bootID() else { return nil }
            if record.bootID != currentBoot { return .init(record: record, previousBoot: true) }
            guard exited(record.host), exited(record.worker) else { return nil }
            let log = try read(profile.appendingPathComponent(record.diagnostic), maximum: 64 * 1024, tail: true)
            guard terminal(log, for: record), exited(record.host), exited(record.worker),
                  bootID() == currentBoot,
                  try read(location(owner: owner, profile: profile), maximum: 64 * 1024) == bytes else { return nil }
            return .init(record: record, previousBoot: false)
        } catch { return nil }
    }

    // Tested with independent receipts: a ready/pending/error line cannot stand
    // in for destroyed native ownership, even if all foreign windows look home.
    static func terminal(_ data: Data, for record: Record) -> Bool {
        guard data.last == 10, let line = data.split(separator: 10).last,
              let row = try? JSONDecoder().decode(Terminal.self, from: Data(line)),
              row.event == "spacesWorker", row.phase == "released" || row.phase == "closed",
              row.lifecycleNonce == record.nonce, row.pid == record.worker.pid, row.birth == record.worker.birth,
              row.parentPID == record.host.pid, row.parentBirth == record.host.birth,
              row.transport == 0, row.owned == 0, row.flags & 128 == 0,
              row.engineDestroyed, row.pendingDrained else { return false }
        return true
    }

    private static func read(_ url: URL, maximum: Int, tail: Bool = false) throws -> Data {
        try ProfileLease.checkPath(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, tail || info.st_size <= Int64(maximum) else { throw CocoaError(.fileReadCorruptFile) }
        if tail, info.st_size > Int64(maximum) { try handle.seek(toOffset: UInt64(info.st_size - Int64(maximum))) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximum else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
