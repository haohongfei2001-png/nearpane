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
    let version: Int, transaction: UUID, active: UUID, changes: [VirtualWindowChange]
    var groups: [VirtualGroup]
    var removedGroups: [VirtualGroup] = []
    var quitTargets: [ManagedWindowID: VirtualWindowState] = [:]
    var excludedAtQuit = Set<ManagedWindowID>()
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        transaction = try c.decode(UUID.self, forKey: .transaction)
        active = try c.decode(UUID.self, forKey: .active)
        groups = try c.decode([VirtualGroup].self, forKey: .groups)
        changes = try c.decode([VirtualWindowChange].self, forKey: .changes)
        removedGroups = try c.decodeIfPresent([VirtualGroup].self, forKey: .removedGroups) ?? []
        quitTargets = try c.decodeIfPresent([ManagedWindowID: VirtualWindowState].self, forKey: .quitTargets) ?? [:]
        excludedAtQuit = try c.decodeIfPresent(Set<ManagedWindowID>.self, forKey: .excludedAtQuit) ?? []
    }
    init(version: Int, transaction: UUID, active: UUID, groups: [VirtualGroup], changes: [VirtualWindowChange]) {
        self.version = version
        self.transaction = transaction
        self.active = active
        self.groups = groups
        self.changes = changes
    }
}

protocol VirtualFixtureBackend {
    func inventory() throws -> [VirtualWindowState]
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
        let candidate = open(
            directory.appendingPathComponent("virtual-owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard candidate >= 0 else { throw WorkspaceFailure.unavailable }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            close(candidate)
            throw WorkspaceFailure.conflict
        }
        lease = candidate
    }
    deinit {
        // A concurrently spawned helper may briefly inherit the open file description before exec.
        // Unlock explicitly; failed contenders never own an initialized lease.
        _ = flock(lease, LOCK_UN)
        close(lease)
    }

