import Darwin
import Foundation
import NearpaneCore

/// An isolated acceptance home can request evidence about its two fixture window
/// identities. No process arguments, bundle names, titles, geometry or pixels are read here.
@MainActor final class NativeSidebarWindowAudit {
    private struct Manifest: Decodable { let version: Int, targets: [NativeSpaceWindow]; let previewTrace: PreviewPipelineAudit.Request? }
    private let directory: Int32
    let previewTrace: PreviewPipelineAudit?

    init?(environment: [String: String] = ProcessInfo.processInfo.environment, cachesForTesting: URL? = nil,
          verifyTrace: @escaping @Sendable (PreviewPipelineAudit.Request, [NativeSpaceWindow]) -> Bool = PreviewPipelineAudit.verifyGenerations) {
        guard let raw = environment["CFFIXED_USER_HOME"], let pw = getpwuid(getuid()) else { return nil }
        let home = URL(fileURLWithPath: raw, isDirectory: true)
        let parent = home.deletingLastPathComponent()
        let caches = cachesForTesting ?? URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        guard home.path == home.resolvingSymlinksInPath().path, home.lastPathComponent == "home",
              parent.lastPathComponent.hasPrefix("nearpane-native-acceptance."), parent.deletingLastPathComponent().path == caches.path,
              Self.privateDirectory(parent.path) else { return nil }
        let fd = open(home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        var info = stat()
        guard fd >= 0 else { return nil }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); return nil }
        directory = fd
        previewTrace = environment["NEARPANE_PREVIEW_DIAGNOSTICS"] == "1" && environment["NEARPANE_TEST_HOME"] == raw
            ? PreviewPipelineAudit(directory: fd, verify: verifyTrace) : nil
    }

    deinit { close(directory) }

    private static func privateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    private func safeFile(_ fd: Int32, maximum: Int64) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0 &&
            info.st_mode & S_IFMT == S_IFREG && info.st_size >= 0 && info.st_size < maximum
    }

    func sample(feed: UUID, epoch: UUID, revision: UInt64) -> Sample? {
        var accepted = false
        defer { if !accepted { previewTrace?.revoke() } }
        let fd = openat(directory, "p0-window-audit-targets.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard safeFile(fd, maximum: 2048) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 2048)
        let length = Darwin.read(fd, &bytes, bytes.count)
        guard length > 0, let m = try? JSONDecoder().decode(Manifest.self, from: Data(bytes.prefix(length))),
              m.version == 1, (1...2).contains(m.targets.count), Set(m.targets).count == m.targets.count,
              m.targets.allSatisfy({ $0.pid > 1 && $0.birth > 0 && $0.number > 0 }) else { return nil }
        if let previewTrace {
            var status = stat()
            if fstat(fd, &status) == 0 {
                previewTrace.enroll(m.previewTrace, targets: m.targets, stamp: .init(status), feed: feed, epoch: epoch, revision: revision)
                accepted = true
            }
        }
        return Sample(sink: self, targets: m.targets, feed: feed, epoch: epoch, revision: revision)
    }

    private func append(_ row: [String: Any]) {
        guard var bytes = try? JSONSerialization.data(withJSONObject: row), bytes.count < 32768 else { return }
        bytes.append(10)
        let fd = openat(directory, "p0-window-audit.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard safeFile(fd, maximum: 2_000_000) else { return }
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    struct Sample {
        fileprivate let sink: NativeSidebarWindowAudit
        let targets: [NativeSpaceWindow]
        let feed, epoch: UUID
        let revision: UInt64

        @MainActor func event(_ stage: String, _ fields: [String: Any] = [:], window: NativeSpaceWindow? = nil) {
            var row = fields
            if let window {
                guard targets.contains(window) else { return }
                row["window"] = ["pid": NSNumber(value: window.pid), "birth": NSNumber(value: window.birth), "number": NSNumber(value: window.number)]
            }
            row["stage"] = stage; row["uptime"] = ProcessInfo.processInfo.systemUptime; row["writerPID"] = getpid()
            row["feed"] = feed.uuidString; row["epoch"] = epoch.uuidString; row["revision"] = revision
            sink.append(row)
        }

        @MainActor func snapshot(_ snapshot: DesktopSnapshot, stage: String) {
            let uptime = ProcessInfo.processInfo.systemUptime, now = Date()
            for key in targets {
                let w = snapshot.windows.first { $0.metadata?.pid == key.pid && $0.metadata?.number == key.number &&
                    $0.metadata?.launchMicroseconds == key.birth }
                var fields: [String: Any] = ["readerPopulation": snapshot.native?.population.rawValue ?? "none",
                    "readerSpaces": snapshot.native?.spaces.rawValue ?? "none", "readerAccessibility": snapshot.native?.accessibility.rawValue ?? "none",
                    "readerEmittedTarget": w != nil, "readerHasScopedAudit": snapshot.native?.sidebarWindowAudit != nil]
                if let proof = snapshot.native?.sidebarWindowAudit?.first(where: { $0.window == key }) { fields["reader"] = proof.flags }
                if let w, let m = w.metadata {
                    fields["readerOrdinary"] = m.overviewOrdinaryRole
                    fields["readerPresented"] = m.overviewIsPresented
                    fields["readerCurrentMembership"] = m.overviewSpaceID
                    fields["readerMinimized"] = m.minimized; fields["readerFullscreen"] = m.fullScreen
                    fields["readerCGOnscreen"] = m.isOnscreen; fields["readerAppKitActive"] = m.onActiveDesktop
                    fields["originalAvailable"] = w.sidebarOriginalWindow != nil
                    if case let .known(ids) = w.membership { fields["spaceIDs"] = ids }
                    let catalog = NativeSpaceCatalog(snapshot, displayID: w.displayID, now: now, uptime: uptime)
                    fields["catalogAvailable"] = catalog != nil
                    fields["currentModel"] = snapshot.currentDesktopWindows(on: w.displayID, now: now, uptime: uptime).contains { $0.id == w.id }
                    fields["backgroundModel"] = catalog.map { SidebarBackgroundWindows.sections(in: $0).contains { s in s.windows.contains { $0.id == w.id } } }
                }
                event(stage, fields, window: key)
            }
        }
    }
}
