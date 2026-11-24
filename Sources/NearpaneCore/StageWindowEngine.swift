import Foundation

/// Swift supplies the independent, complete inventory and keeps the exact-window ordinary focus/placement
/// operations. The Rust worker only receives visibility requests. Both lanes require the same exclusive lease.
@MainActor public protocol StageEngineWindowWitness: AnyObject {
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample
    func ordinary(_ command: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool
    func mayManage(_ state: StageWindowState) -> Bool
    func beginRelease()
    func expectVisibility(_ command: StageWindowCommand, nativeID: UInt64, frame: SurfaceRect?)
}

public extension StageEngineWindowWitness {
    func beginRelease() {}
    func expectVisibility(_ command: StageWindowCommand, nativeID: UInt64, frame: SurfaceRect?) {}
}

/// Independent metadata from the signed ordinary controller's retained AX element and WindowServer.
/// No pixel, title or document content is requested or transferred.
public struct StageWindowPhysicalObservation: Codable, Equatable, Sendable {
    public let id: ManagedWindowID, frame: SurfaceRect, membership: UInt64
    public let onscreen, minimized: Bool
    public let focus: NativeSpaceWindow?
    public init(id: ManagedWindowID, frame: SurfaceRect, membership: UInt64, onscreen: Bool, minimized: Bool, focus: NativeSpaceWindow?) {
        self.id = id; self.frame = frame; self.membership = membership; self.onscreen = onscreen; self.minimized = minimized; self.focus = focus
    }
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
    func start(_ owner: StageEngineOwner, nativeID: UInt64) async throws
    func checkRetirementSurface(_ scope: StageGroupScope, nativeID: UInt64, bottomOnly: Bool, owner: StageEngineOwner) async throws
    func prepareHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws
    /// True only after this worker excluded the HIDE ticket permanently and its prepared Guardian
    /// acknowledged its durable, independently witnessed withdrawal for this exact intent.
    func withdrawUnsubmittedHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool
    func verified(_ command: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws
    func revoke()
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply
    func close() async -> Bool
}

package extension StageEngineTransport {
    func withdrawUnsubmittedHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool { false }
}

/// Only the session that completed both sides of a Corner withdrawal can create this receipt.
struct UnsubmittedCornerHide: Error {
    let owner: StageEngineOwner, command: StageWindowCommand, yieldedFocus: NativeSpaceWindow?
    fileprivate init(owner: StageEngineOwner, command: StageWindowCommand, yieldedFocus: NativeSpaceWindow?) {
        self.owner = owner; self.command = command; self.yieldedFocus = yieldedFocus
    }
}

@MainActor public final class StageEngineSession: StageWindowSession {
    public let owner: StageEngineOwner
    public var engineOwner: StageEngineOwner? { owner }
    private let witness: any StageEngineWindowWitness, transport: any StageEngineTransport
    private var frozen = false, closed = false, recovering = false
    public private(set) var backendFailed = false
    public var isFrozen: Bool { frozen }
    private var enrolledLifetimes: [NativeSpaceWindow: UUID]?
    var intentIsCurrent: @MainActor () -> Bool = { false }
    fileprivate var newerSelectionWaiting: @MainActor () -> Bool = { false }
    var canAttemptRelease: Bool { !closed && witness.permits(owner, restoring: true) }
    public var qualifiedHiddenState: StageWindowState.Visibility? {
        !closed && !frozen && owner.backend == .corner && witness.permits(owner,restoring:false) ? .parked : nil
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
                      state.visibility != .stageSpace && state.hiddenSpaceID == nil
              }) else { throw StageSwitchError.incomplete }
        // Fresh inventory can grow while this owner is observing. Its existing write lease cannot.
        if enrolledLifetimes == nil, !frozen, witness.permits(owner, restoring: false) {
            enrolledLifetimes = sample.windows.mapValues(\.lifetime)
        }
        return sample
    }

    public func mayManage(_ state: StageWindowState) -> Bool {
        enrolledLifetimes?[state.window] == state.lifetime && witness.mayManage(state)
    }

    public func prepareBackend(_ sample: StageWindowSample) async throws {
        guard let native = sample.nativeID, native > 0, qualifiedHiddenState != nil, intentIsCurrent() else { throw StageSwitchError.interrupted }
        do {
            try await transport.start(owner,nativeID:native)
            try await checkHealth()
        } catch { stopAfterBackendFailure(current: intentIsCurrent()); throw error }
        guard intentIsCurrent() else { throw newerSelectionWaiting() ? StageSwitchError.superseded : .interrupted }
    }

    public func checkRetirementSurface(_ sample: StageWindowSample, bottomOnly: Bool) async throws {
        guard let native = sample.nativeID, native > 0, sample.generation == owner.generation,
              qualifiedHiddenState == .parked, intentIsCurrent() else { throw StageSwitchError.unavailable }
        try await transport.checkRetirementSurface(sample.scope, nativeID: native, bottomOnly: bottomOnly, owner: owner)
    }

