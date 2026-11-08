import Foundation
import CSQLite
import RiftletCore

enum LibraryError: LocalizedError {
    case absent, busy, incompatible
    var errorDescription: String? {
        switch self {
        case .absent: return "未找到已有的 Riftlet 资料库。"
        case .busy: return "Riftlet 资料库正被占用，无法连接。"
        case .incompatible: return "此资料库格式不兼容；没有执行迁移。"
        }
    }
}

/// Opening QueueStore directly can CREATE or migrate. Require the existing app lock and exact
/// production format first. The pinned upstream lock is also held by the standalone app.
struct ExistingLibrary {
    let lock: ApplicationInstanceOwnership
    let store: QueueStore
    static func open(_ root: URL) throws -> Self {
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw LibraryError.absent }
        let db = root.appendingPathComponent("queue.sqlite")
        for name in ["queue.sqlite", "instance.lock"] {
            let url = root.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.absent }
        }
        guard let lock = try? ApplicationInstanceOwnership(root: root) else { throw LibraryError.busy }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close(handle) }
        func scalar(_ query: String) -> String? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        guard rc == SQLITE_OK, scalar("PRAGMA user_version") == "4",
              scalar("SELECT value FROM metadata WHERE key='mode'") == StoreMode.production.rawValue else {
            throw LibraryError.incompatible
        }
        return try .init(lock: lock, store: QueueStore(databaseURL: db, mode: .production))
    }
}
