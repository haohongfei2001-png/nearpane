import Foundation

/// Swift supplies the independent, complete inventory and keeps the exact-window ordinary focus/placement
/// operations. The Rust worker only receives visibility requests. Both lanes require the same exclusive lease.
@MainActor public protocol StageEngineWindowWitness: AnyObject {
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample
    func ordinary(_ command: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool
}

package struct StageEngineReply {
    let status, flags: UInt32
    let intent: UUID, nativeID: UInt64, frame: SurfaceRect?
    package init(status: UInt32, flags: UInt32, intent: UUID, nativeID: UInt64, frame: SurfaceRect? = nil) {
        self.status = status; self.flags = flags; self.intent = intent; self.nativeID = nativeID; self.frame = frame
    }
    func verifies(_ intent: UUID, _ mask: UInt32) -> Bool {
        self.intent == intent && status == 0 && flags & mask == mask
    }
}

@MainActor package protocol StageEngineTransport: AnyObject {
    func submit(_ operation: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) async throws -> StageEngineReply
    func revoke()
    func close() async -> Bool
}

@MainActor public final class StageEngineSession: StageWindowSession {
    public let owner: StageEngineOwner
    public var engineOwner: StageEngineOwner? { owner }
    private let witness: any StageEngineWindowWitness, transport: any StageEngineTransport
    private var frozen = false, closed = false
    var intentIsCurrent: @MainActor () -> Bool = { false }
    var canAttemptRelease: Bool { !closed && witness.permits(owner, restoring: true) }
    public var qualifiedHiddenState: StageWindowState.Visibility? {
        !closed && !frozen && witness.permits(owner,restoring:false) ? (owner.backend == .corner ? .parked : .stageSpace) : nil
    }
    package init(owner: StageEngineOwner, witness: any StageEngineWindowWitness, transport: any StageEngineTransport) {
        self.owner = owner; self.witness = witness; self.transport = transport
    }

    public func read(_ scope: StageGroupScope) async throws -> StageWindowSample {
        guard !closed else { throw StageSwitchError.unavailable }
        let sample = try await witness.read(scope,owner:owner)
        let area = sample.workArea
        guard sample.scope == scope, sample.generation == owner.generation, (sample.nativeID ?? 0) > 0, area.width > 0, area.height > 0,
              [area.x,area.y,area.width,area.height].allSatisfy(\.isFinite),
              sample.windows.allSatisfy({ id,state in
                  let f = state.frame
                  return id == state.window && id.pid > 1 && id.birth > 0 && id.number > 0 && f.width > 0 && f.height > 0 &&
                      [f.x,f.y,f.width,f.height].allSatisfy(\.isFinite) &&
                      (state.visibility == .stageSpace ? (state.hiddenSpaceID ?? 0) > 0 && state.hiddenSpaceID != sample.nativeID : state.hiddenSpaceID == nil)
              }) else { throw StageSwitchError.incomplete }
        return sample
    }

    public func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws {
        // A Rust-backed write always needs the coordinator's durable intent and group/member.
        throw StageSwitchError.ownership
    }

    public func dispatch(_ c: StageWindowCommand) async throws {
        func eligible() -> Bool {
            !closed && (c.restoring ? c.action == .show : !frozen && intentIsCurrent()) && witness.permits(owner,restoring:c.restoring)
        }
        guard eligible(), (c.nativeID ?? 0) > 0 else { throw StageSwitchError.interrupted }
        if c.restoring {
            guard c.action == .show, c.restoreFrame != nil, c.before.visibility == (owner.backend == .corner ? .parked : .stageSpace)
            else { throw StageSwitchError.ownership }
        }
        let pre = try await read(c.scope)
        guard eligible(), pre.generation == c.generation, pre.nativeID == c.nativeID,
              pre.windows[c.before.window] == c.before else { throw StageSwitchError.interrupted }
        // Restoration can survive a revoked event tap/failed probe; the old worker must still explicitly
        // attest its retained ownership via RESTORE. No new hide/show/place follows a lost health result.
        if !c.restoring {
            let health = try await transport.submit(6,owner:owner,c)
            guard eligible(), health.verifies(c.intent,64 | (owner.backend == .corner ? 16 : 0)) else { freeze(); throw StageSwitchError.unavailable }
        }
        switch c.action {
        case .place, .focus:
            try await witness.ordinary(c,valid:{ [weak self] in
                guard let self else { return false }
                return !self.frozen && !self.closed && self.intentIsCurrent() && self.witness.permits(self.owner,restoring:false)
            })
        case .hide, .show:
            let hiding = c.action == .hide
            if hiding {
                guard c.before.visibility == .visible else { throw StageSwitchError.ownership }
            } else {
                guard c.restoreFrame != nil, c.before.visibility == (owner.backend == .corner ? .parked : .stageSpace) else {
                    throw StageSwitchError.ownership
                }
            }
            let sent = try await transport.submit(c.restoring ? 5 : hiding ? 3 : 4,owner:owner,c)
            guard eligible(), sent.verifies(c.intent,0) else { freeze(); throw StageSwitchError.incomplete }
            let readback = try await transport.submit(2,owner:owner,c)
            let mask: UInt32 = 4 | 8 | (hiding ? 2 | 128 : 1) | (owner.backend == .spaces ? 32 : hiding ? 16 : 0)
            guard eligible(), readback.verifies(c.intent,mask), readback.flags & (hiding ? 1 : 2) == 0,
                  owner.backend != .spaces || (hiding ? readback.nativeID != 0 && readback.nativeID != pre.nativeID : readback.nativeID == pre.nativeID)
            else { freeze(); throw StageSwitchError.incomplete }
            let independentlyRead = try await read(c.scope)
            guard eligible(), independentlyRead.generation == pre.generation, independentlyRead.nativeID == pre.nativeID,
                  independentlyRead.sequence > pre.sequence, let result = independentlyRead.windows[c.before.window],
                  result.lifetime == c.before.lifetime, let measured = readback.frame,
                  [measured.x,measured.y,measured.width,measured.height].allSatisfy(\.isFinite),
                  abs(measured.x-result.frame.x) <= 1, abs(measured.y-result.frame.y) <= 1,
                  abs(measured.width-result.frame.width) <= 1, abs(measured.height-result.frame.height) <= 1,
                  !hiding || owner.backend != .spaces || result.hiddenSpaceID == readback.nativeID else {
                freeze(); throw StageSwitchError.incomplete
            }
        }
    }
    func freeze() {
        guard !frozen, !closed else { return }
        frozen = true; transport.revoke()
    }
    func close() async throws {
        guard !closed else { return }
        freeze()
        // Rust serializes this transfer with running tickets, retained owners, unresolved writes and lost health.
        guard await transport.close() else { throw StageSwitchError.recoveryRequired }
        closed = true
    }
}

/// Host-scoped authority and lifecycle. Re-arbitration is serialized with switch and recovery, and an old
/// owner with an uncertain window/readback is never replaced by a newly available backend.
@MainActor public final class StageWindowEngineController {
    public let coordinator: StageGroupCoordinator
    public private(set) var session: StageEngineSession?
    public private(set) var lastFailure: StageSwitchError?
    private var busy = false, revision = UUID()
    public var canAttemptOwnedRelease: Bool { !busy && session?.canAttemptRelease == true }
    public var holdsWindowDispatch: Bool { busy || session != nil || coordinator.hasWindowAuthority }
    public init(coordinator: StageGroupCoordinator) { self.coordinator = coordinator }