    private func stopAfterBackendFailure(current: Bool) {
        if current && !Task.isCancelled && qualifiedHiddenState != nil { backendFailed = true }
        freeze()
    }

    public func checkHealth() async throws {
        let intent = UUID()
        guard qualifiedHiddenState != nil else { throw StageSwitchError.unavailable }
        do {
            let health = try await transport.health(owner,intent:intent)
            guard qualifiedHiddenState != nil, health.verifies(intent,64 | 16) else {
                throw StageSwitchError.unavailable
            }
        } catch { stopAfterBackendFailure(current: true); throw error }
    }

    public func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws {
        // A Rust-backed write always needs the coordinator's durable intent and group/member.
        throw StageSwitchError.ownership
    }

    public func dispatch(_ c: StageWindowCommand) async throws {
        func eligible(settling: Bool = false) -> Bool {
            let ownsIntent = intentIsCurrent() || (settling && newerSelectionWaiting())
            return owner.backend == .corner && !closed && mayManage(c.before) &&
            (c.restoring ? c.action == .show && (recovering || (!frozen && ownsIntent)) : !frozen && ownsIntent) && witness.permits(owner,restoring:c.restoring)
        }
        guard eligible(), (c.nativeID ?? 0) > 0 else { throw StageSwitchError.interrupted }
        if c.restoring {
            guard c.action == .show, c.restoreFrame != nil, c.before.visibility == .parked
            else { throw StageSwitchError.ownership }
        }
        let pre = try await read(c.scope)
        guard eligible(), pre.generation == c.generation, pre.nativeID == c.nativeID,
              pre.windows[c.before.window] == c.before else { throw StageSwitchError.interrupted }
        var lastReadSequence = pre.sequence
        // Restoration can survive a revoked event tap/failed probe; the old worker must still explicitly
        // attest its retained ownership via RESTORE. No new hide/show/place follows a lost health result.
        if !c.restoring {
            do {
                let health = try await transport.submit(6,owner:owner,c)
                guard eligible(), health.verifies(c.intent,64 | 16) else {
                    throw StageSwitchError.unavailable
                }
            } catch { stopAfterBackendFailure(current: eligible()); throw error }
            // Recheck the home, roster and original focus after the worker health observation.
            let checked = try await read(c.scope)
            guard eligible(), checked.sequence > pre.sequence, checked.generation == pre.generation,
                  checked.nativeID == pre.nativeID, checked.windows == pre.windows, checked.focus == pre.focus,
                  checked.workArea == pre.workArea else { throw StageSwitchError.interrupted }
            lastReadSequence = checked.sequence
        }
        switch c.action {
        case .place, .focus:
            try await witness.ordinary(c,valid:{ [weak self] in
                guard let self else { return false }
                return !self.frozen && !self.closed && self.mayManage(c.before) && self.intentIsCurrent() && self.witness.permits(self.owner,restoring:false)
            })
        case .hide, .show:
            let hiding = c.action == .hide
            if hiding {
                guard c.before.visibility == .visible else { throw StageSwitchError.ownership }
            } else {
                guard c.restoreFrame != nil, c.before.visibility == .parked else {
                    throw StageSwitchError.ownership
                }
            }
            if hiding, owner.backend == .corner {
                try await transport.prepareHide(c,owner:owner)
                var yieldedFocus: NativeSpaceWindow?
                do {
                    let after = try await read(c.scope)
                    guard after.scope == pre.scope, after.nativeID == pre.nativeID, after.generation == pre.generation,
                          after.sequence > lastReadSequence, after.windows == pre.windows, after.workArea == pre.workArea
                    else { throw StageSwitchError.interrupted }
                    if let focus = after.focus, focus != pre.focus, after.foreignFocusScope == nil,
                       after.windows[focus]?.visibility == .visible { yieldedFocus = focus }
                    guard eligible(), after.focus == pre.focus else { throw StageSwitchError.interrupted }
                } catch {
                    guard c.restoreFrame == nil,
                          (try? await transport.withdrawUnsubmittedHide(c, owner: owner)) == true else { throw error }
                    if yieldedFocus != nil || !newerSelectionWaiting() { freeze() }
                    throw UnsubmittedCornerHide(owner: owner, command: c, yieldedFocus: yieldedFocus)
                }
            }
            let sent = try await transport.submit(c.restoring ? 5 : hiding ? 3 : 4,owner:owner,c)
            guard eligible(settling: true), sent.verifies(c.intent,0) else { freeze(); throw StageSwitchError.incomplete }
            let readback = try await transport.submit(2,owner:owner,c)
            let mask: UInt32 = 4 | 8 | 32 | (hiding ? 2 | 128 | 16 : 1)
            guard eligible(settling: true), readback.verifies(c.intent,mask), readback.flags & (hiding ? 1 : 2) == 0,
                  readback.nativeID == pre.nativeID
            else { freeze(); throw StageSwitchError.incomplete }
            witness.expectVisibility(c,nativeID:readback.nativeID,frame:readback.frame)
            let independentlyRead = try await read(c.scope)
            guard eligible(settling: true), independentlyRead.generation == pre.generation, independentlyRead.nativeID == pre.nativeID,
                  independentlyRead.sequence > pre.sequence, let result = independentlyRead.windows[c.before.window],
                  result.lifetime == c.before.lifetime, let measured = readback.frame,
                  [measured.x,measured.y,measured.width,measured.height].allSatisfy(\.isFinite),
                  abs(measured.x-result.frame.x) <= 1, abs(measured.y-result.frame.y) <= 1,
                  abs(measured.width-result.frame.width) <= 1, abs(measured.height-result.frame.height) <= 1,
                  result.hiddenSpaceID == nil else {
                freeze(); throw StageSwitchError.incomplete
            }
        }
    }
    public func didVerify(_ command: StageWindowCommand, after: StageWindowState) async throws {
        guard owner.backend == .corner, command.generation == owner.generation, command.before.window == after.window,
              command.before.lifetime == after.lifetime else { throw StageSwitchError.ownership }
        try await transport.verified(command,after:after,owner:owner)
    }
    func beginRelease() { recovering = true; witness.beginRelease() }
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
    private var busy = false, releaseRequested = false, revision = UUID()
    private var failedEvidence = Set<UUID>()
    public func preferredRecord(_ records: [StageEngineQualification], in environment: StageEngineEnvironment) -> StageEngineQualification? {
        var unavailable = failedEvidence
        if let session, session.backendFailed { unavailable.insert(session.owner.evidence) }
        return StageEngineQualification.choose(records, in: environment, excluding: unavailable)
    }
    public var canObserve: Bool { !busy && !releaseRequested && session?.qualifiedHiddenState != nil }
    public var canAttemptOwnedRelease: Bool { !busy && session?.canAttemptRelease == true }
    public var holdsWindowDispatch: Bool { busy || releaseRequested || session != nil || coordinator.hasWindowAuthority }
    public init(coordinator: StageGroupCoordinator) { self.coordinator = coordinator }

