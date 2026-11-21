import AppKit
import NearpaneCore

/// The signed desktop reader supplies the complete current ordinary roster. The separate signed ordinary
/// controller retains the AX element for each member and bystander and checks CG, focus and both Space maps.
@MainActor final class StageWindowEngineWitness: StageEngineWindowWitness {
    struct Binding {
        let lifetime: UUID
        let monitor: OrdinaryWindowAX
        let readOnly: Bool
    }
    struct VisibilityClaim {
        let backend: StageWindowBackend, frame: SurfaceRect, member: UInt64
    }
    private weak var feed: CurrentDesktopWindows?
    let scope: StageGroupScope
    let generation = UUID()
    private let available: @MainActor () -> Bool, restoreAvailable: @MainActor () -> Bool
    private var bindings = [NativeSpaceWindow:Binding](), claims = [NativeSpaceWindow:VisibilityClaim]()
    private let session: UUID, display: String
    private var releaseInput: [UInt32]?
    private var owner: StageWindowBackend?, home: OrdinaryDesktopIdentity?, sequence: UInt64 = 0
    private var enrolledTopology: [ManagedDisplayScope]?
    private var lastSnapshot: DesktopSnapshot?, lastStates = [NativeSpaceWindow:StageWindowState]()
    private var lastSample: StageWindowSample?
    private struct ArrivalWatch {
        let token: UUID, group: UUID, source: NativeSpaceWindow, monitor: OrdinaryWindowAX
        let directory: StageGroupDirectory
    }
    private var arrivalWatch: ArrivalWatch?, arrivalAttempt: NativeSpaceWindow?, arrivalEpoch: UInt64 = 0

    init?(feed: CurrentDesktopWindows, scope: StageGroupScope, snapshot: DesktopSnapshot,
          available: @escaping @MainActor () -> Bool, restoreAvailable: @escaping @MainActor () -> Bool) {
        guard let physical = snapshot.displays.first(where: { UUID(uuidString:$0.id) == scope.display }) else { return nil }
        self.feed = feed; self.scope = scope; self.session = snapshot.sessionID; display = physical.id
        self.available = available; self.restoreAvailable = restoreAvailable
    }

    func matches(_ scope: StageGroupScope) -> Bool { self.scope == scope }
    func state(of id: NativeSpaceWindow) -> StageWindowState? { lastStates[id] }
    func contains(pid: pid_t) -> Bool { bindings.keys.contains(where:{ $0.pid == pid }) }
    func lifetime(of window: NativeSpaceWindow) -> UUID? { bindings[window]?.lifetime }

    func beginRelease() { releaseInput = NativeSelectionPermit.inputCounters() }

    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool {
        owner.generation == generation && self.owner.map { $0 == owner.backend } != false &&
            (restoring ? restoreAvailable() && releaseInput.map({ $0 == NativeSelectionPermit.inputCounters() }) != false : available()) && WindowContentPreview.sessionAvailable() &&
            !StageManagerPreference.ownsWindowDispatch && AXIsProcessTrusted()
    }

    /// The only permissible extra native record is a new backend-owned, noncurrent slot of this exact
    /// display. Reordering, removing or replacing any preexisting desktop still invalidates the writer.
    static func topology(_ actual: [ManagedDisplayScope], matches baseline: [ManagedDisplayScope],
                         allowing claimed: Set<UInt64>, on display: String) -> Bool {
        let slots = Set(claimed.map(String.init))
        guard !slots.contains("0"), slots.isDisjoint(with:baseline.flatMap(\.records).map(\.id)) else { return false }
        var found = Set<String>()
        let stripped = actual.map { scope in
            ManagedDisplayScope(id:scope.id,displayID:scope.displayID,records:scope.records.filter { record in
                guard slots.contains(record.id), scope.displayID == display, !record.isCurrent, record.fullscreenUUID == nil,
                      found.insert(record.id).inserted else { return true }
                return false
            })
        }
        return stripped == baseline
    }

