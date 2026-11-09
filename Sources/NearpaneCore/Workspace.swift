import Foundation

public enum WorkspaceMode: String, Codable, Sendable { case native, virtual }
public enum WorkspaceID: Hashable, Codable, Sendable {
    case native(session: UUID, scope: String, record: String)
    case virtual(UUID)

    public var mode: WorkspaceMode {
        switch self { case .native: .native; case .virtual: .virtual }
    }
}

/// A CG number alone can be reused. Incarnation includes process launch and AX element identity.
public struct ManagedWindowID: Hashable, Codable, Sendable {
    public let pid: Int32, launch: UInt64, number: UInt32, element: UUID
    public init(pid: Int32, launch: UInt64, number: UInt32, element: UUID) {
        self.pid = pid; self.launch = launch; self.number = number; self.element = element
    }
    public init?(_ observation: WindowObservation) {
        guard observation.confidence == .corroboratedMetadata, let m = observation.metadata,
              m.minimized == false, m.fullScreen == false, let launch = m.launchMicroseconds,
              let element = m.element else { return nil }
        self.init(pid: m.pid, launch: launch, number: m.number, element: element)
    }
}

public enum WorkspaceFailure: String, Error, Equatable, Sendable {
    case unavailable, stale, identity, membership, display, permission, conflict, recoveryRequired, invalidLayout, minimumSize
    case capacity = "此空间最多容纳 8 个窗口"
}

public enum WorkspaceAction: Hashable, Sendable { case selectMode, switchRow, moveMember, tile, separateFullscreen }
public enum ActionEvidence: Equatable, Sendable { case unavailable, isolated, deviceVerified }
public struct WorkspaceCapabilities: Equatable, Sendable {
    public let mode: WorkspaceMode, build: String, displayID: String
    public let actions: Set<WorkspaceAction>, evidence: ActionEvidence
    public func permits(_ action: WorkspaceAction, isolated: Bool) -> Bool {
        actions.contains(action) && (evidence == .deviceVerified || (isolated && evidence == .isolated))
    }
}

/// The preflight is re-sampled on confirmation. Permission, competing owners and in-flight domain
/// operations may change while Settings is open.
public struct ModePreflight: Equatable, Sendable {
    public let revision: UInt64, capabilities: WorkspaceCapabilities, affected: Set<ManagedWindowID>
    public let permission: Bool, otherOwner: Bool, domainsBusy: Bool, recoverable: Bool
    func validate(for mode: WorkspaceMode, isolated: Bool) throws {
        guard mode == capabilities.mode, capabilities.permits(.selectMode, isolated: isolated) else { throw WorkspaceFailure.unavailable }
        guard permission else { throw WorkspaceFailure.permission }
        guard !otherOwner, !domainsBusy else { throw WorkspaceFailure.conflict }
        guard recoverable else { throw WorkspaceFailure.recoveryRequired }
    }
}

public protocol WorkspaceModeTransaction {
    /// Release old ownership and verify restoration before taking new ownership. Must be journaled.
    func transfer(from: WorkspaceMode, to: WorkspaceMode, preflight: ModePreflight) throws
    func restore(from: WorkspaceMode, preflight: ModePreflight) throws
}

public struct WorkspaceModeCoordinator {
    public private(set) var mode: WorkspaceMode = .native
    public private(set) var needsRecovery = false
    private let isolated: Bool
    private var pending: (token: UUID, preflight: ModePreflight)?
    public init(isolated: Bool = false) { self.isolated = isolated }
    public mutating func prepare(_ check: ModePreflight) throws -> UUID {
        guard !needsRecovery, pending == nil, check.capabilities.mode != mode else { throw WorkspaceFailure.conflict }
        try check.validate(for: check.capabilities.mode, isolated: isolated)
        let token = UUID(); pending = (token, check)
        return token
    }
    public mutating func cancel() { pending = nil }
    public mutating func commit(_ token: UUID, current: ModePreflight, owner: any WorkspaceModeTransaction) throws {
        guard let request = pending, request.token == token else { throw WorkspaceFailure.stale }
        pending = nil
        guard request.preflight == current else { throw WorkspaceFailure.stale }
        let target = current.capabilities.mode
        try current.validate(for: target, isolated: isolated)
        do { try owner.transfer(from: mode, to: target, preflight: current) }
        catch {
            do { try owner.restore(from: mode, preflight: current) }
            catch { needsRecovery = true; throw WorkspaceFailure.recoveryRequired }
            throw error
        }
        mode = target
    }
}

public extension DesktopSnapshot {
    /// A system record is usable only with the independent witness already validated by P4.0.
    func workspaceID(display: String, record: String) -> WorkspaceID? {
        guard isStructurallyValid, native?.rows.contains(where: { $0.displayID == display && $0.recordID == record }) == true,
              let scope = scopes.first(where: { $0.displayID == display && $0.records.contains(where: { $0.id == record }) })
        else { return nil }
        return .native(session: sessionID, scope: scope.id, record: record)
    }
}
