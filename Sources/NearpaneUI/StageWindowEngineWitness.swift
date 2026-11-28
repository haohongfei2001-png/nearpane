import AppKit
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// The signed desktop reader supplies CG and Space metadata. The installed Host retains and checks
/// the original AX object for each member, and rechecks CG, global focus and both membership maps.
@MainActor final class StageWindowEngineWitness: StageEngineWindowWitness {
    struct Binding: Equatable {
        let lifetime: UUID
        let monitor: StageHostWindow
        let readOnly: Bool
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.lifetime == rhs.lifetime && lhs.monitor === rhs.monitor && lhs.readOnly == rhs.readOnly
        }
    }
    struct VisibilityClaim: Equatable {
        let backend: StageWindowBackend, frame: SurfaceRect, member: UInt64
    }
    private weak var feed: CurrentDesktopWindows?
    let scope: StageGroupScope
    let generation = UUID()
    private let available: @MainActor () -> Bool, restoreAvailable: @MainActor () -> Bool
    private var initialSelectionCurrent: (@MainActor () -> Bool)?
    private let availabilityRejection: @MainActor (Bool) -> [String: Any]?
    private let authorizedLifetimes: [NativeSpaceWindow: UUID]
    private var leases: [NativeSpaceWindow: OrdinaryFileLease]
    private var bindings = [NativeSpaceWindow:Binding](), claims = [NativeSpaceWindow:VisibilityClaim]()
    private let session: UUID, display: String, topology: String
    private var releaseInput: [UInt32]?
    private var owner: StageWindowBackend?, home: OrdinaryDesktopIdentity?, sequence: UInt64 = 0
    private var enrolledTopology: [ManagedDisplayScope]?
    private var hostAccess: StageHostAccess?
    private var lastSnapshot: DesktopSnapshot?, lastStates = [NativeSpaceWindow:StageWindowState]()
    private var lastSample: StageWindowSample?
    private var lastAppearances = [DesktopWindowKey: UUID]()
    private var returnedSample: StageWindowSample?
    private var returnedAppearances = [DesktopWindowKey: UUID]()
    private var pendingDeparture: (target: UUID, after: UInt64)?
    private var metadataScopes = [StageMetadataReadScope: StageEngineOwner]()
    private(set) var departures = [UUID:StageGroupDeparture]()

    func preparePictures(leavingFor target: UUID) { pendingDeparture = (target, sequence) }
    func endPicturePreparation() { pendingDeparture = nil }

    func retainsPictureIdentity(_ member: StageGroupDeparture.Member, of departure: StageGroupDeparture) -> Bool {
        generation == departure.generation && scope == departure.scope && departures[departure.group] == departure &&
            bindings[member.before.window]?.lifetime == member.before.lifetime && mayManage(member.before)
    }

    /// Drawing a retained image consumes the last complete witness. It must not
    /// issue AX/WindowServer IPC from SwiftUI body, or every displayed member can
    /// block delivery of a new click and the system-ownership reply. A card is
    /// never a write permit: chooseHeld obtains a new session.read and supplies
    /// that exact sample; the coordinator still performs its normal preflights.
    func confirmsHistoricalMember(_ member: StageGroupDeparture.Member, of departure: StageGroupDeparture,
                                  observed: StageWindowSample? = nil) -> Bool {
        let window = member.before.window
        guard generation == departure.generation, scope == departure.scope, departures[departure.group] == departure,
              let binding = bindings[window], mayManage(member.before), binding.lifetime == member.before.lifetime,
              let latest = lastSample, let sample = observed ?? lastSample, sample.sequence == latest.sequence,
              sample.sequence == sequence, sample.windows[window] == lastStates[window], let claim = claims[window],
              let home, UInt64(home.record) == sample.nativeID,
              lastSnapshot?.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) == true else { return false }
        return Self.confirmsHistoricalState(member, of: departure, in: sample, claim: claim)
    }

    /// Only already observed facts are compared here. A removed/changed claim,
    /// different original lifetime or newer appearance cannot retain old pixels.
    static func confirmsHistoricalState(_ member: StageGroupDeparture.Member, of departure: StageGroupDeparture,
                                        in sample: StageWindowSample, claim: VisibilityClaim) -> Bool {
        guard departure.members.contains(member), sample.generation == departure.generation,
              sample.scope == departure.scope, sample.nativeID == departure.nativeID,
              let state = sample.windows[member.before.window], state.window == member.before.window,
              state.lifetime == member.before.lifetime, state.frame == claim.frame else { return false }
        switch claim.backend {
        case .spaces:
            return state.visibility == .stageSpace && state.hiddenSpaceID == claim.member &&
                claim.member > 0 && claim.member != departure.nativeID
        case .corner:
            return state.visibility == .parked && state.hiddenSpaceID == nil && claim.member == departure.nativeID
        }
    }
    private struct ArrivalWatch {
        let token: UUID, group: UUID, source: NativeSpaceWindow, monitor: StageHostWindow
        let directory: StageGroupDirectory
    }
    private var arrivalWatch: ArrivalWatch?, arrivalAttempt: NativeSpaceWindow?, arrivalEpoch: UInt64 = 0

    init?(feed: CurrentDesktopWindows, scope: StageGroupScope, snapshot: DesktopSnapshot, authorized: [NativeSpaceWindow: UUID],
          initialSelectionCurrent: @escaping @MainActor () -> Bool,
          available: @escaping @MainActor () -> Bool, restoreAvailable: @escaping @MainActor () -> Bool,
          availabilityRejection: @escaping @MainActor (Bool) -> [String: Any]? = { _ in nil }) {
        guard let physical = snapshot.displays.first(where: { UUID(uuidString:$0.id) == scope.display }),
              !authorized.isEmpty, authorized.count <= 64 else { return nil }
        var acquired = [NativeSpaceWindow: OrdinaryFileLease]()
        do {
            for id in authorized.keys { acquired[id] = try OrdinaryFileLease.forWindow(id) }
        } catch { return nil }
        leases = acquired
        authorizedLifetimes = authorized
        self.feed = feed; self.scope = scope; self.session = snapshot.sessionID; display = physical.id
        topology = snapshot.topologyFingerprint
        self.available = available; self.restoreAvailable = restoreAvailable
        self.initialSelectionCurrent = initialSelectionCurrent
        self.availabilityRejection = availabilityRejection
    }

    func matches(_ scope: StageGroupScope) -> Bool { self.scope == scope }
    func state(of id: NativeSpaceWindow) -> StageWindowState? { lastStates[id] }
    func contains(pid: pid_t) -> Bool { bindings.keys.contains(where:{ $0.pid == pid }) }
    func hasVisibilityClaim(_ window: NativeSpaceWindow) -> Bool { claims[window] != nil }
    func discard(_ departure: StageWindowDeparture) {
        guard claims[departure.window] == nil, bindings[departure.window]?.lifetime == departure.lifetime else { return }
        feed?.stageGallery?.cancelPendingPicture(departure.window, lifetime: departure.lifetime)
        bindings.removeValue(forKey: departure.window)
        leases.removeValue(forKey: departure.window)
    }

    func closedWindows() async throws -> [StageWindowDeparture] {
        guard let feed, let snapshot = await feed.readAfterAction(), let access = hostAccess else { return [] }
        let (_, present) = try await roster(snapshot, access: access) {
            !Task.isCancelled && (self.available() || self.restoreAvailable())
        }
        let absent = bindings.filter {
            !present.contains($0.key)
        }
        return absent.compactMap { try? $0.value.monitor.departure() }
    }
    func lifetime(of window: NativeSpaceWindow) -> UUID? { bindings[window]?.lifetime }
    /// Read-only identity for a click crossing from a current row to an owned
    /// hidden row. It is not an appearance token or a physical write permit.
    struct RetainedMemberIdentity: Equatable {
        let generation: UUID, scope: StageGroupScope, session: UUID, topology: String, home: UInt64
        let window: NativeSpaceWindow, lifetime: UUID, original: ObjectIdentifier
    }
    func retainedMemberIdentity(_ window: NativeSpaceWindow, owner: StageEngineOwner) -> RetainedMemberIdentity? {
        guard owner.backend == .spaces, owner.generation == generation, self.owner == .spaces,
              let home, let native = UInt64(home.record), native > 0,
              let binding = bindings[window], let state = lastStates[window], mayManage(state),
              let sample = lastSample, sample.scope == scope, sample.generation == generation,
              sample.nativeID == native, sample.windows[window] == state,
              lastSnapshot?.sessionID == session, lastSnapshot?.topologyFingerprint == topology else { return nil }
        return .init(generation: generation, scope: scope, session: session, topology: topology, home: native,
                     window: window, lifetime: binding.lifetime, original: ObjectIdentifier(binding.monitor))
    }
    func mayManage(_ state: StageWindowState) -> Bool {
        guard let binding = bindings[state.window] else { return false }
        return !binding.readOnly && binding.lifetime == state.lifetime &&
            authorizedLifetimes[state.window] == state.lifetime && leases[state.window] != nil
    }

    func beginRelease() { releaseInput = NativeSelectionPermit.inputCounters() }

    func endedOwnership() {
        cancelMetadataReadScopes()
        cancelArrivals()
        leases.removeAll()
        claims.removeAll()
        returnedSample = nil
        returnedAppearances.removeAll()
    }

    func returnedMembersAreBound(in feed: CurrentDesktopWindows) -> Bool {
        authorizedLifetimes.allSatisfy { window, lifetime in
            let key = DesktopWindowKey(pid: window.pid, birth: window.birth, number: window.number)
            if feed.groupLifetime(of: key) == lifetime { return true }
            guard let binding = bindings[window], let gone = try? binding.monitor.departure() else { return false }
            return gone.window == window && gone.lifetime == lifetime
        }
    }

    /// Retain read-only AX identities across a successful system handoff. This never
    /// writes a window and never treats a recycled CG number as a surviving member.
    func observeReturnedLifetimes(_ snapshot: DesktopSnapshot) {
        guard let feed, let home, let prior = lastSample,
              let catalog = homeCatalog(snapshot), UInt64(home.record) == prior.nativeID else {
            returnedSample = nil; returnedAppearances.removeAll(); return
        }
        var states = [NativeSpaceWindow: StageWindowState]()
        for (window, lifetime) in authorizedLifetimes {
            guard let binding = bindings[window], binding.lifetime == lifetime,
                  let physical = try? binding.monitor.observation(home: home),
                  physical.id.pid == window.pid, physical.id.launch == window.birth, physical.id.number == window.number,
                  let visibility = try? Self.classify(physical, claim: nil, home: prior.nativeID ?? 0,
                      display: catalog.display, displays: snapshot.displays), visibility == .visible else { continue }
            states[window] = .init(window: window, lifetime: lifetime, frame: physical.frame, visibility: .visible)
        }
        sequence &+= 1
        let sample = StageWindowSample(scope: scope, generation: generation, sequence: sequence,
            workArea: prior.workArea, windows: states, focus: nil, nativeID: prior.nativeID)
        returnedAppearances = feed.confirmGroupLifetimes(previous: returnedSample, current: sample, inventory: snapshot,
            previousAppearances: returnedAppearances, enrolled: authorizedLifetimes)
        returnedSample = sample
    }

    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool {
        checkedPermit(owner, restoring: restoring).allowed
    }

    private func checkedPermit(_ owner: StageEngineOwner, restoring: Bool) -> (allowed: Bool, rejection: [String: Any]?) {
        var rejection: [String: Any]?
        func checked(_ value: Bool, _ reason: String) -> Bool {
            if !value {
                rejection = ["reason": reason]
                if reason == "availability", let facts = availabilityRejection(restoring) {
                    rejection?["availability"] = facts
                }
            }
            return value
        }
        // Preserve the original short-circuit order. The rejection describes
        // this invocation; none of these live checks are repeated for logging.
        guard checked(owner.generation == generation, "generation"),
              checked(self.owner.map { $0 == owner.backend } != false, "backend-owner") else { return (false, rejection) }
        if restoring {
            guard checked(restoreAvailable(), "availability"),
                  checked(releaseInput.map({ $0 == NativeSelectionPermit.inputCounters() }) != false, "release-input") else { return (false, rejection) }
        } else if !checked(available(), "availability") { return (false, rejection) }
        let allowed = checked(WindowContentPreview.sessionAvailable(), "session") &&
            checked(!StageManagerPreference.ownsWindowDispatch, "native-stage-manager") &&
            checked(AXIsProcessTrusted(), "accessibility") &&
            checked(restoring || owner.backend == .spaces || WindowVisibilityProvider.corner.requiredPermissions.isSubset(of: StageWindowEngineAttestation.currentPermissions()), "corner-permissions")
        return (allowed, rejection)
    }

    static func homeCatalog(_ snapshot: DesktopSnapshot?, display: String, space: UUID, session: UUID,
                            topology: String, rejected: (([String: Any]) -> Void)? = nil) -> NativeSpaceCatalog? {
        var checkedAt: Date?, checkedUptime: TimeInterval?
        func checked(_ value: Bool, _ reason: String) -> Bool {
            if !value, let rejected {
                var facts: [String: Any] = ["stage": "home-catalog", "reason": reason]
                if let checkedAt { facts["catalogCheckDate"] = checkedAt.timeIntervalSince1970 }
                if let checkedUptime { facts["catalogCheckUptime"] = checkedUptime }
                rejected(facts)
            }
            return value
        }
        guard checked(snapshot != nil, "snapshot"), let snapshot,
              checked(snapshot.sessionID == session, "session"),
              checked(snapshot.topologyFingerprint == topology, "topology"),
              checked(snapshot.native?.stageManagerEnabled == false, "stage-manager"),
              checked(snapshot.native?.catalogComplete == true, "catalog-complete") else { return nil }
        // Capture each original clock once, only when the original catalogue
        // construction is reached. A rejection never reruns its live checks.
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        checkedAt = now; checkedUptime = uptime
        let result = NativeSpaceCatalog(snapshot, displayID: display, now: now, uptime: uptime)
        guard checked(result != nil, "native-catalog"), let catalog = result,
              checked(catalog.current.ordinaryUUID == space, "current-space") else { return nil }
        return catalog
    }

    func homeCatalog(_ snapshot: DesktopSnapshot?, rejected: (([String: Any]) -> Void)? = nil) -> NativeSpaceCatalog? {
        Self.homeCatalog(snapshot, display: display, space: scope.nativeSpace, session: session, topology: topology, rejected: rejected)
    }

    struct InitialReadState {
        var sequence: UInt64 = 0
        var bindings = 0, claims = 0
        var enrolled = false, specialized = false
        var allowsRetry: Bool { sequence == 0 && bindings == 0 && claims == 0 && !enrolled && !specialized }
    }

    struct InitialOpeningCandidate {
        let catalog: NativeSpaceCatalog
        let identities: [UInt32: NativeSpaceWindow]
        let rows: [UInt32: WindowObservation]
    }

    private static func directoryIdentities(_ snapshot: DesktopSnapshot) -> [UInt32: NativeSpaceWindow] {
        Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { window in
            DesktopWindowKey(window).map { ($0.number, NativeSpaceWindow(pid: $0.pid, birth: $0.birth, number: $0.number)) }
        })
    }

    /// Shared read-only eligibility; staging is not evidence that this remains
    /// eligible when the original action resumes. The helper checks it again.
    static func initialOpeningCandidate(_ first: DesktopSnapshot, display: String, scope: StageGroupScope,
                                        session: UUID, topology: String, authorized: Set<NativeSpaceWindow>, state: InitialReadState,
                                        clock: @MainActor () -> (date: Date, uptime: Double)) -> InitialOpeningCandidate? {
        guard state.allowsRetry, first.native?.catalogComplete == false,
              let issues = first.native?.catalogIssues, issues.count < 32,
              issues.filter({ $0 == "windowRosterChanged" }).count == 1 else { return nil }
        let authorizedNumbers = Set(authorized.map(\.number))
        for issue in issues where issue != "windowRosterChanged" {
            let prefix = "windowIdentityOrBounds:pid="
            guard issue.hasPrefix(prefix) else { return nil }
            let parts = String(issue.dropFirst(prefix.count)).components(separatedBy: ",window=")
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 1, let number = UInt32(parts[1]), number > 0,
                  issue == "\(prefix)\(pid),window=\(number)", !authorizedNumbers.contains(number) else { return nil }
        }
        let checked = clock()
        guard !authorized.isEmpty, authorized.count <= 64, UUID(uuidString: display) == scope.display,
              first.sessionID == session, first.topologyFingerprint == topology, first.native?.stageManagerEnabled == false,
              let opening = NativeSpaceCatalog(first, displayID: display, now: checked.date, uptime: checked.uptime),
              opening.current.ordinaryUUID == scope.nativeSpace else { return nil }
        let before = directoryIdentities(first)
        let oldRows = Dictionary(uniqueKeysWithValues: first.windows.compactMap { w in w.metadata.map { ($0.number, w) } })
        guard before.count == first.windows.count, authorized.allSatisfy({ key in
            before[key.number] == key && oldRows[key.number]?.displayID == display &&
                oldRows[key.number]?.membership == .known(recordIDs: [opening.current.id])
        }) else { return nil }
        return .init(catalog: opening, identities: before, rows: oldRows)
    }

    /// One new directory before the first enrollment only. The failed directory
    /// supplies negative/context evidence; none of its rows is repaired or bound.
    static func initialOpeningDirectory(_ first: DesktopSnapshot, display: String, scope: StageGroupScope,
                                        session: UUID, topology: String, authorized: Set<NativeSpaceWindow>,
                                        state: @MainActor () -> InitialReadState, current: @MainActor () -> Bool,
                                        read: @MainActor () async -> DesktopSnapshot?,
                                        clock: @MainActor () -> (date: Date, uptime: Double) = { (.now, ProcessInfo.processInfo.systemUptime) },
                                        retrying: @MainActor () -> Void = {}) async throws -> DesktopSnapshot {
        guard let candidate = initialOpeningCandidate(first, display: display, scope: scope, session: session,
            topology: topology, authorized: authorized, state: state(), clock: clock) else { return first }
        let opening = candidate.catalog, before = candidate.identities, oldRows = candidate.rows
        guard !Task.isCancelled, state().allowsRetry, current() else { throw StageSwitchError.interrupted }
        retrying()
        let boundary = clock()
        guard let fresh = await read(), !Task.isCancelled, state().allowsRetry, current() else { throw StageSwitchError.interrupted }
        let finished = clock()
        guard fresh.sessionID == session, fresh.revision > first.revision,
              fresh.topologyFingerprint == topology, fresh.displays == first.displays, fresh.scopes == first.scopes,
              fresh.separateSpaces == first.separateSpaces, fresh.native?.stageManagerEnabled == false,
              let native = fresh.native, native.catalogComplete == true, native.catalogIssues?.isEmpty != false,
              fresh.sampledFrom > boundary.date, native.beganUptime > boundary.uptime,
              let closing = NativeSpaceCatalog(fresh, displayID: display, now: finished.date, uptime: finished.uptime),
              closing.current == opening.current else { throw StageSwitchError.incomplete }
        let after = directoryIdentities(fresh)
        let newRows = Dictionary(uniqueKeysWithValues: fresh.windows.compactMap { w in w.metadata.map { ($0.number, w) } })
        guard after.count == fresh.windows.count,
              before.allSatisfy({ number, key in after[number].map { $0 == key } != false }),
              authorized.allSatisfy({ key in
                  after[key.number] == key && newRows[key.number]?.displayID == oldRows[key.number]?.displayID &&
                      newRows[key.number]?.membership == oldRows[key.number]?.membership &&
                      newRows[key.number]?.metadata?.globalFrame == oldRows[key.number]?.metadata?.globalFrame
              }) else { throw StageSwitchError.ownership }
        return fresh
    }

    struct HeldOpeningCandidate {
        let catalog: NativeSpaceCatalog
        let identities: [UInt32: NativeSpaceWindow]
        let rows: [UInt32: WindowObservation]
        let newcomers: [UInt32: CatalogIssueWindowFacts.Sample]
    }

    private static func heldRowsMatch(_ snapshot: DesktopSnapshot, display: String, home: String,
                                     expected: [NativeSpaceWindow: StageWindowState]) -> Bool {
        let rows = Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { w in w.metadata.map { ($0.number, w) } })
        for (key, state) in expected {
            guard state.window == key, state.frame.geometry.isValid,
                  state.visibility == .visible || state.visibility == .minimized || state.visibility == .stageSpace else { return false }
            guard let row = rows[key.number] else {
                if state.visibility == .visible { return false }
                continue // A retained hidden/minimized original is checked physically below.
            }
            guard let identity = DesktopWindowKey(row), identity.pid == key.pid, identity.birth == key.birth,
                  let meta = row.metadata, row.displayID == display, meta.globalFrame == state.frame,
                  meta.overviewOrdinaryRole != false, meta.fullScreen != true else { return false }
            let record = state.visibility == .stageSpace ? state.hiddenSpaceID.map { String($0) } : home
            guard let record, row.membership == .known(recordIDs: [record]) else { return false }
            if state.visibility == .visible && (meta.minimized == true || meta.isOnscreen == false || meta.onActiveDesktop == false) { return false }
            if state.visibility == .minimized && meta.minimized == false { return false }
            if state.visibility == .stageSpace && (meta.isOnscreen == true || meta.onActiveDesktop == true) { return false }
        }
        return true
    }

    /// Only an already retained owner's no-write held-card preparation can use
    /// this candidate. These failure facts allow one fresh read, never a row,
    /// lifetime, membership or write authority from the incomplete directory.
    static func heldOpeningCandidate(_ first: DesktopSnapshot, display: String, scope: StageGroupScope,
                                     session: UUID, topology: String, nativeID: UInt64, retained: Set<NativeSpaceWindow>,
                                     authorized: Set<NativeSpaceWindow>, expected: [NativeSpaceWindow: StageWindowState],
                                     clock: @MainActor () -> (date: Date, uptime: Double)) -> HeldOpeningCandidate? {
        let checked = clock()
        guard !retained.isEmpty, retained.count <= 64, Set(expected.keys) == retained,
              !authorized.isEmpty, authorized.isSubset(of: retained),
              Set(retained.map(\.number)).count == retained.count,
              first.sessionID == session, first.topologyFingerprint == topology,
              UUID(uuidString: display) == scope.display, first.native?.stageManagerEnabled == false,
              first.native?.catalogComplete == false,
              let catalog = NativeSpaceCatalog(first, displayID: display, now: checked.date, uptime: checked.uptime),
              nativeID > 0, catalog.current.id == String(nativeID), catalog.current.ordinaryUUID == scope.nativeSpace,
              let issues = first.native?.catalogIssues, issues.count < 32,
              issues.filter({ $0 == "windowRosterChanged" }).count == 1,
              heldRowsMatch(first, display: display, home: catalog.current.id, expected: expected) else { return nil }
        // Preserve the original roster's explicit membership/identity refusals
        // even if an unbound row later disappears. This callback performs no AX read.
        guard (try? ordinaryRoster(first.windows, on: display, current: catalog.current.id, role: { _ in false })) != nil else { return nil }
        let details = first.native?.catalogIssueWindows ?? []
        let extraIssues = issues.enumerated().filter { $0.element != "windowRosterChanged" }
        guard details.count == extraIssues.count, details.count <= CatalogIssueWindowFacts.limit,
              Set(details.map(\.issueIndex)).count == details.count else { return nil }
        let retainedNumbers = Set(retained.union(authorized).map(\.number))
        var newcomers = [UInt32: CatalogIssueWindowFacts.Sample]()
        for (index, issue) in extraIssues {
            guard let facts = details.first(where: { $0.issueIndex == index }), facts.first == nil,
                  !retainedNumbers.contains(facts.number), let birth = facts.second.birth, birth > 0,
                  facts.second.pid > 1, facts.second.frameValid, let frame = facts.second.frame,
                  min(frame.width, frame.height) > 1,
                  issue == "windowIdentityOrBounds:pid=\(facts.second.pid),window=\(facts.number)",
                  facts.left.state == .unavailable, facts.right.state == .unavailable,
                  !facts.left.truncated, !facts.right.truncated,
                  facts.role.firstPID == nil, facts.role.source == .notRequested,
                  !facts.role.ownerRead, !facts.role.windowRead,
                  facts.role.everyNumberKnown == nil, facts.role.allRolesRead == nil,
                  facts.role.ordinary == nil, facts.role.minimized == nil, facts.role.fullscreen == nil,
                  newcomers.updateValue(facts.second, forKey: facts.number) == nil else { return nil }
        }
        let identities = directoryIdentities(first)
        guard identities.count == first.windows.count else { return nil }
        let rows = Dictionary(uniqueKeysWithValues: first.windows.compactMap { w in w.metadata.map { ($0.number, w) } })
        guard Set(rows.keys).isDisjoint(with: newcomers.keys), first.windows.allSatisfy({ row in
            guard row.displayID == display, row.metadata?.overviewOrdinaryRole == true,
                  case .known(let records) = row.membership, records.contains(catalog.current.id),
                  let number = row.metadata?.number else { return true }
            return identities[number].map(retained.contains) == true
        }) else { return nil }
        return .init(catalog: catalog, identities: identities, rows: rows, newcomers: newcomers)
    }

    /// At most one additional whole directory request. Its existing IPC bound
    /// and native freshness checks are not an overall deadline for preparation.
    static func heldOpeningDirectory(_ first: DesktopSnapshot, display: String, scope: StageGroupScope,
                                     session: UUID, topology: String, nativeID: UInt64, retained: Set<NativeSpaceWindow>,
                                     authorized: Set<NativeSpaceWindow>, expected: [NativeSpaceWindow: StageWindowState],
                                     current: @MainActor () -> Bool, read: @MainActor () async -> DesktopSnapshot?,
                                     clock: @MainActor () -> (date: Date, uptime: Double) = { (.now, ProcessInfo.processInfo.systemUptime) },
                                     retrying: @MainActor () -> Void = {}) async throws -> DesktopSnapshot {
        guard let candidate = heldOpeningCandidate(first, display: display, scope: scope, session: session,
            topology: topology, nativeID: nativeID, retained: retained, authorized: authorized, expected: expected, clock: clock) else { return first }
        guard !Task.isCancelled, current() else { throw StageSwitchError.interrupted }
        retrying()
        let boundary = clock()
        guard let fresh = await read(), !Task.isCancelled, current() else { throw StageSwitchError.interrupted }
        let finished = clock()
        guard fresh.sessionID == session, fresh.revision > first.revision,
              fresh.topologyFingerprint == topology, fresh.displays == first.displays, fresh.scopes == first.scopes,
              fresh.separateSpaces == first.separateSpaces, fresh.native?.stageManagerEnabled == false,
              let native = fresh.native, native.catalogComplete == true, native.catalogIssues?.isEmpty != false,
              fresh.sampledFrom > boundary.date, native.beganUptime > boundary.uptime,
              let closing = NativeSpaceCatalog(fresh, displayID: display, now: finished.date, uptime: finished.uptime),
              closing.current == candidate.catalog.current,
              heldRowsMatch(fresh, display: display, home: closing.current.id, expected: expected) else { throw StageSwitchError.incomplete }
        let after = directoryIdentities(fresh)
        let rows = Dictionary(uniqueKeysWithValues: fresh.windows.compactMap { w in w.metadata.map { ($0.number, w) } })
        guard after.count == fresh.windows.count,
              candidate.identities.allSatisfy({ number, key in
                  guard let row = rows[number] else { return true }
                  return after[number] == key && row.displayID == candidate.rows[number]?.displayID &&
                      row.membership == candidate.rows[number]?.membership &&
                      row.metadata?.globalFrame == candidate.rows[number]?.metadata?.globalFrame
              }), candidate.newcomers.allSatisfy({ number, facts in
                  guard let row = rows[number] else { return true }
                  guard let birth = facts.birth else { return false }
                  return after[number] == NativeSpaceWindow(pid: facts.pid, birth: birth, number: number) &&
                      row.metadata?.globalFrame == facts.frame
              }) else { throw StageSwitchError.ownership }
        return fresh // The original role, retained AX, closing roster and coordinator checks still follow.
    }

    private func roster(_ snapshot: DesktopSnapshot, access: StageHostAccess,
                        rejected: (([String: Any]) -> Void)? = nil,
                        metrics: (([String: Any]) -> Void)? = nil,
                        current: @MainActor () -> Bool) async throws -> (NativeSpaceCatalog,Set<NativeSpaceWindow>) {
        var candidateCount = 0, retainedCount = 0, roleReadCount = 0, candidateEnumerationCompleted = false
        var roleReadTotalMS: Double = 0, roleReadMaxMS: Double = 0
        defer {
            metrics?(["candidateCount": candidateCount, "candidateEnumerationCompleted": candidateEnumerationCompleted,
                      "retainedCount": retainedCount, "roleReadCount": roleReadCount,
                      "roleReadTotalMS": roleReadTotalMS, "roleReadMaxMS": roleReadMaxMS,
                      "roleTimingIncludesTaskQueueAndActorResume": true, "nestedInPhaseDurations": true])
        }
        guard let catalog = homeCatalog(snapshot, rejected: rejected) else { throw StageSwitchError.incomplete }
        let originalBindings = bindings, originalClaims = claims, originalHome = home, originalOwner = owner
        let candidates = try Self.ordinaryRoster(snapshot.windows, on: display, current: catalog.current.id, rejected: rejected) { _ in true }
        candidateCount = candidates.count; candidateEnumerationCompleted = true
        var keys = Set<NativeSpaceWindow>()
        for key in candidates {
            guard !Task.isCancelled, current(), bindings == originalBindings, claims == originalClaims,
                  home == originalHome, owner == originalOwner else { throw StageSwitchError.interrupted }
            // An already retained standard window can be unlisted after our same-desktop action.
            // Its original AX object and current physical state are still verified in the binding loop.
            if bindings[key] != nil { retainedCount += 1; keys.insert(key); continue }
            let ordinary: Bool
            do {
                let began = metrics == nil ? 0 : ProcessInfo.processInfo.systemUptime
                roleReadCount += 1
                defer {
                    if metrics != nil {
                        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                        roleReadTotalMS += elapsed; roleReadMaxMS = max(roleReadMaxMS, elapsed)
                    }
                }
                ordinary = try await Task.detached(priority: .userInitiated) { try access.role(of: key) }.value
            }
            guard !Task.isCancelled, current(), bindings == originalBindings, claims == originalClaims,
                  home == originalHome, owner == originalOwner else { throw StageSwitchError.interrupted }
            if ordinary { keys.insert(key) }
        }
        return (catalog,keys)
    }

    static func ordinaryRoster(_ windows: [WindowObservation], on display: String, current: String,
                              rejected: (([String: Any]) -> Void)? = nil,
                              role: (NativeSpaceWindow) throws -> Bool) throws -> Set<NativeSpaceWindow> {
        func incomplete(_ reason: String, _ window: WindowObservation) -> StageSwitchError {
            if let rejected {
                var facts: [String: Any] = ["stage": "ordinary-roster", "reason": reason,
                    "pid": window.metadata?.pid ?? 0, "window": window.metadata?.number ?? 0,
                    "currentRecord": String(current.prefix(80))]
                switch window.membership {
                case .unknown: facts["membership"] = "unknown"
                case .known(let records):
                    facts["membership"] = "known"
                    facts["membershipCount"] = records.count
                    facts["membershipRecords"] = records.prefix(8).map { String($0.prefix(80)) }
                    facts["membershipRecordsTruncated"] = records.count > 8 || records.contains { $0.count > 80 }
                }
                rejected(facts)
            }
            return .incomplete
        }
        var candidates = Set<NativeSpaceWindow>(), keys = Set<NativeSpaceWindow>()
        for w in windows where w.displayID == display {
            guard case .known(let records) = w.membership else { throw incomplete("unknown-membership", w) }
            guard records.contains(current) else { continue }
            guard records == [current] else { throw incomplete("nonexclusive-current-membership", w) }
            guard let k = DesktopWindowKey(w) else { throw incomplete("window-identity", w) }
            let key = NativeSpaceWindow(pid: k.pid, birth: k.birth, number: k.number)
            guard candidates.insert(key).inserted else { throw incomplete("duplicate-window", w) }
            guard candidates.count <= 64 else { throw incomplete("window-count", w) }
            if try role(key) { keys.insert(key) }
        }
        return keys
    }

    /// Bounded metadata from the exact rejected read, never a later feed snapshot
    /// or a second native query. Failed-item CG geometry is diagnostic only;
    /// window titles, paths and contents are omitted.
    private static func rosterSnapshotFacts(_ snapshot: DesktopSnapshot, display: String) -> [String: Any] {
        let scopes = snapshot.scopes.filter { $0.displayID == display }
        var facts: [String: Any] = ["session": snapshot.sessionID.uuidString, "revision": snapshot.revision,
            "sampledFrom": snapshot.sampledFrom.timeIntervalSince1970, "sampledTo": snapshot.sampledTo.timeIntervalSince1970,
            "freshness": snapshot.freshness.rawValue, "topologyConsistent": snapshot.topologyConsistent,
            "separateSpaces": snapshot.separateSpaces.map { $0 ? "true" : "false" } ?? "unavailable",
            "displayCount": snapshot.displays.count, "displayPresent": snapshot.displays.contains { $0.id == display },
            "scopeCount": snapshot.scopes.count, "matchingScopeCount": scopes.count, "windowCount": snapshot.windows.count,
            "scopeFactsTruncated": scopes.count > 4 || scopes.contains { $0.records.count > 16 }]
        facts["scopes"] = scopes.prefix(4).map { scope -> [String: Any] in
            ["recordCount": scope.records.count, "records": scope.records.prefix(16).map { record -> [String: Any] in
                ["id": String(record.id.prefix(80)), "current": record.isCurrent,
                 "ordinaryUUID": record.ordinaryUUID?.uuidString ?? "unavailable",
                 "fullscreenUUID": record.fullscreenUUID?.uuidString ?? "unavailable"]
            }]
        }
        if let native = snapshot.native {
            let issues = native.catalogIssues ?? []
            facts["population"] = native.population.rawValue; facts["spaces"] = native.spaces.rawValue
            facts["catalogComplete"] = native.catalogComplete.map { $0 ? "true" : "false" } ?? "unavailable"
            facts["stageManagerEnabled"] = native.stageManagerEnabled.map { $0 ? "true" : "false" } ?? "unavailable"
            facts["windowLimitReached"] = native.windowLimitReached
            facts["nativeBeganUptime"] = native.beganUptime; facts["nativeEndedUptime"] = native.endedUptime
            facts["catalogIssueCount"] = issues.count
            facts["catalogIssues"] = issues.prefix(12).map { String($0.prefix(200)) }
            facts["catalogIssuesTruncated"] = issues.count > 12 || issues.contains { $0.count > 200 }
            if let census = native.catalogCensus,
               let data = try? JSONEncoder().encode(census),
               let counts = try? JSONSerialization.jsonObject(with: data) {
                facts["catalogCensus"] = counts
            }
            if let samples = native.catalogIssueWindows,
               let data = try? JSONEncoder().encode(Array(samples.prefix(CatalogIssueWindowFacts.limit))),
               let rows = try? JSONSerialization.jsonObject(with: data) {
                facts["catalogIssueWindows"] = rows
            }
        }
        return facts
    }

    /// A foreground app can be active on a second monitor while this display keeps its work set.
    /// Both inventories must locate the exact key on the same ordinary desktop. The Host also
    /// reads its AX role, keyboard focus, physical frame and bidirectional membership.
    static func foreignFocus(_ key: NativeSpaceWindow, outside scope: StageGroupScope, first: DesktopSnapshot, last: DesktopSnapshot,
                             measure: (NativeSpaceWindow, OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation?) throws -> StageGroupScope {
        guard first.sessionID == last.sessionID, first.revision < last.revision, first.displays == last.displays,
              first.topologyFingerprint == last.topologyFingerprint else { throw StageSwitchError.interrupted }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        func locate(_ snapshot: DesktopSnapshot) throws -> (NativeSpaceCatalog, UUID, SurfaceRect) {
            let matches = snapshot.windows.filter { $0.metadata?.number == key.number }
            guard snapshot.separateSpaces == true, snapshot.native?.stageManagerEnabled == false, snapshot.native?.catalogComplete == true,
                  matches.count == 1, let w = matches.first, let k = DesktopWindowKey(w), k.pid == key.pid, k.birth == key.birth,
                  let m = w.metadata, m.isOnscreen == true, let id = UUID(uuidString: w.displayID), id != scope.display,
                  let catalog = NativeSpaceCatalog(snapshot, displayID: w.displayID, now: now, uptime: uptime),
                  let uuid = catalog.current.ordinaryUUID, w.membership == .known(recordIDs: [catalog.current.id])
            else { throw StageSwitchError.incomplete }
            return (catalog, uuid, m.globalFrame)
        }
        let (opening, uuid, frame) = try locate(first)
        let (closing, lastUUID, lastFrame) = try locate(last)
        let home = OrdinaryDesktopIdentity(display: opening.display.id, record: opening.current.id, uuid: uuid)
        guard opening.display == closing.display, uuid == lastUUID, closing.current == opening.current, frame == lastFrame,
              let display = UUID(uuidString: home.display), let native = UInt64(home.record),
              let physical = try measure(key, home), physical.id.pid == key.pid, physical.id.launch == key.birth,
              physical.id.number == key.number, physical.focus == key, physical.frame == frame,
              try classify(physical, claim: nil, home: native, display: opening.display, displays: first.displays) == .visible
        else { throw StageSwitchError.incomplete }
        return .init(display: display, nativeSpace: uuid)
    }

    func read(_ requested: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample {
        try await read(requested, owner: owner, candidate: nil)
    }

    func read(_ requested: StageGroupScope, owner: StageEngineOwner,
              within metadata: StageMetadataReadScope?) async throws -> StageWindowSample {
        try await read(requested, owner: owner, candidate: nil, within: metadata)
    }

    func readPreparingHeldSelection(_ requested: StageGroupScope, owner: StageEngineOwner,
                                    current: @escaping @MainActor () -> Bool) async throws -> StageWindowSample {
        try await read(requested, owner: owner, candidate: nil, heldPreparationCurrent: current)
    }

    func beginMetadataReadScope(owner: StageEngineOwner,
                                purpose: StageMetadataReadScope.Purpose = .witness) async throws -> StageMetadataReadScope? {
        guard owner.backend == .spaces else { return nil }
        guard let feed, !Task.isCancelled, permits(owner, restoring: false) || permits(owner, restoring: true)
        else { throw StageSwitchError.interrupted }
        let metadata = StageMetadataReadScope(purpose: purpose)
        metadataScopes[metadata] = owner
        do {
            try await feed.acquireMetadataReadScope(metadata) { [weak self] in
                guard let self, metadataScopes[metadata] == owner else { return false }
                return permits(owner, restoring: false) || permits(owner, restoring: true)
            }
            return metadata
        } catch {
            endMetadataReadScope(metadata)
            throw error
        }
    }

    func endMetadataReadScope(_ metadata: StageMetadataReadScope) {
        guard metadataScopes.removeValue(forKey: metadata) != nil else { return }
        feed?.endMetadataReadScope(metadata)
    }

    func cancelMetadataReadScopes() {
        for metadata in Array(metadataScopes.keys) { endMetadataReadScope(metadata) }
    }

    func readBystanders(of command: StageWindowCommand, measured: SurfaceRect, owner: StageEngineOwner) async throws -> StageWindowSample {
        guard command.action == .hide, !command.restoring, command.generation == generation,
              let binding = bindings[command.before.window], binding.lifetime == command.before.lifetime,
              !binding.readOnly, claims[command.before.window] == nil else { throw StageSwitchError.ownership }
        return try await read(command.scope, owner: owner, candidate: nil, measured: (command.before.window, measured))
    }

    private func read(_ requested: StageGroupScope, owner: StageEngineOwner,
                      candidate: (NativeSpaceWindow, Binding)?, measured: (NativeSpaceWindow, SurfaceRect)? = nil,
                      within supplied: StageMetadataReadScope? = nil,
                      heldPreparationCurrent: (@MainActor () -> Bool)? = nil) async throws -> StageWindowSample {
        let metadata: StageMetadataReadScope?
        if let supplied {
            guard metadataScopes[supplied] == owner, feed?.hasMetadataReadScope(supplied) == true
            else { throw StageSwitchError.interrupted }
            metadata = supplied
        } else { metadata = try await beginMetadataReadScope(owner: owner) }
        defer { if supplied == nil, let metadata { endMetadataReadScope(metadata) } }
        return try await withTaskCancellationHandler {
            try await readObserved(requested, owner: owner, candidate: candidate, measured: measured,
                                   within: metadata, heldPreparationCurrent: heldPreparationCurrent)
        } onCancel: { [weak self] in
            if let metadata { Task { @MainActor in self?.endMetadataReadScope(metadata) } }
        }
    }

    private func readObserved(_ requested: StageGroupScope, owner: StageEngineOwner,
                              candidate: (NativeSpaceWindow, Binding)?, measured: (NativeSpaceWindow, SurfaceRect)?,
                              within metadata: StageMetadataReadScope?,
                              heldPreparationCurrent: (@MainActor () -> Bool)?) async throws -> StageWindowSample {
        let readStarted = ProcessInfo.processInfo.systemUptime
        let tracing = ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil
        let initialAttempt = sequence == 0 && bindings.isEmpty && claims.isEmpty && self.owner == nil
        var step = "fresh-directory", reading: NativeSpaceWindow?, completed = false
        var guardRejection: [String: Any]?, observationPhase: String?
        var rosterRejection: [String: Any]?, rejectedRoster: DesktopSnapshot?
        var openingRosterMetrics: [String: Any]?, closingRosterMetrics: [String: Any]?
        var physicalBeforeClosing: [String: Any]?
        var unchangedPermitCount = 0, unchangedPermitTotalMS: Double = 0, unchangedPermitMaxMS: Double = 0
        func unchangedPermit(restoring: Bool) -> (allowed: Bool, rejection: [String: Any]?) {
            guard tracing else { return checkedPermit(owner, restoring: restoring) }
            let began = ProcessInfo.processInfo.systemUptime
            defer {
                let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                unchangedPermitCount += 1; unchangedPermitTotalMS += elapsed
                unchangedPermitMaxMS = max(unchangedPermitMaxMS, elapsed)
            }
            return checkedPermit(owner, restoring: restoring)
        }
        // This subset overlaps the existing phase timings; do not add it to them.
        func unchangedPermitTiming() -> [String: Any] {
            ["count": unchangedPermitCount, "totalMS": unchangedPermitTotalMS,
             "maxMS": unchangedPermitMaxMS, "nestedInPhaseDurations": true]
        }
        defer {
            // This predicate belongs to one initial selection, not the lifetime
            // of the subsequently enrolled owner or any later selection.
            if initialAttempt { initialSelectionCurrent = nil }
            if !completed {
                var facts: [String: Any] = ["step": step,
                    "pid": reading?.pid ?? 0, "window": reading?.number ?? 0,
                    "bindings": bindings.count, "claims": claims.count, "sequence": sequence,
                    "durationMS": (ProcessInfo.processInfo.systemUptime - readStarted) * 1000,
                    "unchangedPermitTiming": unchangedPermitTiming()]
                if let guardRejection { facts["guardRejection"] = guardRejection }
                if let observationPhase { facts["observationPhase"] = observationPhase }
                if let rosterRejection { facts["rosterRejection"] = rosterRejection }
                if let openingRosterMetrics { facts["openingRosterMetrics"] = openingRosterMetrics }
                if let closingRosterMetrics { facts["closingRosterMetrics"] = closingRosterMetrics }
                if let physicalBeforeClosing { facts["physicalBeforeClosing"] = physicalBeforeClosing }
                if let rejectedRoster {
                    facts["rosterSnapshot"] = Self.rosterSnapshotFacts(rejectedRoster, display: display)
                    facts["expectedSession"] = session.uuidString
                    facts["expectedDisplay"] = display
                    facts["expectedSpace"] = scope.nativeSpace.uuidString
                }
                IndependentStageTrace.record("witness-read-rejected", facts)
            }
        }
        guard let feed, requested == scope, permits(owner,restoring:false) || permits(owner,restoring:true)
        else { throw StageSwitchError.unavailable }
        let heldBindings = bindings, heldClaims = claims, heldLeases = Set(leases.keys)
        let heldHome = home, heldOwner = self.owner, heldSequence = sequence
        let heldStates = lastStates, heldSnapshot = lastSnapshot, heldSample = lastSample
        func heldContextCurrent() -> Bool {
            guard let heldPreparationCurrent, let metadata, !Task.isCancelled,
                  metadataScopes[metadata] == owner, feed.hasMetadataReadScope(metadata),
                  owner.backend == .spaces, heldOwner == .spaces, self.owner == heldOwner,
                  !initialAttempt, candidate == nil, measured == nil, releaseInput == nil,
                  sequence == heldSequence, heldSequence > 0, lastStates == heldStates,
                  lastSample?.sequence == heldSample?.sequence, lastSnapshot?.revision == heldSnapshot?.revision,
                  bindings == heldBindings, claims == heldClaims, Set(leases.keys) == heldLeases, home == heldHome,
                  heldSample?.windows == heldStates, Set(heldStates.keys) == Set(heldBindings.keys),
                  heldBindings.allSatisfy({ heldStates[$0.key]?.lifetime == $0.value.lifetime }),
                  heldPreparationCurrent() else { return false }
            return permits(owner, restoring: false)
        }
        var staging: CurrentDesktopWindows.InitialDirectoryStaging?
        var heldStaging: CurrentDesktopWindows.InitialDirectoryStaging?
        if initialAttempt, owner.backend == .spaces, candidate == nil, measured == nil,
           home == nil, enrolledTopology == nil, releaseInput == nil, initialSelectionCurrent != nil {
            let initialLeases = Set(leases.keys)
            staging = .init { [weak self, weak feed] sample in
                guard let self, let feed else { return false }
                let state = InitialReadState(sequence: self.sequence, bindings: self.bindings.count, claims: self.claims.count,
                    enrolled: self.owner != nil || self.home != nil || self.enrolledTopology != nil,
                    specialized: self.releaseInput != nil)
                guard Self.initialOpeningCandidate(sample, display: self.display, scope: self.scope, session: self.session,
                    topology: self.topology, authorized: Set(self.authorizedLifetimes.keys), state: state,
                    clock: { (.now, ProcessInfo.processInfo.systemUptime) }) != nil,
                    Set(self.leases.keys) == initialLeases,
                    self.permits(owner, restoring: false) || self.permits(owner, restoring: true),
                    self.initialSelectionCurrent?() == true,
                    self.authorizedLifetimes.allSatisfy({ key, lifetime in
                        feed.groupLifetime(of: .init(pid: key.pid, birth: key.birth, number: key.number)) == lifetime
                    }) else { return false }
                return true
            }
        }
        if heldPreparationCurrent != nil, !initialAttempt, candidate == nil, measured == nil,
           let original = heldSnapshot, let native = heldSample?.nativeID,
           heldHome?.record == String(native), heldHome?.uuid == scope.nativeSpace {
            let token = CurrentDesktopWindows.InitialDirectoryStaging.heldPreparation { sample in
                heldContextCurrent() && sample.scopes == original.scopes && sample.displays == original.displays &&
                    sample.separateSpaces == original.separateSpaces &&
                    Self.heldOpeningCandidate(sample, display: self.display, scope: self.scope,
                        session: self.session, topology: self.topology, nativeID: native,
                        retained: Set(heldBindings.keys), authorized: Set(self.authorizedLifetimes.keys),
                        expected: heldStates, clock: { (.now, ProcessInfo.processInfo.systemUptime) }) != nil
            }
            heldStaging = token; staging = token
        }
        let openingRead: DesktopSnapshot?
        if let staging {
            let cancellation = staging.cancellation
            openingRead = await withTaskCancellationHandler {
                await feed.readAfterAction(staging: staging, within: metadata)
            } onCancel: { cancellation.cancel() }
        } else { openingRead = await feed.readAfterAction(within: metadata) }
        guard var first = openingRead else { throw StageSwitchError.unavailable }
        var directoryReady = ProcessInfo.processInfo.systemUptime
        step = "host-access"
        let access = try hostAccess ?? StageHostAccess(expectedCDHash: owner.environment.hostCDHash)
        hostAccess = access
        var expectedBindings = bindings
        let expectedClaims = claims, expectedLeases = Set(leases.keys)
        var expectedHome = home, expectedOwner = self.owner
        let expectedReleaseInput = releaseInput
        func unchanged() -> Bool {
            guardRejection = nil
            func checked(_ value: Bool, _ reason: String) -> Bool {
                if !value { guardRejection = ["reason": reason] }
                return value
            }
            guard checked(!Task.isCancelled, "cancelled"), checked(metadata.map(feed.hasMetadataReadScope) != false, "metadata-scope"),
                  checked(bindings == expectedBindings, "bindings"),
                  checked(claims == expectedClaims, "claims"), checked(Set(leases.keys) == expectedLeases, "leases"),
                  checked(home == expectedHome, "home"), checked(self.owner == expectedOwner, "owner"),
                  checked(releaseInput == expectedReleaseInput, "release-input") else { return false }
            let ordinary = unchangedPermit(restoring: false)
            if ordinary.allowed { return true }
            let restoring = unchangedPermit(restoring: true)
            if restoring.allowed { return true }
            guardRejection = ["reason": "permission"]
            if let facts = ordinary.rejection { guardRejection?["ordinary"] = facts }
            if let facts = restoring.rejection { guardRejection?["restoring"] = facts }
            return false
        }
        if initialAttempt, candidate == nil, measured == nil, first.native?.catalogComplete == false {
            first = try await Self.initialOpeningDirectory(first, display: display, scope: scope, session: session,
                topology: topology, authorized: Set(authorizedLifetimes.keys), state: {
                    .init(sequence: self.sequence, bindings: self.bindings.count, claims: self.claims.count,
                          enrolled: self.owner != nil || self.home != nil || self.enrolledTopology != nil,
                          specialized: self.releaseInput != nil)
                }, current: {
                    unchanged() && self.initialSelectionCurrent?() == true && self.authorizedLifetimes.allSatisfy { key, lifetime in
                        feed.groupLifetime(of: .init(pid: key.pid, birth: key.birth, number: key.number)) == lifetime
                    }
                }, read: {
                    let fresh = await feed.readAfterAction(within: metadata)
                    if let fresh { rejectedRoster = fresh }
                    return fresh
                }, retrying: {
                    step = "initial-opening-directory-retry"
                    rejectedRoster = first
                    IndependentStageTrace.record("witness-initial-directory-retry", ["revision": first.revision, "sequence": self.sequence])
                })
            directoryReady = ProcessInfo.processInfo.systemUptime
        }
        if let heldStaging, heldStaging.stagedRevision == first.revision,
           let original = heldSnapshot, let native = heldSample?.nativeID {
            let failedOpening = first
            first = try await Self.heldOpeningDirectory(failedOpening, display: display, scope: scope,
                session: session, topology: topology, nativeID: native,
                retained: Set(heldBindings.keys), authorized: Set(authorizedLifetimes.keys), expected: heldStates,
                current: {
                    heldContextCurrent() && unchanged() && failedOpening.scopes == original.scopes &&
                        failedOpening.displays == original.displays && failedOpening.separateSpaces == original.separateSpaces
                }, read: {
                    let fresh = await feed.readAfterAction(within: metadata)
                    if let fresh { rejectedRoster = fresh }
                    return fresh
                }, retrying: {
                    step = "held-opening-directory-retry"
                    rejectedRoster = failedOpening
                    IndependentStageTrace.record("witness-held-opening-directory-retry", ["revision": failedOpening.revision, "sequence": self.sequence])
                })
            directoryReady = ProcessInfo.processInfo.systemUptime
        }
        step = "opening-roster"
        let (opening,keys) = try await roster(first, access: access, rejected: {
            rosterRejection = $0; rejectedRoster = first
        }, metrics: tracing ? { openingRosterMetrics = $0 } : nil, current: unchanged)
        step = "opening-scope"
        let initial = enrolledTopology ?? first.scopes
        guard unchanged(), first.scopes == initial else { throw StageSwitchError.interrupted }
        guard (!keys.isEmpty || !bindings.isEmpty), keys.count <= 64, let native = UInt64(opening.current.id), native > 0, let usable = opening.display.usable
        else { throw StageSwitchError.incomplete }
        let desktop = OrdinaryDesktopIdentity(display:display,record:opening.current.id,uuid:scope.nativeSpace)
        if self.owner == nil {
            var enrolling = [NativeSpaceWindow:Binding]()
            for key in keys {
                step = "initial-window-binding"; reading = key
                let k = DesktopWindowKey(pid:key.pid,birth:key.birth,number:key.number)
                guard let life = feed.groupLifetime(of:k), unchanged(), permits(owner,restoring:false) else { throw StageSwitchError.interrupted }
                let monitor = try await DesktopWindowSelection.bindStage(k, lifetime: life, home: desktop, owner: owner, access: access)
                guard unchanged(), permits(owner,restoring:false),
                      monitor.id.pid == key.pid, monitor.id.launch == key.birth, monitor.id.number == key.number,
                      feed.groupLifetime(of:k) == life else { throw StageSwitchError.ownership }
                enrolling[key] = .init(lifetime:life,monitor:monitor,readOnly:authorizedLifetimes[key] != life)
            }
            bindings = enrolling; self.owner = owner.backend; home = desktop; enrolledTopology = initial
            expectedBindings = bindings; expectedOwner = self.owner; expectedHome = home
        }
        var observedBindings = bindings
        if let (key, binding) = candidate {
            guard observedBindings[key] == nil, keys.contains(key) else { throw StageSwitchError.ownership }
            observedBindings[key] = binding
        }
        guard home == desktop, keys.isSubset(of:Set(observedBindings.keys)) else { throw StageSwitchError.interrupted }
        let bindingsReady = ProcessInfo.processInfo.systemUptime
        var states = [NativeSpaceWindow:StageWindowState](), focuses = [NativeSpaceWindow?]()
        for (key,b) in observedBindings {
            step = "physical-window-observation"; reading = key
            observationPhase = "before"
            guard unchanged() else { throw StageSwitchError.interrupted }
            observationPhase = "await"
            let observed = try await b.monitor.observationAsync(home: desktop)
            observationPhase = "after"
            let sameBinding = bindings[key] == b || (bindings[key] == nil && candidate?.0 == key && candidate?.1 == b)
            guard unchanged() else { throw StageSwitchError.interrupted }
            guard sameBinding else {
                guardRejection = ["reason": "same-binding"]; throw StageSwitchError.interrupted
            }
            observationPhase = nil
            step = "physical-window-classification"
            if let (target, landing) = measured, key == target {
                let frame = CGRect(x: landing.x, y: landing.y, width: landing.width, height: landing.height)
                func bounds(_ display: DisplayObservation) -> CGRect {
                    .init(x: display.frame.x, y: display.frame.y, width: display.frame.width, height: display.frame.height)
                }
                let edge = bounds(opening.display).intersection(frame)
                guard observed.id.pid == key.pid, observed.id.launch == key.birth, observed.id.number == key.number,
                      observed.frame == landing, observed.membership == native, !observed.minimized, observed.focus != key,
                      !edge.isNull, !edge.isEmpty, edge.width <= 8,
                      first.displays.allSatisfy({ $0.id == opening.display.id || bounds($0).intersection(frame).isEmpty })
                else { throw StageSwitchError.ownership }
                focuses.append(observed.focus)
                continue
            }
            let state = try Self.classify(observed,claim:claims[key],home:native,display:opening.display,displays:first.displays)
            if state != .parked && state != .stageSpace, keys.contains(key) != (observed.membership == native) { throw StageSwitchError.incomplete }
            // A confirmed parked sliver can be below the presentation reader's ordinary size cutoff.
            // Its still-retained AX object, actual CG frame and bidirectional home membership were read above.
            states[key] = .init(window:key,lifetime:b.lifetime,frame:observed.frame,visibility:state,
                                hiddenSpaceID: state == .stageSpace ? observed.membership : nil)
            focuses.append(observed.focus)
        }
        let physicalReady = ProcessInfo.processInfo.systemUptime
        if tracing {
            let prior = lastStates
            func ordered(_ keys: Set<NativeSpaceWindow>) -> [NativeSpaceWindow] {
                keys.sorted { ($0.pid, $0.birth, $0.number) < ($1.pid, $1.birth, $1.number) }
            }
            func keyFacts(_ key: NativeSpaceWindow) -> [String: Any] {
                ["pid": key.pid, "birth": key.birth, "window": key.number]
            }
            func stateFacts(_ state: StageWindowState?) -> Any {
                guard let state else { return NSNull() }
                let validFrame = state.frame.geometry.isValid
                return ["visibility": state.visibility.rawValue, "lifetime": state.lifetime.uuidString,
                    "frameValid": validFrame,
                    "frame": validFrame ? [state.frame.x, state.frame.y, state.frame.width, state.frame.height] as Any : NSNull(),
                    "hiddenSpaceID": state.hiddenSpaceID.map { $0 as Any } ?? NSNull()] as [String: Any]
            }
            let observedKeys = ordered(Set(observedBindings.keys))
            let changed = ordered(Set(prior.keys).union(states.keys)).filter { prior[$0] != states[$0] }
            physicalBeforeClosing = ["capturedBeforeClosingValidation": true, "coordinatorValidated": false,
                "physicalObservationCount": focuses.count, "physicalKeys": observedKeys.prefix(64).map(keyFacts),
                "physicalKeysTruncated": observedKeys.count > 64, "stateCount": states.count, "lastStateCount": prior.count,
                "statesEqualLastStates": states == prior,
                "matchingStateCount": states.filter { prior[$0.key] == $0.value }.count,
                "changedStateCount": changed.count, "changedStatesTruncated": changed.count > 8,
                "changedStates": changed.prefix(8).map { key -> [String: Any] in
                    ["key": keyFacts(key), "previous": stateFacts(prior[key]), "current": stateFacts(states[key])]
                },
                "focuses": focuses.prefix(64).map { $0.map { keyFacts($0) as Any } ?? NSNull() },
                "focusesTruncated": focuses.count > 64, "distinctFocusCount": Set(focuses).count]
        }
        step = "closing-roster"; reading = nil
        guard let last = await feed.readAfterAction(within: metadata), unchanged(),
              let closing = try? await roster(last, access: access, rejected: {
                  rosterRejection = $0; rejectedRoster = last
              }, metrics: tracing ? { closingRosterMetrics = $0 } : nil, current: unchanged), unchanged(), closing.1 == keys,
              first.revision < last.revision, last.displays == first.displays, closing.0.current == opening.current,
              last.topologyFingerprint == first.topologyFingerprint, Set(focuses).count == 1 else { throw StageSwitchError.interrupted }
        let focus = focuses[0]
        step = "focused-window-scope"; reading = focus
        var foreign: StageGroupScope?
        if let focus {
            if let local = states[focus] {
                guard local.visibility == .visible else { throw StageSwitchError.incomplete }
            } else {
                foreign = try Self.foreignFocus(focus, outside: scope, first: first, last: last) { try access.currentSurface($0, home: $1) }
            }
        }
        sequence += 1
        let stacking = last.windows.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
            .compactMap(DesktopWindowKey.init).map { NativeSpaceWindow(pid: $0.pid, birth: $0.birth, number: $0.number) }
            .filter { states[$0]?.visibility == .visible }
        let sample = StageWindowSample(scope:scope,generation:generation,sequence:sequence,
            workArea:.init(x:opening.display.frame.x+usable.x,y:opening.display.frame.y+usable.y,width:usable.width,height:usable.height),
            windows:states,focus:focus,nativeID:native,foreignFocusScope:foreign,frontToBack:stacking)
        if candidate == nil && measured == nil {
            let previousAppearances = lastAppearances
            lastAppearances = feed.confirmGroupLifetimes(previous: lastSample, current: sample, inventory: last,
                                                         previousAppearances: lastAppearances, enrolled: authorizedLifetimes)
            if let plan = pendingDeparture, let previous = lastSample, previous.sequence > plan.after,
               let opening = lastSnapshot, let gallery = feed.stageGallery {
                pendingDeparture = nil
                let stable = lastAppearances.filter { previousAppearances[$0.key] == $0.value }
                for group in feed.groups.groups(in:scope) where group.id != plan.target &&
                    group.members.contains(where: { states[$0.windowHint]?.visibility == .visible }) {
                    departures[group.id] = nil
                    guard let captured = StageGroupDeparture.read(group:group,first:previous,second:sample,
                        opening:opening,closing:last,appearances:stable,authorized:authorizedLifetimes) else { continue }
                    departures[group.id] = captured
                    _ = gallery.remember(captured, in:feed.stageEngine.snapshotForGroups(last), current: { [weak self] member in
                        self?.retainsPictureIdentity(member, of: captured) == true
                    }, confirmsHidden: { [weak self] member in
                        self?.state(of: member.before.window)?.visibility == .stageSpace &&
                            self?.confirmsHistoricalMember(member, of: captured) == true
                    })
                }
                departures = departures.filter { gallery.retains($0.value) }
            }
            lastSnapshot = last; lastStates = states; lastSample = sample
        }
        IndependentStageTrace.record("witness-read-completed", ["sequence": sequence, "windows": states.count,
            "managed": states.values.filter(mayManage).count, "roster": keys.count,
            "focusPID": focus?.pid ?? 0, "focusWindow": focus?.number ?? 0,
            "focusLocal": focus.map { states[$0] != nil } ?? false, "foreignFocus": foreign != nil,
            "durationMS": (ProcessInfo.processInfo.systemUptime - readStarted) * 1000,
            "unchangedPermitTiming": unchangedPermitTiming(),
            "openingRosterMetrics": openingRosterMetrics ?? [:], "closingRosterMetrics": closingRosterMetrics ?? [:],
            "openingDirectoryMS": (directoryReady - readStarted) * 1000,
            "bindingMS": (bindingsReady - directoryReady) * 1000,
            "physicalWindowsMS": (physicalReady - bindingsReady) * 1000,
            "closingDirectoryMS": (ProcessInfo.processInfo.systemUptime - physicalReady) * 1000])
        completed = true
        return sample
    }

    func cancelArrivals(unlessFocusedPID pid: Int32? = nil) {
        if let pid, arrivalAttempt?.pid == pid { return }
        arrivalEpoch &+= 1
        arrivalAttempt = nil
        if let watch = arrivalWatch {
            arrivalWatch = nil
            watch.monitor.endCreation(watch.token)
        }
    }

    /// Only the original focused member of the already-active, explicitly enrolled group can
    /// start a read-only creation subscription. Unsupported AX notifications give no admission.
    func armArrivals(in store: StageGroupStore, authorized: [NativeSpaceWindow: UUID],
                     current: @MainActor () -> Bool) async {
        guard current(), let sample = lastSample, let baseline = store.arrivalBaseline(sample),
              let source = bindings[baseline.source], !source.readOnly, authorized[baseline.source] == source.lifetime else {
            cancelArrivals(); return
        }
        if let watch = arrivalWatch, watch.source == baseline.source, watch.group == baseline.group,
           watch.directory.hasSameWindowGroups(as: baseline.directory, in: scope) { return }
        if arrivalWatch == nil, arrivalAttempt == baseline.source { return }
        cancelArrivals()
        let epoch = arrivalEpoch, token = UUID()
        arrivalAttempt = baseline.source
        do { try source.monitor.beginCreation(token) }
        catch { return }
        guard current(), epoch == arrivalEpoch, store.directory.hasSameWindowGroups(as: baseline.directory, in: scope) else {
            source.monitor.endCreation(token); return
        }
        arrivalWatch = .init(token: token, group: baseline.group, source: baseline.source,
                             monitor: source.monitor, directory: baseline.directory)
    }

    /// Called only from the idle read lane. Provisional reads cannot authorize or publish a target.
    func consumeArrival(in store: StageGroupStore, owner: StageEngineOwner, current: @MainActor () -> Bool) async throws -> Bool {
        guard let watch = arrivalWatch, current(), let feed, let before = lastSample,
              let baseline = store.arrivalBaseline(before), baseline.group == watch.group,
              baseline.source == watch.source, store.directory.hasSameWindowGroups(as: watch.directory, in: scope) else { return false }
        let epoch = arrivalEpoch
        guard let monitor = try watch.monitor.nextCreation(watch.token) else { return false }
        guard current(), epoch == arrivalEpoch,
              monitor.id.pid == watch.source.pid, monitor.id.launch == watch.source.birth else { throw StageSwitchError.ownership }
        let key = NativeSpaceWindow(pid: monitor.id.pid, birth: monitor.id.launch, number: monitor.id.number)
        let desktopKey = DesktopWindowKey(pid: key.pid, birth: key.birth, number: key.number)
        guard bindings[key] == nil, await feed.readAfterAction() != nil, current(), epoch == arrivalEpoch,
              let lifetime = feed.lifetime(of: desktopKey) else { throw StageSwitchError.interrupted }
        let binding = Binding(lifetime: lifetime, monitor: monitor, readOnly: true)
        let first = try await read(scope, owner: owner, candidate: (key, binding))
        guard current(), epoch == arrivalEpoch, feed.lifetime(of: desktopKey) == lifetime else { throw StageSwitchError.interrupted }
        let second = try await read(scope, owner: owner, candidate: (key, binding))
        guard current(), epoch == arrivalEpoch, feed.lifetime(of: desktopKey) == lifetime else { throw StageSwitchError.interrupted }
        try store.recordCreatedWindow(key, since: baseline, first: first, second: second)
        bindings[key] = binding
        cancelArrivals()
        return true
    }

    static func classify(_ o: StageWindowPhysicalObservation, claim: VisibilityClaim?, home: UInt64,
                         display: DisplayObservation, displays: [DisplayObservation]) throws -> StageWindowState.Visibility {
        let rect = CGRect(x:o.frame.x,y:o.frame.y,width:o.frame.width,height:o.frame.height)
        func bounds(_ d: DisplayObservation) -> CGRect { .init(x:d.frame.x,y:d.frame.y,width:d.frame.width,height:d.frame.height) }
        if let claim {
            guard !o.minimized, claim.member == o.membership, claim.frame == o.frame else { throw StageSwitchError.ownership }
            if claim.backend == .spaces {
                guard claim.member > 0, claim.member != home, !o.onscreen, o.focus != .init(pid: o.id.pid, birth: o.id.launch, number: o.id.number)
                else { throw StageSwitchError.incomplete }
                return .stageSpace
            }
            let exposed = bounds(display).intersection(rect)
            // Independent upper bound for the physical remainder. Rust additionally verifies the actual corner
            // shield/zone and the live input tap; its classification alone cannot qualify this geometry.
            guard o.membership == home, !exposed.isEmpty, min(exposed.width,exposed.height) <= 8,
                  max(exposed.width,exposed.height) <= StageWindowState.maximumParkedExtent,
                  displays.allSatisfy({ $0.id == display.id || bounds($0).intersection(rect).isEmpty })
            else { throw StageSwitchError.incomplete }
            return .parked
        }
        guard o.membership == home else { throw StageSwitchError.ownership }
        if o.minimized {
            guard !o.onscreen else { throw StageSwitchError.incomplete }
            return .minimized
        }
        guard o.onscreen, bounds(display).contains(rect), displays.allSatisfy({ $0.id == display.id || bounds($0).intersection(rect).isEmpty })
        else { throw StageSwitchError.incomplete }
        return .visible
    }

    func expectVisibility(_ c: StageWindowCommand, nativeID: UInt64, frame: SurfaceRect?) {
        guard c.scope == scope, c.generation == generation, let b = bindings[c.before.window], b.lifetime == c.before.lifetime,
              let owner, let frame else { return }
        if c.action == .hide { claims[c.before.window] = .init(backend:owner,frame:frame,member:nativeID) }
        if c.action == .show {
            claims.removeValue(forKey:c.before.window)
            feed?.stageGallery?.cancelPendingPicture(c.before.window, lifetime: c.before.lifetime)
        }
    }

    func confirmsSystemReturn(_ returned: StageWindowReturn) async -> Bool {
        guard returned.scope == scope, let home, UInt64(home.record) == returned.nativeID,
              let binding = bindings[returned.original.window], binding.lifetime == returned.original.lifetime else { return false }
        if binding.monitor.returnedHome(home: home, frame: returned.original.frame, allowMinimized: returned.original.visibility == .minimized) { return true }
        if let closed = try? binding.monitor.departure(), closed.window == returned.original.window,
           closed.lifetime == returned.original.lifetime { return true }
        let gone = try? await StageWindowDeparture.exited(pid: returned.original.window.pid,
            bound: [returned.original.window: returned.original.lifetime])
        return gone?.contains { $0.window == returned.original.window && $0.lifetime == returned.original.lifetime } == true
    }

    func ordinary(_ c: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws {
        guard c.scope == scope, c.generation == generation, let b = bindings[c.before.window], !b.readOnly, b.lifetime == c.before.lifetime,
              lastStates[c.before.window] == c.before, c.before.visibility == .visible, let home, let snapshot = lastSnapshot,
              let order = snapshot.scopes.first(where: { $0.displayID == display })?.records,
              let physical = snapshot.displays.first(where: { $0.id == display }),
              let focusScope = OrdinaryFocusScope(display:display,topology:snapshot.topologyFingerprint,order:order,
                  physicalDisplay:physical,separateSpaces:snapshot.separateSpaces), focusScope.desktop == home, valid()
        else { throw StageSwitchError.interrupted }
        try b.monitor.perform(c, scope: focusScope, current: valid)
    }
}