    func pending() throws -> VirtualRecoveryRecord? {
        do {
            let record = try JSONDecoder().decode(VirtualRecoveryRecord.self, from: Data(contentsOf: journal))
            try validate(record)
            return record
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    private func validate(_ r: VirtualRecoveryRecord) throws {
        guard r.version == 1, r.groups.contains(where: { $0.id == r.active }),
            Set(r.groups.map(\.id)).count == r.groups.count,
            !r.changes.isEmpty, Set(r.changes.map(\.original.id)).count == r.changes.count
        else { throw WorkspaceFailure.identity }
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
                    change.target.visible
                        ? change.target.frame == frame : g.area.geometry.intersection(change.target.frame.geometry) == nil
                else { throw WorkspaceFailure.membership }
            }
        }
        guard r.excludedAtQuit.isSubset(of: accounted),
            r.quitTargets.allSatisfy({ key, value in
                accounted.contains(key) && value.id == key && value.frame.geometry.isValid && value.visible && value.ordinary
            }), accounted.count == r.changes.count
        else { throw WorkspaceFailure.membership }
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
    func removeEmptySource(
        _ e: EmptySourceEvidence, current: WorkspaceSnapshot, uptime: Double,
        on backend: any VirtualFixtureBackend
    ) throws -> CleanupDisposition {
        let decision = EmptyWorkspaceCleanup.evaluate(e, current: current, uptime: uptime, isolated: true)
        guard case .requestDeletion(.virtual(let source)) = decision else { return decision }
        guard var record = try pending(), record.active != source, record.groups.count > 1,
            let index = record.groups.firstIndex(where: { $0.id == source && $0.layout.members.isEmpty }),
            record.changes.contains(where: {
                $0.original.id == e.departed && $0.original.workspace == source && $0.target.workspace != source
            }),
            try !backend.inventory().contains(where: { $0.workspace == source })
        else { return .preserve }
        let baseline = record
        record.removedGroups.append(record.groups.remove(at: index))
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        do {
            guard try pending() == record, try !backend.inventory().contains(where: { $0.workspace == source })
            else { throw WorkspaceFailure.conflict }
        } catch {
            try JSONEncoder().encode(baseline).write(to: journal, options: .atomic)
            throw error
        }
        return .deleted(.virtual(source))
    }
    /// Explicit quit preserves a verified user partition on the full usable desktop. Seal these
    /// goals before releasing any fixture window so a later recovery continues the same intent.
    func quit(
        usable: [String: SurfaceRect], preferences: WorkspacePreferences, bundles: [ManagedWindowID: String],
        on backend: any VirtualFixtureBackend
    ) throws {
        guard var record = try pending() else { return }
        for change in record.changes {
            let id = change.original.id
            if try preferences.excluded(id, bundle: bundles[id]) {
                record.excludedAtQuit.insert(id)
                continue
            }
            guard let g = record.groups.first(where: { $0.id == change.target.workspace }), g.layout.userAdjusted else {
                continue
            }
            guard let full = usable[g.display], let target = try g.layout.frames(in: full)[id] else {
                throw WorkspaceFailure.display
            }
            let old = change.original
            record.quitTargets[id] = .init(
                id: id, display: g.display, workspace: old.workspace, frame: target,
                visible: true, zOrder: old.zOrder, ordinary: old.ordinary)
        }
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        try restore(on: backend)
    }
    func restore(on backend: any VirtualFixtureBackend) throws {
        guard let record = try pending() else { return }
        var unresolved = false
        for change in record.changes.reversed() {
            let current = try backend.observe(change.original.id)
            let goal = record.quitTargets[change.original.id] ?? change.original
            if current == goal { continue }
            if record.excludedAtQuit.contains(change.original.id) {
                unresolved = true
                continue
            }
            guard current == change.target else {
                unresolved = true
                continue
            }
            do { try backend.replace(change.target, with: goal) } catch { unresolved = true }
        }
        guard !unresolved else { throw WorkspaceFailure.recoveryRequired }
        for change in record.changes {
            guard try backend.observe(change.original.id) == (record.quitTargets[change.original.id] ?? change.original)
            else { throw WorkspaceFailure.recoveryRequired }
        }
        try FileManager.default.removeItem(at: journal)
    }
}

/// This adapter is injectable only inside the isolated experiment. It has no AppKit/AX handles.
final class IsolatedVirtualActions: WorkspaceActionAdapter {
    let mode = WorkspaceMode.virtual
    private let ledger: VirtualWorkspaceExperiment, world: any VirtualFixtureBackend
    private let active: UUID
    private var pending: UUID?
    init(ledger: VirtualWorkspaceExperiment, world: any VirtualFixtureBackend, active: UUID) {
        self.ledger = ledger
        self.world = world
        self.active = active
    }
    func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback {
        guard change.before.mode == .virtual, try ledger.pending() == nil else { throw WorkspaceFailure.recoveryRequired }
        var groups = [VirtualGroup]()
        var changes = [VirtualWindowChange]()
        let target: UUID
        var created: WorkspaceRowState?
        var rows = change.before.rows
        if let request = change.admission, request.create {
            guard let dest = rows[request.destination] else { throw WorkspaceFailure.membership }
            target = UUID()
            let id = WorkspaceID.virtual(target)
            let layout = try ManagedWindowTiler(workspace: id).adding(request.member, in: dest.area)
            created = .init(id: id, display: dest.display, area: dest.area, layout: layout)
            rows[id] = created
        } else {
            switch change.intent {
            case .switchRow(.virtual(let to)), .move(_, _, .virtual(let to)), .placeNew(_, .virtual(let to)): target = to
            default: throw WorkspaceFailure.identity
            }
        }
        guard rows[.virtual(active)] != nil else { throw WorkspaceFailure.membership }
        let parkingEdge = rows.values.map { $0.area.geometry.x }.min() ?? 0
        for row in rows.values {
            guard case .virtual(let id) = row.id, let layout = change.layouts[row.id] ?? row.layout else {
                throw WorkspaceFailure.membership
            }
            groups.append(.init(id: id, display: row.display, area: row.area, layout: layout))
            for (member, frame) in try layout.frames(in: row.area) {
                guard let original = try world.observe(member), original.ordinary else { throw WorkspaceFailure.identity }
                let expectedOrigin: UUID?
                if case .placeNew(let born, .virtual(let appeared)) = change.intent, born == member {
                    guard original.display == change.before.rows[.virtual(appeared)]?.display,
                        original.workspace == nil || original.workspace == appeared
                    else { throw WorkspaceFailure.membership }
                    expectedOrigin = original.workspace
                } else {
                    let owners = change.before.rows.values.filter {
                        $0.layout?.members.contains(where: { $0.id == member }) == true
                    }
                    guard owners.count == 1, case .virtual(let owner) = owners[0].id else {
                        throw WorkspaceFailure.membership
                    }
                    expectedOrigin = owner
                }
                guard original.workspace == expectedOrigin else { throw WorkspaceFailure.stale }
                let visible = id == target
                let actual =
                    visible
                    ? frame
                    : SurfaceRect(x: parkingEdge - frame.width - 1, y: frame.y, width: frame.width, height: frame.height)
                changes.append(
                    .init(
                        original: original,
                        target: .init(
                            id: member, display: row.display, workspace: id, frame: actual,
                            visible: visible, zOrder: original.zOrder, ordinary: true)))
            }
        }
        pending = change.operation
        try ledger.begin(
            .init(version: 1, transaction: change.operation, active: target, groups: groups, changes: changes), on: world)
        guard let record = try ledger.pending(), record.transaction == change.operation else {
            throw WorkspaceFailure.recoveryRequired
        }
        var membership = Dictionary(
            uniqueKeysWithValues: record.groups.map { (WorkspaceID.virtual($0.id), Set<ManagedWindowID>()) })
        var frames = [ManagedWindowID: SurfaceRect]()
        var parked = [ManagedWindowID: VerifiedParking]()
        for row in record.changes {
            guard let w = try world.observe(row.target.id), w == row.target, let id = w.workspace else {
                throw WorkspaceFailure.stale
            }
            membership[.virtual(id), default: []].insert(w.id)
            frames[w.id] = w.frame
            if !w.visible, let g = record.groups.first(where: { $0.id == id }),
                let intended = try g.layout.frames(in: g.area)[w.id]
            {
                parked[w.id] = .init(workspace: .virtual(id), savedFrame: intended, observedFrame: w.frame)
            }
        }
        return .init(
            operation: record.transaction, session: change.before.session, revision: change.before.revision + 1,
            active: .virtual(record.active), membership: membership, frames: frames, created: created, parked: parked)
    }
    func rollback(_ change: WorkspaceMutation) throws {
        // Never restore a different or older outstanding transaction.
        if let existing = try ledger.pending() {
            guard existing.transaction == change.operation, pending == change.operation else {
                throw WorkspaceFailure.recoveryRequired
            }
            try ledger.restore(on: world)
        }
        pending = nil
    }
}
