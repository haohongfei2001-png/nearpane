import AppKit
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// The signed desktop reader supplies CG and Space metadata. The installed Host retains and checks
/// the original AX object for each member, and rechecks CG, global focus and both membership maps.
@MainActor final class StageWindowEngineWitness: StageEngineWindowWitness {
    struct Binding {
        let lifetime: UUID
        let monitor: StageHostWindow
        let readOnly: Bool
    }
    struct VisibilityClaim {
        let backend: StageWindowBackend, frame: SurfaceRect, member: UInt64
    }
    private weak var feed: CurrentDesktopWindows?
    let scope: StageGroupScope
    let generation = UUID()
    private let available: @MainActor () -> Bool, restoreAvailable: @MainActor () -> Bool
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
    private(set) var departures = [UUID:StageGroupDeparture]()

    func preparePictures(leavingFor target: UUID) { pendingDeparture = (target, sequence) }
    func endPicturePreparation() { pendingDeparture = nil }

    func confirmsHistoricalMember(_ member: StageGroupDeparture.Member, of departure: StageGroupDeparture) -> Bool {
        let window = member.before.window
        guard generation == departure.generation, scope == departure.scope, departures[departure.group] == departure,
              let binding = bindings[window], mayManage(member.before), binding.lifetime == member.before.lifetime,
              let held = lastStates[window], held.lifetime == binding.lifetime, let claim = claims[window],
              [StageWindowState.Visibility.parked, .stageSpace].contains(held.visibility), let home,
              let actual = try? binding.monitor.observation(home:home), actual.id.pid == window.pid,
              actual.id.number == window.number, actual.id.launch == window.birth, !actual.minimized,
              actual.frame == held.frame, actual.membership == claim.member else { return false }
        return claim.backend == .spaces ? !actual.onscreen && actual.membership == held.hiddenSpaceID : actual.membership == departure.nativeID
    }
    private struct ArrivalWatch {
        let token: UUID, group: UUID, source: NativeSpaceWindow, monitor: StageHostWindow
        let directory: StageGroupDirectory
    }
    private var arrivalWatch: ArrivalWatch?, arrivalAttempt: NativeSpaceWindow?, arrivalEpoch: UInt64 = 0

    init?(feed: CurrentDesktopWindows, scope: StageGroupScope, snapshot: DesktopSnapshot, authorized: [NativeSpaceWindow: UUID],
          available: @escaping @MainActor () -> Bool, restoreAvailable: @escaping @MainActor () -> Bool) {
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
    }

    func matches(_ scope: StageGroupScope) -> Bool { self.scope == scope }
    func state(of id: NativeSpaceWindow) -> StageWindowState? { lastStates[id] }
    func contains(pid: pid_t) -> Bool { bindings.keys.contains(where:{ $0.pid == pid }) }
    func hasVisibilityClaim(_ window: NativeSpaceWindow) -> Bool { claims[window] != nil }
    func discard(_ departure: StageWindowDeparture) {
        guard claims[departure.window] == nil, bindings[departure.window]?.lifetime == departure.lifetime else { return }
        bindings.removeValue(forKey: departure.window)
        leases.removeValue(forKey: departure.window)
    }

    func closedWindows() async throws -> [StageWindowDeparture] {
        guard let feed, let snapshot = await feed.readAfterAction(), let access = hostAccess else { return [] }
        let (_, present) = try roster(snapshot, access: access)
        let absent = bindings.filter {
            !present.contains($0.key)
        }
        return absent.compactMap { try? $0.value.monitor.departure() }
    }
    func lifetime(of window: NativeSpaceWindow) -> UUID? { bindings[window]?.lifetime }
    func mayManage(_ state: StageWindowState) -> Bool {
        guard let binding = bindings[state.window] else { return false }
        return !binding.readOnly && binding.lifetime == state.lifetime &&
            authorizedLifetimes[state.window] == state.lifetime && leases[state.window] != nil
    }

    func beginRelease() { releaseInput = NativeSelectionPermit.inputCounters() }

    func endedOwnership() {
        cancelArrivals()
        leases.removeAll()
        claims.removeAll()
        returnedSample = nil
        returnedAppearances.removeAll()
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
        owner.generation == generation && self.owner.map { $0 == owner.backend } != false &&
            (restoring ? restoreAvailable() && releaseInput.map({ $0 == NativeSelectionPermit.inputCounters() }) != false : available()) && WindowContentPreview.sessionAvailable() &&
            !StageManagerPreference.ownsWindowDispatch && AXIsProcessTrusted() &&
            (restoring || owner.backend == .spaces || WindowVisibilityProvider.corner.requiredPermissions.isSubset(of: StageWindowEngineAttestation.currentPermissions()))
    }

    static func homeCatalog(_ snapshot: DesktopSnapshot?, display: String, space: UUID, session: UUID,
                            topology: String) -> NativeSpaceCatalog? {
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology,
              snapshot.native?.stageManagerEnabled == false, snapshot.native?.catalogComplete == true,
              let catalog = NativeSpaceCatalog(snapshot, displayID: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime),
              catalog.current.ordinaryUUID == space else { return nil }
        return catalog
    }

    func homeCatalog(_ snapshot: DesktopSnapshot?) -> NativeSpaceCatalog? {
        Self.homeCatalog(snapshot, display: display, space: scope.nativeSpace, session: session, topology: topology)
    }

