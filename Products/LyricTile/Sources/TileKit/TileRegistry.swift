import Foundation
import CTileLock

public struct TilePlan: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case stable, withdrawing }
    public var epoch: UUID
    public var generation: UInt64
    public var phase: Phase
    public var placements: [String: TilePlacement]
    public var pendingPlacements: [String: TilePlacement]
    public var withdraw: Set<String>
    public var hiddenAcknowledgements: Set<String>
    public init() {
        epoch = UUID(); generation = 0; phase = .stable
        placements = [:]; pendingPlacements = [:]; withdraw = []; hiddenAcknowledgements = []
    }
    public func mayShow(_ id: String) -> Bool { placements[id] != nil && !withdraw.contains(id) }
}

public struct TileObservation: Sendable {
    /// nil means unavailable; it must never be treated as an empty WindowServer list.
    public var visibleWindowIDs: Set<UInt32>?
    /// Verified process-launch identities that have ended, not merely expired heartbeats.
    public var endedProcessTokens: Set<String>
    public init(visibleWindowIDs: Set<UInt32>?, endedProcessTokens: Set<String> = []) {
        self.visibleWindowIDs = visibleWindowIDs; self.endedProcessTokens = endedProcessTokens
    }
}

public struct TileRegistryState: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var members: [String: TileMember] = [:]
    public var lastSeen: [String: Date] = [:]
    public var plan = TilePlan()
    public init() {}
}

