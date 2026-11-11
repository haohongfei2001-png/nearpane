import Foundation
import Darwin

/// All versions using profile format 1 must hold this lease until every domain and helper has stopped.
public final class ProfileLease {
    public static let marker = Data("Nearpane P5.3\n".utf8)
    public let root: URL
    private let descriptor: Int32

    public init(root: URL) throws {
        try Self.checkPath(root)
        let fd = open(root.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "Nearpane.Profile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "资料正在使用或无法独占。请先退出另一版本，再打开 Nearpane。"])
        }
        self.root = root
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    public static func checkPath(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
    }

    public func activeGeneration() throws -> URL {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("transaction.json").path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        struct Index: Decodable { let format: Int, active: String, previous: String? }
        let pointer = root.appendingPathComponent("profile-index.json")
        try Self.checkPath(pointer)
        let handle = try FileHandle(forReadingFrom: pointer)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["imports"] is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.format == 1, UUID(uuidString: index.active)?.uuidString.lowercased() == index.active,
              index.previous.map({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 && $0 != index.active }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let generation = root.appendingPathComponent("generations/").appendingPathComponent(index.active)
        for path in ["profile.version", "Nearpane/host-configuration.json", "Nearpane/Voice/Saytile.sqlite",
                     "Nearpane/Voice/.writer-lock", "Riftlet/queue.sqlite", "Riftlet/instance.lock"] {
            let file = generation.appendingPathComponent(path)
            try Self.checkPath(file)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        guard try Data(contentsOf: generation.appendingPathComponent("profile.version")) == Self.marker else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return generation
    }
}
