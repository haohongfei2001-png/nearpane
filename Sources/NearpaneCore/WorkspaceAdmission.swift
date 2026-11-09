import Foundation

public enum NewWindowPlacement: String, Codable, CaseIterable, Sendable { case newWorkspace, joinExisting }
public enum WindowOverflowPolicy: String, Codable, CaseIterable, Sendable { case newAboveEight, continuousSplit }
public enum WindowRule: String, Codable, Sendable { case include, exclude }
public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var newWindow: NewWindowPlacement = .newWorkspace
    public var overflow: WindowOverflowPolicy = .newAboveEight
    public var excludedApps = Set<String>()
    public var windows: [ManagedWindowID: WindowRule] = [:]
    public init() {}
    public func excluded(_ id: ManagedWindowID, bundle: String?) throws -> Bool {
        if let specific = windows[id] { return specific == .exclude }
        if !excludedApps.isEmpty {
            guard let bundle, !bundle.isEmpty else { throw WorkspaceFailure.identity }
            if excludedApps.contains(bundle) { return true }
        }
        // An AX token can change between readers. Neither silently re-admit a possibly excluded
        // window nor transfer its rule to a replacement solely because CG reused its number.
        if windows.contains(where: { key, rule in
            rule == .exclude && key.pid == id.pid && key.launch == id.launch && key.number == id.number
        }) {
            throw WorkspaceFailure.identity
        }
        return false
    }
}

public enum ObservedWindowRole { case ordinary, sheet, dialog, system, nativeFullscreen, unknown }
public enum AdmissionSource { case application, explicitDrop }
public struct WorkspaceAdmission: Equatable, Sendable {
    public let member: ManagedMember, destination: WorkspaceID, create: Bool
    /// For creation the adapter must return a newly observed ID. No speculative native record is allocated.
    public let existingLayout: ManagedWindowTiler?
}

public enum WorkspaceAdmissionPlanner {
    public static func plan(
        member: ManagedMember, bundle: String?, role: ObservedWindowRole, source: AdmissionSource,
        target: WorkspaceID, snapshot: WorkspaceSnapshot, preferences: WorkspacePreferences,
        uptime: Double, isolated: Bool
    ) throws -> WorkspaceAdmission {
        guard role == .ordinary else { throw WorkspaceFailure.unmanaged }
        guard try !preferences.excluded(member.id, bundle: bundle) else { throw WorkspaceFailure.excluded }
        let row = try snapshot.validate(target, action: .tile, at: uptime, isolated: isolated)
        guard let layout = row.layout, layout.workspace == target,
            !layout.members.contains(where: { $0.id == member.id })
        else { throw WorkspaceFailure.membership }
        let newAtBirth = source == .application && preferences.newWindow == .newWorkspace
        let overflow = layout.members.count >= 8 && preferences.overflow == .newAboveEight
        if newAtBirth || overflow {
            let caps = snapshot.grants[row.display]
            if caps?.permits(.createWorkspace, isolated: isolated) == true
                && caps?.permits(.moveMember, isolated: isolated) == true
            {
                // A fresh single-member workspace must itself fit before any creation is attempted.
                _ = try ManagedWindowTiler(workspace: target).adding(member, in: row.area)
                return .init(member: member, destination: target, create: true, existingLayout: nil)
            }
        }
        return .init(
            member: member, destination: target, create: false, existingLayout: try layout.adding(member, in: row.area))
    }
}

public struct EmptySourceEvidence: Equatable, Sendable {
    public let from: WorkspaceID, departed: ManagedWindowID, session: UUID
    public let beforeRevision, afterRevision: UInt64
    public let wasMember: Bool, causedByCloseOrMove: Bool, completeAllMembers: Bool
    public let remaining: Set<ManagedWindowID>, active: Bool, protectedOrFullscreen: Bool, otherDesktopAvailable: Bool
}
public enum CleanupDisposition: Equatable {
    case preserve, pendingCapability
    case requestDeletion(WorkspaceID)
    case deleted(WorkspaceID)
}
public enum EmptyWorkspaceCleanup {
    /// A complete membership read includes hidden, minimized, sticky and unmanaged windows.
    public static func evaluate(_ e: EmptySourceEvidence, current: WorkspaceSnapshot, uptime: Double, isolated: Bool)
        -> CleanupDisposition
    {
        guard current.stable, current.rows[e.from] != nil, current.session == e.session, current.revision == e.afterRevision,
            e.afterRevision > e.beforeRevision, e.wasMember, e.causedByCloseOrMove, e.completeAllMembers,
            e.remaining.isEmpty,
            !e.active, !e.protectedOrFullscreen, e.otherDesktopAvailable, let source = current.rows[e.from],
            source.layout?.members.isEmpty == true,
            current.rows.values.contains(where: {
                $0.id != e.from && $0.id.mode == e.from.mode && $0.display == source.display
            }),
            uptime.isFinite, uptime <= current.validUntil
        else { return .preserve }
        guard (try? current.validate(e.from, action: .removeWorkspace, at: uptime, isolated: isolated)) != nil else {
            return .pendingCapability
        }
        return .requestDeletion(e.from)
    }
    public static func confirmed(_ e: EmptySourceEvidence, after: WorkspaceSnapshot, completeInventory: Bool, uptime: Double)
        -> Bool
    {
        completeInventory && after.stable && after.session == e.session && after.revision > e.afterRevision
            && after.mode == e.from.mode && after.rows[e.from] == nil && !after.rows.isEmpty && uptime.isFinite
            && uptime <= after.validUntil
    }
}

