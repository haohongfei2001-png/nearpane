import Darwin
import Foundation

/// File-backed capability spike. The only backend in this phase is a synthetic window world.
struct VirtualWindowState: Equatable, Codable {
    let id: ManagedWindowID, display: String, workspace: UUID?, frame: SurfaceRect
    let visible: Bool, zOrder: Int, ordinary: Bool
}
struct VirtualWindowChange: Codable, Equatable {
    let original, target: VirtualWindowState
}
struct VirtualGroup: Codable, Equatable {
    let id: UUID, display: String, area: SurfaceRect, layout: ManagedWindowTiler
}
struct VirtualRecoveryRecord: Codable, Equatable {
    let version: Int, transaction: UUID, active: UUID, groups: [VirtualGroup], changes: [VirtualWindowChange]
}

protocol VirtualFixtureBackend {
    func observe(_ id: ManagedWindowID) throws -> VirtualWindowState?
    /// A competing owner, permission loss or identity mismatch must reject the compare-and-set.
    func replace(_ expected: VirtualWindowState, with new: VirtualWindowState) throws
}

/// One live writer across processes. The durable before/after pairs also cover death after a
/// successful frame write but before its callback. Never guess ownership from a window number.
final class VirtualWorkspaceExperiment {
    private let journal: URL, lease: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = directory.appendingPathComponent("virtual-recovery.json")
        lease = open(directory.appendingPathComponent("virtual-owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw WorkspaceFailure.unavailable }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { close(lease); throw WorkspaceFailure.conflict }
    }
    deinit { close(lease) }

    func pending() throws -> VirtualRecoveryRecord? {
        do {
            let record = try JSONDecoder().decode(VirtualRecoveryRecord.self, from: Data(contentsOf: journal))
            try validate(record)
            return record
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    private func validate(_ r: VirtualRecoveryRecord) throws {
        guard r.version == 1, r.groups.contains(where: { $0.id == r.active }), Set(r.groups.map(\.id)).count == r.groups.count,
              !r.changes.isEmpty, Set(r.changes.map(\.original.id)).count == r.changes.count else { throw WorkspaceFailure.identity }
        var accounted = Set<ManagedWindowID>()
        for g in r.groups {
            guard g.layout.workspace == .virtual(g.id) else { throw WorkspaceFailure.membership }
            let frames = try g.layout.frames(in: g.area)
            for (id, frame) in frames {
                guard accounted.insert(id).inserted, let change = r.changes.first(where: { $0.target.id == id }),
                      change.original.id == id, change.original.ordinary, change.target.ordinary,
                      change.target.workspace == g.id, change.target.display == g.display,
                      change.target.visible == (g.id == r.active), change.original.frame.geometry.isValid,
                      change.target.frame.geometry.isValid, !change.original.display.isEmpty,
                      (change.target.visible ? change.target.frame == frame : g.area.geometry.intersection(change.target.frame.geometry) == nil)
                else { throw WorkspaceFailure.membership }
            }
        }
        guard accounted.count == r.changes.count else { throw WorkspaceFailure.membership }
    }

    func begin(_ record: VirtualRecoveryRecord, on backend: any VirtualFixtureBackend) throws {
        guard try pending() == nil else { throw WorkspaceFailure.recoveryRequired }
        try validate(record)
        for change in record.changes {
            guard try backend.observe(change.original.id) == change.original else { throw WorkspaceFailure.identity }
        }
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        do {
            for change in record.changes {
                try backend.replace(change.original, with: change.target)
                guard try backend.observe(change.target.id) == change.target else { throw WorkspaceFailure.conflict }
            }
        } catch {
            do { try restore(on: backend) } catch { throw WorkspaceFailure.recoveryRequired }
            throw error
        }
    }
    func restore(on backend: any VirtualFixtureBackend) throws {
        guard let record = try pending() else { return }
        for change in record.changes.reversed() {
            let current = try backend.observe(change.original.id)
            if current == change.original { continue }
            guard current == change.target else { throw WorkspaceFailure.recoveryRequired }
            try backend.replace(change.target, with: change.original)
        }
        for change in record.changes {
            guard try backend.observe(change.original.id) == change.original else { throw WorkspaceFailure.recoveryRequired }
        }
        try FileManager.default.removeItem(at: journal)
    }
}
