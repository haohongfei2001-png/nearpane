import Foundation

/// Swift supplies the independent, complete inventory and keeps the exact-window ordinary focus/placement
/// operations. The Rust worker only receives visibility requests. Both lanes require the same exclusive lease.
@MainActor public protocol StageEngineWindowWitness: AnyObject {
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample
    func readBystanders(of command: StageWindowCommand, measured: SurfaceRect, owner: StageEngineOwner) async throws -> StageWindowSample
    func ordinary(_ command: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool
    func mayManage(_ state: StageWindowState) -> Bool
    func beginRelease()
    func expectVisibility(_ command: StageWindowCommand, nativeID: UInt64, frame: SurfaceRect?)
}

public extension StageEngineWindowWitness {
    func readBystanders(of command: StageWindowCommand, measured: SurfaceRect, owner: StageEngineOwner) async throws -> StageWindowSample {
        throw StageSwitchError.unavailable
    }
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
    let workAreaObstructed: Bool
    package init(status: UInt32, flags: UInt32, intent: UUID, nativeID: UInt64, frame: SurfaceRect? = nil,
                 workAreaObstructed: Bool = false) {
        self.status = status; self.flags = flags; self.intent = intent; self.nativeID = nativeID; self.frame = frame
        self.workAreaObstructed = workAreaObstructed
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
    func returnMeasured(_ proof: MeasuredCornerHide, intent: UUID, valid: @escaping @MainActor () -> Bool) async throws -> StageEngineReply
    func confirmMeasuredReturn(_ proof: MeasuredCornerHide, intent: UUID) async throws
    func verified(_ command: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws
    func readsFinalRelease(_ command: StageWindowCommand, owner: StageEngineOwner) async -> Bool
    func revoke()
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply
    func close() async -> Bool
}

package extension StageEngineTransport {
    func returnMeasured(_ proof: MeasuredCornerHide, intent: UUID, valid: @escaping @MainActor () -> Bool) async throws -> StageEngineReply {
        throw StageSwitchError.unavailable
    }
    func confirmMeasuredReturn(_ proof: MeasuredCornerHide, intent: UUID) async throws { throw StageSwitchError.unavailable }
    func withdrawUnsubmittedHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool { false }
    func readsFinalRelease(_ command: StageWindowCommand, owner: StageEngineOwner) async -> Bool { false }
}

/// The original signed Guardian has independently acknowledged a physical landing.
/// This error carries no evidence of visual or input isolation.
package struct MeasuredCornerHide: Error {
    package let owner: StageEngineOwner, command: StageWindowCommand, landing: SurfaceRect
    package init(owner: StageEngineOwner, command: StageWindowCommand, landing: SurfaceRect) {
        self.owner = owner; self.command = command; self.landing = landing
    }
}

/// A pre-ticket refusal allows the session to ask for proof. It cannot clear the journal.
package struct CornerHideAdmissionRefused: Error {
    package let cause: any Error
    package init(_ cause: any Error) { self.cause = cause }
}

/// The original live session yielded before calling a window writer or preparing a Guardian.
struct SupersededBeforeStageWrite: Error {
    let owner: StageEngineOwner
    let command: StageWindowCommand
    fileprivate init(owner: StageEngineOwner, command: StageWindowCommand) {
        self.owner = owner
        self.command = command
    }
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
        guard !closed, !frozen, witness.permits(owner, restoring: false) else { return nil }
        return owner.backend == .spaces ? .stageSpace : .parked
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
                      (owner.backend == .spaces
                        ? (state.visibility == .stageSpace ? (state.hiddenSpaceID ?? 0) > 0 && state.hiddenSpaceID != sample.nativeID : state.hiddenSpaceID == nil)
                        : state.visibility != .stageSpace && state.hiddenSpaceID == nil)
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
              qualifiedHiddenState != nil, intentIsCurrent() else { throw StageSwitchError.unavailable }
        // A hidden Space has no screen retirement region, wallpaper shield or input tap.
        if owner.backend == .spaces { return }
        try await transport.checkRetirementSurface(sample.scope, nativeID: native, bottomOnly: bottomOnly, owner: owner)
    }

    private func stopAfterBackendFailure(current: Bool) {
        if current && !Task.isCancelled && qualifiedHiddenState != nil { backendFailed = true }
        freeze()
    }

    private func requireHealthy(_ reply: StageEngineReply, intent: UUID) throws {
        if reply.intent == intent, reply.status == 2, reply.workAreaObstructed {
            // This generation must return its windows. A later unobstructed desktop
            // may use the reviewed backend after the old ownership has been released.
            freeze()
            throw StageSwitchError.workAreaObstructed
        }
        guard reply.verifies(intent, owner.backend == .spaces ? 64 : 64 | 16) else { throw StageSwitchError.unavailable }
    }

    public func checkHealth() async throws {
        let intent = UUID()
        guard qualifiedHiddenState != nil else { throw StageSwitchError.unavailable }
        do {
            let health = try await transport.health(owner,intent:intent)
            guard qualifiedHiddenState != nil else { throw StageSwitchError.unavailable }
            try requireHealthy(health, intent: intent)
        } catch { stopAfterBackendFailure(current: true); throw error }
    }

    public func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws {
        // A Rust-backed write always needs the coordinator's durable intent and group/member.
        throw StageSwitchError.ownership
    }

    public func dispatch(_ c: StageWindowCommand) async throws {
        func eligible(settling: Bool = false) -> Bool {
            let ownsIntent = intentIsCurrent() || (settling && newerSelectionWaiting())
            return !closed && mayManage(c.before) &&
            (c.restoring ? c.action == .show && (recovering || (!frozen && ownsIntent)) : !frozen && ownsIntent) && witness.permits(owner,restoring:c.restoring)
        }
        // Only use this check before entering a writer or asking a Guardian to prepare.
        // Once handed off, even a superseding click must settle the actual command.
        func requireUnsentIntent() throws {
            if eligible() { return }
            guard !c.restoring, !Task.isCancelled, newerSelectionWaiting(), eligible(settling: true)
            else { throw StageSwitchError.interrupted }
            throw SupersededBeforeStageWrite(owner: owner, command: c)
        }
        guard (c.nativeID ?? 0) > 0, c.generation == owner.generation else { throw StageSwitchError.interrupted }
        try requireUnsentIntent()
        if c.restoring {
            guard c.action == .show, c.restoreFrame != nil, c.before.visibility == (owner.backend == .spaces ? .stageSpace : .parked)
            else { throw StageSwitchError.ownership }
        }
        let pre = try await read(c.scope)
        guard pre.generation == c.generation, pre.nativeID == c.nativeID,
              pre.windows[c.before.window] == c.before else { throw StageSwitchError.interrupted }
        try requireUnsentIntent()
        var lastReadSequence = pre.sequence
        // Restoration can survive a revoked event tap/failed probe; the old worker must still explicitly
        // attest its retained ownership via RESTORE. No new hide/show/place follows a lost health result.
        if !c.restoring {
            do {
                let health = try await transport.submit(6,owner:owner,c)
                try requireHealthy(health, intent: c.intent)
            } catch { stopAfterBackendFailure(current: eligible()); throw error }
            try requireUnsentIntent()
            // Recheck the home, roster and original focus after the worker health observation.
            let checked = try await read(c.scope)
            guard checked.sequence > pre.sequence, checked.generation == pre.generation,
                  checked.nativeID == pre.nativeID, checked.windows == pre.windows, checked.focus == pre.focus,
                  checked.foreignFocusScope == pre.foreignFocusScope, checked.workArea == pre.workArea
            else { throw StageSwitchError.interrupted }
            try requireUnsentIntent()
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
                guard c.before.visibility == .visible || (owner.backend == .spaces && c.before.visibility == .minimized)
                else { throw StageSwitchError.ownership }
            } else {
                guard c.restoreFrame != nil, c.before.visibility == (owner.backend == .spaces ? .stageSpace : .parked) else {
                    throw StageSwitchError.ownership
                }
            }
            let sent: StageEngineReply
            if hiding && owner.backend == .spaces {
                // Space ownership and return membership are recorded by the engine before the
                // bridged move. No Corner guardian or screen surface participates in this path.
                try await transport.prepareHide(c, owner: owner)
                try requireUnsentIntent()
                sent = try await transport.submit(3, owner: owner, c)
            } else if hiding {
                try await transport.prepareHide(c,owner:owner)
                var yieldedFocus: NativeSpaceWindow?
                var submitting = false
                do {
                    let after = try await read(c.scope)
                    guard after.scope == pre.scope, after.nativeID == pre.nativeID, after.generation == pre.generation,
                          after.sequence > lastReadSequence, after.windows == pre.windows, after.workArea == pre.workArea
                    else { throw StageSwitchError.interrupted }
                    if let focus = after.focus, focus != pre.focus, after.foreignFocusScope == nil,
                       after.windows[focus]?.visibility == .visible { yieldedFocus = focus }
                    guard eligible(), after.focus == pre.focus else { throw StageSwitchError.interrupted }
                    submitting = true
                    sent = try await transport.submit(3,owner:owner,c)
                } catch {
                    // Admission can be lost between the last read and Rust taking the ticket.
                    // Only the original engine fence plus the live Guardian can prove it unused.
                    let refused = error as? CornerHideAdmissionRefused
                    guard !submitting || refused != nil, c.restoreFrame == nil,
                          (try? await transport.withdrawUnsubmittedHide(c, owner: owner)) == true
                    else { throw refused?.cause ?? error }
                    if yieldedFocus != nil || !newerSelectionWaiting() { freeze() }
                    throw UnsubmittedCornerHide(owner: owner, command: c, yieldedFocus: yieldedFocus)
                }
            } else {
                sent = try await transport.submit(c.restoring ? 5 : 4,owner:owner,c)
            }
            guard eligible(settling: true), sent.verifies(c.intent,0) else { freeze(); throw StageSwitchError.incomplete }
            let readback = try await transport.submit(2,owner:owner,c)
            let mask: UInt32 = 4 | 8 | 32 | (hiding ? (owner.backend == .spaces ? 2 : 2 | 128 | 16) : 1)
            let membershipMatches = hiding && owner.backend == .spaces
                ? readback.nativeID > 0 && readback.nativeID != pre.nativeID
                : readback.nativeID == pre.nativeID
            guard eligible(settling: true), readback.verifies(c.intent,mask), readback.flags & (hiding ? 1 : 2) == 0,
                  membershipMatches
            else { freeze(); throw StageSwitchError.incomplete }
            witness.expectVisibility(c,nativeID:readback.nativeID,frame:readback.frame)
            let independentlyRead = try await read(c.scope)
            guard eligible(settling: true), independentlyRead.generation == pre.generation, independentlyRead.nativeID == pre.nativeID,
                  independentlyRead.sequence > pre.sequence, let result = independentlyRead.windows[c.before.window],
                  result.lifetime == c.before.lifetime, let measured = readback.frame,
                  [measured.x,measured.y,measured.width,measured.height].allSatisfy(\.isFinite),
                  abs(measured.x-result.frame.x) <= 1, abs(measured.y-result.frame.y) <= 1,
                  abs(measured.width-result.frame.width) <= 1, abs(measured.height-result.frame.height) <= 1,
                  (hiding && owner.backend == .spaces
                    ? result.visibility == .stageSpace && result.hiddenSpaceID == readback.nativeID
                    : result.hiddenSpaceID == nil) else {
                freeze(); throw StageSwitchError.incomplete
            }
        }
    }
    func returnMeasured(_ proof: MeasuredCornerHide, intent: UUID, baseline: StageWindowSample) async throws {
        let c = proof.command
        func permitted() -> Bool {
            owner == proof.owner && c.generation == owner.generation && !closed && !frozen && intentIsCurrent() &&
                !Task.isCancelled && c.action == .hide && !c.restoring && mayManage(c.before) && witness.permits(owner, restoring: false)
        }
        guard permitted(), baseline.windows[c.before.window] == c.before, baseline.focus != nil,
              baseline.focus != c.before.window, baseline.generation == owner.generation, baseline.nativeID == c.nativeID,
              baseline.scope == c.scope else { throw StageSwitchError.interrupted }
        var sequence = baseline.sequence
        func verify(_ sample: StageWindowSample, windows: [NativeSpaceWindow: StageWindowState]) throws {
            guard permitted(), sample.scope == baseline.scope, sample.nativeID == baseline.nativeID,
                  sample.generation == baseline.generation, sample.workArea == baseline.workArea, sample.sequence > sequence,
                  sample.focus == baseline.focus, sample.foreignFocusScope == baseline.foreignFocusScope,
                  sample.windows == windows else { throw StageSwitchError.interrupted }
            sequence = sample.sequence
        }
        let others = baseline.windows.filter { $0.key != c.before.window }
        for _ in 0..<2 {
            try verify(try await witness.readBystanders(of: c, measured: proof.landing, owner: owner), windows: others)
        }
        let result = try await transport.returnMeasured(proof, intent: intent, valid: permitted)
        guard result.verifies(intent, 1 | 4 | 8 | 32), result.flags == (1 | 4 | 8 | 32),
              result.nativeID == c.nativeID, result.frame == c.before.frame else { throw StageSwitchError.incomplete }
        for _ in 0..<2 { try verify(try await read(c.scope), windows: baseline.windows) }
        try await transport.confirmMeasuredReturn(proof, intent: intent)
    }

