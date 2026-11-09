import Foundation

public struct WorkspaceRowState: Equatable, Sendable {
    public let id: WorkspaceID, display: String, area: SurfaceRect
    /// nil means the provider cannot attest complete membership, resize rights and minimum sizes.
    public let layout: ManagedWindowTiler?
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public let session: UUID, revision: UInt64, mode: WorkspaceMode, build: String, validUntil: Double
    public let rows: [WorkspaceID: WorkspaceRowState]
    public let grants: [String: WorkspaceCapabilities]
    public let stable: Bool
    public var preferences = WorkspacePreferences()
    public var observed: [ManagedWindowID: LiveManagedWindow] = [:]
    public var bundles: [ManagedWindowID: String] = [:]
    public func validate(_ row: WorkspaceID, action: WorkspaceAction, at uptime: Double, isolated: Bool) throws
        -> WorkspaceRowState
    {
        guard stable, uptime.isFinite, validUntil.isFinite, uptime <= validUntil else { throw WorkspaceFailure.stale }
        guard row.mode == mode, let r = rows[row], r.id == row else { throw WorkspaceFailure.membership }
        if case .native(let owner, _, _) = row, owner != session { throw WorkspaceFailure.identity }
        guard let g = grants[r.display], g.build == build, g.mode == mode, g.displayID == r.display,
            g.permits(action, isolated: isolated)
        else { throw WorkspaceFailure.unavailable }
        return r
    }
}

public enum WorkspaceIntent: Equatable, Sendable {
    case switchRow(WorkspaceID)
    case move(ManagedWindowID, from: WorkspaceID, to: WorkspaceID)
    case placeNew(ManagedWindowID, appearedIn: WorkspaceID)
}
public struct WorkspaceMutation: Equatable, Sendable {
    public let intent: WorkspaceIntent
    public let before: WorkspaceSnapshot
    public let layouts: [WorkspaceID: ManagedWindowTiler]
    public let operation: UUID
    public var admission: WorkspaceAdmission? = nil
}

public struct VerifiedParking: Sendable {
    public let workspace: WorkspaceID, savedFrame: SurfaceRect, observedFrame: SurfaceRect
}
public struct WorkspaceReadback: Sendable {
    public let operation: UUID, session: UUID, revision: UInt64
    public let active: WorkspaceID?
    /// Obtained independently from the provider after the operation, in global logical points.
    public let membership: [WorkspaceID: Set<ManagedWindowID>]
    public let frames: [ManagedWindowID: SurfaceRect]
    /// The creating adapter re-observes the workspace identity and display after the OS/fixture commits.
    public var created: WorkspaceRowState? = nil
    public var parked: [ManagedWindowID: VerifiedParking] = [:]
    func confirms(_ change: WorkspaceMutation) -> Bool {
        guard operation == change.operation, session == change.before.session, revision > change.before.revision else {
            return false
        }
        switch change.intent {
        case .switchRow(let row): return active == row
        case .move, .placeNew:
            guard let admission = change.admission else { return false }
            let id = admission.member.id
            let expectedOwner = admission.create ? created?.id : admission.destination
            guard let expectedOwner,
                Set(membership.keys) == Set(change.before.rows.keys).union(created.map { [$0.id] } ?? []),
                membership.filter({ $0.value.contains(id) }).map(\.key) == [expectedOwner]
            else { return false }
            for (workspace, state) in change.before.rows where change.layouts[workspace] == nil {
                guard let old = state.layout, membership[workspace] == Set(old.members.map(\.id)) else { return false }
            }
            if let a = change.admission, a.create {
                guard let new = created, change.before.rows[new.id] == nil, new.id.mode == change.before.mode,
                    let intended = change.before.rows[a.destination], new.display == intended.display,
                    new.area == intended.area, membership[new.id] == [a.member.id], frames[a.member.id] == new.area,
                    new.layout?.workspace == new.id, new.layout?.members == [a.member]
                else { return false }
                if case .native(let s, _, _) = new.id, s != session { return false }
            } else if created != nil {
                return false
            }
            for (workspace, layout) in change.layouts {
                guard membership[workspace] == Set(layout.members.map(\.id)), let area = change.before.rows[workspace]?.area,
                    let planned = try? layout.frames(in: area),
                    planned.allSatisfy({ id, target in
                        if frames[id] == target { return true }
                        guard workspace.mode == .virtual, active != workspace, let proof = parked[id],
                            proof.workspace == workspace, proof.savedFrame == target, proof.observedFrame == frames[id],
                            proof.observedFrame.geometry.isValid
                        else { return false }
                        return change.before.rows.values.allSatisfy {
                            $0.area.geometry.intersection(proof.observedFrame.geometry) == nil
                        }
                    })
                else { return false }
            }
            return true
        }
    }
}

public protocol WorkspaceActionAdapter {
    var mode: WorkspaceMode { get }
    func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback
    /// Return only after the before-state has been restored and independently checked.
    func rollback(_ change: WorkspaceMutation) throws
}

public struct NativeSpacesProvider: WorkspaceActionAdapter {
    public init() {}
    public let mode = WorkspaceMode.native
    public func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback { throw WorkspaceFailure.unavailable }
    public func rollback(_ change: WorkspaceMutation) throws { throw WorkspaceFailure.unavailable }