    private func roster(_ snapshot: DesktopSnapshot) throws -> (NativeSpaceCatalog,Set<NativeSpaceWindow>) {
        guard snapshot.sessionID == session, snapshot.native?.stageManagerEnabled == false,
              snapshot.native?.accessibility != .denied, snapshot.native?.catalogComplete == true,
              let catalog = NativeSpaceCatalog(snapshot,displayID:display,now:.now,uptime:ProcessInfo.processInfo.systemUptime),
              catalog.current.ordinaryUUID == scope.nativeSpace, let row = catalog.rows.first(where:{ $0.record == catalog.current }),
              row.regularWindowListComplete else { throw StageSwitchError.incomplete }
        var keys = Set<NativeSpaceWindow>()
        for w in row.windows {
            guard let k = DesktopWindowKey(w), w.membership == .known(recordIDs:[row.id]), w.displayID == display,
                  keys.insert(.init(pid:k.pid,birth:k.birth,number:k.number)).inserted else { throw StageSwitchError.incomplete }
        }
        return (catalog,keys)
    }

    func read(_ requested: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample {
        try await read(requested, owner: owner, candidate: nil)
    }

    private func read(_ requested: StageGroupScope, owner: StageEngineOwner,
                      candidate: (NativeSpaceWindow, Binding)?) async throws -> StageWindowSample {
        guard let feed, requested == scope, permits(owner,restoring:false) || permits(owner,restoring:true),
              let first = await feed.readAfterAction() else { throw StageSwitchError.unavailable }
        let (opening,keys) = try roster(first)
        let initial = enrolledTopology ?? first.scopes
        let slots = Set(claims.values.filter { $0.backend == .spaces }.map(\.member))
        guard Self.topology(first.scopes,matches:initial,allowing:slots,on:display) else { throw StageSwitchError.interrupted }
        guard !keys.isEmpty, keys.count <= 64, let native = UInt64(opening.current.id), native > 0, let usable = opening.display.usable
        else { throw StageSwitchError.incomplete }
        let desktop = OrdinaryDesktopIdentity(display:display,record:opening.current.id,uuid:scope.nativeSpace)
        if self.owner == nil {
            var enrolling = [NativeSpaceWindow:Binding]()
            for key in keys {
                let k = DesktopWindowKey(pid:key.pid,birth:key.birth,number:key.number)
                guard let life = feed.lifetime(of:k), permits(owner,restoring:false) else { throw StageSwitchError.interrupted }
                let monitor = try await DesktopWindowSelection.bind(k)
                // The object stays bound in the identical signed worker across hide, show, place, and focus.
                guard monitor.id.pid == key.pid, monitor.id.launch == key.birth, monitor.id.number == key.number,
                      feed.lifetime(of:k) == life else { throw StageSwitchError.ownership }
                enrolling[key] = .init(lifetime:life,monitor:monitor,readOnly:false)
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
            let observed = try await b.monitor.stageObservation(home:desktop)
            let state = try Self.classify(observed,claim:claims[key],home:native,display:opening.display,displays:first.displays)
            if state != .parked, keys.contains(key) != (observed.membership == native) { throw StageSwitchError.incomplete }
            // A confirmed parked sliver can be below the presentation reader's ordinary size cutoff.
            // Its still-retained AX object, actual CG frame and bidirectional home membership were read above.
            states[key] = .init(window:key,lifetime:b.lifetime,frame:observed.frame,visibility:state,
                                hiddenSpaceID:state == .stageSpace ? observed.membership : nil)
            focuses.append(observed.focus)
        }
        guard let last = await feed.readAfterAction(), let closing = try? roster(last), closing.1 == keys,
              first.revision < last.revision, last.displays == first.displays, closing.0.current == opening.current,
              last.topologyFingerprint == first.topologyFingerprint, Set(focuses).count == 1 else { throw StageSwitchError.interrupted }
        let focus = focuses[0]
        guard focus.map({ states[$0]?.visibility == .visible }) != false else { throw StageSwitchError.incomplete }
        sequence += 1
        let sample = StageWindowSample(scope:scope,generation:generation,sequence:sequence,
            workArea:.init(x:opening.display.frame.x+usable.x,y:opening.display.frame.y+usable.y,width:usable.width,height:usable.height),
            windows:states,focus:focus,nativeID:native)
        if candidate == nil { lastSnapshot = last; lastStates = states; lastSample = sample }
        return sample
    }

    func cancelArrivals(unlessFocusedPID pid: Int32? = nil) {
        if let pid, arrivalAttempt?.pid == pid { return }
        arrivalEpoch &+= 1
        arrivalAttempt = nil
        if let watch = arrivalWatch {
            arrivalWatch = nil
            Task { try? await watch.monitor.setCreationWatch(watch.token, enabled: false) }
        }
    }

    /// Only the original focused member of the already-active, explicitly enrolled group can
    /// start a read-only creation subscription. Unsupported AX notifications give no admission.
    func armArrivals(in store: StageGroupStore, authorized: [NativeSpaceWindow: UUID],
                     current: @MainActor () -> Bool) async {
        guard current(), let home, let sample = lastSample, let baseline = store.arrivalBaseline(sample),
              let source = bindings[baseline.source], !source.readOnly, authorized[baseline.source] == source.lifetime else {
            cancelArrivals(); return
        }
        if let watch = arrivalWatch, watch.source == baseline.source, watch.group == baseline.group,
           watch.directory == baseline.directory { return }
        if arrivalWatch == nil, arrivalAttempt == baseline.source { return }
        cancelArrivals()
        let epoch = arrivalEpoch, token = UUID()
        arrivalAttempt = baseline.source
        do { try await source.monitor.watchStageCreation(token, home: home) }
        catch { return }
        guard current(), epoch == arrivalEpoch, store.directory == baseline.directory else {
            try? await source.monitor.setCreationWatch(token, enabled: false); return
        }
        arrivalWatch = .init(token: token, group: baseline.group, source: baseline.source,
                             monitor: source.monitor, directory: baseline.directory)
    }

    /// Called only from the idle read lane. Provisional reads cannot authorize or publish a target.
    func consumeArrival(in store: StageGroupStore, owner: StageEngineOwner, current: @MainActor () -> Bool) async throws -> Bool {
        guard let watch = arrivalWatch, current(), let feed, let before = lastSample,
              let baseline = store.arrivalBaseline(before), baseline.group == watch.group,
              baseline.source == watch.source, store.directory == watch.directory else { return false }
        let epoch = arrivalEpoch
        let event = try await watch.monitor.nextCreatedWindow(watch.token)
        guard case .window(let object) = event else { return false }
        guard let monitor = object as? OrdinaryWindowAX, current(), epoch == arrivalEpoch,
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
                guard o.membership != home, !o.onscreen else { throw StageSwitchError.incomplete }
                return .stageSpace
            }
            let exposed = bounds(display).intersection(rect)
            // Independent upper bound for the physical remainder. Rust additionally verifies the actual corner
            // shield/zone and the live input tap; its classification alone cannot qualify this geometry.
            guard o.membership == home, !exposed.isEmpty, min(exposed.width,exposed.height) <= 8,
                  max(exposed.width,exposed.height) <= 256, displays.allSatisfy({ $0.id == display.id || bounds($0).intersection(rect).isEmpty })
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

    func ordinary(_ c: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws {
        guard c.scope == scope, c.generation == generation, let b = bindings[c.before.window], !b.readOnly, b.lifetime == c.before.lifetime,
              lastStates[c.before.window] == c.before, c.before.visibility == .visible, let home, let snapshot = lastSnapshot,
              let order = snapshot.scopes.first(where: { $0.displayID == display })?.records,
              let physical = snapshot.displays.first(where: { $0.id == display }),
              let focusScope = OrdinaryFocusScope(display:display,topology:snapshot.topologyFingerprint,order:order,
                  physicalDisplay:physical,separateSpaces:snapshot.separateSpaces), focusScope.desktop == home, valid()
        else { throw StageSwitchError.interrupted }
        let permit = NativeSelectionPermit(current:valid)
        defer { permit.revoke() }
        let monitor = b.monitor
        switch c.action {
        case .focus:
            try await monitor.focusCurrent(frame:c.before.frame,display:display,deadline:ProcessInfo.processInfo.systemUptime+5,
                                           space:home.record,permit:permit,scope:focusScope)
        case .place(let frame):
            try monitor.bindDesktop(home)
            let proof = try await monitor.prepare()
            guard valid(), proof.first.cgFrame == c.before.frame, proof.second.cgFrame == c.before.frame else { throw StageSwitchError.interrupted }
            try await monitor.stagePlace(from:c.before.frame,to:frame,desktop:home,permit:permit)
        default: throw StageSwitchError.ownership
        }
    }
}