/// A provider may emit this only after proving that a failed allocation made no change. The
/// independent sample must still describe the same members, displays and frames before fallback.
struct AllocationUnchanged: Error { let sample: WorkspaceSnapshot }

struct WorkspaceExecution {
    /// Shared by a pointer drop and an application-born ordinary window. A partial or unknown
    /// create never causes a second move. An uncertain rollback blocks the caller's next action.
    static func run(
        _ mutation: WorkspaceMutation, adapter: any WorkspaceActionAdapter,
        uptime: Double, isolated: Bool
    ) throws {
        var change = mutation
        guard adapter.mode == change.before.mode else { throw WorkspaceFailure.identity }
        do {
            let receipt: WorkspaceReadback
            do { receipt = try adapter.apply(change) } catch let unchanged as AllocationUnchanged {
                let fresh = unchanged.sample
                guard let admission = change.admission, admission.create, fresh.session == change.before.session,
                    fresh.mode == change.before.mode, fresh.build == change.before.build,
                    fresh.revision > change.before.revision,
                    fresh.rows == change.before.rows, fresh.observed == change.before.observed,
                    fresh.preferences == change.before.preferences, fresh.bundles == change.before.bundles,
                    let layout = fresh.rows[admission.destination]?.layout
                else { throw WorkspaceFailure.stale }
                let target = try fresh.validate(admission.destination, action: .tile, at: uptime, isolated: isolated)
                if case .move(_, let from, let to) = change.intent {
                    for id in [from, to] {
                        _ = try fresh.validate(id, action: .moveMember, at: uptime, isolated: isolated)
                        _ = try fresh.validate(id, action: .tile, at: uptime, isolated: isolated)
                    }
                }
                let split = try layout.adding(admission.member, in: target.area)
                var next = change.layouts
                next[target.id] = split
                change = .init(
                    intent: change.intent, before: fresh, layouts: next, operation: change.operation,
                    admission: .init(member: admission.member, destination: target.id, create: false, existingLayout: split))
                receipt = try adapter.apply(change)
            }
            guard receipt.confirms(change) else { throw WorkspaceFailure.stale }
        } catch {
            do { try adapter.rollback(change) } catch { throw WorkspaceFailure.recoveryRequired }
            throw error
        }
    }
}

public struct NewWindowAdmissionCoordinator {
    private var handled = Set<ManagedWindowID>()
    private var session: UUID?
    public private(set) var needsRecovery = false
    public init() {}
    /// The caller supplies the verified space where the newly observed ordinary window appeared.
    public mutating func appeared(
        _ window: LiveManagedWindow, role: ObservedWindowRole, previous: WorkspaceSnapshot, snapshot: WorkspaceSnapshot,
        uptime: Double, isolated: Bool, adapter: any WorkspaceActionAdapter
    ) throws {
        guard !needsRecovery else { throw WorkspaceFailure.recoveryRequired }
        if session != snapshot.session {
            session = snapshot.session
            handled.removeAll()
        }
        guard !handled.contains(window.member.id) else { throw WorkspaceFailure.conflict }
        guard previous.stable, previous.session == snapshot.session, previous.mode == snapshot.mode,
            previous.build == snapshot.build, previous.revision < snapshot.revision, uptime <= previous.validUntil,
            previous.observed.keys.allSatisfy({ $0.pid != window.member.id.pid || $0.number != window.member.id.number })
        else { throw WorkspaceFailure.stale }
        guard snapshot.observed[window.member.id] == window, window.ordinary, window.frame.geometry.isValid,
            snapshot.rows[window.workspace]?.display == window.display,
            !snapshot.rows.values.contains(where: {
                $0.layout?.members.contains(where: { $0.id == window.member.id }) == true
            })
        else { throw WorkspaceFailure.identity }
        let plan = try WorkspaceAdmissionPlanner.plan(
            member: window.member, bundle: window.bundle, role: role, source: .application,
            target: window.workspace, snapshot: snapshot, preferences: snapshot.preferences, uptime: uptime,
            isolated: isolated)
        var layouts = [WorkspaceID: ManagedWindowTiler]()
        layouts[window.workspace] = plan.existingLayout
        let mutation = WorkspaceMutation(
            intent: .placeNew(window.member.id, appearedIn: window.workspace), before: snapshot,
            layouts: layouts, operation: UUID(), admission: plan)
        do {
            try WorkspaceExecution.run(mutation, adapter: adapter, uptime: uptime, isolated: isolated)
        } catch WorkspaceFailure.recoveryRequired {
            needsRecovery = true
            throw WorkspaceFailure.recoveryRequired
        }
        handled.insert(window.member.id)
    }
}