    public func invalidate() {
        revision = UUID(); session?.freeze(); coordinator.invalidate()
        do { try coordinator.withdrawVerifiedActivity() }
        catch { lastFailure = .recoveryRequired }
    }

    /// Only the old driver may perform recovery, never the newly preferred driver. When there is no
    /// executable authority after restart the durable records block every replacement until reconciliation.
    public func release() async throws {
        guard !releaseRequested else { throw StageSwitchError.busy }
        releaseRequested = true
        defer { releaseRequested = false }
        invalidate()
        // A native takeover or normal quit can occur while the accepted worker command is awaiting its
        // terminal receipt. Give its write-ahead record time to settle. Never replay a timed-out command.
        let deadline = ContinuousClock.now.advanced(by:.seconds(12))
        while busy {
            guard ContinuousClock.now < deadline else { throw StageSwitchError.recoveryRequired }
            try await Task.sleep(for:.milliseconds(12))
        }
        busy = true
        defer { busy = false }
        try await releaseCurrent()
    }

    private func releaseCurrent() async throws {
        guard let previous = session else {
            guard !coordinator.hasWindowAuthority else { throw StageSwitchError.recoveryRequired }
            return
        }
        if previous.backendFailed { failedEvidence.insert(previous.owner.evidence) }
        let token = revision
        do {
            previous.beginRelease()
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
        guard !busy, !releaseRequested else { throw StageSwitchError.busy }
        busy = true
        defer { busy = false }
        let next = preferredRecord(records, in: environment)
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

    public func activate(_ group: UUID, member: UUID?, in scope: StageGroupScope, consent: Bool,
                         current: @escaping @MainActor () -> Bool,
                         newerChoice: @escaping @MainActor () -> Bool = { false }) async throws {
        guard !busy, !releaseRequested else { throw StageSwitchError.busy }
        guard let session, session.qualifiedHiddenState != nil, current() else { throw StageSwitchError.unavailable }
        let token = revision; busy = true; session.intentIsCurrent = current
        session.newerSelectionWaiting = { self.revision == token && !Task.isCancelled && newerChoice() }
        defer { busy = false; session.intentIsCurrent = { false }; session.newerSelectionWaiting = { false } }
        do {
            try await coordinator.activate(group, member: member, in: scope, consent: consent, session: session,
                                          current: { token == self.revision && current() }, newerChoice: session.newerSelectionWaiting)
            guard token == revision, current() else { throw StageSwitchError.interrupted }
        } catch {
            if session.qualifiedHiddenState == nil || coordinator.requiresRecovery { invalidate() }
            lastFailure = error as? StageSwitchError ?? .incomplete
            throw error
        }
    }
}