    private func roster(_ snapshot: DesktopSnapshot, access: StageHostAccess) throws -> (NativeSpaceCatalog,Set<NativeSpaceWindow>) {
        guard let catalog = homeCatalog(snapshot) else { throw StageSwitchError.incomplete }
        let keys = try Self.ordinaryRoster(snapshot.windows, on: display, current: catalog.current.id) { key in
            // An already retained standard window can be unlisted after our same-desktop action.
            // Its original AX object and current physical state are still verified in the binding loop.
            if bindings[key] != nil { return true }
            return try access.role(of: key)
        }
        return (catalog,keys)
    }

    static func ordinaryRoster(_ windows: [WindowObservation], on display: String, current: String,
                              role: (NativeSpaceWindow) throws -> Bool) throws -> Set<NativeSpaceWindow> {
        var candidates = Set<NativeSpaceWindow>(), keys = Set<NativeSpaceWindow>()
        for w in windows where w.displayID == display {
            guard case .known(let records) = w.membership else { throw StageSwitchError.incomplete }
            guard records.contains(current) else { continue }
            guard records == [current], let k = DesktopWindowKey(w) else { throw StageSwitchError.incomplete }
            let key = NativeSpaceWindow(pid: k.pid, birth: k.birth, number: k.number)
            guard candidates.insert(key).inserted, candidates.count <= 64 else { throw StageSwitchError.incomplete }
            if try role(key) { keys.insert(key) }
        }
        return keys
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

    func readBystanders(of command: StageWindowCommand, measured: SurfaceRect, owner: StageEngineOwner) async throws -> StageWindowSample {
        guard command.action == .hide, !command.restoring, command.generation == generation,
              let binding = bindings[command.before.window], binding.lifetime == command.before.lifetime,
              !binding.readOnly, claims[command.before.window] == nil else { throw StageSwitchError.ownership }
        return try await read(command.scope, owner: owner, candidate: nil, measured: (command.before.window, measured))
    }

    private func read(_ requested: StageGroupScope, owner: StageEngineOwner,
                      candidate: (NativeSpaceWindow, Binding)?, measured: (NativeSpaceWindow, SurfaceRect)? = nil) async throws -> StageWindowSample {
        guard let feed, requested == scope, permits(owner,restoring:false) || permits(owner,restoring:true),
              let first = await feed.readAfterAction() else { throw StageSwitchError.unavailable }
        let access = try hostAccess ?? StageHostAccess(expectedCDHash: owner.environment.hostCDHash)
        hostAccess = access
        let (opening,keys) = try roster(first, access: access)
        let initial = enrolledTopology ?? first.scopes
        guard first.scopes == initial else { throw StageSwitchError.interrupted }
        guard (!keys.isEmpty || !bindings.isEmpty), keys.count <= 64, let native = UInt64(opening.current.id), native > 0, let usable = opening.display.usable
        else { throw StageSwitchError.incomplete }
        let desktop = OrdinaryDesktopIdentity(display:display,record:opening.current.id,uuid:scope.nativeSpace)
        if self.owner == nil {
            var enrolling = [NativeSpaceWindow:Binding]()
            for key in keys {
                let k = DesktopWindowKey(pid:key.pid,birth:key.birth,number:key.number)
                guard let life = feed.groupLifetime(of:k), permits(owner,restoring:false) else { throw StageSwitchError.interrupted }
                let monitor = try DesktopWindowSelection.bindStage(k, lifetime: life, home: desktop, owner: owner, access: access)
                guard monitor.id.pid == key.pid, monitor.id.launch == key.birth, monitor.id.number == key.number,
                      feed.groupLifetime(of:k) == life else { throw StageSwitchError.ownership }
                enrolling[key] = .init(lifetime:life,monitor:monitor,readOnly:authorizedLifetimes[key] != life)
            }
            bindings = enrolling; self.owner = owner.backend; home = desktop; enrolledTopology = initial
        }
        var observedBindings = bindings
        if let (key, binding) = candidate {
            guard observedBindings[key] == nil, keys.contains(key) else { throw StageSwitchError.ownership }
            observedBindings[key] = binding
        }
        guard home == desktop, keys.isSubset(of:Set(observedBindings.keys)) else { throw StageSwitchError.interrupted }
        var states = [NativeSpaceWindow:StageWindowState](), focuses = [NativeSpaceWindow?]()
        for (key,b) in observedBindings {
            await Task.yield()
            guard permits(owner, restoring: false) || permits(owner, restoring: true) else { throw StageSwitchError.interrupted }
            let observed = try b.monitor.observation(home: desktop)
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
        guard let last = await feed.readAfterAction(), let closing = try? roster(last, access: access), closing.1 == keys,
              first.revision < last.revision, last.displays == first.displays, closing.0.current == opening.current,
              last.topologyFingerprint == first.topologyFingerprint, Set(focuses).count == 1 else { throw StageSwitchError.interrupted }
        let focus = focuses[0]
        var foreign: StageGroupScope?
        if let focus {
            if let local = states[focus] {
                guard local.visibility == .visible else { throw StageSwitchError.incomplete }
            } else {
                foreign = try Self.foreignFocus(focus, outside: scope, first: first, last: last) { try access.currentSurface($0, home: $1) }
            }
        }
        sequence += 1
        let sample = StageWindowSample(scope:scope,generation:generation,sequence:sequence,
            workArea:.init(x:opening.display.frame.x+usable.x,y:opening.display.frame.y+usable.y,width:usable.width,height:usable.height),
            windows:states,focus:focus,nativeID:native,foreignFocusScope:foreign)
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
                    if gallery.remember(captured, in:feed.stageEngine.snapshotForGroups(last)) {
                        departures[group.id] = captured
                    }
                }
                departures = departures.filter { gallery.retains($0.value) }
            }
            lastSnapshot = last; lastStates = states; lastSample = sample
        }
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
        if c.action == .show { claims.removeValue(forKey:c.before.window) }
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
