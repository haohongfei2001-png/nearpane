import Darwin
import Foundation
import NearpaneCore

/// Window numbers identify lock names only. A lock never confers permission to write a window.
final class OrdinaryFileLease {
    let descriptor: Int32
    init(_ file: URL) throws {
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        var st = stat()
        guard fd >= 0 else { throw WorkspaceFailure.conflict }
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == getuid(), st.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw WorkspaceFailure.conflict
        }
        descriptor = fd
    }
    deinit { close(descriptor) }

    static func forWindow(_ id: ManagedWindowID) throws -> OrdinaryFileLease {
        // Shared across profiles and Alpha installations, private to this login user.
        let folder = URL(fileURLWithPath: "/private/tmp/com.holdsnow.nearpane.window-leases.\(getuid())", isDirectory: true)
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { throw WorkspaceFailure.conflict }
        var st = stat()
        guard lstat(folder.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o077 == 0,
              st.st_uid == getuid() else { throw WorkspaceFailure.conflict }
        return try OrdinaryFileLease(folder.appendingPathComponent("\(id.pid).\(id.launch).\(id.number).lock"))
    }
}

struct OrdinaryJournal {
    struct Entry: Codable {
        let id: ManagedWindowID
        let bundle: String
        let original: SurfaceRect
        var confirmed: SurfaceRect
        var intended: SurfaceRect?
        var operation: UUID?
        var refusal: String?
    }
    struct Record: Codable {
        let version: Int
        let session: UUID
        let status: String
        let display: String
        let entries: [Entry]
    }
    let directory: URL
    init(support: URL) { directory = support.appendingPathComponent("WorkRect/ordinary", isDirectory: true) }
    var file: URL { directory.appendingPathComponent("journal.json") }
    var exists: Bool {
        var st = stat()
        return lstat(file.path, &st) == 0 || errno != ENOENT
    }

    func lock() throws -> OrdinaryFileLease {
        let fm = FileManager.default
        try ProfileLease.checkPath(directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try sync(directory.deletingLastPathComponent())
        try sync(directory.deletingLastPathComponent().deletingLastPathComponent())
        return try OrdinaryFileLease(directory.appendingPathComponent("session.lock"))
    }

    private func sync(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func publish(_ record: Record) throws { try persist(record, to: file) }

    struct Receipt: Codable {
        let operation: UUID, session: UUID, id: ManagedWindowID, kind: String
        let previous: SurfaceRect, requested: SurfaceRect, readback: AdmissionPair
        let steps: [OrdinaryWindowStep]
    }
    func record(_ receipt: Receipt) throws {
        try persist(receipt, to: directory.appendingPathComponent("action-\(receipt.operation.uuidString).json"))
    }

    private func persist(_ record: some Encodable, to destination: URL) throws {
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(record)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temp.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try sync(directory)
    }

    /// Retain the finished receipt. Keeping a crash receipt and the current user layout is a separate explicit action.
    func archive(as outcome: String) throws {
        let name = directory.appendingPathComponent("\(outcome)-\(UUID().uuidString).json")
        guard rename(file.path, name.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try sync(directory)
    }
}
