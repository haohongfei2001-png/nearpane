import AppKit
import Foundation
import Observation
import NearpaneCore
import NearpaneWindowEngine
import NearpaneOrdinaryWindowRuntime

/// Operations are enabled by reviewed physical qualification in the signed build. Neither package preferences,
/// old group/visibility ledgers nor an available Rust symbol can enroll an operating environment.
@MainActor @Observable final class StageWindowEngineHost {
    struct Consent: Equatable {
        let scope: StageGroupScope, evidence: UUID
        let groups: [UUID:[UUID]], lifetimes: [NativeSpaceWindow:UUID]
    }
    // The exact signed physical record is produced after final signing. Only its reviewed ID and
    // independent verification key are pinned here. Neither gate has a completed physical receipt.
    static let shipped: [StageWindowEngineAttestation.Pin] = []
    private let engine: StageWindowEngineController?, profile: URL?
    private var admissions: [StageEngineQualification]
    @ObservationIgnored private var groupProjection: DesktopSnapshot?
    private(set) var observedCapability: StageWindowBackend?
    private var needsReassessment = true
    private var lastEnvironmentalRead: TimeInterval = 0
    private weak var feed: CurrentDesktopWindows?
    struct HeldGroup: Equatable, Identifiable {
        let id, member: UUID, scope: StageGroupScope, state: StageWindowState, owner: StageEngineOwner, count: Int
    }
    private(set) var heldGroups = [HeldGroup]()
    @ObservationIgnored private var heldRefresh: Task<Void,Never>?
    private var lastVerifiedAt: TimeInterval = 0
    @ObservationIgnored private var watchers = [(NotificationCenter,NSObjectProtocol)]()
    private(set) var consentRequest: Consent?
    private var granted: Consent?
    private weak var witness: StageWindowEngineWitness?
    private var releaseInput: [UInt32]?
    private let unreadableLedger: Bool
    weak var management: CandidateWorkRect?
    @ObservationIgnored private var shutdownTask: Task<Bool,Never>?
    private var terminationOwnsLane = false
    private var releaseTask: Task<Void,Never>?
    private var releasing: Bool { releaseTask != nil }
    private var recoveryRequested = false
    private var revision: UInt64 = 0

    init(profile: URL?, store: StageGroupStore) {
        self.profile = profile
        admissions = profile.map { folder in Self.shipped.compactMap { StageWindowEngineAttestation.read($0,profile:folder) } } ?? []
        if let profile {
            do {
                let journal = try StageGroupCoordinator(store:store,profile:profile)
                try journal.withdrawVerifiedActivity()
                engine = StageWindowEngineController(coordinator:journal)
                unreadableLedger = false
            } catch { engine = nil; unreadableLedger = true }
        } else { engine = nil; unreadableLedger = false }
    }

    func attach(to feed: CurrentDesktopWindows) {
        self.feed = feed
        if !Self.shipped.isEmpty || holdsDispatch { watchSystem() }
    }

    /// Initial sample, wake/unlock and display notifications re-evaluate the installed environment.
    /// They never enroll a new writer or infer that a pre-restart AX reference survived.
    func observeEnvironment(_ snapshot: DesktopSnapshot) {
        guard !Self.shipped.isEmpty, let profile else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard needsReassessment || now-lastEnvironmentalRead >= 2 else { return }
        needsReassessment = false
        lastEnvironmentalRead = now
        let records = Self.shipped.compactMap { StageWindowEngineAttestation.read($0,profile:profile) }
        if admissions != records { witness?.cancelArrivals(); admissions = records; granted = nil; consentRequest = nil }
        let selected = StageWindowEngineAttestation.installedEnvironment(snapshot).flatMap {
            StageEngineQualification.choose(records,in:$0,retaining:engine?.session?.owner.backend)
        }
        observedCapability = selected?.backend
        guard let engine, let session = engine.session, session.qualifiedHiddenState != nil else { return }
        if selected?.evidence != session.owner.evidence { freeze() }
    }

