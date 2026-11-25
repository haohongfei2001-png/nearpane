import AppKit
import NearpaneCore
import OSLog

/// One fast, metadata-only feed for all visible sidebar panels. The full reader
/// serves geometry and window management independently of the window switcher.
@MainActor @Observable final class CurrentDesktopWindows {
    typealias Read = NativeDesktopProvider.Read
    #if NEARPANE_P0_DIAGNOSTIC
    private let diagnosticLease = P0DiagnosticLease.installed()
    #endif
    private let read: Read
    private let sessionAvailable: @MainActor () -> Bool
    private let fingerprint: @MainActor () -> Int
    private let session = UUID()
    private(set) var revision: UInt64 = 0
    private(set) var snapshot: DesktopSnapshot?
    struct DepartingPictures {
        let snapshot: DesktopSnapshot
        let appearances: [DesktopWindowKey: UUID]
        let groups: [String: [NativeSpaceWindow: StageGroupDirectory.Group]]
        var cappedAppearance: UUID?

        mutating func retainAcrossCappedInventory(_ next: DesktopSnapshot) -> Bool {
            guard next.native?.windowLimitReached == true, snapshot.sessionID == next.sessionID,
                  snapshot.topologyConsistent, next.topologyConsistent,
                  snapshot.topologyFingerprint == next.topologyFingerprint, snapshot.separateSpaces == next.separateSpaces,
                  snapshot.native?.stageManagerEnabled == next.native?.stageManagerEnabled,
                  Set(snapshot.displays.map(\.id)) == Set(next.displays.map(\.id)) else { return false }
            let sameHomes = snapshot.displays.allSatisfy { display in
                func home(_ sample: DesktopSnapshot) -> SpaceRecord? {
                    let records = sample.scopes.filter { $0.displayID == display.id }.flatMap(\.records).filter(\.isCurrent)
                    return records.count == 1 ? records[0] : nil
                }
                guard let old = home(snapshot), let new = home(next), old.id == new.id,
                      old.ordinaryUUID != nil || old.fullscreenUUID != nil else { return false }
                return old.ordinaryUUID == new.ordinaryUUID && old.fullscreenUUID == new.fullscreenUUID
            }
            if sameHomes { cappedAppearance = UUID() }
            return sameHomes
        }
    }
    private(set) var departingPictures: DepartingPictures?