    public func invalidate() {
        revision = UUID(); session?.freeze(); coordinator.invalidate()
        do { try coordinator.withdrawVerifiedActivity() }
        catch { lastFailure = .recoveryRequired }
    }

    /// Only the old driver may perform recovery, never the newly preferred driver. When there is no
    /// executable authority after restart the durable records block every replacement until reconciliation.
    public func release() async throws {
        invalidate()
        guard !busy else { throw StageSwitchError.busy }
        busy = true
        defer { busy = false }
        try await releaseCurrent()
    }

    private func releaseCurrent() async throws {
        guard let previous = session else {
            guard !coordinator.hasWindowAuthority else { throw StageSwitchError.recoveryRequired }
            return
        }
        let token = revision
        do {
            if coordinator.hasWindowAuthority { try await coordinator.releaseOwned(previous) }
            try await previous.close()
            try coordinator.confirmReleased(previous.owner)
            session = nil
            guard revision == token else { throw StageSwitchError.interrupted }
        } catch {
            lastFailure = .recoveryRequired
            throw error
        }
    }

    @discardableResult public func configure(for environment: StageEngineEnvironment, records: [StageEngineQualification],
        exclusive: () -> Bool, make: (StageEngineQualification) -> StageEngineSession?) async throws -> Bool {
        guard !busy else { throw StageSwitchError.busy }
        busy = true
        defer { busy = false }
        let next = StageEngineQualification.choose(records,in:environment,retaining:session?.owner.backend)
        if let session, let next, session.owner.environment == environment && session.owner.evidence == next.evidence &&
                session.owner.backend == next.backend && session.qualifiedHiddenState != nil && exclusive() { return true }
        if session != nil {
            invalidate()
            try await releaseCurrent()
        }
        guard let next, exclusive(), !coordinator.hasWindowAuthority else {
            if coordinator.hasWindowAuthority { throw StageSwitchError.recoveryRequired }
            return false
        }
        guard let candidate = make(next) else { return false }
        session = candidate
        guard candidate.owner.environment == environment, candidate.owner.evidence == next.evidence,
              candidate.owner.backend == next.backend, candidate.qualifiedHiddenState != nil else {
            try await releaseCurrent()
            return false
        }
        lastFailure = nil
        return true
    }

    public func activate(_ group: UUID, member: UUID, in scope: StageGroupScope, consent: Bool,
                         current: @escaping @MainActor () -> Bool) async throws {
        guard !busy else { throw StageSwitchError.busy }
        guard let session, session.qualifiedHiddenState != nil, current() else { throw StageSwitchError.unavailable }
        let token = revision; busy = true; session.intentIsCurrent = current
        defer { busy = false; session.intentIsCurrent = { false } }
        do {
            try await coordinator.activate(group,member:member,in:scope,consent:consent,session:session)
            guard token == revision, current() else { throw StageSwitchError.interrupted }
        } catch {
            if session.qualifiedHiddenState == nil || coordinator.requiresRecovery { invalidate() }
            lastFailure = error as? StageSwitchError ?? .incomplete
            throw error
        }
    }
}