    public func projection(
        _ snapshot: DesktopSnapshot, preferredDisplay: String?, settings: [String: DisplaySettings],
        edge: SurfaceEdge, date: Date, uptime: Double, preferences: WorkspacePreferences = .init()
    ) -> WorkspaceSnapshot? {
        guard snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: date, uptime: uptime),
            let evidence = snapshot.native, !evidence.windowLimitReached
        else { return nil }
        var rows = [WorkspaceID: WorkspaceRowState]()
        for witness in evidence.rows {
            guard let id = snapshot.workspaceID(display: witness.displayID, record: witness.recordID),
                let d = snapshot.displays.first(where: { $0.id == witness.displayID }), var usable = d.usable
            else { continue }
            usable.x += d.frame.x
            usable.y += d.frame.y
            guard
                let work = try? DesktopWorkArea(
                    display: d.id, screen: d.frame, usable: usable,
                    primary: d.id == preferredDisplay, settings: settings[d.id] ?? .init(), fallbackEdge: edge)
            else { continue }
            rows[id] = .init(id: id, display: d.id, area: work.ordinary, layout: nil)
        }
        // P4.0 proves observation only. Scope count, AX trust and frame matches do not mint write grants.
        return .init(
            session: snapshot.sessionID, revision: snapshot.revision, mode: .native, build: snapshot.sourceBuild,
            validUntil: evidence.beganUptime + 12, rows: rows, grants: [:], stable: true, preferences: preferences)
    }
}

/// One physical press, consumed on release/cancel. Crossing the threshold is sticky even on return to origin.
public struct WorkspaceGestureRouter {
    public static let threshold = 6.0
    private struct Press {
        let snapshot: WorkspaceSnapshot, row: WorkspaceID, window: ManagedWindowID?, x: Double, y: Double
        var dragged = false
    }
    private var press: Press?
    private let isolated: Bool
    public private(set) var needsRecovery = false
    public init(isolated: Bool = false) { self.isolated = isolated }
    public mutating func down(row: WorkspaceID, window: ManagedWindowID?, x: Double, y: Double, snapshot: WorkspaceSnapshot)
    {
        press = nil
        guard !needsRecovery, snapshot.stable, snapshot.rows[row] != nil, x.isFinite, y.isFinite else { return }
        press = Press(snapshot: snapshot, row: row, window: window, x: x, y: y)
    }
    public mutating func moved(x: Double, y: Double) {
        guard let held = press else { return }
        guard x.isFinite, y.isFinite else {
            press = nil
            return
        }
        if hypot(x - held.x, y - held.y) >= Self.threshold { press?.dragged = true }
    }
    public mutating func cancel() { press = nil }

    public mutating func release(
        on destination: WorkspaceID?, x: Double, y: Double, current: WorkspaceSnapshot,
        uptime: Double, native: any WorkspaceActionAdapter, virtual: any WorkspaceActionAdapter
    ) throws -> WorkspaceIntent {
        moved(x: x, y: y)
        guard let held = press else { throw WorkspaceFailure.stale }
        press = nil
        guard current == held.snapshot else { throw WorkspaceFailure.stale }
        guard let destination else { throw WorkspaceFailure.membership }
        let intent: WorkspaceIntent
        var layouts = [WorkspaceID: ManagedWindowTiler]()
        var admission: WorkspaceAdmission?
        if held.dragged {
            guard held.row != destination, let id = held.window else { throw WorkspaceFailure.membership }
            let from = try current.validate(held.row, action: .moveMember, at: uptime, isolated: isolated)
            let to = try current.validate(destination, action: .moveMember, at: uptime, isolated: isolated)
            for row in [from, to] { _ = try current.validate(row.id, action: .tile, at: uptime, isolated: isolated) }
            guard let src = from.layout, src.workspace == from.id, let dst = to.layout, dst.workspace == to.id,
                let member = src.members.first(where: { $0.id == id }),
                current.rows.values.allSatisfy({ r in
                    guard let l = r.layout else { return false }
                    return r.id == from.id || !l.members.contains(where: { $0.id == id })
                })
            else { throw WorkspaceFailure.membership }
            let plan = try WorkspaceAdmissionPlanner.plan(
                member: member, bundle: current.bundles[id], role: .ordinary, source: .explicitDrop,
                target: to.id, snapshot: current, preferences: current.preferences, uptime: uptime, isolated: isolated)
            admission = plan
            layouts[to.id] = plan.existingLayout
            layouts[from.id] = try src.removing(id, in: from.area)
            intent = .move(id, from: from.id, to: to.id)
        } else {
            guard destination == held.row else { throw WorkspaceFailure.membership }
            _ = try current.validate(destination, action: .switchRow, at: uptime, isolated: isolated)
            intent = .switchRow(destination)
        }
        let adapter = current.mode == .native ? native : virtual
        guard adapter.mode == current.mode else { throw WorkspaceFailure.identity }
        let change = WorkspaceMutation(
            intent: intent, before: current, layouts: layouts, operation: UUID(), admission: admission)
        do {
            try WorkspaceExecution.run(change, adapter: adapter, uptime: uptime, isolated: isolated)
        } catch WorkspaceFailure.recoveryRequired {
            needsRecovery = true
            throw WorkspaceFailure.recoveryRequired
        }
        return intent
    }
}

public struct VirtualWorkspacesProvider: WorkspaceActionAdapter {
    private let experiment: IsolatedVirtualActions?
    public init() { experiment = nil }
    init(experiment: IsolatedVirtualActions) { self.experiment = experiment }
    public let mode = WorkspaceMode.virtual
    public func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback {
        guard let experiment else { throw WorkspaceFailure.unavailable }
        return try experiment.apply(change)
    }
    public func rollback(_ change: WorkspaceMutation) throws {
        guard let experiment else { throw WorkspaceFailure.unavailable }
        try experiment.rollback(change)
    }
}
