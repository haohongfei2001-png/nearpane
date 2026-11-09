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
    public func validate(_ row: WorkspaceID, action: WorkspaceAction, at uptime: Double, isolated: Bool) throws -> WorkspaceRowState {
        guard stable, uptime.isFinite, validUntil.isFinite, uptime <= validUntil else { throw WorkspaceFailure.stale }
        guard row.mode == mode, let r = rows[row], r.id == row else { throw WorkspaceFailure.membership }
        if case let .native(owner, _, _) = row, owner != session { throw WorkspaceFailure.identity }
        guard let g = grants[r.display], g.build == build, g.mode == mode, g.displayID == r.display,
              g.permits(action, isolated: isolated) else { throw WorkspaceFailure.unavailable }
        return r
    }
}

public enum WorkspaceIntent: Equatable, Sendable {
    case switchRow(WorkspaceID)
    case move(ManagedWindowID, from: WorkspaceID, to: WorkspaceID)
}
public struct WorkspaceMutation: Equatable, Sendable {
    public let intent: WorkspaceIntent
    public let before: WorkspaceSnapshot
    public let layouts: [WorkspaceID: ManagedWindowTiler]
    public let operation: UUID
}

public struct WorkspaceReadback: Sendable {
    public let operation: UUID, session: UUID, revision: UInt64
    public let active: WorkspaceID?
    /// Obtained independently from the provider after the operation, in global logical points.
    public let membership: [WorkspaceID: Set<ManagedWindowID>]
    public let frames: [ManagedWindowID: SurfaceRect]
    func confirms(_ change: WorkspaceMutation) -> Bool {
        guard operation == change.operation, session == change.before.session, revision > change.before.revision else { return false }
        switch change.intent {
        case .switchRow(let row): return active == row
        case .move:
            for (workspace, layout) in change.layouts {
                guard membership[workspace] == Set(layout.members.map(\.id)), let area = change.before.rows[workspace]?.area,
                      let planned = try? layout.frames(in: area),
                      planned.allSatisfy({ frames[$0.key] == $0.value }) else { return false }
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

    public func projection(_ snapshot: DesktopSnapshot, preferredDisplay: String?, settings: [String: DisplaySettings],
                           edge: SurfaceEdge, date: Date, uptime: Double) -> WorkspaceSnapshot? {
        guard snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: date, uptime: uptime),
              let evidence = snapshot.native, !evidence.windowLimitReached else { return nil }
        var rows = [WorkspaceID: WorkspaceRowState]()
        for witness in evidence.rows {
            guard let id = snapshot.workspaceID(display: witness.displayID, record: witness.recordID),
                  let d = snapshot.displays.first(where: { $0.id == witness.displayID }), var usable = d.usable else { continue }
            usable.x += d.frame.x; usable.y += d.frame.y
            guard let work = try? DesktopWorkArea(display: d.id, screen: d.frame, usable: usable,
                primary: d.id == preferredDisplay, settings: settings[d.id] ?? .init(), fallbackEdge: edge) else { continue }
            rows[id] = .init(id: id, display: d.id, area: work.ordinary, layout: nil)
        }
        // P4.0 proves observation only. Scope count, AX trust and frame matches do not mint write grants.
        return .init(session: snapshot.sessionID, revision: snapshot.revision, mode: .native, build: snapshot.sourceBuild,
                     validUntil: evidence.beganUptime + 12, rows: rows, grants: [:], stable: true)
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
    public mutating func down(row: WorkspaceID, window: ManagedWindowID?, x: Double, y: Double, snapshot: WorkspaceSnapshot) {
        press = nil
        guard !needsRecovery, snapshot.stable, snapshot.rows[row] != nil, x.isFinite, y.isFinite else { return }
        press = Press(snapshot: snapshot, row: row, window: window, x: x, y: y)
    }
    public mutating func moved(x: Double, y: Double) {
        guard let held = press else { return }
        guard x.isFinite, y.isFinite else { press = nil; return }
        if hypot(x - held.x, y - held.y) >= Self.threshold { press?.dragged = true }
    }
    public mutating func cancel() { press = nil }

    public mutating func release(on destination: WorkspaceID?, x: Double, y: Double, current: WorkspaceSnapshot,
                                 uptime: Double, native: any WorkspaceActionAdapter, virtual: any WorkspaceActionAdapter) throws -> WorkspaceIntent {
        moved(x: x, y: y)
        guard let held = press else { throw WorkspaceFailure.stale }
        press = nil
        guard current == held.snapshot else { throw WorkspaceFailure.stale }
        guard let destination else { throw WorkspaceFailure.membership }
        let intent: WorkspaceIntent
        var layouts = [WorkspaceID: ManagedWindowTiler]()
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
                  }) else { throw WorkspaceFailure.membership }
            layouts[to.id] = try dst.adding(member, in: to.area)
            layouts[from.id] = try src.removing(id, in: from.area)
            intent = .move(id, from: from.id, to: to.id)
        } else {
            guard destination == held.row else { throw WorkspaceFailure.membership }
            _ = try current.validate(destination, action: .switchRow, at: uptime, isolated: isolated)
            intent = .switchRow(destination)
        }
        let adapter = current.mode == .native ? native : virtual
        guard adapter.mode == current.mode else { throw WorkspaceFailure.identity }
        let change = WorkspaceMutation(intent: intent, before: current, layouts: layouts, operation: UUID())
        do {
            guard try adapter.apply(change).confirms(change) else { throw WorkspaceFailure.stale }
        } catch {
            do { try adapter.rollback(change) }
            catch { needsRecovery = true; throw WorkspaceFailure.recoveryRequired }
            throw error
        }
        return intent
    }
}

public struct VirtualWorkspacesProvider: WorkspaceActionAdapter {
    public init() {}
    public let mode = WorkspaceMode.virtual
    public func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback { throw WorkspaceFailure.unavailable }
    public func rollback(_ change: WorkspaceMutation) throws { throw WorkspaceFailure.unavailable }
}
