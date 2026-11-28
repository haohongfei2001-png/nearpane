import Foundation
import Observation

public struct ModuleProjection: Equatable, Sendable {
    public let message: String
    public let refreshCount: Int
    public init(message: String, refreshCount: Int = 0) { self.message = message; self.refreshCount = refreshCount }
}

public struct ModuleEvent: Equatable, Sendable {
    public let moduleID: String
    public let instanceID: UUID
    public let revision: UInt64
    public let timestamp: Date
    public let snapshot: ModuleProjection

    public init(moduleID: String, instanceID: UUID, revision: UInt64, timestamp: Date = Date(), snapshot: ModuleProjection) {
        self.moduleID = moduleID; self.instanceID = instanceID; self.revision = revision
        self.timestamp = timestamp; self.snapshot = snapshot
    }
}

@Observable @MainActor
public final class SnapshotBus {
    public private(set) var desktop: DesktopSnapshot?
    public private(set) var lastStableDesktop: DesktopSnapshot?
    public private(set) var moduleSnapshots: [String: ModuleEvent] = [:]
    @ObservationIgnored private var activeInstances: [String: UUID] = [:]
    @ObservationIgnored private var subscribers: [UUID: (ids: Set<String>, receive: (ModuleEvent) throws -> Void)] = [:]
    @ObservationIgnored private var pending: [ModuleEvent] = []
    @ObservationIgnored private var delivering = false
    private let diagnostics: Diagnostics

    public init(diagnostics: Diagnostics) { self.diagnostics = diagnostics }

    public func activate(moduleID: String, instanceID: UUID) {
        activeInstances[moduleID] = instanceID
        moduleSnapshots[moduleID] = nil
    }

    public func deactivate(moduleID: String) {
        activeInstances[moduleID] = nil
        moduleSnapshots[moduleID] = nil
    }

    @discardableResult
    public func publish(_ event: ModuleEvent) -> Bool {
        guard activeInstances[event.moduleID] == event.instanceID, event.revision > 0,
              event.revision > (moduleSnapshots[event.moduleID]?.revision ?? 0) else {
            diagnostics.record(.eventRejected, moduleID: event.moduleID)
            return false
        }
        moduleSnapshots[event.moduleID] = event
        pending.append(event)
        guard !delivering else { return true }
        delivering = true
        defer { delivering = false }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            for id in Array(subscribers.keys) {
                guard activeInstances[next.moduleID] == next.instanceID else { break }
                guard let subscriber = subscribers[id], subscriber.ids.contains(next.moduleID) else { continue }
                do { try subscriber.receive(next) }
                catch {
                    subscribers[id] = nil
                    diagnostics.record(.subscriberFailed, moduleID: next.moduleID)
                }
            }
        }
        return true
    }

    /// Subscriptions are explicitly scoped. Re-synchronization reads moduleSnapshots, not an unbounded event log.
    public func subscribe(moduleIDs: Set<String>, receive: @escaping (ModuleEvent) throws -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = (moduleIDs, receive)
        return id
    }

    public func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    @discardableResult
    public func acceptDesktop(_ snapshot: DesktopSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.isStructurallyValid,
              desktop == nil || (desktop?.sessionID == snapshot.sessionID && snapshot.revision > (desktop?.revision ?? 0)) else {
            diagnostics.record(.snapshotRejected)
            return false
        }
        desktop = snapshot
        if snapshot.effectiveFreshness(at: now) == .fresh { lastStableDesktop = snapshot }
        diagnostics.record(.snapshotAccepted)
        return true
    }

    public func resetDesktopSession() {
        desktop = nil
        lastStableDesktop = nil
    }

    func endSession() {
        resetDesktopSession()
        pending.removeAll()
        subscribers.removeAll()
    }
}
