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
        let departure: StageGroupDeparture?
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
                try journal.finishExitedGuardianReturn { CornerExitedReturnReceipt.confirmed($0, in: profile) }
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
    func observeEnvironment(_ snapshot: DesktopSnapshot?) {
        guard !Self.shipped.isEmpty, let profile else { return }
        // A reader failure or a different ordinary desktop revokes the current intent even
        // when a previous build/permission attestation is still within its two-second cache.
        guard let snapshot, snapshot.native?.stageManagerEnabled == false, snapshot.native?.catalogComplete == true,
              witness.map({ $0.homeCatalog(snapshot) != nil }) != false else {
            if !needsReassessment || granted != nil || consentRequest != nil || engine?.session?.isFrozen == false { freeze() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard needsReassessment || now-lastEnvironmentalRead >= 2 else { return }
        needsReassessment = false
        lastEnvironmentalRead = now
        let records = Self.shipped.compactMap { StageWindowEngineAttestation.read($0,profile:profile) }
        if admissions != records { witness?.cancelArrivals(); admissions = records; granted = nil; consentRequest = nil }
        let selected = StageWindowEngineAttestation.installedEnvironment(snapshot).flatMap {
            engine?.preferredRecord(records, in: $0)
        }
        observedCapability = selected?.backend
        guard let session = engine?.session, !session.isFrozen else { return }
        if session.qualifiedHiddenState == nil || selected?.evidence != session.owner.evidence { freeze() }
    }

    /// The directory can show positively identified ordinary windows even when every visibility provider is unsupported.
    func updateGroupProjection(_ raw: DesktopSnapshot, current: @MainActor () -> Bool) async {
        guard current() else { return }
        groupProjection = nil
        guard Self.needsDirectoryRead(raw), let measure = try? StageHostAccess.directoryReader() else { return }
        let projection = await Self.projectGroups(raw, current: current, measure: measure)
        if current() { groupProjection = projection }
    }

    static func needsDirectoryRead(_ raw: DesktopSnapshot) -> Bool {
        guard raw.native?.population == .workWindows, raw.native?.catalogComplete == true,
              raw.native?.stageManagerEnabled == false, raw.native?.windowLimitReached == false else { return false }
        return raw.windows.contains { window in
            guard let m = window.metadata, m.isOnscreen == true, m.fullScreen != true, m.minimized != true,
                  let home = raw.scopes.first(where: { $0.displayID == window.displayID })?.records.first(where: \.isCurrent),
                  home.ordinaryUUID != nil, window.membership == .known(recordIDs: [home.id]),
                  DesktopWindowKey(window) != nil else { return false }
            return raw.native?.accessibility == .denied || (m.overviewOrdinaryRole != false && (m.overviewOrdinaryRole == nil || m.minimized == nil))
        }
    }

    static func projectGroups(_ raw: DesktopSnapshot, current: @MainActor () -> Bool = { true },
        measure: (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation?) async -> DesktopSnapshot? {
        guard needsDirectoryRead(raw) else { return nil }
        // Charge time spent querying AX. Time yielded to the UI cannot exhaust the remaining rows.
        var remainingReadTime: TimeInterval = 1
        var copy = raw, confirmed = false
        for i in raw.windows.indices {
            let w = raw.windows[i]
            guard let record = raw.scopes.first(where: { $0.displayID == w.displayID })?.records.first(where: \.isCurrent),
                  let uuid = record.ordinaryUUID, w.membership == .known(recordIDs: [record.id]),
                  let key = DesktopWindowKey(w), var m = w.metadata else { continue }
            // Preserve observations made by an independently authorized reader.
            if raw.native?.accessibility != .denied && (m.overviewOrdinaryRole == false || (m.overviewOrdinaryRole == true && m.minimized != nil)) { continue }
            // With a denied reader, clear all its role fields before upgrading the projection to partial.
            let visibleCandidate = m.isOnscreen == true && m.fullScreen != true && m.minimized != true
            m.overviewOrdinaryRole = nil
            m.minimized = nil
            if visibleCandidate && remainingReadTime > 0 {
                await Task.yield()
                guard !Task.isCancelled, current() else { return nil }
                let started = ProcessInfo.processInfo.systemUptime
                defer { remainingReadTime -= ProcessInfo.processInfo.systemUptime - started }
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
        guard confirmed || raw.native?.accessibility == .denied else { return nil }
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
            MainActor.assumeIsolated {
                self?.witness?.cancelArrivals(unlessFocusedPID: pid)
                self?.feed?.changed()
            }
        }))
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            watchers.append((workspace,workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.freeze() }
            }))
        }
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

    func offersGroupSelection(on source: NativeSidebarDestination) -> Bool {
        guard source.kind == .ordinary, let display = UUID(uuidString: source.display) else { return false }
        return observedCapability != nil && !needsReassessment && !recoveryRequested && !unreadableLedger &&
            !releasing && !terminationOwnsLane && engine?.coordinator.requiresRecovery == false &&
            engine?.session?.isFrozen != true && (witness?.matches(.init(display: display, nativeSpace: source.uuid)) ?? true) &&
            management?.permitsStageEngine(on: source.display) == true
    }

    func observeDirectory(_ candidates: [StageGroupWindow], in store: StageGroupStore) throws {
        if !holdsDispatch { try store.observe(candidates) }
        else if let scope = witness?.scope { try store.observe(candidates, preserving: scope.display) }
    }

    private func retire(_ departures: [StageWindowDeparture], from store: StageGroupStore) throws -> Bool {
        guard !departures.isEmpty, !unreadableLedger, !releasing, !terminationOwnsLane else { return false }
        let retired = try store.retire(departures) { key in
            engine?.coordinator.permitsRetirement(of: key) != false && witness?.hasVisibilityClaim(key) != true
        }
        for item in departures where retired.contains(item.window) { witness?.discard(item) }
        return !retired.isEmpty
    }

    func processEnded(_ pid: Int32, in feed: CurrentDesktopWindows) async throws {
        let enrolled = witness?.contains(pid: pid) == true
        if enrolled { freeze() }
        let departed = try await StageWindowDeparture.exited(pid: pid, bound: feed.groups.boundWindows(of: pid))
        if try retire(departed, from: feed.groups) { feed.changed() }
        if enrolled { ordinaryContextObserved() }
    }

    /// Membership edits and ordinary tiling share the sidebar's serialized intent lane.
    func prepareForGroupEdit(current: @MainActor () -> Bool) async throws {
        guard current(), !unreadableLedger, !terminationOwnsLane, !releasing else { throw StageSwitchError.interrupted }
        granted = nil
        consentRequest = nil
        if holdsDispatch { await release() }
        guard !holdsDispatch else { throw StageSwitchError.recoveryRequired }
        guard current() else { throw StageSwitchError.interrupted }
    }

    func answerConsent(allow: Bool) {
        if allow { granted = consentRequest }
        consentRequest = nil
    }

    func freeze() {
        needsReassessment = true
        observedCapability = nil
        groupProjection = nil
        feed?.stageGallery?.clearHeldPictures()
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
        guard recoveryRequested, !releasing, engine?.canAttemptOwnedRelease == true,
              witness?.homeCatalog(feed?.snapshot) != nil else { return }
        recoveryRequested = false
        _ = beginRelease()
    }

    private func beginRelease() -> Task<Void,Never>? {
        if let releaseTask { return releaseTask }
        guard let engine, engine.holdsWindowDispatch else { return nil }
        feed?.stageGallery?.clearHeldPictures()
        witness?.cancelArrivals()
        releaseInput = NativeSelectionPermit.inputCounters()
        let pending = Task { [weak self] in
            defer {
                self?.releaseTask = nil; self?.releaseInput = nil
                if engine.session == nil {
                    if Self.shipped.isEmpty { self?.stopWatching() }
                    self?.heldGroups = []
                    self?.feed?.observeStageOwnership(false)
                }
            }
            do { try await engine.release() } catch { /* Retain the prior worker and unresolved WAL. */ }
        }
        releaseTask = pending
        return pending
    }

    func release() async { await beginRelease()?.value }

    private func guardianExited(releasing intent: UUID, owner: StageEngineOwner) {
        Task { [weak self] in
            await self?.releaseTask?.value
            guard let self, let engine, engine.session?.owner == owner,
                  engine.coordinator.awaitsFinalRelease(intent, from: owner), engine.canAttemptOwnedRelease,
                  witness?.homeCatalog(feed?.snapshot) != nil else { return }
            await release()
        }
    }

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

    private func consent(for scope: StageGroupScope, evidence: UUID, feed: CurrentDesktopWindows) throws -> Consent {
        guard let excluded = management?.ordinary.stageWindowExclusions else { throw StageSwitchError.busy }
        func lifetime(_ key: NativeSpaceWindow) -> UUID? {
            guard !excluded.contains(key) else { return nil }
            return witness?.lifetime(of: key) ?? feed.groupLifetime(of: .init(pid: key.pid, birth: key.birth, number: key.number))
        }
        let participants = feed.groups.participatingGroups(in: scope, lifetime: lifetime)
        var lifetimes = [NativeSpaceWindow: UUID]()
        for member in participants.flatMap(\.members) { lifetimes[member.windowHint] = lifetime(member.windowHint) }
        return Consent(scope: scope, evidence: evidence, groups: Dictionary(uniqueKeysWithValues:
            participants.map { ($0.id, $0.members.map(\.id)) }), lifetimes: lifetimes)
    }

    func groupChoice(_ group: UUID, member: NativeSidebarMember, selection: StageSidebarSelection, in feed: CurrentDesktopWindows,
                     snapshot raw: DesktopSnapshot, current: @escaping @MainActor () -> Bool,
                     newerChoice: @escaping @MainActor () -> Bool = { false }) async throws -> Bool {
        guard routesGroupChoice else { return false }
        let snapshot = snapshotForGroups(raw)
        await heldRefresh?.value
        guard !unreadableLedger, !releasing, !terminationOwnsLane, let engine, let window = feed.groupWindow(member,in:snapshot),
              let space = window.nativeSpace, let saved = feed.groups.groups(in:.init(display:window.display,nativeSpace:space))
                .first(where: { $0.id == group })?.members.first(where: { $0.windowHint == window.identity })
        else { throw StageSwitchError.recoveryRequired }
        let scope = StageGroupScope(display:window.display,nativeSpace:space)
        // The live worker owns one certified home. A click on a different monitor must leave
        // that home intact until a worker can independently verify simultaneous display dispatch.
        if let witness, witness.scope.display != scope.display { throw StageSwitchError.busy }
        guard let env = StageWindowEngineAttestation.installedEnvironment(snapshot),
              let selected = engine.preferredRecord(admissions, in: env) else {
            if engine.holdsWindowDispatch { await release(); throw StageSwitchError.unavailable }
            return false
        }
        if let witness, !witness.matches(scope) { await release(); throw StageSwitchError.interrupted }
        let token = revision
        let environmentCurrent: @MainActor () -> Bool = { [weak self] in
            self?.revision == token && self?.management?.permitsStageEngine(on:member.source.display) == true
        }
        let permitted: @MainActor () -> Bool = { [weak self,weak feed] in
            self != nil && feed?.groupLifetime(of:member.key) == window.lifetime && current() && environmentCurrent()
        }
        guard permitted() else { throw StageSwitchError.busy }
        let approval = try consent(for: scope, evidence: selected.evidence, feed: feed)
        guard approval.groups[group]?.contains(saved.id) == true else { throw StageSwitchError.ownership }
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
            guard let witness = StageWindowEngineWitness(feed:feed,scope:scope,snapshot:snapshot,authorized:approval.lifetimes,
                available:environmentCurrent,restoreAvailable:restore) else { return nil }
            self.witness = witness
            watchSystem()
            guard let profile else { return nil }
            let owner = StageEngineOwner(qualification: q, generation: witness.generation)
            return StageEngineSession(owner: owner, witness: witness, profile: profile) { [weak self] terminal in
                self?.guardianExited(releasing: terminal, owner: owner)
            }
        }
        if engine.session != nil { feed.observeStageOwnership(true) }
        guard available, permitted() else { throw StageSwitchError.unavailable }
        do {
            witness?.preparePictures(leavingFor:group)
            defer { witness?.endPicturePreparation() }
            try await engine.activate(group,member:selection == .member ? saved.id : nil,in:scope,consent:true,current:permitted,
                                      newerChoice: { environmentCurrent() && newerChoice() })
            projectHeld(feed.groups,in:scope)
            await armArrivals(in: feed, revision: token)
            return true
        } catch StageSwitchError.superseded {
            projectHeld(feed.groups, in: scope)
            throw StageSwitchError.superseded
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
            guard g.verifiedActive != true, g.needsReorganization != true else { return nil }
            let parked = g.members.filter { m in
                guard let s = witness.state(of:m.windowHint) else { return false }
                return engine.coordinator.confirmsHidden(group:g.id,member:m.id,state:s,scope:scope,owner:session.owner)
            }
            let parkedIDs = Set(parked.map(\.id))
            guard g.members.allSatisfy({ m in
                      if parkedIDs.contains(m.id) { return true }
                      guard let s = witness.state(of:m.windowHint), s.visibility == .minimized, s.hiddenSpaceID == nil,
                            witness.mayManage(s), !witness.hasVisibilityClaim(m.windowHint) else { return false }
                      return store.isBound(m, to:s.lifetime)
                  }), let target = g.focusMember(including: { parkedIDs.contains($0.id) }),
                  let state = witness.state(of:target.windowHint) else { return nil }
            let departure = witness.departures[g.id].flatMap { captured -> StageGroupDeparture? in
                guard captured.generation == session.owner.generation, captured.scope == scope,
                      Set(captured.members.map(\.id)) == parkedIDs,
                      captured.members.allSatisfy({ m in
                          g.members.contains { $0.id == m.id && $0.windowHint == m.before.window && $0.layout == m.layout } &&
                              witness.state(of:m.before.window)?.lifetime == m.before.lifetime
                      }) else { return nil }
                return captured
            }
            return .init(id:g.id,member:target.id,scope:scope,state:state,owner:session.owner,count:parked.count,departure:departure)
        }
        lastVerifiedAt = ProcessInfo.processInfo.systemUptime
        if heldGroups != next { heldGroups = next }
    }

    func confirmsPicture(_ member: StageGroupDeparture.Member, group: HeldGroup) -> Bool {
        guard let departure = group.departure, heldGroups.contains(group), !releasing, !terminationOwnsLane,
              let engine, engine.canObserve, engine.session?.owner == group.owner, granted?.scope == group.scope,
              let witness, let state = witness.state(of:member.before.window),
              engine.coordinator.confirmsHidden(group:group.id,member:member.id,state:state,scope:group.scope,owner:group.owner)
        else { return false }
        return witness.confirmsHistoricalMember(member, of:departure)
    }

    func refreshHeld(feed: CurrentDesktopWindows) {
        guard let witness, heldRefresh == nil, let engine, engine.canObserve, let session = engine.session,
              engine.coordinator.retainedOwner == session.owner,
              ProcessInfo.processInfo.systemUptime - lastVerifiedAt > 0.75 else { return }
        let token = revision, scope = witness.scope
        heldRefresh = Task { [weak self,weak feed] in
            guard let self, let feed else { return }
            defer { heldRefresh = nil }
            do {
                try await session.checkHealth()
                do {
                    let sample = try await session.read(scope)
                    guard engine.coordinator.observesActiveGroup(sample, owner: session.owner, mayManage: session.mayManage) else {
                        throw StageSwitchError.ownership
                    }
                } catch {
                    let failure = error
                    if let closed = try? await witness.closedWindows(), token == revision, !Task.isCancelled,
                       try retire(closed, from: feed.groups) {
                        freeze()
                        ordinaryContextObserved()
                        return
                    }
                    guard let source = failure as? StageSwitchError, source == .interrupted || source == .incomplete else {
                        throw failure
                    }
                    // A newly visible window can reach the desktop reader before its independent AX
                    // creation notification. Only an original event and two complete reads may admit it.
                    let recorded = try await witness.consumeArrival(in: feed.groups, owner: session.owner) { [weak self] in
                        self?.canObserveArrivals(session, revision: token) == true
                    }
                    guard recorded else { throw failure }
                    // A new singleton has no part in the current grant. Preserve the user's focus and
                    // return the confirmed hides to their owners before accepting a different roster.
                    freeze()
                    ordinaryContextObserved()
                    return
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
    func chooseHeld(_ held: HeldGroup, member stamp: StageGroupDeparture.Stamp?, in feed: CurrentDesktopWindows,
                    current: @escaping @MainActor () -> Bool,
                    newerChoice: @escaping @MainActor () -> Bool = { false }) async throws {
        await heldRefresh?.value
        guard !releasing, !terminationOwnsLane, let engine, let session = engine.session, session.owner == held.owner,
              heldGroups.contains(held), let granted, granted.scope == held.scope, granted.evidence == held.owner.evidence,
              current(), let witness, witness.matches(held.scope) else { throw StageSwitchError.interrupted }
        guard try granted == consent(for: held.scope, evidence: held.owner.evidence, feed: feed) else {
            throw StageSwitchError.ownership
        }
        let token = revision
        let observed = try await session.read(held.scope)
        if !current() && newerChoice() { throw StageSwitchError.superseded }
        guard revision == token, engine.session === session, heldGroups.contains(held), !releasing, !terminationOwnsLane else {
            throw StageSwitchError.interrupted
        }
        let selected: UUID, parked: StageWindowState
        if let stamp {
            guard let departure = held.departure, let (member, state) = departure.parkedMember(stamp, in: observed),
                  witness.confirmsHistoricalMember(member, of: departure) else { throw StageSwitchError.interrupted }
            selected = member.id
            parked = state
        } else {
            selected = held.member
            parked = held.state
        }
        guard current(), observed.windows[parked.window] == parked,
              engine.coordinator.confirmsHidden(group:held.id,member:selected,state:parked,scope:held.scope,owner:held.owner) else {
            freeze(); throw StageSwitchError.ownership
        }
        do {
            witness.preparePictures(leavingFor:held.id)
            defer { witness.endPicturePreparation() }
            try await engine.activate(held.id,member:selected,in:held.scope,consent:true,current:current,
                                      newerChoice: { self.revision == token && newerChoice() })
            projectHeld(feed.groups,in:held.scope)
            await armArrivals(in: feed, revision: token)
        } catch StageSwitchError.superseded {
            projectHeld(feed.groups, in: held.scope)
            throw StageSwitchError.superseded
        } catch {
            freeze(); ordinaryContextObserved()
            throw error
        }
    }

}