    private func holdDisplayedRoster() {
        guard departingPictures == nil, panelRequested, sessionAvailable(), let snapshot, snapshot.native?.windowLimitReached == false,
              snapshot.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return }
        let groups = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, visibleGroups(in: snapshot, on: $0)) })
        departingPictures = DepartingPictures(snapshot: snapshot, appearances: lifetimes, groups: groups)
    }

    func pictureAppearance(of key: DesktopWindowKey) -> UUID? {
        if let departingPictures {
            guard let prior = departingPictures.appearances[key] else { return nil }
            return departingPictures.cappedAppearance ?? prior
        }
        return lifetimes[key]
    }
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var stageLifetimes = StageGroupWindowLifetimes()
    @ObservationIgnored private var lifetimes = [DesktopWindowKey: UUID]() {
        didSet { stageLifetimes.prune(lifetimes) }
    }
    @ObservationIgnored weak var boundSidebarPair: BoundSidebarPair?
    @ObservationIgnored private var sidebarWindows = NativeSidebarWindowHistory()
    private let readSidebarWindows: NativeSidebarWindowHistory.Read?
    @ObservationIgnored let windowAudit = NativeSidebarWindowAudit()
    @ObservationIgnored private var pendingAudit: NativeSidebarWindowAudit.Sample?
    let groups: StageGroupStore
    let stageEngine: StageWindowEngineHost
    @ObservationIgnored weak var stageGallery: DesktopWindowGallery?
    private(set) var groupIssue: String?
    @ObservationIgnored var splitPresentationChanged: (() -> Void)?
    private(set) var pairedDisplays = Set<String>()
    @ObservationIgnored private var splitObservationAllowed = false
    @ObservationIgnored private var fullscreenHint = false
    @ObservationIgnored private var nativeFullscreenSeen = false
    @ObservationIgnored private var sampleNextSpace = false

    // A native fullscreen transition can withdraw every ordinary panel. Keep a
    // metadata-only lease long enough to recognize a pair without starting a capture.
    func configureSplitObservation(allowed: Bool, fullscreenHint: Bool) {
        guard allowed != splitObservationAllowed || fullscreenHint != self.fullscreenHint else { return }
        if allowed && !splitObservationAllowed { sampleNextSpace = true }
        splitObservationAllowed = allowed
        self.fullscreenHint = allowed && fullscreenHint
        if !allowed {
            sampleNextSpace = false
            nativeFullscreenSeen = false
            publishPairs([])
        }
        updateObservation()
    }

    private func publishPairs(_ displays: Set<String>) {
        guard displays != pairedDisplays else { return }
        pairedDisplays = displays
        Task { [weak self] in self?.splitPresentationChanged?() }
    }

    private func sampleSplitPresentation(_ snapshot: DesktopSnapshot?) {
        guard splitObservationAllowed else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let fresh = snapshot.flatMap { $0.nativeIsFresh(now: .now, uptime: uptime) ? $0 : nil }
        nativeFullscreenSeen = fresh?.scopes.contains { $0.records.contains { $0.isCurrent && $0.nativeKind == .fullscreen } } == true
        let pairs = fresh.map { value in
            Set(value.displays.compactMap { display in
                value.currentSplitView(on: display.id, now: .now, uptime: uptime) == nil ? nil : display.id
            })
        } ?? []
        publishPairs(pairs)
        sampleNextSpace = false
        if !observationRequested { updateObservation() }
    }

    func tracks(_ token: UUID, at location: NativeSidebarWindowLocation) -> Bool {
        panelRequested && sidebarWindows.tracks(token, at: location)
    }

    /// A member must still be on this physical display and its current ordinary desktop.
    private func groupWindow(_ window: WindowObservation, on screen: DisplayObservation,
                             current: SpaceRecord) -> StageGroupWindow? {
        guard let nativeSpace = current.ordinaryUUID, window.displayID == screen.id, let display = UUID(uuidString: screen.id),
              window.membership == .known(recordIDs: [current.id]), let m = window.metadata, m.isOnscreen == true,
              m.minimized != true, m.fullScreen != true, m.overviewOrdinaryRole != false, m.overviewOrdinaryRole == true || window.canWitnessCurrentSpace,
              let key = DesktopWindowKey(window), let lifetime = groupLifetime(of: key) else { return nil }
        let layout = screen.usable.flatMap { area in
            m.hasCatalogGeometry == true || m.presentation == .confirmed
                ? StageGroupWindow.relativeFrame(window.bounds, in: area) : nil
        }
        return .init(display: display, identity: .init(pid: key.pid, birth: key.birth, number: key.number),
                     lifetime: lifetime, layout: layout, nativeSpace: nativeSpace)
    }

    private func stageWindows(in snapshot: DesktopSnapshot, on screen: DisplayObservation) -> [StageGroupWindow] {
        guard snapshot.native?.stageManagerEnabled == false, snapshot.native?.windowLimitReached == false,
              let catalog = NativeSpaceCatalog(snapshot, displayID: screen.id, now: .now, uptime: ProcessInfo.processInfo.systemUptime),
              let row = catalog.rows.first(where: { $0.record.isCurrent && $0.record.ordinaryUUID != nil }) else { return [] }
        let observations = Dictionary(grouping: snapshot.windows.compactMap(DesktopWindowKey.init), by: { $0 })
        return ordered(row.windows).filter { w in
            guard let key = DesktopWindowKey(w), observations[key]?.count == 1 else { return false }
            return snapshot.isCurrentDesktopWindow(w)
        }.compactMap { groupWindow($0, on: screen, current: row.record) }
    }

    func groupWindow(_ member: NativeSidebarMember, in raw: DesktopSnapshot) -> StageGroupWindow? {
        let snapshot = stageEngine.snapshotForGroups(raw)
        guard snapshot.native?.stageManagerEnabled == false, let catalog = member.source.resolve(snapshot),
              catalog.current.id == member.source.space, let window = member.resolve(snapshot),
              snapshot.windows.filter({ DesktopWindowKey($0) == member.key }).count == 1,
              DesktopWindowTarget(window, in: snapshot) != nil else { return nil }
        return groupWindow(window, on: catalog.display, current: catalog.current)
    }

    func join(_ moving: NativeSidebarMember, _ target: NativeSidebarMember, in snapshot: DesktopSnapshot,
              verifiedPair: BoundSidebarPair? = nil) throws {
        guard moving.source == target.source, let first = groupWindow(moving, in: snapshot),
              let second = groupWindow(target, in: snapshot) else { throw StageGroupError.staleBinding }
        try groups.observe([first, second])
        // The ordinary worker retained both original AX elements through a temporary reader outage.
        if let verifiedPair, verifiedPair === boundSidebarPair, verifiedPair.loss == nil,
           verifiedPair.pair.dragged == moving, verifiedPair.pair.target == target {
            for window in [first, second] where groups.needsRebinding(window) { try groups.rebind(window) }
        }
        try groups.join(first, to: second)
    }

    func visibleGroups(in raw: DesktopSnapshot, on screen: DisplayObservation) -> [NativeSpaceWindow: StageGroupDirectory.Group] {
        let snapshot = stageEngine.snapshotForGroups(raw)
        guard let id = UUID(uuidString: screen.id) else { return [:] }
        let visible = groups.projectedGroups(on: id, among: stageWindows(in: snapshot, on: screen))
        return Dictionary(uniqueKeysWithValues: visible.flatMap { group in group.members.map { ($0.windowHint, group) } })
    }

    func lifetime(of key: DesktopWindowKey) -> UUID? { lifetimes[key] }

    func stillGroups(_ member: NativeSidebarMember, in group: UUID, appearance: UUID) -> Bool {
        guard groups.loadIssue == nil, lifetime(of: member.key) == appearance, let bound = groupLifetime(of: member.key),
              let location = member.location else { return false }
        let scope = StageGroupScope(display: location.display, nativeSpace: location.spaceUUID)
        return groups.groups(in: scope).contains { saved in
            saved.id == group && saved.needsReorganization != true && saved.members.contains {
                $0.windowHint == location.window && groups.isBound($0, to: bound)
            }
        }
    }
    func pictureGroups(in snapshot: DesktopSnapshot, screen: DisplayObservation, area: SurfaceRect) -> ObservedPictureGroups? {
        let active = snapshot.scopes.filter { $0.displayID == screen.id }.flatMap(\.records).filter(\.isCurrent)
        guard active.count == 1, let space = active[0].ordinaryUUID, let display = UUID(uuidString:screen.id),
              snapshot.native?.stageManagerEnabled == false, snapshot.native?.catalogComplete == true else { return nil }
        let scope = StageGroupScope(display:display,nativeSpace:space)
        let candidates = stageWindows(in:snapshot,on:screen)
        let eligible = groups.projectedGroups(on:display,among:candidates)
        let stamped = Dictionary(grouping:candidates) { window in
            DesktopWindowKey(pid:window.identity.pid,birth:window.identity.birth,number:window.identity.number)
        }.compactMapValues { $0.count == 1 ? $0.first?.lifetime : nil }
        return .init(scope:scope,area:.init(x:area.x + screen.frame.x,y:area.y + screen.frame.y,width:area.width,height:area.height),
                     groups:groups.groups(in:scope),visible:Set(eligible.map(\.id)),lifetimes:stamped)
    }
    func groupLifetime(of key: DesktopWindowKey) -> UUID? {
        stageLifetimes.lifetime(of: key, appearance: lifetimes[key])
    }

    func confirmGroupLifetimes(previous: StageWindowSample?, current: StageWindowSample, inventory: DesktopSnapshot,
                               previousAppearances: [DesktopWindowKey: UUID], enrolled: [NativeSpaceWindow: UUID]) -> [DesktopWindowKey: UUID] {
        guard inventory.sessionID == session, inventory.revision == revision, sessionAvailable() else { return [:] }
        if let previous {
            stageLifetimes.confirm(first: previous, second: current, previousAppearances: previousAppearances,
                                   appearances: lifetimes, enrolled: enrolled)
        }
        return lifetimes.filter { key, _ in enrolled[.init(pid: key.pid, birth: key.birth, number: key.number)] != nil }
    }
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var pending: (UUID, Task<DesktopSnapshot?, Never>)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var reportedCounts: [Int]?
    @ObservationIgnored weak var automaticTiling: DesktopAutomaticTiling?
    @ObservationIgnored var didSample: (() -> Void)?
    private var panelRequested = false
    private var managementRequested = false
    private var stageOwnershipObserved = false

    init(read: @escaping Read, sessionAvailable: @escaping @MainActor () -> Bool = WindowContentPreview.sessionAvailable,
         fingerprint: @escaping @MainActor () -> Int = CurrentDesktopWindows.windowNumbersFingerprint,
         readSidebarWindows: NativeSidebarWindowHistory.Read? = nil, stageGroupProfile: URL? = nil) {
        let store = StageGroupStore(profile: stageGroupProfile)
        groups = store
        stageEngine = StageWindowEngineHost(profile:stageGroupProfile,store:store)
        self.readSidebarWindows = readSidebarWindows
        self.read = read; self.sessionAvailable = sessionAvailable; self.fingerprint = fingerprint
        stageEngine.attach(to:self)
    }

    func changed() { events?.yield(()) }

    func cardAppeared(_ member: NativeSidebarMember) {
        guard let key = member.location?.window else { return }
        pendingAudit?.event("background-card-appeared", window: key)
    }

    func invalidate(preservingOriginalWindows: Bool = false, reason: String = "invalidate") {
        if preservingOriginalWindows { holdDisplayedRoster() }
        else { departingPictures = nil }
        stageEngine.freeze()
        boundSidebarPair?.revoke(.feedInvalidated)
        windowAudit?.sample(feed: session, epoch: epoch, revision: revision)?.event("invalidate",
            ["reason": reason, "keepsOriginals": preservingOriginalWindows, "panelRequested": panelRequested])
        if !preservingOriginalWindows { sidebarWindows = .init() }
        epoch = UUID()
        pending?.1.cancel()
        pending = nil
        snapshot = nil
        nativeFullscreenSeen = false
        publishPairs([])
        if preservingOriginalWindows && splitObservationAllowed {
            sampleNextSpace = true
            updateObservation()
        }
        lifetimes.removeAll()
        retry?.cancel(); retry = nil; failures = 0
        didSample?()
        changed()
    }

    func observe(_ enable: Bool) {
        windowAudit?.sample(feed: session, epoch: epoch, revision: revision)?.event("panel-observation", ["enabled": enable])
        panelRequested = enable
        if !enable { sidebarWindows = .init(); departingPictures = nil }
        updateObservation()
    }

    func observeManagement(_ enable: Bool) {
        managementRequested = enable
        updateObservation()
    }

    func observeStageOwnership(_ enabled: Bool) {
        guard enabled != stageOwnershipObserved else { return }
        stageOwnershipObserved = enabled
        updateObservation()
    }

    private var observationRequested: Bool {
        panelRequested || managementRequested || stageOwnershipObserved || (splitObservationAllowed && (fullscreenHint || sampleNextSpace || nativeFullscreenSeen))
    }

    private func updateObservation() {
        if !observationRequested {
            guard loop != nil || events != nil || snapshot != nil else { return }
            events?.finish(); events = nil
            loop?.cancel(); loop = nil
            invalidate()
            return
        }
        guard loop == nil else { return }
        let (stream, events) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        let fingerprint = self.fingerprint
        loop = Task { [weak self] in
            let workspace = NSWorkspace.shared.notificationCenter
            let termination = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await stageEngine.processEnded(pid, in: self) }
                    catch { groupIssue = error.localizedDescription }
                }
            }
            defer { workspace.removeObserver(termination) }
            let detector = Task {
                var previous: Int?, last = ContinuousClock.now
                var settleUntil = last
                var settledDragCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDragged)
                while !Task.isCancelled {
                    let now = ContinuousClock.now, numbers = fingerprint()
                    if numbers != previous {
                        previous = numbers
                        // WindowServer's numbers can precede the settled Space membership.
                        settleUntil = now.advanced(by: .milliseconds(760))
                    }
                    // A resize or move need not change the window list. Refresh on mouse
                    // release without monitoring events or reading their coordinates.
                    var dragEnded = false
                    if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDragged)
                        dragEnded = count != settledDragCount
                        settledDragCount = count
                    }
                    if dragEnded || now < settleUntil || now - last >= .seconds(3) {
                        last = now; events.yield(())
                    }
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                }
            }
            defer { detector.cancel() }
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                let expected = epoch
                let next = await readNow()
                guard !Task.isCancelled, expected == epoch else { continue }
                snapshot = next
                if next?.native?.windowLimitReached == false || !sessionAvailable() { departingPictures = nil }
                stageEngine.observeEnvironment(next)
                if next?.native?.stageManagerEnabled == false {
                    stageEngine.ordinaryContextObserved()
                    stageEngine.refreshHeld(feed:self)
                }
                sampleSplitPresentation(next)
                guard !Task.isCancelled, expected == epoch else { continue }
                if let next, pendingAudit?.revision == next.revision { pendingAudit?.snapshot(next, stage: "publish") }
                retry?.cancel()
                retry = nil
                if next != nil {
                    failures = 0
                } else {
                    failures = min(4, failures + 1)
                    let delay = [180, 360, 720, 1500][failures - 1]
                    retry = Task {
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        guard expected == epoch else { return }
                        events.yield(())
                    }
                }
                didSample?()
                if let next {
                    let presented = next.windows.filter(next.isCurrentDesktopWindow)
                    let counts = [presented.count, presented.filter { $0.metadata?.onActiveDesktop == false }.count, next.windows.count]
                    if counts != reportedCounts {
                        reportedCounts = counts
                        Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowOverview")
                            .info("Current desktop windows: total=\(counts[0], privacy: .public) background=\(counts[1], privacy: .public) inventory=\(counts[2], privacy: .public)")
                    }
                }
            }
        }
    }

    /// Used on both sides of a background picture batch and before an explicit click.
    /// Concurrent consumers join the same in-flight read.
    private var firstObserved = [DesktopWindowKey: UInt64]()
    private var nextOrdinal: UInt64 = 0

    func ordered(_ windows: [WindowObservation], on display: String? = nil) -> [WindowObservation] {
        let ranks = display.flatMap(UUID.init(uuidString:)).map { id in
            Dictionary(uniqueKeysWithValues: groups.groups(on: id).enumerated().flatMap { index, group in
                group.members.map { ($0.windowHint, index) }
            })
        } ?? [:]
        func groupRank(_ w: WindowObservation) -> Int {
            guard let k = DesktopWindowKey(w) else { return .max }
            return ranks[.init(pid: k.pid, birth: k.birth, number: k.number)] ?? .max
        }
        func ordinal(_ window: WindowObservation) -> UInt64 {
            guard let m = window.metadata, let birth = m.launchMicroseconds else { return .max }
            return firstObserved[.init(pid: m.pid, birth: birth, number: m.number)] ?? .max
        }
        return windows.sorted { (groupRank($0), ordinal($0), $0.id) < (groupRank($1), ordinal($1), $1.id) }
    }

    /// A gesture cannot use a coalesced inventory that started before its input or before its AX write.
    func readAfterAction() async -> DesktopSnapshot? {
        let boundary = revision, expected = epoch
        if let prior = pending {
            _ = await prior.1.value
            if pending?.0 == prior.0 { pending = nil }
        }
        guard epoch == expected, let fresh = await readNow(), fresh.revision > boundary, epoch == expected else { return nil }
        return fresh
    }

    func readNow() async -> DesktopSnapshot? {
        guard events != nil, sessionAvailable() else {
            departingPictures = nil
            boundSidebarPair?.revoke(.feedInvalidated)
            lifetimes.removeAll()
            sidebarWindows = .init()
            return nil
        }
        let expected = epoch
        if let pending {
            let result = await pending.1.value
            return expected == epoch ? result : nil
        }
        revision &+= 1
        let audit = windowAudit?.sample(feed: session, epoch: epoch, revision: revision)
        let request = DesktopReadRequest(session: session, revision: revision, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false, sidebarAuditWindows: audit?.targets)
        let task = Task { [read, weak self] () -> DesktopSnapshot? in
            guard let self, !Task.isCancelled, self.epoch == expected, self.observationRequested, self.sessionAvailable() else { return nil }
            let readback = try? await read(request)
            guard !Task.isCancelled, expected == self.epoch else { audit?.event("reader-cancelled"); return nil }
            guard var result = readback, self.sessionAvailable(),
                  result.sessionID == request.session, result.revision == request.revision, result.isStructurallyValid,
                  result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else {
                audit?.event("reader-rejected", ["reply": readback != nil, "sessionAvailable": self.sessionAvailable(),
                    "structurallyValid": readback?.isStructurallyValid == true])
                if self.sessionAvailable() { self.holdDisplayedRoster() }
                else { self.departingPictures = nil }
                self.lifetimes.removeAll()
                if !self.sessionAvailable() {
                    self.boundSidebarPair?.revoke(.feedInvalidated)
                    self.sidebarWindows = .init()
                }
                return nil
            }
            self.boundSidebarPair?.observe(result)
            audit?.snapshot(result, stage: "reader")
            self.pendingAudit = audit
            if result.native?.windowLimitReached == true {
                // This inventory cannot replace the visible roster or establish a window lifetime.
                // Rotate the presentation generation so replay requires the retained original AX object.
                self.holdDisplayedRoster()
                if self.departingPictures?.retainAcrossCappedInventory(result) != true { self.departingPictures = nil }
                self.lifetimes.removeAll()
                return result
            }
            let ordinaryObservation = NativeSidebarNavigation.shared.canSwitch || self.readSidebarWindows != nil
            var diagnosticTargets: Set<NativeSidebarWindowLocation>?
            #if NEARPANE_P0_DIAGNOSTIC
            if self.panelRequested, !ordinaryObservation {
                diagnosticTargets = self.diagnosticLease?.observationTargets(host:getpid())
            }
            #endif
            if self.panelRequested && (ordinaryObservation || diagnosticTargets?.isEmpty == false) {
                var history = self.sidebarWindows
                let sampleWindows = self.readSidebarWindows ?? { await NativeSpaceActionClient.shared.observe($0, audit: audit) }
                await history.update(&result, audit: audit, eligible: diagnosticTargets, read: sampleWindows)
                guard !Task.isCancelled, expected == self.epoch, self.sessionAvailable(), self.panelRequested,
                      result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return nil }
                self.sidebarWindows = history
            } else { audit?.event("panel-observation-disabled") }
            var next = [DesktopWindowKey: UUID]()
            for window in result.windows {
                guard let meta = window.metadata, let birth = meta.launchMicroseconds, birth > 0 else { continue }
                let key = DesktopWindowKey(pid: meta.pid, birth: birth, number: meta.number)
                next[key] = self.lifetimes[key] ?? UUID()
            }
            self.firstObserved = self.firstObserved.filter { next[$0.key] != nil }
            // IDs order the initial batch only. A later window cannot overtake an older one.
            for key in next.keys.sorted(by: { $0.number < $1.number }) where self.firstObserved[key] == nil {
                self.nextOrdinal += 1
                self.firstObserved[key] = self.nextOrdinal
            }
            self.lifetimes = next
            if self.panelRequested, self.groups.loadIssue == nil {
                @MainActor func currentDirectory() -> Bool {
                    !Task.isCancelled && expected == self.epoch && self.panelRequested && self.sessionAvailable()
                        && result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                }
                await self.stageEngine.updateGroupProjection(result, current: currentDirectory)
                guard currentDirectory() else { return nil }
                let stage = self.stageEngine.snapshotForGroups(result)
                let candidates = stage.displays.flatMap { self.stageWindows(in: stage, on: $0) }
                do {
                    try self.stageEngine.observeDirectory(candidates, in: self.groups)
                    self.groupIssue = nil
                } catch { self.groupIssue = error.localizedDescription }
            }
            if let audit, audit.focusRequest != nil {
                let snapshot = result
                Task { @MainActor [weak self] in
                    await audit.inspectEnrolledFocus(snapshot) {
                        self?.epoch == expected && self?.panelRequested == true && self?.sessionAvailable() == true
                    }
                }
            }
            return result
        }
        let token = UUID()
        pending = (token, task)
        let result = await task.value
        if pending?.0 == token { pending = nil }
        return expected == epoch ? result : nil
    }

    /// The cheap wake-up check reads only raw WindowServer numbers. Even while
    /// another app is frontmost a newly opened or closed sibling changes the list.
    private static func windowNumbersFingerprint() -> Int {
        var hash = Hasher()
        for options: NSWindow.NumberListOptions in [.allApplications, [.allApplications, .allSpaces]] {
            let ids = NSWindow.windowNumbers(options: options) ?? []
            hash.combine(ids.count)
            for id in ids { hash.combine(id.uint32Value) }
        }
        return hash.finalize()
    }
}