    /// Only a physically qualified Stage environment gets this projection. The signed reader's
    /// original permission receipt remains the source for the ordinary sidebar and other clients.
    func updateGroupProjection(_ raw: DesktopSnapshot) {
        groupProjection = nil
        guard !Self.shipped.isEmpty, !admissions.isEmpty, raw.native?.catalogComplete == true,
              raw.native?.stageManagerEnabled == false, let environment = StageWindowEngineAttestation.installedEnvironment(raw),
              StageEngineQualification.choose(admissions, in: environment, retaining: engine?.session?.owner.backend) != nil,
              let access = try? StageHostAccess(expectedCDHash: environment.hostCDHash) else { return }
        groupProjection = Self.projectGroups(raw) { try access.currentSurface($0, home: $1) }
    }

    static func projectGroups(_ raw: DesktopSnapshot,
        measure: (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation?) -> DesktopSnapshot? {
        guard raw.native?.population == .workWindows, raw.native?.catalogComplete == true,
              raw.native?.stageManagerEnabled == false, raw.native?.windowLimitReached == false else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var copy = raw, confirmed = false
        for i in raw.windows.indices {
            let w = raw.windows[i]
            guard let record = raw.scopes.first(where: { $0.displayID == w.displayID })?.records.first(where: \.isCurrent),
                  let uuid = record.ordinaryUUID, w.membership == .known(recordIDs: [record.id]),
                  let key = DesktopWindowKey(w), var m = w.metadata else { continue }
            m.overviewOrdinaryRole = nil
            m.minimized = nil
            if ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    let member = NativeSpaceWindow(pid: key.pid, birth: key.birth, number: key.number)
                    if let s = try measure(member, .init(display: w.displayID, record: record.id, uuid: uuid)) {
                        if s.id.pid == key.pid, s.id.launch == key.birth, s.id.number == key.number,
                           s.membership == UInt64(record.id), s.frame == m.globalFrame, s.onscreen == m.isOnscreen {
                            m.overviewOrdinaryRole = true; m.fullScreen = false; m.minimized = s.minimized
                            m.overviewIsPresented = s.onscreen && !s.minimized && m.overviewSpaceID == record.id
                            confirmed = true
                        }
                    } else { m.overviewOrdinaryRole = false }
                } catch { /* This surface stays unconfirmed. */ }
            }
            copy.windows[i].metadata = m
        }
        copy.native?.accessibility = confirmed ? .partial : .denied
        return copy
    }

    func snapshotForGroups(_ raw: DesktopSnapshot) -> DesktopSnapshot {
        guard let groupProjection, groupProjection.sessionID == raw.sessionID,
              groupProjection.revision == raw.revision else { return raw }
        return groupProjection
    }

    private func watchSystem() {
        guard watchers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        watchers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.witness?.cancelArrivals(unlessFocusedPID: pid) }
        }))
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            watchers.append((workspace,workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.freeze() }
            }))
        }
        watchers.append((workspace,workspace.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid, self?.witness?.contains(pid:pid) == true { self?.freeze() } }
        }))
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            watchers.append((workspace,workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsReassessment = true
                    self?.feed?.changed()
                }
            }))
        }
        let app = NotificationCenter.default
        let observer = app.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.freeze(); self?.needsReassessment = true; self?.feed?.changed() }
        }
        watchers.append((app,observer))
    }

    private func stopWatching() {
        for (center,observer) in watchers { center.removeObserver(observer) }
        watchers.removeAll()
    }

    var holdsDispatch: Bool { terminationOwnsLane || unreadableLedger || releasing || engine?.holdsWindowDispatch == true }
    var routesGroupChoice: Bool { !admissions.isEmpty || holdsDispatch }

    func answerConsent(allow: Bool) {
        if allow { granted = consentRequest }
        consentRequest = nil
    }

    func freeze() {
        groupProjection = nil
        witness?.cancelArrivals()
        consentRequest = nil
        granted = nil
        heldGroups = []
        heldRefresh?.cancel()
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
        _ = beginRelease()
    }

    private func beginRelease() -> Task<Void,Never>? {
        if let releaseTask { return releaseTask }
        guard let engine, engine.holdsWindowDispatch else { return nil }
        witness?.cancelArrivals()
        releaseInput = NativeSelectionPermit.inputCounters()
        let pending = Task { [weak self] in
            defer {
                self?.releaseTask = nil; self?.releaseInput = nil
                if engine.session == nil {
                    if Self.shipped.isEmpty { self?.stopWatching() }
                    self?.heldGroups = []
                }
            }
            do { try await engine.release() } catch { /* Retain the prior worker and unresolved WAL. */ }
        }
        releaseTask = pending
        return pending
    }

    func release() async { await beginRelease()?.value }

    func prepareForShutdown() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        guard !unreadableLedger else { return false }
        guard holdsDispatch else { return true }
        terminationOwnsLane = true
        let drain = Task { [weak self] in
            guard let self else { return false }
            await self.release()
            return !unreadableLedger && engine?.holdsWindowDispatch != true
        }
        shutdownTask = drain
        return await drain.value
    }

    func groupChoice(_ group: UUID, member: NativeSidebarMember, in feed: CurrentDesktopWindows,
                     snapshot raw: DesktopSnapshot, current: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard routesGroupChoice else { return false }
        let snapshot = snapshotForGroups(raw)
        await heldRefresh?.value
        guard !unreadableLedger, !releasing, !terminationOwnsLane, let engine, let window = feed.groupWindow(member,in:snapshot),
              let space = window.nativeSpace, let saved = feed.groups.groups(in:.init(display:window.display,nativeSpace:space))
                .first(where: { $0.id == group })?.members.first(where: { $0.windowHint == window.identity })
        else { throw StageSwitchError.recoveryRequired }
        let scope = StageGroupScope(display:window.display,nativeSpace:space)
        guard let env = StageWindowEngineAttestation.installedEnvironment(snapshot),
              let selected = StageEngineQualification.choose(admissions,in:env,retaining:engine.session?.owner.backend) else {
            if engine.holdsWindowDispatch { await release(); throw StageSwitchError.unavailable }
            return false
        }
        if let witness, !witness.matches(scope) { await release(); throw StageSwitchError.interrupted }
        let token = revision
        let environmentCurrent: @MainActor () -> Bool = { [weak self] in
            self?.revision == token && self?.management?.permitsStageEngine(on:member.source.display) == true
        }
        let permitted: @MainActor () -> Bool = { [weak self,weak feed] in
            self != nil && feed?.lifetime(of:member.key) == window.lifetime && current() && environmentCurrent()
        }
        guard permitted() else { throw StageSwitchError.busy }
        let directory = feed.groups.groups(in:scope)
        var lifetimes = [NativeSpaceWindow:UUID]()
        for m in directory.flatMap(\.members) {
            let k = DesktopWindowKey(pid:m.windowHint.pid,birth:m.windowHint.birth,number:m.windowHint.number)
            guard let life = witness?.lifetime(of:m.windowHint) ?? feed.lifetime(of:k) else { throw StageSwitchError.incomplete }
            lifetimes[m.windowHint] = life
        }
        let approval = Consent(scope:scope,evidence:selected.evidence,groups:
            Dictionary(uniqueKeysWithValues:directory.map { ($0.id,$0.members.map(\.id)) }),lifetimes:lifetimes)
        if granted != approval {
            guard !engine.holdsWindowDispatch else { await release(); throw StageSwitchError.recoveryRequired }
            consentRequest = approval
            return true
        }
        let available = try await engine.configure(for:env,records:admissions,exclusive:permitted) { q in
            guard q == selected else { return nil }
            let restore: @MainActor () -> Bool = { [weak self] in
                guard let self, self.management?.permitsStageEngine(on:member.source.display) == true else { return false }
                return self.releaseInput.map { $0 == NativeSelectionPermit.inputCounters() } != false
            }
            guard let witness = StageWindowEngineWitness(feed:feed,scope:scope,snapshot:snapshot,
                available:environmentCurrent,restoreAvailable:restore) else { return nil }
            self.witness = witness
            watchSystem()
            guard let profile else { return nil }
            return StageEngineSession(owner:.init(qualification:q,generation:witness.generation),witness:witness,profile:profile)
        }
        guard available, permitted() else { throw StageSwitchError.unavailable }
        do {
            try await engine.activate(group,member:saved.id,in:scope,consent:true,current:permitted)
            projectHeld(feed.groups,in:scope)
            await armArrivals(in: feed, revision: token)
            return true
        } catch {
            if engine.coordinator.requiresRecovery || engine.session?.qualifiedHiddenState == nil {
                recoveryRequested = true
                ordinaryContextObserved()
            }
            throw error
        }
    }
    private func projectHeld(_ store: StageGroupStore, in scope: StageGroupScope) {
        guard let engine, let session = engine.session, session.qualifiedHiddenState != nil, let witness,
              witness.matches(scope) else { heldGroups = []; return }
        let next = store.groups(in:scope).compactMap { g -> HeldGroup? in
            guard g.verifiedActive != true, g.needsReorganization != true,
                  g.members.allSatisfy({ m in
                      guard let s = witness.state(of:m.windowHint) else { return false }
                      return engine.coordinator.confirmsHidden(group:g.id,member:m.id,state:s,scope:scope,owner:session.owner)
                  }), let target = g.members.first(where:{ $0.id == g.selectedMember }) ?? g.members.first,
                  let state = witness.state(of:target.windowHint) else { return nil }
            return .init(id:g.id,member:target.id,scope:scope,state:state,owner:session.owner,count:g.members.count)
        }
        lastVerifiedAt = ProcessInfo.processInfo.systemUptime
        if heldGroups != next { heldGroups = next }
    }

    func refreshHeld(feed: CurrentDesktopWindows) {
        guard let witness, heldRefresh == nil, engine?.canObserve == true, let session = engine?.session,
              ProcessInfo.processInfo.systemUptime - lastVerifiedAt > 0.75 else { return }
        let token = revision, scope = witness.scope
        heldRefresh = Task { [weak self,weak feed] in
            guard let self, let feed else { return }
            defer { heldRefresh = nil }
            do {
                try await session.checkHealth()
                do {
                    _ = try await session.read(scope)
                } catch let failure as StageSwitchError where failure == .interrupted || failure == .incomplete {
                    // A newly visible window can reach the desktop reader before its independent AX
                    // creation notification. Only an original event and two complete reads may admit it.
                    let recorded = try await witness.consumeArrival(in: feed.groups, owner: session.owner) { [weak self] in
                        self?.canObserveArrivals(session, revision: token) == true
                    }
                    guard recorded else { throw failure }
                    _ = try await session.read(scope)
                }
                guard !Task.isCancelled, token == revision, self.engine?.session === session else { return }
                projectHeld(feed.groups,in:scope)
                await armArrivals(in: feed, revision: token)
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                freeze()
                ordinaryContextObserved()
            }
        }
    }

    private func canObserveArrivals(_ session: StageEngineSession, revision token: UInt64) -> Bool {
        !Task.isCancelled && !releasing && !terminationOwnsLane && revision == token &&
            engine?.session === session && engine?.canObserve == true &&
            granted?.scope == witness?.scope && granted?.evidence == session.owner.evidence
    }

    private func armArrivals(in feed: CurrentDesktopWindows, revision token: UInt64) async {
        guard let session = engine?.session, let granted, let witness else { return }
        await witness.armArrivals(in: feed.groups, authorized: granted.lifetimes) { [weak self] in
            self?.canObserveArrivals(session, revision: token) == true
        }
    }

    /// The row represents an explicitly owned, independently read group. Its pixel stream and drag source
    /// remain absent while hidden. Recheck the whole roster before the existing coordinator can dispatch.
    func chooseHeld(_ held: HeldGroup, in feed: CurrentDesktopWindows, current: @escaping @MainActor () -> Bool) async throws {
        await heldRefresh?.value
        guard !releasing, !terminationOwnsLane, let engine, let session = engine.session, session.owner == held.owner,
              heldGroups.contains(held), let granted, granted.scope == held.scope, granted.evidence == held.owner.evidence,
              current(), witness?.matches(held.scope) == true else { throw StageSwitchError.interrupted }
        let groups = feed.groups.groups(in: held.scope)
        guard granted.groups == Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members.map(\.id)) }) else {
            throw StageSwitchError.ownership
        }
        let token = revision
        let observed = try await session.read(held.scope)
        guard current(), observed.windows[held.state.window] == held.state,
              engine.coordinator.confirmsHidden(group:held.id,member:held.member,state:held.state,scope:held.scope,owner:held.owner) else {
            freeze(); throw StageSwitchError.ownership
        }
        do {
            try await engine.activate(held.id,member:held.member,in:held.scope,consent:true,current:current)
            projectHeld(feed.groups,in:held.scope)
            await armArrivals(in: feed, revision: token)
        } catch {
            freeze(); ordinaryContextObserved()
            throw error
        }
    }

}
