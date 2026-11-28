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
    private let candidateMode = IndependentStagePolicy.candidateHasScope
    private let candidateEvidence = UUID()
    @ObservationIgnored private var groupProjection: DesktopSnapshot?
    private(set) var observedCapability: StageWindowBackend?
    private var needsReassessment = true
    private var lastEnvironmentalRead: TimeInterval = 0
    private weak var feed: CurrentDesktopWindows?
    struct HeldGroup: Equatable, Identifiable {
        let id, member: UUID, scope: StageGroupScope, state: StageWindowState, owner: StageEngineOwner, count: Int
        let departure: StageGroupDeparture?

        func memberIdentity(_ stamp: StageGroupDeparture.Stamp?) -> (member: UUID, window: NativeSpaceWindow, lifetime: UUID)? {
            guard let stamp else { return (member, state.window, state.lifetime) }
            guard let departure, departure.group == id, departure.scope == scope, departure.generation == owner.generation,
                  let selected = departure.members.first(where: { $0.id == stamp.member }), departure.stamp(for: selected) == stamp
            else { return nil }
            return (selected.id, selected.before.window, selected.before.lifetime)
        }
    }
    /// This records which original member the user clicked. Only the later
    /// chooseHeld read and coordinator can authorize its restoration.
    struct OwnedMemberSelection: Equatable {
        let owner: StageEngineOwner, session: ObjectIdentifier, revision: UInt64
        let group: UUID, member: UUID, members: [UUID: NativeSpaceWindow]
        let identity: StageWindowEngineWitness.RetainedMemberIdentity

        func capturesWholeGroup(_ states: [StageWindowState], claimed: Set<NativeSpaceWindow>) -> Bool {
            guard states.count == members.count, Set(states.map(\.window)) == Set(members.values),
                  states.contains(where: { $0.window == identity.window && $0.lifetime == identity.lifetime && $0.visibility == .stageSpace })
            else { return false }
            return states.allSatisfy { state in
                if state.visibility == .stageSpace {
                    return claimed.contains(state.window) && (state.hiddenSpaceID ?? 0) > 0 && state.hiddenSpaceID != identity.home
                }
                return state.visibility == .minimized && state.hiddenSpaceID == nil && !claimed.contains(state.window)
            }
        }

        func parkedState(in observed: StageWindowSample, held: HeldGroup, current: OwnedMemberSelection?) -> StageWindowState? {
            guard current == self, held.id == group, held.owner == owner, held.scope == identity.scope,
                  members[member] == identity.window, owner.generation == identity.generation,
                  observed.scope == identity.scope, observed.generation == identity.generation,
                  observed.nativeID == identity.home, let state = observed.windows[identity.window],
                  state.window == identity.window, state.lifetime == identity.lifetime,
                  state.visibility == .stageSpace, let hidden = state.hiddenSpaceID,
                  hidden > 0, hidden != identity.home else { return nil }
            return state
        }
    }
    private(set) var heldGroups = [HeldGroup]()
    private var heldSuccessor: (token: UUID, card: HeldGroup)?
    @ObservationIgnored private var heldRefresh: Task<Void,Never>?
    private var lastVerifiedAt: TimeInterval = 0
    @ObservationIgnored private var watchers = [(NotificationCenter,NSObjectProtocol)]()
    private(set) var consentRequest: Consent?
    private var granted: Consent?
    private weak var witness: StageWindowEngineWitness?
    @ObservationIgnored private var returnedWitnesses = [StageGroupScope: StageWindowEngineWitness]()
    private var releaseInput: [UInt32]?
    private let unreadableLedger: Bool
    weak var management: CandidateWorkRect?
    @ObservationIgnored private var shutdownTask: Task<Bool,Never>?
    private var terminationOwnsLane = false
    private var releaseTask: Task<Void,Never>?
    private var releasing: Bool { releaseTask != nil }
    private var recoveryRequested = false
    private var resumeScopes = Set<StageGroupScope>()
    private var resumeEnqueued = false
    private var lastResumeAttempt: TimeInterval = 0
    private enum WallpaperState: Equatable { case ordinary, showing, returning }
    private var wallpaperState = WallpaperState.ordinary
    var wallpaperPaused: Bool { wallpaperState != .ordinary }
    private var wallpaperReturnedWithoutFocus = false
    private var revision: UInt64 = 0
    @ObservationIgnored private let minimizeObserver = IndependentStageMinimizeObserver()
    @ObservationIgnored private var minimizeTask: Task<Void, Never>?
    private var pendingMinimized = [DesktopWindowKey]()
    @ObservationIgnored private var coldReturnTask: Task<Void, Never>?
    private var coldReturnPending = false
    private var lastColdReturnAttempt: TimeInterval = 0

    init(profile: URL?, store: StageGroupStore) {
        self.profile = profile
        admissions = profile.map { folder in Self.shipped.compactMap { StageWindowEngineAttestation.read($0,profile:folder) } } ?? []
        if let profile {
            do {
                let journal = try StageGroupCoordinator(store:store,profile:profile)
                try journal.finishExitedGuardianReturn { CornerExitedReturnReceipt.confirmed($0, in: profile) }
                try journal.withdrawVerifiedActivity()
                engine = StageWindowEngineController(coordinator:journal)
                coldReturnPending = journal.retainedOwner?.backend == .spaces
                unreadableLedger = false
            } catch { engine = nil; unreadableLedger = true }
        } else { engine = nil; unreadableLedger = false }
    }

    func attach(to feed: CurrentDesktopWindows) {
        self.feed = feed
        if candidateMode || !Self.shipped.isEmpty || holdsDispatch { watchSystem() }
        if coldReturnPending { feed.observeStageOwnership(true); reconcileColdSpacesOwner() }
    }

    /// The original pipe worker has already restored its retained objects. A new
    /// Host only observes the terminal and current physical state; it never sends
    /// the old WAL to a replacement worker or restores from saved numeric hints.
    private func reconcileColdSpacesOwner() {
        let now = ProcessInfo.processInfo.systemUptime
        guard coldReturnPending, coldReturnTask == nil, !releasing, !terminationOwnsLane,
              now - lastColdReturnAttempt >= 1, let profile, let engine, engine.session == nil else { return }
        lastColdReturnAttempt = now
        coldReturnTask = Task { [weak self] in
            defer { self?.coldReturnTask = nil }
            do {
                guard let plan = try engine.coordinator.coldSpacesReturn() else {
                    self?.coldReturnPending = false; self?.updateReleasedObservation(); return
                }
                guard let completion = SpacesWorkerLifecycle.completed(owner: plan.owner, profile: profile) else {
                    SpacesWorkerLifecycle.trace("cold-return-awaits-original-worker"); return
                }
                let returned: Bool
                if completion.previousBoot { returned = true }
                else { returned = await StageHostAccess.confirmsColdSpacesReturn(plan.windows, hiddenSpaces: plan.hiddenSpaces) }
                guard returned, !Task.isCancelled, let self, !self.terminationOwnsLane, !self.releasing,
                      engine.session == nil,
                      SpacesWorkerLifecycle.completed(owner: plan.owner, profile: profile) == completion else {
                    SpacesWorkerLifecycle.trace("cold-return-physical-read-unconfirmed"); return
                }
                try engine.coordinator.finishColdSpacesReturn(plan, workerFinished: true, physicalReturnConfirmed: true)
                self.coldReturnPending = false; self.recoveryRequested = false
                self.observedCapability = nil; self.needsReassessment = true
                self.updateReleasedObservation()
                self.feed?.changed()
                SpacesWorkerLifecycle.trace("cold-return-confirmed", ["previousBoot": completion.previousBoot,
                    "windows": plan.windows.count, "hiddenSpaces": plan.hiddenSpaces.count])
            } catch { SpacesWorkerLifecycle.trace("cold-return-rejected", ["error": String(describing: error)]) }
        }
    }

    /// Initial sample, wake/unlock and display notifications re-evaluate the installed environment.
    /// They never enroll a new writer or infer that a pre-restart AX reference survived.
    func observeEnvironment(_ snapshot: DesktopSnapshot?) {
        reconcileColdSpacesOwner()
        guard candidateMode || !Self.shipped.isEmpty, let profile else { return }
        if wallpaperPaused {
            // Incomplete/animated geometry is not a native desktop handoff. A
            // positively different current Space or native Stage Manager is.
            if snapshot?.native?.stageManagerEnabled == true {
                systemTakesOver()
            } else if let witness, let current = snapshot?.scopes.first(where: {
                $0.displayID == witness.scope.display.uuidString
            })?.records.first(where: \.isCurrent),
                current.nativeUUID != nil, current.ordinaryUUID != witness.scope.nativeSpace {
                systemTakesOver()
            } else { verifyWallpaperReturn() }
            return
        }
        // A reader failure or a different ordinary desktop revokes the current intent even
        // when a previous build/permission attestation is still within its two-second cache.
        guard let snapshot, snapshot.native?.stageManagerEnabled == false, snapshot.native?.catalogComplete == true,
              witness.map({ $0.homeCatalog(snapshot) != nil }) != false else {
            if !needsReassessment || granted != nil || consentRequest != nil || engine?.session?.isFrozen == false { systemTakesOver() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard needsReassessment || now-lastEnvironmentalRead >= 2 else { return }
        needsReassessment = false
        lastEnvironmentalRead = now
        let records = Self.shipped.compactMap { StageWindowEngineAttestation.read($0,profile:profile) }
        if admissions != records { witness?.cancelArrivals(); admissions = records; granted = nil; consentRequest = nil }
        let environment = StageWindowEngineAttestation.installedEnvironment(snapshot)
        let selected = environment.flatMap {
            engine?.preferredRecord(records, in: $0)
        }
        let candidateAvailable = candidateMode && environment?.permissions?.contains(.accessibility) == true
        observedCapability = candidateAvailable ? .spaces : selected?.backend
        guard let session = engine?.session, !session.isFrozen else { return }
        if session.qualifiedHiddenState == nil || (candidateMode ? !candidateAvailable : selected?.evidence != session.owner.evidence) { systemTakesOver() }
    }

    /// The directory can show positively identified ordinary windows even when every visibility provider is unsupported.
    func updateGroupProjection(_ raw: DesktopSnapshot, current: @MainActor () -> Bool) async {
        guard current(), !wallpaperPaused else { return }
        // A system takeover ends the writer, not the retained AX object's identity. Two
        // ordinary observations can reconnect its new sidebar appearance to its group.
        for returned in returnedWitnesses.values { returned.observeReturnedLifetimes(raw) }
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
        measure: @escaping @Sendable (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation?) async -> DesktopSnapshot? {
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
                guard !Task.isCancelled, current() else { return nil }
                let member = NativeSpaceWindow(pid: key.pid, birth: key.birth, number: key.number)
                let home = OrdinaryDesktopIdentity(display: w.displayID, record: record.id, uuid: uuid)
                // Yielding immediately before a synchronous AX read still runs that
                // read on MainActor. Keep the read sequential, but let the UI deliver
                // new input and fresh Dock observations while it is in flight.
                let (reading, elapsed) = await Task.detached(priority: .userInitiated) {
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = Result { try measure(member, home) }
                    return (result, ProcessInfo.processInfo.systemUptime - started)
                }.value
                remainingReadTime -= elapsed
                guard !Task.isCancelled, current() else { return nil }
                do {
                    if let s = try reading.get() {
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
                MainActor.assumeIsolated { self?.systemTakesOver() }
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
            MainActor.assumeIsolated { self?.systemTakesOver(); self?.needsReassessment = true; self?.feed?.changed() }
        }
        watchers.append((app,observer))
    }

    private func stopWatching() {
        minimizeObserver.stop()
        for (center,observer) in watchers { center.removeObserver(observer) }
        watchers.removeAll()
    }

    var holdsDispatch: Bool { terminationOwnsLane || unreadableLedger || releasing || engine?.holdsWindowDispatch == true }
    var routesGroupChoice: Bool { candidateMode || !admissions.isEmpty || holdsDispatch }

    func offersGroupSelection(on source: NativeSidebarDestination) -> Bool {
        guard source.kind == .ordinary, let display = UUID(uuidString: source.display) else { return false }
        return !wallpaperPaused && observedCapability != nil && !needsReassessment && !recoveryRequested && !unreadableLedger &&
            !releasing && !terminationOwnsLane && engine?.coordinator.requiresRecovery == false &&
            engine?.session?.isFrozen != true && (witness?.matches(.init(display: display, nativeSpace: source.uuid)) ?? true) &&
            management?.permitsStageEngine(on: source.display) == true
    }

    func observeDirectory(_ candidates: [StageGroupWindow], in store: StageGroupStore) throws {
        guard !wallpaperPaused else { return }
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
        if wallpaperPaused { if enrolled { recoveryRequested = true }; return }
        if enrolled { systemTakesOver(); await releaseTask?.value }
        let departed = try await StageWindowDeparture.exited(pid: pid, bound: feed.groups.boundWindows(of: pid))
        if try retire(departed, from: feed.groups) { feed.changed() }
        if enrolled { ordinaryContextObserved() }
    }

    /// Membership edits and ordinary tiling share the sidebar's serialized intent lane.
    func prepareForGroupEdit(current: @MainActor () -> Bool) async throws {
        guard current(), !wallpaperPaused, !unreadableLedger, !terminationOwnsLane, !releasing else { throw StageSwitchError.interrupted }
        granted = nil
        consentRequest = nil
        if holdsDispatch { await release() }
        guard !holdsDispatch else { throw StageSwitchError.recoveryRequired }
        guard current() else { throw StageSwitchError.interrupted }
        if let feed, !returnedWitnesses.isEmpty {
            guard await feed.readAfterAction() != nil, current(),
                  await feed.readAfterAction() != nil, current() else { throw StageSwitchError.interrupted }
            for returned in returnedWitnesses.values where returned.homeCatalog(feed.snapshot) != nil {
                guard returned.returnedMembersAreBound(in: feed) else { throw StageSwitchError.interrupted }
            }
        }
    }

    func prepareHeldGroupEdit(_ held: HeldGroup, in feed: CurrentDesktopWindows,
                              current: @escaping @MainActor () -> Bool) async throws -> DesktopSnapshot {
        guard current(), heldGroups.contains(held), engine?.session?.owner == held.owner,
              let witness, witness.matches(held.scope),
              engine?.coordinator.confirmsHidden(group: held.id, member: held.member, state: held.state,
                  scope: held.scope, owner: held.owner) == true else { throw StageSwitchError.ownership }
        try await prepareForGroupEdit(current: current)
        guard let fresh = await feed.readAfterAction(), current(), witness.homeCatalog(fresh) != nil else {
            throw StageSwitchError.interrupted
        }
        return snapshotForGroups(fresh)
    }

    func answerConsent(allow: Bool) {
        if allow { granted = consentRequest }
        consentRequest = nil
    }

    /// Show Desktop transforms the active windows but does not acquire our hidden
    /// groups. Keep their real leases while the native animation owns presentation.
    func setWallpaperHeld(_ held: Bool) {
        if held {
            guard wallpaperState != .showing else { return }
            wallpaperState = .showing
            wallpaperReturnedWithoutFocus = false
            if let witness, let feed, engine?.session?.owner.backend == .spaces,
               feed.groups.activeGroup(in: witness.scope) != nil { resumeScopes.insert(witness.scope) }
            minimizeObserver.stop()
            witness?.cancelArrivals()
            heldRefresh?.cancel()
        } else if wallpaperState == .showing {
            wallpaperState = .returning
            needsReassessment = true
            feed?.changed()
        }
    }

    private func verifyWallpaperReturn() {
        guard wallpaperState == .returning, !releasing, !terminationOwnsLane,
              heldRefresh == nil, minimizeTask == nil, let feed else { return }
        guard let engine, let session = engine.session, let witness else {
            wallpaperState = .ordinary
            feed.changed()
            return
        }
        guard management?.permitsStageEngine(on: witness.scope.display.uuidString) == true else { return }
        if recoveryRequested || session.isFrozen || engine.coordinator.requiresRecovery {
            systemTakesOver()
            return
        }
        guard engine.canObserve else { return }
        let token = revision, scope = witness.scope
        heldRefresh = Task { [weak self, weak feed] in
            guard let self, let feed else { return }
            defer { heldRefresh = nil }
            do {
                var previous: StageWindowSample?
                for _ in 0..<2 {
                    let sample = try await session.read(scope)
                    guard !Task.isCancelled, wallpaperState == .returning, token == revision,
                          engine.coordinator.observesActiveGroup(sample, owner: session.owner,
                              mayManage: session.mayManage, requiringActiveFocus: false),
                          previous.map({ $0.windows == sample.windows && $0.workArea == sample.workArea &&
                              $0.nativeID == sample.nativeID && $0.sequence < sample.sequence }) != false else {
                        throw StageSwitchError.incomplete
                    }
                    previous = sample
                }
                try await session.checkHealth()
                guard !Task.isCancelled, wallpaperState == .returning, token == revision else { return }
                wallpaperState = .ordinary
                needsReassessment = true
                observedCapability = nil
                wallpaperReturnedWithoutFocus = previous?.focus == nil
                resumeScopes.remove(scope)
                projectHeld(feed.groups, in: scope)
                await armArrivals(in: feed, revision: token)
                // A new published catalogue re-evaluates capability before any R4
                // selection is offered; keep the metadata loop even with panels hidden.
                feed.observeStageOwnership(true)
                feed.changed()
            } catch {
                guard !Task.isCancelled, wallpaperState == .returning, token == revision else { return }
                // An interrupted transaction or changed member requires the existing
                // real return/recovery path, after the native desktop has returned.
                systemTakesOver()
                feed.changed()
            }
        }
    }

    func freeze() {
        if wallpaperPaused {
            groupProjection = nil
            minimizeObserver.stop()
            witness?.cancelArrivals()
            heldRefresh?.cancel()
            return
        }
        heldSuccessor = nil
        needsReassessment = true
        observedCapability = nil
        groupProjection = nil
        feed?.stageGallery?.clearHeldPictures()
        minimizeObserver.stop()
        pendingMinimized.removeAll()
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

    func systemTakesOver() {
        wallpaperState = .ordinary
        wallpaperReturnedWithoutFocus = false
        if let witness, let feed, engine?.session?.owner.backend == .spaces,
           feed.groups.activeGroup(in: witness.scope) != nil { resumeScopes.insert(witness.scope) }
        freeze()
        if engine?.session?.owner.backend == .spaces { _ = beginRelease() }
    }

    /// A takeover revokes new actions immediately. Restore under the old worker only after its independent
    /// witness positively observes a safe context again. An uncertain issued restore remains in the WAL.
    func ordinaryContextObserved() {
        if wallpaperPaused { verifyWallpaperReturn(); return }
        if !holdsDispatch { resumeFocusedGroupIfNeeded(); return }
        guard recoveryRequested, !releasing, engine?.canAttemptOwnedRelease == true,
              witness?.homeCatalog(feed?.snapshot) != nil else { return }
        recoveryRequested = false
        _ = beginRelease()
    }

    /// Native overview and desktop navigation temporarily own the real windows. Once
    /// they finish, resume the group of the actually focused window through R4's same
    /// serialized action lane; a newer pointer/keyboard choice supersedes this work.
    private func resumeFocusedGroupIfNeeded() {
        let navigation = NativeSidebarNavigation.shared
        let now = ProcessInfo.processInfo.systemUptime
        guard !resumeEnqueued, !terminationOwnsLane, !resumeScopes.isEmpty,
              navigation.idleGeneration != nil, now - lastResumeAttempt >= 1,
              let feed, let snapshot = feed.snapshot else { return }
        let scopes = resumeScopes.filter { scope in
            management?.permitsStageEngine(on: scope.display.uuidString) == true &&
            returnedWitnesses[scope]?.homeCatalog(snapshot) != nil &&
            returnedWitnesses[scope]?.returnedMembersAreBound(in: feed) == true
        }
        guard !scopes.isEmpty else { return }
        lastResumeAttempt = now
        let input = NativeSelectionPermit.inputCounters(), version = revision, epoch = navigation.ownershipEpoch
        navigation.submit(stage: true, userActivity: false, needsInitialObservation: true) { [weak self, weak feed] token in
            guard let self, let feed else { return }
            self.resumeEnqueued = true
            defer { self.resumeEnqueued = false }
            let sameInput: @MainActor () -> Bool = { [weak self] in
                self?.revision == version && navigation.isCurrent(token) &&
                input == NativeSelectionPermit.inputCounters()
            }
            let measure = try StageHostAccess.directoryReader()
            // Several returned ordinary desktops can be visible on different displays.
            // Only the one with the independently confirmed focused window may resume.
            for scope in scopes {
                guard sameInput(), !self.holdsDispatch else { return }
                let current: @MainActor () -> Bool = { [weak self] in
                    sameInput() && self?.resumeScopes.contains(scope) == true &&
                    self?.management?.permitsStageEngine(on: scope.display.uuidString) == true
                }
                guard current(), let first = await feed.readAfterAction(), current(),
                      let catalog = NativeSpaceCatalog(self.snapshotForGroups(first), displayID: scope.display.uuidString,
                          now: .now, uptime: ProcessInfo.processInfo.systemUptime),
                      catalog.current.ordinaryUUID == scope.nativeSpace,
                      let row = catalog.rows.first(where: { $0.record.isCurrent }),
                      let source = NativeSidebarDestination(row, in: catalog) else { continue }
                if first.native?.catalogComplete == true {
                    navigation.completeInitialObservation(for: token, in: epoch)
                }
                let home = OrdinaryDesktopIdentity(display: source.display, record: source.space, uuid: source.uuid)
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                for window in row.windows where window.metadata?.pid == frontPID {
                    guard let member = NativeSidebarMember(window, source: source),
                          let grouped = feed.groupWindow(member, in: first),
                          let physical = try measure(grouped.identity, home), physical.focus == grouped.identity,
                          physical.onscreen, !physical.minimized,
                          let group = feed.groups.groups(in: scope).first(where: { $0.members.contains { $0.windowHint == grouped.identity } }),
                          let second = await feed.readAfterAction(), current(),
                          let stable = feed.groupWindow(member, in: second), stable.lifetime == grouped.lifetime,
                          let confirmed = try measure(grouped.identity, home), confirmed.focus == grouped.identity,
                          confirmed.onscreen, !confirmed.minimized, confirmed.frame == physical.frame else { continue }
                    do {
                        _ = try await self.groupChoice(group.id, member: member, selection: .member, in: feed,
                            snapshot: second, current: current,
                            successor: { navigation.queuedGroupChoice(after: token, in: navigation.ownershipEpoch) })
                    } catch {
                        // Cancellation can happen after configuring the worker but before
                        // its first journal entry. Return that idle owner as well, so a
                        // later settled input can retry. A queued R4 choice keeps its lane.
                        let inputChanged = input != NativeSelectionPermit.inputCounters() || !navigation.isCurrent(token)
                        if (error as? StageSwitchError) != .superseded,
                           self.engine?.session != nil, !self.releasing, !self.terminationOwnsLane {
                            self.systemTakesOver()
                        }
                        if inputChanged { return }
                        throw error
                    }
                    return
                }
            }
        }
    }

    private func updateReleasedObservation() {
        let waitingForResume = !resumeScopes.isEmpty
        if !waitingForResume && Self.shipped.isEmpty { stopWatching() }
        feed?.observeStageOwnership(waitingForResume)
    }

    private func beginRelease() -> Task<Void,Never>? {
        if let releaseTask { return releaseTask }
        guard let engine, engine.holdsWindowDispatch else { return nil }
        feed?.stageGallery?.clearHeldPictures()
        minimizeObserver.stop()
        pendingMinimized.removeAll()
        witness?.cancelArrivals()
        releaseInput = NativeSelectionPermit.inputCounters()
        let returning = witness
        let completeUserActivity = NativeSidebarNavigation.shared.retainRunningUserActivity()
        let pending = Task { [weak self] in
            defer {
                self?.releaseTask = nil; self?.releaseInput = nil
                if engine.session == nil {
                    self?.heldGroups = []
                    self?.updateReleasedObservation()
                }
                completeUserActivity?()
            }
            do {
                if engine.session?.owner.backend == .spaces { try await engine.handoffToSystem() }
                else { try await engine.release() }
                if engine.session == nil, let returning {
                    returning.endedOwnership()
                    self?.returnedWitnesses[returning.scope] = returning
                    self?.witness = nil
                    self?.recoveryRequested = false
                }
            } catch { self?.recoveryRequested = true /* Retain ownership until independent return is proved. */ }
        }
        releaseTask = pending
        return pending
    }

    func release() async {
        wallpaperState = .ordinary
        wallpaperReturnedWithoutFocus = false
        resumeScopes.removeAll()
        await beginRelease()?.value
        if !holdsDispatch { updateReleasedObservation() }
    }

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
        if coldReturnPending { reconcileColdSpacesOwner(); await coldReturnTask?.value }
        wallpaperState = .ordinary
        wallpaperReturnedWithoutFocus = false
        resumeScopes.removeAll()
        terminationOwnsLane = true
        guard !unreadableLedger else { return false }
        guard engine?.holdsWindowDispatch == true || releasing else {
            updateReleasedObservation()
            return true
        }
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
            guard !excluded.contains(key), !candidateMode || IndependentStagePolicy.candidateIncludes(key.pid) else { return nil }
            return witness?.lifetime(of: key) ?? feed.groupLifetime(of: .init(pid: key.pid, birth: key.birth, number: key.number))
        }
        let participants = feed.groups.participatingGroups(in: scope, lifetime: lifetime)
        var lifetimes = [NativeSpaceWindow: UUID]()
        for member in participants.flatMap(\.members) { lifetimes[member.windowHint] = lifetime(member.windowHint) }
        return Consent(scope: scope, evidence: evidence, groups: Dictionary(uniqueKeysWithValues:
            participants.map { ($0.id, $0.members.map(\.id)) }), lifetimes: lifetimes)
    }

    private func ownedMemberSelection(group: UUID, member: UUID, window: NativeSpaceWindow,
                                      in feed: CurrentDesktopWindows) -> OwnedMemberSelection? {
        guard self.feed === feed, !wallpaperPaused, !unreadableLedger, !releasing, !terminationOwnsLane,
              let engine, let session = engine.session, session.owner.backend == .spaces, !session.isFrozen, let witness,
              let identity = witness.retainedMemberIdentity(window, owner: session.owner),
              let granted, granted.scope == identity.scope, granted.evidence == session.owner.evidence,
              granted.groups[group]?.contains(member) == true, granted.lifetimes[window] == identity.lifetime,
              let saved = feed.groups.groups(in: identity.scope).first(where: { $0.id == group }),
              saved.needsReorganization != true,
              let selected = saved.members.first(where: { $0.id == member }), selected.windowHint == window,
              feed.groups.isBound(selected, to: identity.lifetime) else { return nil }
        return .init(owner: session.owner, session: ObjectIdentifier(session), revision: revision,
                     group: group, member: member,
                     members: Dictionary(uniqueKeysWithValues: saved.members.map { ($0.id, $0.windowHint) }), identity: identity)
    }

    func ownedMemberSelection(_ member: NativeSidebarMember, group: UUID, in snapshot: DesktopSnapshot,
                              feed: CurrentDesktopWindows) -> OwnedMemberSelection? {
        guard let location = member.location,
              let saved = feed.selectionGroup(member, in: snapshot), saved.id == group,
              let selected = saved.members.first(where: { $0.windowHint == location.window }),
              let stamp = ownedMemberSelection(group: group, member: selected.id, window: location.window, in: feed),
              member.source.session == stamp.identity.session, member.source.topology == stamp.identity.topology,
              location.display == stamp.identity.scope.display, location.spaceUUID == stamp.identity.scope.nativeSpace,
              UInt64(location.space) == stamp.identity.home,
              snapshot.windows.contains(where: { DesktopWindowKey($0) == member.key &&
                  (member.originalWindow == nil || $0.sidebarOriginalWindow == member.originalWindow) }), let witness else { return nil }
        let states = saved.members.compactMap { saved -> StageWindowState? in
            guard let state = witness.state(of: saved.windowHint), witness.mayManage(state),
                  feed.groups.isBound(saved, to: state.lifetime) else { return nil }
            return state
        }
        let claimed = Set(saved.members.map(\.windowHint).filter(witness.hasVisibilityClaim))
        guard stamp.capturesWholeGroup(states, claimed: claimed) else { return nil }
        return stamp
    }

    func ownedMemberSelectionIsCurrent(_ stamp: OwnedMemberSelection, in feed: CurrentDesktopWindows) -> Bool {
        ownedMemberSelection(group: stamp.group, member: stamp.member, window: stamp.identity.window, in: feed) == stamp
    }

    func chooseOwnedMember(_ stamp: OwnedMemberSelection, in feed: CurrentDesktopWindows, selectionToken: UUID,
                           current: @escaping @MainActor () -> Bool,
                           successor: @escaping @MainActor () -> UUID? = { nil },
                           initialObservationCompleted: @escaping @MainActor () -> Void = {}) async throws {
        var completed = false
        IndependentStageTrace.record("owned-member-selection-enter", ["window": stamp.identity.window.number,
            "group": stamp.group.uuidString, "member": stamp.member.uuidString, "hostRevision": stamp.revision])
        defer { IndependentStageTrace.record("owned-member-selection-exit", ["window": stamp.identity.window.number,
            "member": stamp.member.uuidString, "completed": completed]) }
        guard current(), ownedMemberSelectionIsCurrent(stamp, in: feed),
              let held = heldGroups.first(where: { $0.id == stamp.group && $0.scope == stamp.identity.scope && $0.owner == stamp.owner })
        else { throw StageSwitchError.interrupted }
        try await chooseHeld(held, member: nil, ownedSelection: stamp, in: feed, selectionToken: selectionToken,
            current: { current() && self.ownedMemberSelectionIsCurrent(stamp, in: feed) },
            successor: { self.ownedMemberSelectionIsCurrent(stamp, in: feed) ? successor() : nil },
            initialObservationCompleted: initialObservationCompleted)
        completed = true
    }

    func groupChoice(_ group: UUID, member: NativeSidebarMember, selection: StageSidebarSelection, in feed: CurrentDesktopWindows,
                     snapshot raw: DesktopSnapshot, current: @escaping @MainActor () -> Bool,
                     successor: @escaping @MainActor () -> UUID? = { nil }) async throws -> Bool {
        var phase = "entry", completed = false
        var permittedRejection: [String: Any]?
        SpacesWorkerLifecycle.trace("group-choice-entry", ["candidate": candidateMode, "routes": routesGroupChoice,
            "wallpaperPaused": wallpaperPaused, "unreadableLedger": unreadableLedger, "releasing": releasing,
            "terminating": terminationOwnsLane, "hasController": engine != nil])
        defer {
            var facts: [String: Any] = ["lastPhase": phase, "completed": completed]
            if !completed, let permittedRejection { facts["permittedRejection"] = permittedRejection }
            SpacesWorkerLifecycle.trace("group-choice-exit", facts)
        }
        heldSuccessor = nil
        guard !wallpaperPaused else { throw StageSwitchError.busy }
        guard routesGroupChoice else { return false }
        let snapshot = snapshotForGroups(raw)
        await heldRefresh?.value
        phase = "binding"
        func bindingRejected(_ reason: String, hasLiveWindow: Bool = false,
                             details: [String: Any] = [:]) -> StageSwitchError {
            var facts: [String: Any] = ["reason": reason, "hasLiveWindow": hasLiveWindow,
                                      "snapshotRevision": snapshot.revision]
            facts.merge(details, uniquingKeysWith: { _, observed in observed })
            SpacesWorkerLifecycle.trace("group-choice-binding-rejected", facts)
            return .recoveryRequired
        }
        guard !unreadableLedger else { throw bindingRejected("host/unreadable-ledger") }
        guard !releasing else { throw bindingRejected("host/releasing") }
        guard !terminationOwnsLane else { throw bindingRejected("host/terminating") }
        guard let engine else { throw bindingRejected("host/controller") }
        var windowRejection = [String: Any]()
        guard let window = feed.groupWindow(member, in: snapshot, rejected: { windowRejection = $0 }) else {
            // Use this exact failed read. Repeating groupWindow here would use a
            // later clock/projection and could contradict the rejected guard.
            throw bindingRejected("member/window", details: windowRejection)
        }
        guard let space = window.nativeSpace else { throw bindingRejected("member/ordinary-space", hasLiveWindow: true) }
        guard let saved = feed.groups.groups(in:.init(display:window.display,nativeSpace:space))
            .first(where: { $0.id == group })?.members.first(where: { $0.windowHint == window.identity }) else {
            throw bindingRejected("group/member", hasLiveWindow: true)
        }
        let scope = StageGroupScope(display:window.display,nativeSpace:space)
        // The live worker owns one certified home. A click on a different monitor must leave
        // that home intact until a worker can independently verify simultaneous display dispatch.
        if let witness, witness.scope.display != scope.display { throw StageSwitchError.busy }
        phase = "environment"
        guard let env = StageWindowEngineAttestation.installedEnvironment(snapshot) else {
            if engine.holdsWindowDispatch { await release(); throw StageSwitchError.unavailable }
            return false
        }
        let selected = engine.preferredRecord(admissions, in: env)
        guard candidateMode || selected != nil else { return false }
        let evidence = candidateMode ? candidateEvidence : selected!.evidence
        if let witness, !witness.matches(scope) { await release(); throw StageSwitchError.interrupted }
        let token = revision
        var environmentRejection: [String: Any]?
        let environmentCurrent: @MainActor () -> Bool = { [weak self] in
            environmentRejection = nil
            let observedRevision = self?.revision
            guard observedRevision == token else {
                environmentRejection = ["reason": "host-revision", "expectedRevision": token]
                if let observedRevision { environmentRejection?["observedRevision"] = observedRevision }
                return false
            }
            guard let management = self?.management else {
                environmentRejection = ["reason": "management-missing"]; return false
            }
            return management.permitsStageEngine(on: member.source.display) { reason, facts in
                environmentRejection = facts
                environmentRejection?["reason"] = "management/" + reason
            }
        }
        let permitted: @MainActor () -> Bool = { [weak self,weak feed] in
            permittedRejection = nil
            @MainActor func rejected(_ reason: String, _ facts: [String: Any] = [:]) -> Bool {
                var recorded = facts
                recorded["reason"] = reason
                recorded["phase"] = phase
                recorded["snapshotSession"] = snapshot.sessionID.uuidString
                recorded["snapshotRevision"] = snapshot.revision
                recorded["expectedHostRevision"] = token
                recorded["window"] = member.key.number
                permittedRejection = recorded
                return false
            }
            // Preserve the original short circuit. Record only the values this
            // permission attempt actually read, including its own environment
            // rejection before another availability check can replace it.
            let paused = self?.wallpaperPaused
            guard paused == false else {
                var facts: [String: Any] = ["hostPresent": paused != nil]
                if let paused { facts["wallpaperPaused"] = paused }
                return rejected("wallpaper-state", facts)
            }
            let lifetime = feed?.groupLifetime(of: member.key)
            guard lifetime == window.lifetime else {
                var facts: [String: Any] = ["expectedLifetime": window.lifetime.uuidString]
                if let lifetime { facts["observedLifetime"] = lifetime.uuidString }
                return rejected("member-lifetime", facts)
            }
            guard current() else { return rejected("current") }
            guard environmentCurrent() else {
                var facts: [String: Any] = [:]
                if let environmentRejection { facts["environmentRejection"] = environmentRejection }
                return rejected("environment", facts)
            }
            return true
        }
        phase = "current-intent"
        guard permitted() else { throw StageSwitchError.busy }
        let approval = try consent(for: scope, evidence: evidence, feed: feed)
        phase = "participants"
        SpacesWorkerLifecycle.trace("group-choice-participants", ["groups": approval.groups.count,
            "lifetimes": approval.lifetimes.count, "selectedMemberIncluded": approval.groups[group]?.contains(saved.id) == true])
        guard approval.groups[group]?.contains(saved.id) == true else { throw StageSwitchError.ownership }
        // Choosing a group is the explicit request to schedule its real windows.
        // The same already-qualified Spaces route must not ask for a second click
        // when the candidate is installed with a production attestation.
        if candidateMode || selected?.backend == .spaces { granted = approval }
        if granted != approval {
            guard !engine.holdsWindowDispatch else { await release(); throw StageSwitchError.recoveryRequired }
            consentRequest = approval
            return true
        }
        let make: (StageEngineEnvironment, StageEngineQualification?) -> StageEngineSession? = { [self] environment, qualification in
            SpacesWorkerLifecycle.trace("group-choice-make-enter")
            guard returnedWitnesses[scope]?.returnedMembersAreBound(in: feed) != false else {
                SpacesWorkerLifecycle.trace("group-choice-returned-binding-rejected"); return nil
            }
            var restoreRejection: [String: Any]?
            let restore: @MainActor () -> Bool = { [weak self] in
                restoreRejection = nil
                guard let self else { restoreRejection = ["reason": "host-missing"]; return false }
                guard let management = self.management else {
                    restoreRejection = ["reason": "management-missing"]; return false
                }
                guard management.permitsStageEngine(on: member.source.display, onRejection: { reason, facts in
                    restoreRejection = facts
                    restoreRejection?["reason"] = "management/" + reason
                }) else { return false }
                let unchangedInput = self.releaseInput.map { $0 == NativeSelectionPermit.inputCounters() } != false
                if !unchangedInput { restoreRejection = ["reason": "release-input"] }
                return unchangedInput
            }
            guard let witness = StageWindowEngineWitness(feed:feed,scope:scope,snapshot:snapshot,authorized:approval.lifetimes,
                initialSelectionCurrent: permitted,
                available:environmentCurrent,restoreAvailable:restore,
                availabilityRejection: { restoring in restoring ? restoreRejection : environmentRejection }) else {
                SpacesWorkerLifecycle.trace("group-choice-witness-rejected", ["lifetimes": approval.lifetimes.count]); return nil
            }
            self.witness = witness
            returnedWitnesses.removeValue(forKey: scope)
            watchSystem()
            guard let profile else { SpacesWorkerLifecycle.trace("group-choice-profile-missing"); return nil }
            let owner = qualification.map { StageEngineOwner(qualification: $0, generation: witness.generation) }
                ?? StageEngineOwner(spacesCandidate: environment, generation: witness.generation, evidence: evidence)
            let created = StageEngineSession(owner: owner, witness: witness, profile: profile) { [weak self] terminal in
                self?.guardianExited(releasing: terminal, owner: owner)
            }
            SpacesWorkerLifecycle.trace("group-choice-session-created", ["created": created != nil])
            return created
        }
        let available: Bool
        phase = "configure"
        if candidateMode {
            available = try await engine.configureSpacesCandidate(for: env, exclusive: permitted) { make($0, nil) }
        } else {
            available = try await engine.configure(for:env,records:admissions,exclusive:permitted) { q in
                q == selected ? make(env, q) : nil
            }
        }
        if engine.session != nil { feed.observeStageOwnership(true) }
        let currentAfterConfiguration = permitted()
        SpacesWorkerLifecycle.trace("group-choice-configured", ["available": available, "hasSession": engine.session != nil,
            "permitted": currentAfterConfiguration])
        guard available, currentAfterConfiguration else { throw StageSwitchError.unavailable }
        do {
            phase = "activate"
            witness?.preparePictures(leavingFor:group)
            defer { witness?.endPicturePreparation() }
            try await engine.activate(group,member:selection == .member ? saved.id : nil,in:scope,consent:true,current:permitted,
                                      newerChoice: { environmentCurrent() && successor() != nil })
            projectHeld(feed.groups,in:scope)
            await armArrivals(in: feed, revision: token)
            resumeScopes.remove(scope)
            completed = true
            return true
        } catch StageSwitchError.superseded {
            if let token = successor(), let card = heldGroups.first(where: { $0.id == group && $0.scope == scope }) {
                heldSuccessor = (token, card)
            }
            projectHeld(feed.groups, in: scope)
            throw StageSwitchError.superseded
        } catch {
            SpacesWorkerLifecycle.trace("group-choice-activation-error", ["error": String(describing: error)])
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
        if wallpaperPaused { verifyWallpaperReturn(); return }
        drainMinimized()
        // A selection reads its retained roster before controller.activate marks
        // the engine busy. Do not let a publisher start an idle verification in
        // that gap, or it can mistake the ensuing transaction for lost ownership.
        NativeSidebarNavigation.shared.whenIdle { beginHeldRefresh(feed: feed) }
    }

    private func beginHeldRefresh(feed: CurrentDesktopWindows) {
        guard minimizeTask == nil, let witness, heldRefresh == nil, let engine, engine.canObserve, let session = engine.session,
              engine.coordinator.retainedOwner == session.owner,
              ProcessInfo.processInfo.systemUptime - lastVerifiedAt > 0.75 else { return }
        let token = revision, scope = witness.scope
        heldRefresh = Task { [weak self,weak feed] in
            guard let self, let feed else { return }
            defer { heldRefresh = nil }
            do {
                do {
                    try await session.checkHealth()
                    let sample = try await session.read(scope)
                    guard engine.coordinator.observesActiveGroup(sample, owner: session.owner, mayManage: session.mayManage,
                        requiringActiveFocus: !(wallpaperReturnedWithoutFocus && sample.focus == nil)) else {
                        throw StageSwitchError.ownership
                    }
                    if sample.focus != nil { wallpaperReturnedWithoutFocus = false }
                } catch {
                    let failure = error
                    if let closed = try? await witness.closedWindows(), !closed.isEmpty, token == revision, !Task.isCancelled {
                        systemTakesOver()
                        await releaseTask?.value
                        _ = try retire(closed, from: feed.groups)
                        feed.changed()
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
                    // Recording a focused creation clears the old active-group marker.
                    // Keep this verified scope's resume intent before that marker is consulted.
                    resumeScopes.insert(scope)
                    systemTakesOver()
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
        !wallpaperPaused && !Task.isCancelled && !releasing && !terminationOwnsLane && revision == token &&
            engine?.session === session && engine?.canObserve == true &&
            granted?.scope == witness?.scope && granted?.evidence == session.owner.evidence
    }

    private func armArrivals(in feed: CurrentDesktopWindows, revision token: UInt64) async {
        guard !wallpaperPaused, let session = engine?.session, let granted, let witness else { return }
        if session.owner.backend == .spaces {
            let presented = granted.lifetimes.keys.filter {
                guard let state = witness.state(of: $0) else { return false }
                return state.visibility == .visible || state.visibility == .minimized
            }
            minimizeObserver.update(targets: presented.map { .init(pid:$0.pid,birth:$0.birth,number:$0.number) },
                minimized: { [weak self] key in self?.retireMinimized(key) }, changed: { [weak feed] in feed?.changed() })
        }
        await witness.armArrivals(in: feed.groups, authorized: granted.lifetimes) { [weak self] in
            self?.canObserveArrivals(session, revision: token) == true
        }
    }

    private func retireMinimized(_ key: DesktopWindowKey) {
        if !pendingMinimized.contains(key) { pendingMinimized.append(key) }
        drainMinimized()
    }

    private func drainMinimized() {
        guard !wallpaperPaused else { return }
        guard let key = pendingMinimized.first else { return }
        let window = NativeSpaceWindow(pid:key.pid, birth:key.birth, number:key.number)
        guard minimizeTask == nil, !releasing, !terminationOwnsLane, let engine, engine.canObserve, let session = engine.session,
              session.owner.backend == .spaces, let witness, let feed,
              granted?.lifetimes[window] == witness.lifetime(of:window) else { return }
        let token = revision, scope = witness.scope
        minimizeTask = Task { [weak self, weak feed] in
            guard let self, let feed else { return }
            defer { minimizeTask = nil; feed.changed() }
            await heldRefresh?.value
            guard revision == token, !releasing, !session.isFrozen else { return }
            do {
                try await engine.retireMinimized(window, in:scope) { [weak self] in
                    self?.revision == token && self?.releasing == false && self?.wallpaperPaused == false && !Task.isCancelled
                }
                pendingMinimized.removeAll { $0 == key }
                granted = try consent(for:scope, evidence:session.owner.evidence, feed:feed)
                projectHeld(feed.groups, in:scope)
                await armArrivals(in:feed, revision:token)
            } catch {
                recoveryRequested = engine.coordinator.requiresRecovery
                if recoveryRequested && !wallpaperPaused { systemTakesOver() }
                else if (error as? StageSwitchError) != .busy { pendingMinimized.removeAll { $0 == key } }
            }
        }
    }

    /// The row represents an explicitly owned, independently read group. Its pixel stream and drag source
    /// remain absent while hidden. Recheck the whole roster before the existing coordinator can dispatch.
    func chooseHeld(_ held: HeldGroup, member stamp: StageGroupDeparture.Stamp?, ownedSelection: OwnedMemberSelection? = nil,
                    in feed: CurrentDesktopWindows, selectionToken: UUID,
                    current: @escaping @MainActor () -> Bool,
                    successor: @escaping @MainActor () -> UUID? = { nil },
                    initialObservationCompleted: @escaping @MainActor () -> Void = {}) async throws {
        guard !wallpaperPaused else { throw StageSwitchError.busy }
        let continuing = heldSuccessor?.token == selectionToken && heldSuccessor?.card == held
        heldSuccessor = nil
        await heldRefresh?.value
        guard !releasing, !terminationOwnsLane, let engine, let session = engine.session, session.owner == held.owner,
              heldGroups.contains(held) || continuing, let granted, granted.scope == held.scope, granted.evidence == held.owner.evidence,
              let witness, witness.matches(held.scope) else { throw StageSwitchError.interrupted }
        func checkSelection() throws {
            if current() { return }
            if let next = successor() {
                if continuing { heldSuccessor = (next, held) }
                throw StageSwitchError.superseded
            }
            throw StageSwitchError.interrupted
        }
        try checkSelection()
        guard try granted == consent(for: held.scope, evidence: held.owner.evidence, feed: feed) else {
            throw StageSwitchError.ownership
        }
        let token = revision
        let observed = try await session.read(held.scope)
        guard revision == token, engine.session === session, !releasing, !terminationOwnsLane else {
            throw StageSwitchError.interrupted
        }
        try checkSelection()
        initialObservationCompleted()
        let choice: (member: UUID, window: NativeSpaceWindow, lifetime: UUID)
        if let ownedSelection {
            guard stamp == nil, ownedMemberSelectionIsCurrent(ownedSelection, in: feed),
                  ownedSelection.group == held.id, ownedSelection.owner == held.owner,
                  ownedSelection.identity.scope == held.scope else { throw StageSwitchError.interrupted }
            choice = (ownedSelection.member, ownedSelection.identity.window, ownedSelection.identity.lifetime)
        } else {
            guard let selected = held.memberIdentity(stamp) else { throw StageSwitchError.interrupted }
            choice = selected
        }
        let stillParked = heldGroups.contains(held)
        if stillParked {
            let parked: StageWindowState
            if let ownedSelection {
                let current = self.ownedMemberSelection(group: ownedSelection.group, member: ownedSelection.member,
                    window: ownedSelection.identity.window, in: feed)
                guard let state = ownedSelection.parkedState(in: observed, held: held, current: current) else { throw StageSwitchError.interrupted }
                parked = state
            } else if let stamp {
                guard let departure = held.departure, let (member, state) = departure.parkedMember(stamp, in: observed),
                      witness.confirmsHistoricalMember(member, of: departure, observed: observed) else { throw StageSwitchError.interrupted }
                parked = state
            } else { parked = held.state }
            guard observed.windows[parked.window] == parked,
                  engine.coordinator.confirmsHidden(group:held.id,member:choice.member,state:parked,scope:held.scope,owner:held.owner) else {
                freeze(); throw StageSwitchError.ownership
            }
        } else {
            guard continuing, engine.coordinator.confirmsYieldedHeldMember(group: held.id, member: choice.member, window: choice.window,
                lifetime: choice.lifetime, owner: held.owner, observed: observed) else { throw StageSwitchError.interrupted }
        }
        do {
            witness.preparePictures(leavingFor:held.id)
            defer { witness.endPicturePreparation() }
            try await engine.activate(held.id,member:choice.member,in:held.scope,consent:true,
                                      resumingFrom: stillParked ? nil : observed, current:current,
                                      newerChoice: { self.revision == token && successor() != nil })
            projectHeld(feed.groups,in:held.scope)
            await armArrivals(in: feed, revision: token)
        } catch StageSwitchError.superseded {
            if let next = successor() { heldSuccessor = (next, held) }
            projectHeld(feed.groups, in: held.scope)
            throw StageSwitchError.superseded
        } catch {
            freeze(); ordinaryContextObserved()
            throw error
        }
    }

}
