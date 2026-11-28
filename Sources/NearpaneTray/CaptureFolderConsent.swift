import Foundation
import Darwin

/// Local consent for ONE user-selected folder, not a general Desktop grant. No bookmarks
/// from another installation. Resolve without UI or mounting; fail closed on replacement.
struct CaptureFolderConsent: Codable, Equatable {
    let bookmark: Data
    let path: String
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int
    let birthNanos: Int

    static func location(in library: URL) -> URL { library.appendingPathComponent("nearpane-capture-source.json") }

    init(selected: URL) throws {
        guard selected.isFileURL, selected.standardizedFileURL.path == selected.resolvingSymlinksInPath().path
        else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        guard lstat(selected.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadNoPermission) }
        path = selected.standardizedFileURL.path
        device = info.st_dev; inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec; birthNanos = info.st_birthtimespec.tv_nsec
        // The local Alpha is not App Sandbox entitled. A regular native bookmark is an
        // identity hint, never a way to obtain a new permission or substitute another path.
        bookmark = try selected.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolves(_ selected: URL) -> Bool {
        var info = stat()
        return selected.isFileURL && selected.standardizedFileURL.path == path && selected.resolvingSymlinksInPath().path == path
            && lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_dev == device && info.st_ino == inode
            && info.st_birthtimespec.tv_sec == birthSeconds && info.st_birthtimespec.tv_nsec == birthNanos
    }

    func directory() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, resolves(url) else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    func save(in library: URL) throws {
        _ = try directory()
        try JSONEncoder().encode(self).write(to: Self.location(in: library), options: .atomic)
    }

    static func read(in library: URL) throws -> Self? {
        let url = location(in: library)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size < 131072,
              let data = try file.read(upToCount: Int(info.st_size)), data.count == info.st_size
        else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func forget(in library: URL) throws {
        if unlink(location(in: library).path) != 0 && errno != ENOENT { throw CocoaError(.fileWriteNoPermission) }
    }
}
