import Foundation
import Observation

public enum PermissionDecision: String, Sendable { case notRequested, granted, denied }
public struct PermissionKey: Hashable, Sendable {
    public let moduleID: String
    public let permission: HostPermission
    public init(moduleID: String, permission: HostPermission) { self.moduleID = moduleID; self.permission = permission }
}

@MainActor
public protocol PermissionBroker {
    func decision(for key: PermissionKey) -> PermissionDecision
    func request(_ key: PermissionKey, userInitiated: Bool) -> PermissionDecision
}

/// Simulation only: never calls a macOS permission API or stores grants on disk.
@Observable @MainActor
public final class MockPermissionBroker: PermissionBroker {
    public private(set) var decisions: [PermissionKey: PermissionDecision] = [:]
    public private(set) var requests: Set<PermissionKey> = []
    @ObservationIgnored public var onRevocation: ((PermissionKey) -> Void)?
    public init() {}
    public func decision(for key: PermissionKey) -> PermissionDecision { decisions[key] ?? .notRequested }
    public func request(_ key: PermissionKey, userInitiated: Bool) -> PermissionDecision {
        if userInitiated { requests.insert(key) }
        return decision(for: key)
    }
    public func setDecision(_ decision: PermissionDecision, for key: PermissionKey) {
        let old = self.decision(for: key)
        decisions[key] = decision
        if old == .granted && decision != .granted { onRevocation?(key) }
    }
}

public enum HostAction: Sendable {
    case setEnabled(String, Bool), setPinned(String, Bool), move(String, Int)
    case expand(String), collapse, suspend(String), resume(String)
    case module(String, ModuleAction)
    case switchSpace(DesktopTarget), activateWindow(DesktopTarget)
}

public enum ActionRejection: String, Sendable {
    case userIntentRequired, unknownModule, unsupported, moduleUnavailable, permissionRequired
    case moduleFailed, snapshotUnavailable, staleSnapshot, identityUnknown, hostStopped
}
public enum ActionResult: Equatable, Sendable {
    case accepted
    case rejected(ActionRejection)
}

@MainActor
public final class InteractionRouter {
    private let registry: ModuleRegistry
    private let permissions: any PermissionBroker
    private let bus: SnapshotBus
    private let diagnostics: Diagnostics

    public init(registry: ModuleRegistry, permissions: any PermissionBroker, bus: SnapshotBus, diagnostics: Diagnostics) {
        self.registry = registry; self.permissions = permissions; self.bus = bus; self.diagnostics = diagnostics
    }

    public func route(_ action: HostAction, userInitiated: Bool, now: Date = Date()) -> ActionResult {
        guard userInitiated else { return reject(.userIntentRequired) }
        do {
            switch action {
            case .setEnabled(let id, let enabled): try registry.setEnabled(id, enabled)
            case .setPinned(let id, let pinned): try registry.setPinned(id, pinned)
            case .move(let id, let offset): try registry.move(id, by: offset)
            case .expand(let id): try registry.expand(id)
            case .collapse: registry.collapse()
            case .suspend(let id): registry.suspend(id)
            case .resume(let id): registry.resume(id)
            case .module(let id, let action):
                guard let manifest = registry.manifests.first(where: { $0.id == id }) else { return reject(.unknownModule) }
                guard let required = manifest.actions[action] else { return reject(.unsupported) }
                guard [.resident, .expanded, .permissionRequired].contains(registry.states[id]) else { return reject(.moduleUnavailable) }
                for permission in required {
                    let key = PermissionKey(moduleID: id, permission: permission)
                    guard permissions.request(key, userInitiated: userInitiated) == .granted else {
                        registry.permissionRequired(id)
                        return reject(.permissionRequired)
                    }
                }
                try registry.perform(action, on: id)
            case .switchSpace(let target), .activateWindow(let target):
                guard let snapshot = bus.desktop else { return reject(.snapshotUnavailable) }
                guard snapshot.effectiveFreshness(at: now) == .fresh,
                      target.sessionID == snapshot.sessionID, target.revision == snapshot.revision else { return reject(.staleSnapshot) }
                guard snapshot.identityConfidence != .unknown else { return reject(.identityUnknown) }
                // P2 never dispatches desktop actions, even if a fixture has a plausible runtime ID.
                return reject(.unsupported)
            }
            return .accepted
        } catch let error as RegistryError {
            switch error {
            case .unknownModule: return reject(.unknownModule)
            case .notRunning: return reject(.moduleUnavailable)
            default: return reject(.unsupported)
            }
        } catch { return reject(.moduleFailed) }
    }

    private func reject(_ reason: ActionRejection) -> ActionResult {
        diagnostics.record(.actionRejected)
        return .rejected(reason)
    }
}
