import AppKit
import CReadOnlySpaces
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import OSLog

/// The publishing reader runs in a different task from the initial user action.
/// Carry only that action's cancellation across the boundary, never its authority.
final class InitialDirectoryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// One fast, metadata-only feed for all visible sidebar panels. The full reader
/// serves geometry and window management independently of the window switcher.
@MainActor @Observable final class CurrentDesktopWindows {
    typealias Read = NativeDesktopProvider.Read
    #if NEARPANE_P0_DIAGNOSTIC
    private let diagnosticLease = P0DiagnosticLease.installed()
    #endif
    private let read: Read
    private let sessionAvailable: @MainActor () -> Bool
    private let fingerprint: @Sendable () -> Int?
    private let navigation: NativeSidebarNavigation
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
                             current: SpaceRecord, rejected: ((String) -> Void)? = nil) -> StageGroupWindow? {
        func reject(_ reason: String) -> StageGroupWindow? { rejected?(reason); return nil }
        // Keep the original guard's short-circuit order. A diagnostic observes
        // the first failed predicate without repeating any live resolver.
        guard let nativeSpace = current.ordinaryUUID else { return reject("window/ordinary-space") }
        guard window.displayID == screen.id else { return reject("window/display") }
        guard let display = UUID(uuidString: screen.id) else { return reject("window/display-uuid") }
        guard window.membership == .known(recordIDs: [current.id]) else { return reject("window/membership") }
        guard let m = window.metadata else { return reject("window/metadata") }
        guard m.isOnscreen == true else { return reject("window/onscreen") }
        guard m.minimized != true else { return reject("window/minimized") }
        guard m.fullScreen != true else { return reject("window/fullscreen") }
        guard m.overviewOrdinaryRole != false else { return reject("window/ordinary-role") }
        guard m.overviewOrdinaryRole == true || window.canWitnessCurrentSpace else { return reject("window/current-space-witness") }
        guard let key = DesktopWindowKey(window) else { return reject("window/identity") }
        guard let lifetime = groupLifetime(of: key) else { return reject("window/group-lifetime") }
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
            if IndependentStagePolicy.candidateRequested && !IndependentStagePolicy.candidateIncludes(key.pid) { return false }
            return snapshot.isCurrentDesktopWindow(w)
        }.compactMap { groupWindow($0, on: screen, current: row.record) }
    }

    func groupWindow(_ member: NativeSidebarMember, in raw: DesktopSnapshot,
                     rejected: (([String: Any]) -> Void)? = nil) -> StageGroupWindow? {
        let snapshot = stageEngine.snapshotForGroups(raw)
        func reject(_ reason: String) -> StageGroupWindow? {
            guard let rejected else { return nil }
            func value<T>(_ optional: T?) -> Any { optional.map { $0 as Any } ?? NSNull() }
            var facts: [String: Any] = ["reason": reason, "snapshotRevision": snapshot.revision,
                "snapshotSession": snapshot.sessionID.uuidString, "snapshotWindows": snapshot.windows.count,
                "catalogComplete": value(snapshot.native?.catalogComplete), "catalogIssues": value(snapshot.native?.catalogIssues),
                "stageManagerEnabled": value(snapshot.native?.stageManagerEnabled),
                "sourceSessionMatches": member.source.session == snapshot.sessionID,
                "sourceTopologyMatches": member.source.topology == snapshot.topologyFingerprint,
                "sourceDisplay": member.source.display, "sourceSpace": member.source.space,
                "selectedPID": member.key.pid, "selectedBirth": member.key.birth, "selectedWindow": member.key.number,
                "selectionOnly": member.selectionOnly, "originalWindowPresent": member.originalWindow != nil]
            if let native = snapshot.native {
                let now = ProcessInfo.processInfo.systemUptime
                if native.beganUptime.isFinite, native.endedUptime.isFinite {
                    facts["nativeBeganUptime"] = native.beganUptime; facts["nativeEndedUptime"] = native.endedUptime
                    facts["nativeSampleMS"] = (native.endedUptime - native.beganUptime) * 1000
                    facts["nativeAgeMS"] = (now - native.beganUptime) * 1000
                    facts["nativeSinceEndMS"] = (now - native.endedUptime) * 1000
                }
            }
            // Include same-number rows so a conflicting owner/birth is visible.
            // These are existing metadata only: no titles, paths, AX or new reads.
            facts["selectedRows"] = snapshot.windows.compactMap { row -> [String: Any]? in
                guard let m = row.metadata, m.number == member.key.number else { return nil }
                let membership: Any
                switch row.membership { case .known(let ids): membership = ids; case .unknown: membership = NSNull() }
                return ["pid": m.pid, "birth": value(m.launchMicroseconds), "window": m.number,
                    "identityMatches": m.pid == member.key.pid && m.launchMicroseconds == member.key.birth,
                    "display": row.displayID, "displayMatches": row.displayID == member.source.display,
                    "knownMembership": membership, "membershipMatchesSource": row.membership == .known(recordIDs: [member.source.space]),
                    "overviewOrdinaryRole": value(m.overviewOrdinaryRole), "minimized": value(m.minimized),
                    "fullScreen": value(m.fullScreen), "isOnscreen": value(m.isOnscreen),
                    "onActiveDesktop": value(m.onActiveDesktop), "overviewSpaceID": value(m.overviewSpaceID),
                    "overviewIsPresented": value(m.overviewIsPresented), "hasCatalogGeometry": value(m.hasCatalogGeometry),
                    "sidebarOriginalWindowPresent": row.sidebarOriginalWindow != nil,
                    "originalWindowMatches": row.sidebarOriginalWindow == member.originalWindow,
                    "originalWindowConstraintSatisfied": member.originalWindow == nil || row.sidebarOriginalWindow == member.originalWindow,
                    "confidence": String(describing: row.confidence), "globalFrameValid": m.globalFrame.geometry.isValid,
                    "axElementPresent": m.element != nil, "axFramePresent": m.axFrame != nil,
                    "axStandardWindowNumber": value(m.axStandardWindowNumber)]
            }
            rejected(facts)
            return nil
        }
        guard snapshot.native?.stageManagerEnabled == false else { return reject("catalog/native-stage-manager") }
        guard let catalog = member.source.resolve(snapshot) else { return reject("catalog/source") }
        guard catalog.current.id == member.source.space else { return reject("catalog/current-space") }
        guard let window = member.resolve(snapshot) else { return reject("member/resolve") }
        guard snapshot.windows.filter({ DesktopWindowKey($0) == member.key }).count == 1 else { return reject("member/unique-identity") }
        guard DesktopWindowTarget(window, in: snapshot) != nil else { return reject("member/desktop-target") }
        return groupWindow(window, on: catalog.display, current: catalog.current, rejected: { _ = reject($0) })
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

    /// The live card supplies a new selection intent. Looking up its saved group
    /// here does not bind it, publish activity, or authorize a window operation.
    func selectionGroup(_ member: NativeSidebarMember, in raw: DesktopSnapshot) -> StageGroupDirectory.Group? {
        guard groups.loadIssue == nil, let location = member.location,
              raw.sessionID == member.source.session, raw.topologyFingerprint == member.source.topology,
              raw.windows.filter({ DesktopWindowKey($0) == member.key }).count == 1 else { return nil }
        let matches = groups.groups(in: .init(display: location.display, nativeSpace: location.spaceUUID)).filter {
            $0.needsReorganization != true && $0.members.contains { $0.windowHint == location.window }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func stillIntendsGroup(_ member: NativeSidebarMember, group: StageGroupDirectory.Group, appearance: UUID) -> Bool {
        guard groups.loadIssue == nil, lifetime(of: member.key) == appearance,
              groupLifetime(of: member.key) != nil, let location = member.location,
              group.needsReorganization != true, group.nativeSpace == location.spaceUUID,
              group.members.contains(where: { $0.windowHint == location.window }) else { return false }
        return groups.groups(in: .init(display: location.display, nativeSpace: location.spaceUUID)).contains(group)
    }

    private struct RebindingRoster: Equatable {
        let home: OrdinaryDesktopIdentity
        let displays: [DisplayObservation]
        let windows: [StageGroupWindow]
        let frames: [NativeSpaceWindow: SurfaceRect]
        let appearances: [NativeSpaceWindow: UUID]
    }

    private func rebindingRoster(_ raw: DesktopSnapshot, source: NativeSidebarDestination) throws -> RebindingRoster {
        let sample = stageEngine.snapshotForGroups(raw)
        guard source.kind == .ordinary, sample.native?.catalogComplete == true,
              sample.native?.stageManagerEnabled == false, sample.native?.windowLimitReached == false,
              let catalog = source.resolve(sample), catalog.current.id == source.space,
              catalog.current.ordinaryUUID == source.uuid, let number = UInt64(source.space), number > 0 else {
            throw StageSwitchError.incomplete
        }
        let keys = try StageWindowEngineWitness.ordinaryRoster(sample.windows, on: source.display, current: source.space) { key in
            if IndependentStagePolicy.candidateRequested && !IndependentStagePolicy.candidateIncludes(key.pid) { return false }
            guard let row = sample.windows.first(where: { DesktopWindowKey($0) == .init(pid: key.pid, birth: key.birth, number: key.number) }),
                  let meta = row.metadata else { throw StageSwitchError.incomplete }
            if meta.overviewOrdinaryRole == false || meta.minimized == true { return false }
            guard meta.overviewOrdinaryRole == true, meta.minimized == false, meta.fullScreen == false,
                  meta.isOnscreen == true, meta.globalFrame.geometry.isValid else { throw StageSwitchError.incomplete }
            return true
        }
        let live = stageWindows(in: sample, on: catalog.display).sorted { $0.identity.number < $1.identity.number }
        guard !live.isEmpty, Set(live.map(\.identity)) == keys else { throw StageSwitchError.incomplete }
        var frames = [NativeSpaceWindow: SurfaceRect](), appearances = [NativeSpaceWindow: UUID]()
        for window in live {
            let key = DesktopWindowKey(pid: window.identity.pid, birth: window.identity.birth, number: window.identity.number)
            guard let appearance = lifetime(of: key), let frame = sample.windows.first(where: { DesktopWindowKey($0) == key })?.metadata?.globalFrame else {
                throw StageSwitchError.interrupted
            }
            appearances[window.identity] = appearance; frames[window.identity] = frame
        }
        return .init(home: .init(display: source.display, record: source.space, uuid: source.uuid),
                     displays: sample.displays, windows: live, frames: frames, appearances: appearances)
    }

    /// Rebinding is part of this one real current-card click. The old authority
    /// must already be discharged; two new complete roster/AX/CG/home reads then
    /// establish current lifetimes for all participating groups together.
    func prepareGroupSelection(_ member: NativeSidebarMember, group: StageGroupDirectory.Group, appearance: UUID,
                               current: @escaping @MainActor () -> Bool,
                               measure supplied: (@MainActor (NativeSpaceWindow, OrdinaryDesktopIdentity) async throws -> StageWindowPhysicalObservation?)? = nil) async throws -> DesktopSnapshot {
        let originalEpoch = epoch, started = ProcessInfo.processInfo.systemUptime
        var step = "entry", rejectedBy = "none", completed = false
        var awaits = [[String: Any]]()
        defer {
            IndependentStageTrace.record("group-selection-preparation-exit", ["window": member.key.number,
                "completed": completed, "step": step, "rejectedBy": rejectedBy,
                "durationMS": (ProcessInfo.processInfo.systemUptime - started) * 1000, "awaits": awaits,
                "epochMatches": epoch == originalEpoch, "cancelled": Task.isCancelled,
                "appearanceMatches": lifetimes[member.key] == appearance,
                "groupLifetimePresent": groupLifetime(of: member.key) != nil,
                "revision": revision, "pendingRead": pending != nil, "holdsDispatch": stageEngine.holdsDispatch])
        }
        func valid() -> Bool {
            // Keep the original short-circuit order. Diagnostics reuse these
            // decisions; they never perform another live navigation check.
            guard !Task.isCancelled else { rejectedBy = "cancelled"; return false }
            guard epoch == originalEpoch else { rejectedBy = "epochChanged"; return false }
            guard current() else { rejectedBy = "selectionNoLongerCurrent"; return false }
            guard stillIntendsGroup(member, group: group, appearance: appearance) else {
                rejectedBy = "groupIntentChanged"; return false
            }
            return true
        }
        func readDirectory(_ phase: String) async -> DesktopSnapshot? {
            step = phase
            let began = ProcessInfo.processInfo.systemUptime
            let result = await readAfterAction()
            awaits.append(["step": phase, "durationMS": (ProcessInfo.processInfo.systemUptime - began) * 1000,
                           "resultPresent": result != nil, "revision": result?.revision ?? 0])
            if result == nil { rejectedBy = "directoryUnavailable" }
            return result
        }
        guard valid(), let first = await readDirectory("first-directory"), valid() else { throw StageSwitchError.interrupted }
        step = "first-home-catalog"
        let sample = stageEngine.snapshotForGroups(first)
        guard let catalog = member.source.resolve(sample), catalog.current.id == member.source.space,
              catalog.current.ordinaryUUID == member.source.uuid else { throw StageSwitchError.incomplete }
        let candidates = stageWindows(in: sample, on: catalog.display)
        if !candidates.contains(where: groups.needsRebinding) {
            step = "existing-group-binding"
            guard stillGroups(member, in: group.id, appearance: appearance) else { throw StageGroupError.staleBinding }
            completed = true
            return first // Normal already-bound selections keep their existing fast path.
        }
        step = "opening-rebinding-roster"
        guard !stageEngine.holdsDispatch else { throw StageSwitchError.recoveryRequired }
        let before = try rebindingRoster(first, source: member.source), directory = groups.directory
        let native: (@Sendable (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation?)?
        step = "directory-reader-access"
        if supplied == nil { native = try StageHostAccess.directoryReader() }
        else { native = nil }
        func physical(_ roster: RebindingRoster, phase: String) async throws -> [NativeSpaceWindow: StageWindowState] {
            var values = [NativeSpaceWindow: StageWindowState]()
            for window in roster.windows {
                step = phase + "-before-read"
                guard valid(), !stageEngine.holdsDispatch else { throw StageSwitchError.interrupted }
                let observed: StageWindowPhysicalObservation?
                step = phase + "-read"
                do {
                    let began = ProcessInfo.processInfo.systemUptime
                    defer { awaits.append(["step": step, "window": window.identity.number,
                        "durationMS": (ProcessInfo.processInfo.systemUptime - began) * 1000]) }
                    if let supplied {
                        observed = try await supplied(window.identity, roster.home)
                    } else if let native {
                        // Pure AX/CG/Space reads must not prevent the UI from
                        // receiving real input or fresh system-ownership samples.
                        let identity = window.identity, home = roster.home
                        observed = try await Task.detached(priority: .userInitiated) { try native(identity, home) }.value
                    } else { throw StageSwitchError.unavailable }
                }
                step = phase + "-verify"
                guard valid(), !stageEngine.holdsDispatch, let read = observed,
                      read.id.pid == window.identity.pid, read.id.launch == window.identity.birth, read.id.number == window.identity.number,
                      read.membership == UInt64(roster.home.record), read.onscreen, !read.minimized,
                      read.frame == roster.frames[window.identity] else { throw StageSwitchError.interrupted }
                values[window.identity] = .init(window: window.identity, lifetime: window.lifetime, frame: read.frame, visibility: .visible)
            }
            return values
        }
        let firstRead = try await physical(before, phase: "first-physical")
        guard let second = await readDirectory("second-directory"), second.sessionID == first.sessionID, second.revision > first.revision,
              valid(), !stageEngine.holdsDispatch else { throw StageSwitchError.interrupted }
        step = "closing-rebinding-roster"
        let after = try rebindingRoster(second, source: member.source)
        guard after == before, try await physical(after, phase: "second-physical") == firstRead, valid(), !stageEngine.holdsDispatch,
              second.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else {
            throw StageSwitchError.interrupted
        }
        step = "rebind-current-scope"
        try groups.rebindCurrentScope(after.windows,
            in: .init(display: try requireDisplay(member.source.display), nativeSpace: member.source.uuid), unchanged: directory)
        step = "final-group-binding"
        guard stillGroups(member, in: group.id, appearance: appearance) else { throw StageGroupError.staleBinding }
        IndependentStageTrace.record("current-click-new-bindings", ["windows": after.windows.count, "group": group.id.uuidString])
        completed = true
        return second
    }

    private func requireDisplay(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw StageSwitchError.incomplete }
        return id
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
    private struct ReadOutcome: Sendable {
        let snapshot: DesktopSnapshot
        /// Travels with this exact task result even after its action has ended.
        let stagedFor: UUID?
    }
    @MainActor final class InitialDirectoryStaging {
        fileprivate let id = UUID()
        fileprivate var registered = false
        let cancellation = InitialDirectoryReadCancellation()
        fileprivate let eligible: @MainActor (DesktopSnapshot) -> Bool
        init(eligible: @escaping @MainActor (DesktopSnapshot) -> Bool) { self.eligible = eligible }
    }
    private struct InitialStage {
        let token: InitialDirectoryStaging, epoch: UUID
        let boundaryRevision: UInt64, date: Date, uptime: Double
        var request: (id: UUID, revision: UInt64)?
    }
    private struct PendingRead {
        let id: UUID, revision: UInt64
        let metadata: StageMetadataReadScope?
        let task: Task<ReadOutcome?, Never>
    }
    @ObservationIgnored private var initialStage: InitialStage?
    @ObservationIgnored private var pending: PendingRead?
    @ObservationIgnored private var stageableRead: UUID?
    private struct MetadataReservation {
        let scope: StageMetadataReadScope, epoch: UUID
        let started: TimeInterval
        var ready = false
    }
    @ObservationIgnored private var metadataReservation: MetadataReservation?
    @ObservationIgnored private var metadataWaiters = [UUID: CheckedContinuation<Void, Never>]()
    @ObservationIgnored private var admittedObserver: UUID?
    @ObservationIgnored private var observerNavigationWait: UUID?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var reportedCounts: [Int]?
    @ObservationIgnored weak var automaticTiling: DesktopAutomaticTiling?
    @ObservationIgnored var didSample: (() -> Void)?
    @ObservationIgnored var didBeginAfterActionRead: ((Date, TimeInterval) -> Void)?
    /// Deterministic test barrier for a late event-loop consumer of a shared read.
    @ObservationIgnored var beforePublishingRead: (@MainActor (UInt64?) async -> Void)?
    @ObservationIgnored var didFinishPublishingRead: ((UInt64?) -> Void)?
    @ObservationIgnored var didJoinPendingRead: ((UInt64) -> Void)?
    @ObservationIgnored var beforeFreshAfterActionRead: (@MainActor () async -> Void)?
    @ObservationIgnored var didWaitForMetadataRead: ((String) -> Void)?
    private var panelRequested = false
    private var managementRequested = false
    private var stageOwnershipObserved = false

    init(read: @escaping Read, sessionAvailable: @escaping @MainActor () -> Bool = WindowContentPreview.sessionAvailable,
         fingerprint: @escaping @Sendable () -> Int? = CurrentDesktopWindows.windowNumbersFingerprint,
         readSidebarWindows: NativeSidebarWindowHistory.Read? = nil, stageGroupProfile: URL? = nil,
         navigation: NativeSidebarNavigation = .shared) {
        let store = StageGroupStore(profile: stageGroupProfile)
        groups = store
        stageEngine = StageWindowEngineHost(profile:stageGroupProfile,store:store)
        self.readSidebarWindows = readSidebarWindows
        self.read = read; self.sessionAvailable = sessionAvailable; self.fingerprint = fingerprint
        self.navigation = navigation
        stageEngine.attach(to:self)
    }

    private func metadataChanged() {
        let waiters = metadataWaiters.values
        metadataWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForMetadataChange(_ reason: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                metadataWaiters[id] = continuation
                didWaitForMetadataRead?(reason)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.metadataWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    func hasMetadataReadScope(_ scope: StageMetadataReadScope) -> Bool {
        metadataReservation?.scope == scope && metadataReservation?.epoch == epoch && metadataReservation?.ready == true
    }

    /// Close ordinary admission first. Every already-admitted producer and the
    /// exact observer publication turn finish normally before foreground reads.
    func acquireMetadataReadScope(_ scope: StageMetadataReadScope, current: @MainActor () -> Bool) async throws {
        let expected = epoch, started = ProcessInfo.processInfo.systemUptime
        func valid() -> Bool {
            !Task.isCancelled && expected == epoch && events != nil && observationRequested && current()
        }
        do {
            while metadataReservation != nil {
                guard valid() else { throw StageSwitchError.interrupted }
                await waitForMetadataChange("acquire")
            }
            guard valid() else { throw StageSwitchError.interrupted }
            metadataReservation = .init(scope: scope, epoch: expected, started: started)
            IndependentStageTrace.record("metadata-scope-reserved", ["scope": scope.id.uuidString,
                "purpose": scope.purpose.rawValue, "epoch": expected.uuidString,
                "pendingProducer": pending != nil, "pendingPublisher": admittedObserver != nil,
                "queuedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            while pending != nil || admittedObserver != nil {
                guard valid(), metadataReservation?.scope == scope else { throw StageSwitchError.interrupted }
                await waitForMetadataChange("drain")
            }
            guard valid(), metadataReservation?.scope == scope else { throw StageSwitchError.interrupted }
            metadataReservation?.ready = true
            IndependentStageTrace.record("metadata-scope-drained", ["scope": scope.id.uuidString,
                "purpose": scope.purpose.rawValue, "epoch": expected.uuidString,
                "pendingProducer": pending != nil, "pendingPublisher": admittedObserver != nil,
                "durationMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        } catch {
            endMetadataReadScope(scope)
            throw error
        }
    }

    func endMetadataReadScope(_ scope: StageMetadataReadScope) {
        if let reservation = metadataReservation, reservation.scope == scope {
            metadataReservation = nil
            // An owner cancelled/frozen while its read awaited the helper. Its
            // late result cannot mutate the feed after this scope was revoked.
            if pending?.metadata == scope { pending?.task.cancel() }
            IndependentStageTrace.record("metadata-scope-ended", ["scope": scope.id.uuidString,
                "purpose": scope.purpose.rawValue, "epoch": reservation.epoch.uuidString, "drained": reservation.ready,
                "durationMS": (ProcessInfo.processInfo.systemUptime - reservation.started) * 1000])
        }
        metadataChanged()
    }

    private func admitObserver() async -> UUID? {
        let expected = epoch
        while true {
            guard !Task.isCancelled, expected == epoch, events != nil else { return nil }
            if navigation.blocksObserverAdmission {
                // Wait before acquiring either a publication token or a pending
                // producer. Foreground reads must never drain an observer that
                // is itself waiting for that foreground navigation to finish.
                let id = UUID(), started = ProcessInfo.processInfo.systemUptime
                observerNavigationWait = id
                IndependentStageTrace.record("observer-navigation-wait-enter", ["waiter": id.uuidString,
                    "epoch": expected.uuidString, "revision": revision])
                didWaitForMetadataRead?("observer-navigation")
                let ready = await navigation.waitForObserverAdmission(id) { [weak self] in
                    self?.epoch == expected && self?.events != nil
                }
                if observerNavigationWait == id { observerNavigationWait = nil }
                IndependentStageTrace.record("observer-navigation-wait-exit", ["waiter": id.uuidString,
                    "durationMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                    "ready": ready, "blocked": navigation.blocksObserverAdmission, "dispatching": navigation.isDispatching,
                    "epochMatches": expected == epoch, "cancelled": Task.isCancelled])
                // A navigation epoch change revokes that wait, not this observation
                // request. Recheck feed lifetime and the current queue before admission.
                continue
            }
            if metadataReservation != nil {
                await waitForMetadataChange("observer")
                continue
            }
            let id = UUID()
            admittedObserver = id
            return id
        }
    }

    func changed() { events?.yield(()) }

    func cardAppeared(_ member: NativeSidebarMember) {
        guard let key = member.location?.window else { return }
        pendingAudit?.event("background-card-appeared", window: key)
    }

    func invalidate(preservingOriginalWindows: Bool = false, reason: String = "invalidate") {
        if let id = observerNavigationWait { navigation.cancelObserverWait(id); observerNavigationWait = nil }
        if preservingOriginalWindows { holdDisplayedRoster() }
        else { departingPictures = nil }
        stageEngine.freeze()
        boundSidebarPair?.revoke(.feedInvalidated)
        windowAudit?.sample(feed: session, epoch: epoch, revision: revision)?.event("invalidate",
            ["reason": reason, "keepsOriginals": preservingOriginalWindows, "panelRequested": panelRequested])
        if !preservingOriginalWindows { sidebarWindows = .init() }
        epoch = UUID()
        metadataReservation = nil
        metadataChanged()
        initialStage = nil
        stageableRead = nil
        pending?.task.cancel()
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
        // The full roster establishes the first display state. A slow or queued
        // window-number hint must not delay it; hints only request later reads.
        events.yield(())
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
                    // WindowServer enumeration can block even when only IDs are requested.
                    // This wake-up hint must never hold the actor needed to consume a click's
                    // fresh native observation. Only the full reader can authorize a dispatch.
                    let numbers = await Task.detached(priority: .utility, operation: fingerprint).value
                    guard !Task.isCancelled else { return }
                    let now = ContinuousClock.now
                    if let numbers, numbers != previous {
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
                guard let observer = await admitObserver() else { continue }
                defer {
                    if admittedObserver == observer { admittedObserver = nil }
                    metadataChanged()
                }
                let outcome = await readOutcome(observer: observer)
                defer { didFinishPublishingRead?(outcome?.snapshot.revision) }
                if let beforePublishingRead { await beforePublishingRead(outcome?.snapshot.revision) }
                guard !Task.isCancelled, expected == epoch else { continue }
                if let outcome, let token = outcome.stagedFor {
                    IndependentStageTrace.record("desktop-read-publication-staged", ["revision": outcome.snapshot.revision,
                                                                                     "token": token.uuidString])
                    continue
                }
                let next = outcome?.snapshot
                snapshot = next
                if ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil {
                    let publishedAt = Date(), publicationUptime = ProcessInfo.processInfo.systemUptime
                    func finite(_ value: Double?) -> Any {
                        guard let value, value.isFinite else { return NSNull() }
                        return value
                    }
                    IndependentStageTrace.record("desktop-observer-published", [
                        "observer": observer.uuidString, "epoch": expected.uuidString,
                        "snapshotPresent": next != nil,
                        "snapshotSession": next.map { $0.sessionID.uuidString as Any } ?? NSNull(),
                        "snapshotRevision": next.map { $0.revision as Any } ?? NSNull(),
                        "catalogComplete": (next?.native?.catalogComplete).map { $0 as Any } ?? NSNull(),
                        "navigationEpoch": navigation.ownershipEpoch.uuidString,
                        "dispatching": navigation.isDispatching, "publicationUptime": finite(publicationUptime),
                        "nativeBeganUptime": finite(next?.native?.beganUptime),
                        "nativeEndedUptime": finite(next?.native?.endedUptime),
                        "wallSampledToAgeMS": finite(next.map { publishedAt.timeIntervalSince($0.sampledTo) * 1000 }),
                        "nativeFreshAtPublication": next.map {
                            $0.nativeIsFresh(now: publishedAt, uptime: publicationUptime) as Any
                        } ?? NSNull()])
                }
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
    func readAfterAction(staging: InitialDirectoryStaging? = nil,
                         within metadata: StageMetadataReadScope? = nil) async -> DesktopSnapshot? {
        let enteringEpoch = epoch
        while metadata == nil && metadataReservation != nil {
            guard !Task.isCancelled, enteringEpoch == epoch else { return nil }
            await waitForMetadataChange("after-action")
        }
        guard enteringEpoch == epoch, metadata.map(hasMetadataReadScope) != false else { return nil }
        let boundary = revision, expected = epoch, afterDate = Date(), started = ProcessInfo.processInfo.systemUptime
        var registeredStaging: InitialDirectoryStaging?
        if let staging, !staging.registered, initialStage == nil {
            staging.registered = true
            registeredStaging = staging
            initialStage = .init(token: staging, epoch: expected, boundaryRevision: boundary,
                                 date: afterDate, uptime: started)
        }
        var priorMS: Double = 0, freshMS: Double = 0, receivedRevision: UInt64 = 0
        var freshRequestedUptime: TimeInterval?
        var step = "waiting-prior", completed = false, hadPrior = false, reusedPrior = false
        var priorResult: DesktopSnapshot?
        defer {
            if let registeredStaging, initialStage?.token.id == registeredStaging.id { initialStage = nil }
            var facts: [String: Any] = ["step": step, "completed": completed,
                "durationMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "priorWaitMS": priorMS, "freshReadMS": freshMS, "hadPrior": hadPrior,
                "reusedPrior": reusedPrior, "boundaryDate": afterDate.timeIntervalSince1970, "boundaryUptime": started,
                "boundaryRevision": boundary, "receivedRevision": receivedRevision, "revision": revision,
                "epochMatches": epoch == expected, "cancelled": Task.isCancelled, "pendingRead": pending != nil]
            if let freshRequestedUptime { facts["freshRequestedUptime"] = freshRequestedUptime }
            if let priorResult {
                facts["priorRevision"] = priorResult.revision
                facts["priorSampledFrom"] = priorResult.sampledFrom.timeIntervalSince1970
                if let native = priorResult.native { facts["priorNativeBeganUptime"] = native.beganUptime }
            }
            IndependentStageTrace.record("after-action-directory-read", facts)
        }
        didBeginAfterActionRead?(afterDate, started)
        if let prior = pending {
            hadPrior = true
            let began = ProcessInfo.processInfo.systemUptime
            priorResult = (await prior.task.value)?.snapshot
            priorMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
            if pending?.id == prior.id { pending = nil; metadataChanged() }
        }
        step = "epoch-after-prior"
        guard epoch == expected else { return nil }
        step = "observation-after-prior"
        guard !Task.isCancelled, observationRequested, events != nil else { return nil }
        guard metadata.map(hasMetadataReadScope) != false else { return nil }
        // A queued request may not have begun its actual native sample until
        // after this call. Reuse only that complete, still-fresh sample; retain
        // its real revision so the next serial read must establish a later one.
        if let priorResult, priorResult.sessionID == session, priorResult.revision == boundary,
           priorResult.isStructurallyValid, let native = priorResult.native,
           native.catalogComplete == true, !native.windowLimitReached,
           priorResult.sampledFrom > afterDate, native.beganUptime > started {
            step = "session-after-prior"
            guard sessionAvailable() else {
                departingPictures = nil
                boundSidebarPair?.revoke(.feedInvalidated)
                lifetimes.removeAll()
                sidebarWindows = .init()
                return nil
            }
            guard !Task.isCancelled else { return nil }
            if priorResult.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) {
                receivedRevision = priorResult.revision
                reusedPrior = true; step = "complete"; completed = true
                return priorResult
            }
        }
        step = "fresh-read"
        if let beforeFreshAfterActionRead { await beforeFreshAfterActionRead() }
        let began = ProcessInfo.processInfo.systemUptime
        freshRequestedUptime = began
        let result = (await readOutcome(staging: registeredStaging, within: metadata))?.snapshot
        freshMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        step = "fresh-read-unavailable"
        guard let fresh = result else { return nil }
        receivedRevision = fresh.revision
        step = "fresh-read-revision"
        guard fresh.revision > boundary else { return nil }
        step = "epoch-after-fresh"
        guard epoch == expected, metadata.map(hasMetadataReadScope) != false else { return nil }
        step = "complete"; completed = true
        return fresh
    }

    func readNow() async -> DesktopSnapshot? {
        (await readOutcome())?.snapshot
    }

    private func readOutcome(staging: InitialDirectoryStaging? = nil, within metadata: StageMetadataReadScope? = nil,
                             observer: UUID? = nil) async -> ReadOutcome? {
        let readCallStarted = ProcessInfo.processInfo.systemUptime
        let enteringEpoch = epoch
        // Never put a gated request in pending: its own foreground owner must
        // not later join a producer that is waiting for that owner to release.
        while metadata == nil && metadataReservation != nil && (observer == nil || observer != admittedObserver) {
            guard !Task.isCancelled, enteringEpoch == epoch else { return nil }
            await waitForMetadataChange("reader")
        }
        guard enteringEpoch == epoch, metadata.map(hasMetadataReadScope) != false else { return nil }
        let metadataAdmitted = ProcessInfo.processInfo.systemUptime
        // Time the original short-circuit check without introducing a second
        // permission/session query or changing when a pending read is joined.
        let available = events != nil && sessionAvailable()
        let availabilityChecked = ProcessInfo.processInfo.systemUptime
        guard available else {
            departingPictures = nil
            boundSidebarPair?.revoke(.feedInvalidated)
            lifetimes.removeAll()
            sidebarWindows = .init()
            return nil
        }
        let expected = epoch
        func bindInitialStage(to id: UUID, revision: UInt64) {
            guard let staging, var stage = initialStage, stage.token.id == staging.id, stage.epoch == expected,
                  stage.request == nil, stageableRead == id, revision > stage.boundaryRevision else { return }
            stage.request = (id, revision)
            initialStage = stage
        }
        if let pending {
            bindInitialStage(to: pending.id, revision: pending.revision)
            didJoinPendingRead?(pending.revision)
            let result = await pending.task.value
            return expected == epoch && metadata.map(hasMetadataReadScope) != false ? result : nil
        }
        revision &+= 1
        let token = UUID()
        stageableRead = token
        // Only the action's actual fresh-read call can bind its shared request.
        // A background read completed while it waits for a prior read cannot.
        bindInitialStage(to: token, revision: revision)
        let auditStarted = ProcessInfo.processInfo.systemUptime
        let audit = windowAudit?.sample(feed: session, epoch: epoch, revision: revision)
        let auditCreated = ProcessInfo.processInfo.systemUptime
        let request = DesktopReadRequest(session: session, revision: revision, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false, sidebarAuditWindows: audit?.targets)
        let taskCreated = ProcessInfo.processInfo.systemUptime
        let task = Task { [read, weak self] () -> ReadOutcome? in
            let taskStarted = ProcessInfo.processInfo.systemUptime
            IndependentStageTrace.record("desktop-read-task-started", ["readSession": request.session.uuidString,
                "requestRevision": request.revision, "taskCreatedUptime": taskCreated,
                "taskStartedUptime": taskStarted, "taskPriority": Task.currentPriority.rawValue])
            var step = "entry", completed = false, receivedReply = false
            var readerMS: Double = 0, historyMS: Double = 0, projectionMS: Double = 0, directoryMS: Double = 0
            var nativeTiming = [String: Double]()
            var incompleteCatalogFacts: [String: Any]?
            defer {
                if self?.stageableRead == token { self?.stageableRead = nil }
                let totalMS = (ProcessInfo.processInfo.systemUptime - taskStarted) * 1000
                var fields: [String: Any] = ["readSession": request.session.uuidString, "requestRevision": request.revision,
                    "step": step, "completed": completed, "receivedReply": receivedReply,
                    "taskPriority": Task.currentPriority.rawValue,
                    "taskCreatedUptime": taskCreated, "taskStartedUptime": taskStarted,
                    "taskQueueMS": (taskStarted - taskCreated) * 1000, "durationMS": totalMS,
                    "readerAwaitMS": readerMS, "sidebarHistoryMS": historyMS,
                    "groupProjectionMS": projectionMS, "observeDirectoryMS": directoryMS,
                    "remainingProcessingMS": max(0, totalMS - readerMS - historyMS - projectionMS - directoryMS)]
                for (key, value) in nativeTiming { fields[key] = value }
                if let incompleteCatalogFacts { fields["incompleteCatalog"] = incompleteCatalogFacts }
                IndependentStageTrace.record("desktop-read-task-exit", fields)
            }
            guard let self, !Task.isCancelled, self.epoch == expected, self.observationRequested, self.sessionAvailable() else { return nil }
            step = "reader-await"
            let readerStarted = ProcessInfo.processInfo.systemUptime
            let readback = try? await read(request)
            let readerReturned = ProcessInfo.processInfo.systemUptime
            readerMS = (readerReturned - readerStarted) * 1000
            receivedReply = readback != nil
            if let native = readback?.native, native.catalogComplete != true {
                let issues = native.catalogIssues ?? []
                var facts: [String: Any] = ["catalogComplete": native.catalogComplete.map { $0 as Any } ?? NSNull(),
                    "catalogIssueCount": issues.count, "catalogIssues": issues.prefix(12).map { String($0.prefix(200)) },
                    "catalogIssuesTruncated": issues.count > 12 || issues.contains { $0.count > 200 }]
                if let samples = native.catalogIssueWindows,
                   let data = try? JSONEncoder().encode(Array(samples.prefix(CatalogIssueWindowFacts.limit))),
                   let rows = try? JSONSerialization.jsonObject(with: data) {
                    facts["catalogIssueWindows"] = rows
                }
                incompleteCatalogFacts = facts
            }
            // These are the helper's existing timestamps, observed before any
            // result validation. Diagnostics perform no additional native read.
            if let native = readback?.native, native.beganUptime.isFinite, native.endedUptime.isFinite {
                nativeTiming = ["readerAwaitStartedUptime": readerStarted, "readerReturnedUptime": readerReturned,
                    "nativeBeganUptime": native.beganUptime, "nativeEndedUptime": native.endedUptime,
                    "nativeDurationMS": (native.endedUptime - native.beganUptime) * 1000,
                    "nativeBeginAfterRequestMS": (native.beganUptime - readerStarted) * 1000,
                    "nativeAgeOnReturnMS": (readerReturned - native.beganUptime) * 1000,
                    "nativeEndToReturnMS": (readerReturned - native.endedUptime) * 1000]
            }
            step = "reader-epoch-check"
            guard !Task.isCancelled, expected == self.epoch else { audit?.event("reader-cancelled"); return nil }
            step = "reader-validation"
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
            // Only an already validated, genuinely later sample may be staged.
            // Return the unmodified failure to the original helper before any
            // lifetime, group, history or environment publication can consume it.
            let stageIsOpen = self.stageableRead == token
            if stageIsOpen { self.stageableRead = nil }
            if stageIsOpen, let stage = self.initialStage, stage.epoch == expected,
               stage.request?.id == token, stage.request?.revision == request.revision,
               result.revision > stage.boundaryRevision, result.native?.catalogComplete == false,
               result.sampledFrom > stage.date, let native = result.native, native.beganUptime > stage.uptime,
               !stage.token.cancellation.isCancelled, stage.token.eligible(result), !stage.token.cancellation.isCancelled {
                step = "initial-directory-staged"; completed = true
                IndependentStageTrace.record("initial-directory-staged", ["revision": result.revision,
                    "boundaryRevision": stage.boundaryRevision, "token": stage.token.id.uuidString])
                return .init(snapshot: result, stagedFor: stage.token.id)
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
                step = "capped-inventory"; completed = true
                return .init(snapshot: result, stagedFor: nil)
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
                step = "sidebar-history"
                let historyStarted = ProcessInfo.processInfo.systemUptime
                await history.update(&result, audit: audit, eligible: diagnosticTargets, read: sampleWindows)
                historyMS = (ProcessInfo.processInfo.systemUptime - historyStarted) * 1000
                step = "sidebar-history-validation"
                guard !Task.isCancelled, expected == self.epoch, self.sessionAvailable(), self.panelRequested,
                      result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return nil }
                self.sidebarWindows = history
            } else { audit?.event("panel-observation-disabled") }
            step = "lifetimes"
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
            // Returning from a native overview may briefly leave every panel hidden.
            // The existing metadata lease must still reconnect retained AX lifetimes
            // before the independent engine can resume the actually focused group.
            if self.panelRequested || (self.stageOwnershipObserved && NativeSidebarNavigation.shared.dispatchAvailable),
               self.groups.loadIssue == nil {
                @MainActor func currentDirectory() -> Bool {
                    !Task.isCancelled && expected == self.epoch && self.sessionAvailable() &&
                        (self.panelRequested || (self.stageOwnershipObserved && NativeSidebarNavigation.shared.dispatchAvailable))
                        && result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                }
                step = "group-projection"
                let projectionStarted = ProcessInfo.processInfo.systemUptime
                await self.stageEngine.updateGroupProjection(result, current: currentDirectory)
                projectionMS = (ProcessInfo.processInfo.systemUptime - projectionStarted) * 1000
                step = "group-projection-validation"
                guard currentDirectory() else { return nil }
                let stage = self.stageEngine.snapshotForGroups(result)
                let candidates = stage.displays.flatMap { self.stageWindows(in: stage, on: $0) }
                step = "directory-observation"
                let directoryStarted = ProcessInfo.processInfo.systemUptime
                do {
                    try self.stageEngine.observeDirectory(candidates, in: self.groups)
                    self.groupIssue = nil
                } catch { self.groupIssue = error.localizedDescription }
                directoryMS = (ProcessInfo.processInfo.systemUptime - directoryStarted) * 1000
            }
            step = "focus-audit-scheduling"
            if let audit, audit.focusRequest != nil {
                let snapshot = result
                Task { @MainActor [weak self] in
                    await audit.inspectEnrolledFocus(snapshot) {
                        self?.epoch == expected && self?.panelRequested == true && self?.sessionAvailable() == true
                    }
                }
            }
            step = "complete"; completed = true
            return .init(snapshot: result, stagedFor: nil)
        }
        pending = .init(id: token, revision: request.revision, metadata: metadata, task: task)
        IndependentStageTrace.record("desktop-read-task-created", ["readSession": request.session.uuidString,
            "requestRevision": request.revision, "taskCreatedUptime": taskCreated,
            "readCallStartedUptime": readCallStarted, "metadataAdmittedUptime": metadataAdmitted,
            "sessionAvailabilityMS": (availabilityChecked - metadataAdmitted) * 1000,
            "auditCreationMS": (auditCreated - auditStarted) * 1000,
            "requestConstructionMS": (taskCreated - auditCreated) * 1000,
            "preTaskCreationMS": (taskCreated - readCallStarted) * 1000,
            "creatorPriority": Task.currentPriority.rawValue,
            "creatorKind": metadata != nil ? "metadata-owner" : (observer != nil ? "observer" : "direct"),
            "dispatching": navigation.isDispatching])
        let result = await task.value
        if pending?.id == token { pending = nil; metadataChanged() }
        return expected == epoch && metadata.map(hasMetadataReadScope) != false ? result : nil
    }

    /// A read-only wake-up hint, independent of AppKit and safe on a background executor.
    /// A failed hint leaves the periodic full reader active; it never means an empty desktop.
    private nonisolated static func windowNumbersFingerprint() -> Int? {
        var value: UInt64 = 0
        guard NPReadWindowNumbersFingerprint(&value) == 1 else { return nil }
        return Int(truncatingIfNeeded: value)
    }
}
