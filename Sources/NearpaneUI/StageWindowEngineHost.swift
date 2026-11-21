import Foundation
import NearpaneCore
import NearpaneWindowEngine

/// Operations are enabled by reviewed physical qualification in the signed build. Neither package preferences,
/// old group/visibility ledgers nor an available Rust symbol can enroll an operating environment.
@MainActor final class StageWindowEngineHost {
    struct Admission {
        let qualification: StageEngineQualification
        /// Fresh OS/build/signature, security posture, full physical topology and window class comparison.
        let environment: (DesktopSnapshot) -> StageEngineEnvironment?
        /// The registered adapter supplies complete independent observation, user consent, and a retained
        /// worker generation. Product input is never used as a substitute for first-use authorization.
        let isAuthorized: (StageGroupScope) -> Bool
        let witness: (CurrentDesktopWindows, StageGroupScope, @escaping @MainActor () -> Bool) -> (UUID, any StageEngineWindowWitness)?
    }
    // Neither gate currently has a completed physical receipt for the installed Host.
    static let shipped: [Admission] = []

    private let admissions: [Admission], engine: StageWindowEngineController?
    private let unreadableLedger: Bool
    weak var management: CandidateWorkRect?
    private var releasing = false, recoveryRequested = false, revision: UInt64 = 0

    init(profile: URL?, store: StageGroupStore, admissions: [Admission] = StageWindowEngineHost.shipped) {
        self.admissions = admissions
        if let profile {
            do {
                engine = try StageWindowEngineController(coordinator: StageGroupCoordinator(store:store,profile:profile))
                unreadableLedger = false
            } catch { engine = nil; unreadableLedger = true }
        } else { engine = nil; unreadableLedger = false }
    }

    var holdsDispatch: Bool { unreadableLedger || releasing || engine?.holdsWindowDispatch == true }
    var routesGroupChoice: Bool { !admissions.isEmpty || holdsDispatch }

    func freeze() {
        guard let engine, engine.holdsWindowDispatch else { return }
        revision &+= 1
        recoveryRequested = true
        engine.invalidate()
    }

    /// A takeover revokes new actions immediately. Restore under the old worker only after its independent
    /// witness positively observes a safe context again. An uncertain issued restore remains in the WAL.
    func ordinaryContextObserved() {
        guard recoveryRequested, !releasing, engine?.canAttemptOwnedRelease == true else { return }
        recoveryRequested = false
        Task { [weak self] in await self?.release() }
    }

    func release() async {
        guard let engine, engine.holdsWindowDispatch, !releasing else { return }
        releasing = true; defer { releasing = false }
        do { try await engine.release() } catch { /* The old owner and its WAL remain authoritative. */ }
    }

    func groupChoice(_ group: UUID, member: NativeSidebarMember, in feed: CurrentDesktopWindows,
                     snapshot: DesktopSnapshot, current: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard routesGroupChoice else { return false }
        guard !unreadableLedger, !releasing, let engine, let window = feed.groupWindow(member,in:snapshot),
              let space = window.nativeSpace, let saved = feed.groups.groups(in:.init(display:window.display,nativeSpace:space))
                .first(where: { $0.id == group })?.members.first(where: { $0.windowHint == window.identity })
        else { throw StageSwitchError.recoveryRequired }
        let scope = StageGroupScope(display:window.display,nativeSpace:space)
        let entries = admissions.compactMap { entry -> (Admission,StageEngineEnvironment)? in
            guard let env = entry.environment(snapshot), entry.qualification.admits(env) else { return nil }
            return (entry,env)
        }
        guard let env = entries.first?.1, entries.allSatisfy({ $0.1 == env }) else {
            if engine.holdsWindowDispatch { await release(); throw StageSwitchError.unavailable }
            return false
        }
        let token = revision
        let environmentCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, self.revision == token else { return false }
            return self.management?.permitsStageEngine(on:member.source.display) == true
        }
        let permitted: @MainActor () -> Bool = { [weak self,weak feed] in
            self != nil && feed?.lifetime(of:member.key) == window.lifetime && current() && environmentCurrent()
        }
        guard permitted() else { throw StageSwitchError.busy }
        let records = entries.map { $0.0.qualification }
        guard let selected = StageEngineQualification.choose(records,in:env,retaining:engine.session?.owner.backend),
              let admission = entries.first(where: { $0.0.qualification == selected })?.0,
              admission.isAuthorized(scope) else {
            if engine.holdsWindowDispatch { await release(); throw StageSwitchError.unavailable }
            return false
        }
        let available = try await engine.configure(for:env,records:records,exclusive:permitted) { q in
            guard q == selected, let (generation,witness) = admission.witness(feed,scope,environmentCurrent) else { return nil }
            return StageEngineSession(owner:.init(qualification:q,generation:generation),witness:witness)
        }
        guard available, permitted() else { throw StageSwitchError.unavailable }
        do {
            try await engine.activate(group,member:saved.id,in:scope,consent:true,current:permitted)
            return true
        } catch {
            if engine.coordinator.requiresRecovery || engine.session?.qualifiedHiddenState == nil {
                recoveryRequested = true
                ordinaryContextObserved()
            }
            throw error
        }
    }
}