/// All registry operations are short, nonblocking transactions. Call from an actor /
/// background task; a busy lock is retried by the caller, never waited for on MainActor.
public final class TileRegistry: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL = TileStorage.root) { self.directory = directory }

    public func snapshot() throws -> TileRegistryState { try transaction { $0 } }

    /// MainActor may use this short nonblocking transaction for native setFrame/orderFront.
    /// An actor-returned plan is only a snapshot; it cannot authorize a later UI mutation alone.
    public func withPresentationAuthority(id: String, instanceID: UUID, epoch: UUID,
                                          generation: UInt64, placement: TilePlacement,
                                          perform: () -> Void) throws -> Bool {
        try transaction { state in
            guard state.members[id]?.instanceID == instanceID,
                  state.plan.epoch == epoch, state.plan.generation == generation,
                  state.plan.mayShow(id), state.plan.placements[id] == placement else { return false }
            perform()
            return true
        }
    }

    /// Called after the moving window has been withdrawn and unregistered.
    /// Ranks leave insertion gaps; the next reconciliation applies its usual barrier.
    public func insertionOrder(displayID: String?, top: Double) throws -> Int {
        try transaction { state in
            let ordered = state.plan.placements.sorted {
                if $0.value.displayID != $1.value.displayID { return $0.value.displayID < $1.value.displayID }
                return $0.value.rect.y == $1.value.rect.y ? $0.key < $1.key : $0.value.rect.y < $1.value.rect.y
            }
            for (index, entry) in ordered.enumerated() { state.members[entry.key]?.userOrder = index * 2 }
            let sameDisplay = ordered.filter { $0.value.displayID == displayID }
            if let next = sameDisplay.first(where: { $0.value.rect.y >= top }) {
                return (state.members[next.key]?.userOrder ?? 0) - 1
            }
            if let previous = sameDisplay.last { return (state.members[previous.key]?.userOrder ?? 0) + 1 }
            return ordered.count * 2
        }
    }

    public func reconcile(_ member: TileMember, displays: [TileDisplay],
                          observation: TileObservation, obstacles: [TilePlacement] = [], now: Date = Date()) throws -> TilePlan {
        guard TileStorage.valid(member.id), member.reservedHeight.isFinite,
              (1...4096).contains(member.reservedHeight) else { throw TileCoordinationError.invalidIdentifier }
        return try transaction { state in
            if let old = state.members[member.id], old.instanceID != member.instanceID {
                guard canRemove(old, observation) else { throw TileCoordinationError.instanceConflict }
            }
            for (id, old) in state.members where canRemove(old, observation) {
                state.members.removeValue(forKey: id); state.lastSeen.removeValue(forKey: id)
                // A verified dead process with absent windows is an independent withdrawal proof.
                state.plan.hiddenAcknowledgements.insert(id)
            }
            var accepted = member
            if let existingOrder = state.members[member.id]?.userOrder { accepted.userOrder = existingOrder }
            state.members[member.id] = accepted
            if now.timeIntervalSince(state.lastSeen[member.id] ?? .distantPast) >= 30 { state.lastSeen[member.id] = now }
            if state.plan.phase == .withdrawing {
                finishWithdrawal(&state, observation)
                return state.plan
            }
            let desired = TileGeometry.placements(members: Array(state.members.values), displays: displays,
                                                  previous: state.plan.placements, obstacles: obstacles)
            propose(desired, state: &state)
            return state.plan
        }
    }

    public func acknowledgeHidden(id: String, instanceID: UUID, generation: UInt64,
                                  observation: TileObservation) throws -> TilePlan {
        try transaction { state in
            guard state.members[id]?.instanceID == instanceID else { throw TileCoordinationError.instanceConflict }
            guard state.plan.generation == generation, state.plan.phase == .withdrawing,
                  state.plan.withdraw.contains(id) else { throw TileCoordinationError.staleGeneration }
            guard let visible = observation.visibleWindowIDs,
                  Set(state.members[id]!.windowIDs).isDisjoint(with: visible) else { return state.plan }
            state.plan.hiddenAcknowledgements.insert(id)
            finishWithdrawal(&state, observation)
            return state.plan
        }
    }

    /// Call only after the native shell has ordered its windows out. No lock or timeout
    /// can hide another process's window, so absent WindowServer observation is insufficient.
    public func unregister(id: String, instanceID: UUID, observation: TileObservation) throws {
        try transaction { state in
            guard let member = state.members[id], member.instanceID == instanceID else { return }
            guard let visible = observation.visibleWindowIDs,
                  Set(member.windowIDs).isDisjoint(with: visible) else { throw TileCoordinationError.busy }
            state.members.removeValue(forKey: id); state.lastSeen.removeValue(forKey: id)
            if state.plan.phase == .stable { state.plan.generation &+= 1 }
            state.plan.placements.removeValue(forKey: id)
            state.plan.pendingPlacements.removeValue(forKey: id)
            state.plan.hiddenAcknowledgements.insert(id)
            finishWithdrawal(&state, observation)
        }
    }

    private func canRemove(_ member: TileMember, _ observation: TileObservation) -> Bool {
        guard observation.endedProcessTokens.contains(member.processToken),
              let visible = observation.visibleWindowIDs else { return false }
        return Set(member.windowIDs).isDisjoint(with: visible)
    }
    private func propose(_ desired: [String: TilePlacement], state: inout TileRegistryState) {
        guard desired != state.plan.placements else { return }
        state.plan.generation &+= 1
        let moving = Set(state.plan.placements.keys.filter { state.plan.placements[$0] != desired[$0] })
        if moving.isEmpty {
            state.plan.placements = desired
            state.plan.phase = .stable
            state.plan.withdraw = []; state.plan.hiddenAcknowledgements = []; state.plan.pendingPlacements = [:]
        } else {
            state.plan.phase = .withdrawing; state.plan.pendingPlacements = desired
            state.plan.withdraw = moving; state.plan.hiddenAcknowledgements = []
        }
    }
    private func finishWithdrawal(_ state: inout TileRegistryState, _ observation: TileObservation) {
        guard state.plan.phase == .withdrawing,
              state.plan.withdraw.isSubset(of: state.plan.hiddenAcknowledgements),
              let visible = observation.visibleWindowIDs else { return }
        for id in state.plan.withdraw {
            if let member = state.members[id], !Set(member.windowIDs).isDisjoint(with: visible) { return }
        }
        state.plan.placements = state.plan.pendingPlacements
        state.plan.pendingPlacements = [:]; state.plan.phase = .stable
        state.plan.withdraw = []; state.plan.hiddenAcknowledgements = []
    }
    private func transaction<T>(_ operation: (inout TileRegistryState) throws -> T) throws -> T {
        try TileStorage.prepare(directory)
        var number: Int32 = 0
        let fd = directory.appendingPathComponent("registry.lock").path.withCString { lt_lock_acquire($0, &number) }
        if fd == -2 { throw TileCoordinationError.busy }
        guard fd >= 0 else { throw TileCoordinationError.fileSystem(number) }
        defer { lt_lock_release(fd) }
        let url = directory.appendingPathComponent("registry.json")
        var state: TileRegistryState
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 262_144, let decoded = try? JSONDecoder().decode(TileRegistryState.self, from: data),
                  decoded.schemaVersion == 1, decoded.members.count <= 32 else { throw TileCoordinationError.corruptRegistry }
            state = decoded
        } else { state = TileRegistryState() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(state)
        let result = try operation(&state)
        let data = try encoder.encode(state)
        guard data.count <= 262_144 else { throw TileCoordinationError.corruptRegistry }
        // Lock inode stays fixed; only the data file is atomically replaced.
        if data != before { try data.write(to: url, options: .atomic) }
        return result
    }
}
