import Foundation
import Darwin
import RiftletCapture
import RiftletCore

/// The picker grant is session-local and bound to a directory identity. Never import
/// Riftlet's bookmarks or silently authorize a replacement folder at the same path.
private final class FolderGrant: @unchecked Sendable {
    let directory: URL
    let device: dev_t
    let inode: ino_t
    let scoped: Bool
    init(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw CocoaError(.fileReadNoPermission)
        }
        self.scoped = scoped; directory = url; device = info.st_dev; inode = info.st_ino
    }
    func permits(_ url: URL) -> Bool {
        var info = stat()
        return url.standardizedFileURL.path == directory.standardizedFileURL.path &&
            lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
            device == info.st_dev && inode == info.st_ino
    }
    deinit { if scoped { directory.stopAccessingSecurityScopedResource() } }
}

@MainActor
final class TrayCollection {
    let binding: CaptureSourceBinding
    init(owner: TrayOwner, selected: URL, provider: any CaptureLocationProviding) throws {
        let grant = try FolderGrant(selected)
        let root = owner.root.standardizedFileURL.path
        let source = selected.resolvingSymlinksInPath().path
        guard source != root, !source.hasPrefix(root + "/"), !root.hasPrefix(source + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let change = owner.notify, report = owner.report
        let magnet = owner.magnetEnabled
        let arrival: @MainActor @Sendable (TrayArrival) -> Void = { [weak owner] in owner?.arrived?($0) }
        let service = CaptureService(store: owner.store, privateRoot: owner.root, sourceDirectory: selected,
            permitsRead: { grant.permits($0) }, onChange: { await change() },
            onImported: { row, observation in
                guard magnet else { return }
                Task(priority: .utility) {
                    guard case let .success(metadata) = observation.readMetadata() else { return }
                    await arrival(.init(id: row.id, ready: observation.readyUptime, source: .system(metadata)))
                }
            },
            onIssue: { _ in await report("系统截图目录暂不可用；已保留原队列。") })
        binding = CaptureSourceBinding(service: service, provider: provider, permitsSource: { grant.permits($0) },
            onIssue: { _ in await report("系统截图位置已改变，请重新选择目录。") })
    }
}
