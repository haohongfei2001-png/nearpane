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
        // A system move/resize event has no trustworthy author. Once observed, an old
        // pre-management frame must never overwrite the newly chosen layout on exit.
        var retainsExternalLayout: Bool?
        var externalLayout: SurfaceRect?
        var boundaryCorrections: Int?
    }
    struct Record: Codable {
        let version: Int
        let session: UUID
        let status: String
        let display: String
        let entries: [Entry]
        // Provenance for recovery review. Decoding it never creates a live window grant.
        var layout: ManagedWindowTiler? = nil
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

    /// A clean shutdown can remember permission for a desktop, never a window handle.
    /// Binding the handoff to this directory prevents a copied/imported profile inheriting it.
    private struct DesktopHandoff: Codable {
        let desktop: OrdinaryDesktopIdentity
        let device: Int64
        let inode: UInt64
    }
    private var handoff: URL { directory.appendingPathComponent("next-desktop.json") }

    func rememberCleanDesktop(_ desktop: OrdinaryDesktopIdentity) throws {
        let lease = try lock()
        try withExtendedLifetime(lease) {
            var identity = stat()
            guard !exists, lstat(directory.path, &identity) == 0 else { throw OrdinaryRefusal.storage }
            let record = DesktopHandoff(desktop: desktop, device: Int64(identity.st_dev), inode: UInt64(identity.st_ino))
            try persist(record, to: handoff)
        }
    }

    func takeCleanDesktop() throws -> OrdinaryDesktopIdentity? {
        try ProfileLease.checkPath(handoff)
        var info = stat()
        guard lstat(handoff.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw OrdinaryRefusal.storage
        }
        let lease = try lock()
        return try withExtendedLifetime(lease) {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 2048,
                  info.st_uid == getuid(), info.st_nlink == 1 else { throw OrdinaryRefusal.storage }
            let fd = open(handoff.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw OrdinaryRefusal.storage }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var actual = stat(), identity = stat()
            guard fstat(fd, &actual) == 0, actual.st_ino == info.st_ino, actual.st_dev == info.st_dev,
                  lstat(directory.path, &identity) == 0 else { throw OrdinaryRefusal.storage }
            let bytes = try handle.read(upToCount: 2049) ?? Data()
            guard unlink(handoff.path) == 0 else { throw OrdinaryRefusal.storage }
            try sync(directory)
            guard !exists, let saved = try? JSONDecoder().decode(DesktopHandoff.self, from: bytes),
                  saved.inode == UInt64(identity.st_ino), saved.device == Int64(identity.st_dev)
            else { return nil }
            return saved.desktop
        }
    }

    struct Receipt: Codable {
        let operation: UUID, session: UUID, id: ManagedWindowID, kind: String
        let previous: SurfaceRect, requested: SurfaceRect, readback: AdmissionPair
        let steps: [OrdinaryWindowStep]
    }
    func record(_ receipt: Receipt) throws {
        try persist(receipt, to: directory.appendingPathComponent("action-\(receipt.operation.uuidString).json"))
    }
    struct BoundaryRead: Codable {
        let session: UUID, id: ManagedWindowID, revision: UUID
        let previous: SurfaceRect
        let observed: AdmissionPair
    }
    func record(_ read: BoundaryRead) throws {
        try persist(read, to: directory.appendingPathComponent("boundary-\(read.revision.uuidString).json"))
    }
    struct ClosedMember: Codable {
        let session: UUID, entry: Entry, witness: OrdinaryWindowClosure
    }
    func record(_ closure: ClosedMember) throws {
        let name = "closure-\(closure.session.uuidString)-\(closure.entry.id.element.uuidString).json"
        try persist(closure, to: directory.appendingPathComponent(name))
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