    public func didVerify(_ command: StageWindowCommand, after: StageWindowState) async throws {
        guard command.generation == owner.generation, command.before.window == after.window,
              command.before.lifetime == after.lifetime else { throw StageSwitchError.ownership }
        try await transport.verified(command,after:after,owner:owner)
    }
    public func readsFinalRelease(_ command: StageWindowCommand) async -> Bool {
        guard recovering, !closed, command.generation == owner.generation,
              command.restoring, command.action == .show, command.before.visibility == (owner.backend == .spaces ? .stageSpace : .parked),
              command.restoreFrame != nil, witness.permits(owner, restoring: true) else { return false }
        return await transport.readsFinalRelease(command, owner: owner)
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
    private let selectRecord: ([StageEngineQualification], StageEngineEnvironment, Set<UUID>) -> StageEngineQualification?
    public func preferredRecord(_ records: [StageEngineQualification], in environment: StageEngineEnvironment) -> StageEngineQualification? {
        var unavailable = failedEvidence
        if let session, session.backendFailed { unavailable.insert(session.owner.evidence) }
        return selectRecord(records, environment, unavailable)
    }
    public var canObserve: Bool { !busy && !releaseRequested && session?.qualifiedHiddenState != nil }
    public var canAttemptOwnedRelease: Bool { !busy && session?.canAttemptRelease == true }
    public var holdsWindowDispatch: Bool { busy || releaseRequested || session != nil || coordinator.hasWindowAuthority }
    public init(coordinator: StageGroupCoordinator) {
        self.coordinator = coordinator
        selectRecord = { StageEngineQualification.choose($0, in: $1, excluding: $2) }
    }
    /// Dependency injection keeps historical recovery regression tests independent of the
    /// current product route. The shipping initializer always uses IndependentStagePolicy.
    package init(coordinator: StageGroupCoordinator,
                 selection: @escaping ([StageEngineQualification], StageEngineEnvironment, Set<UUID>) -> StageEngineQualification?) {
        self.coordinator = coordinator; selectRecord = selection
    }

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

    /// Explicit isolated execution of the real product path. This is separate from
    /// physical release qualification and never manufactures passing evidence.
    @discardableResult public func configureSpacesCandidate(for environment: StageEngineEnvironment,
        exclusive: () -> Bool, make: (StageEngineEnvironment) -> StageEngineSession?) async throws -> Bool {
        guard !busy, !releaseRequested else { throw StageSwitchError.busy }
        busy = true
        defer { busy = false }
        if let session, session.owner.backend == .spaces, session.owner.environment == environment,
           session.qualifiedHiddenState == .stageSpace, exclusive() { return true }
        if session != nil { invalidate(); try await releaseCurrent() }
        guard exclusive(), !coordinator.hasWindowAuthority else { throw StageSwitchError.recoveryRequired }
        guard let candidate = make(environment), candidate.owner.backend == .spaces,
              candidate.owner.environment == environment, candidate.qualifiedHiddenState == .stageSpace else { return false }
        session = candidate
        lastFailure = nil
        return true
    }

    public func retireMinimized(_ window: NativeSpaceWindow, in scope: StageGroupScope,
                                current: @escaping @MainActor () -> Bool) async throws {
        guard !busy, !releaseRequested, let session, session.owner.backend == .spaces,
              session.qualifiedHiddenState == .stageSpace, current() else { throw StageSwitchError.unavailable }
        busy = true; session.intentIsCurrent = current
        defer { busy = false; session.intentIsCurrent = { false } }
        try await coordinator.retireMinimized(window, in: scope, session: session, current: current)
    }

    public func activate(_ group: UUID, member: UUID?, in scope: StageGroupScope, consent: Bool,
                         resumingFrom: StageWindowSample? = nil,
                         current: @escaping @MainActor () -> Bool,
                         newerChoice: @escaping @MainActor () -> Bool = { false }) async throws {
        guard !busy, !releaseRequested else { throw StageSwitchError.busy }
        guard let session, session.qualifiedHiddenState != nil, current() else { throw StageSwitchError.unavailable }
        let token = revision; busy = true; session.intentIsCurrent = current
        session.newerSelectionWaiting = { self.revision == token && !Task.isCancelled && newerChoice() }
        defer { busy = false; session.intentIsCurrent = { false }; session.newerSelectionWaiting = { false } }
        do {
            try await coordinator.activate(group, member: member, in: scope, consent: consent, session: session, resumingFrom: resumingFrom,
                                          current: { token == self.revision && current() }, newerChoice: session.newerSelectionWaiting)
            guard token == revision, current() else { throw StageSwitchError.interrupted }
        } catch {
            if session.qualifiedHiddenState == nil || coordinator.requiresRecovery { invalidate() }
            lastFailure = error as? StageSwitchError ?? .incomplete
            throw error
        }
    }
}
