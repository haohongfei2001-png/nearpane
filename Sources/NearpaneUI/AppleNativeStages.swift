import AppKit
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import NearpaneWindowEngine

/// One display's transient view of Apple's stages. WindowManager remains the owner of
/// visibility and layout. A card's ordinal is never used as a window or group identity.
@MainActor @Observable final class AppleNativeStages {
    struct Group: Identifiable, Equatable {
        let id: String
        let current: Bool
        let members: [DesktopWindowKey]
        var evidence: AppleStageMirror.MembershipEvidence = .unsettled
    }
    struct MinimizedMembership {
        typealias Items = [DesktopWindowKey: Set<DesktopWindowKey>]
        private var previous = Items()
        private var previousTimestamp: UInt64?
        private(set) var admitted = Items()
        mutating func update(_ observed: Items, at timestamp: UInt64) {
            // Keep both independent observations inside the desktop sample's
            // twelve-second freshness horizon, including after system wake.
            if let previousTimestamp, timestamp > previousTimestamp,
               timestamp - previousTimestamp <= 12_000_000_000 {
                admitted = observed.filter { previous[$0.key] == $0.value }
            } else { admitted = [:] }
            previousTimestamp = timestamp
            previous = observed
        }
    }
    @ObservationIgnored private var minimizedMembership = MinimizedMembership()
    private struct Home: Equatable {
        let session: UUID
        let topology: String
        let display: String
        let screen: UUID
        let desktop: UUID
        let record: UInt64
        let frame: CGRect
        init?(_ snapshot: DesktopSnapshot?, _ display: String) {
            guard let snapshot, snapshot.topologyConsistent, snapshot.native?.stageManagerEnabled == true,
                  !((snapshot.native?.windowLimitReached) ?? true),
                  snapshot.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime),
                  let screen = UUID(uuidString: display), let physical = snapshot.displays.first(where: { $0.id == display }),
                  let scope = snapshot.scopes.first(where: { $0.displayID == display }) else { return nil }
            let records = scope.records.filter(\.isCurrent)
            guard records.count == 1, let r = records.first, let desktop = r.ordinaryUUID,
                  let record = UInt64(r.id), record > 0 else { return nil }
            self.session = snapshot.sessionID; self.topology = snapshot.topologyFingerprint
            self.display = display; self.screen = screen; self.desktop = desktop; self.record = record
            self.frame = CGRect(x: physical.frame.x, y: physical.frame.y, width: physical.frame.width, height: physical.frame.height)
        }
    }
    private(set) var groups = [Group]()
    #if DEBUG
    private var cycleTarget: DesktopWindowKey?
    #endif
    private(set) var ready = false
    private var handoff: AppleStageSelectionHandoff? { didSet { oldValue?.release() } }
    @ObservationIgnored private var home: Home?
    @ObservationIgnored private var mirror: AppleStageMirror?
    @ObservationIgnored private var keys = [UInt32:DesktopWindowKey]()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var didDispatch = false
    @ObservationIgnored private let minimize = AppleStageMinimizeObserver(observesGeometry: true)
    @ObservationIgnored private var lastChoice: [String:DesktopWindowKey] = [:]
    @ObservationIgnored private var lastMemberCycle: AppleStageMemberCycle?
    @ObservationIgnored private var currentSnapshot: (@MainActor () -> DesktopSnapshot?)?
    @ObservationIgnored private var refreshSnapshot: (@MainActor () async -> DesktopSnapshot?)?
    @ObservationIgnored private var visible: (@MainActor () -> Bool)?
    @ObservationIgnored private var updates: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var latestSystem: AppleStageSystemRead?
    @ObservationIgnored private var completeMembership = false
    @ObservationIgnored private var lastRead: UInt64 = 0

    func matches(_ snapshot: DesktopSnapshot, display: String) -> Bool {
        guard let home else { return false }
        return home == Home(snapshot, display)
    }
    private func clear() {
        lastMemberCycle = nil
        handoff = nil
        minimize.stop()
        if !groups.isEmpty { groups = [] }
        ready = false; keys = [:]; lastChoice = [:]; mirror = nil; home = nil; lastRead = 0; latestSystem = nil
        minimizedMembership = MinimizedMembership()
        didDispatch = false; completeMembership = false
    }

    func run(display: String, snapshot: @escaping @MainActor () -> DesktopSnapshot?,
             refresh: @escaping @MainActor () async -> DesktopSnapshot?, visible: @escaping @MainActor () -> Bool) async {
        let token = UUID()
        generation = token
        updates?.finish()
        clear()
        currentSnapshot = snapshot; refreshSnapshot = refresh; self.visible = visible
        let (events, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = wake
        var nextRead: Task<Void, Never>?
        wake.yield(())
        let listener = NSWorkspace.shared.notificationCenter
        let notices = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                       NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification].map { name in
            listener.addObserver(forName: name, object: nil, queue: nil) { _ in wake.yield(()) }
        }
        defer {
            nextRead?.cancel()
            for notice in notices { listener.removeObserver(notice) }
            if generation == token {
                clear(); self.visible = nil; currentSnapshot = nil; refreshSnapshot = nil; updates = nil
            }
        }
        for await _ in events {
            guard generation == token, !Task.isCancelled else { return }
            // An observed native drag can start while the settled (slow) timer sleeps.
            // Select the next interval from this read, including all unavailable paths.
            nextRead?.cancel()
            defer {
                let delay: Duration = .milliseconds(ready ? 1800 : 250)
                nextRead = Task {
                    do { try await Task.sleep(for: delay) } catch { return }
                    wake.yield(())
                }
            }
            guard visible(), WindowContentPreview.sessionAvailable() else { clear(); continue }
            guard let sample = snapshot() else { ready = false; handoff = nil; minimize.stop(); continue }
            guard let scope = Home(sample, display) else {
                // The surface owns the read-only departing snapshot during brief catalog gaps.
                if sample.native?.windowLimitReached == true { ready = false; handoff = nil; minimize.stop() }
                else { clear() }
                continue
            }
            await observe(sample, scope: scope, token: token)
        }
    }

    private func observe(_ sample: DesktopSnapshot, scope: Home, token: UUID) async {
        let single = sample.displays.count == 1
        let raw = await Task.detached(priority: .utility) { AppleStageSystemRead.capture(singleDisplay: single) }.value
        guard generation == token, !Task.isCancelled, visible?() == true,
              scope == Home(currentSnapshot?(), scope.display) else { return }
        guard let raw else { minimizedMembership = MinimizedMembership(); ready = false; handoff = nil; return }
        // An asynchronous collector from before a selection may finish after the newer read.
        guard raw.timestamp > lastRead else { return }
        let ordinary = Self.roster(sample, display: scope.display, nativeID: String(scope.record))
        let all = Self.roster(sample, display: scope.display, nativeID: String(scope.record), includingMinimized: true)
        if scope != home || all.contains(where: { keys[$0.key] != nil && keys[$0.key] != $0.value }) {
            clear()
            home = scope
            mirror = AppleStageMirror(display: scope.screen, space: scope.record)
        }
        let minimized = Set(all.keys).subtracting(ordinary.keys)
        let items = AppleStageMirror.minimizedStripItems(in: raw, screen: scope.frame, owners: all.mapValues(\.pid), minimized: minimized)
        var observed = MinimizedMembership.Items()
        if sample.native?.catalogComplete == true {
            for (id, item) in items {
                if let key = all[id] { observed[key] = Set(item.compactMap { all[$0] }) }
            }
        }
        minimizedMembership.update(observed, at: raw.timestamp)
        let admitted = minimizedMembership.admitted
        let restoring = handoff?.restoringNativeMinimizedWindow
        let known = all.filter { ordinary[$0.key] != nil || admitted[$0.value] != nil || $0.value == restoring }
        latestSystem = raw
        lastRead = raw.timestamp
        keys = known
        minimize.update(targets: Array(all.values)) { [weak self] in self?.updates?.yield(()) }
        let transition = didDispatch
        didDispatch = false
        guard let reading = mirror?.read(raw, owners: known.mapValues(\.pid), screen: scope.frame, minimized: Set(admitted.keys.map(\.number)), transition: transition)
        else { ready = false; handoff = nil; return }
        completeMembership = reading.completeMembership
        let stable = reading.settled && !reading.contradictory
        // A partially classified scan can paint its last group but cannot attest that
        // every member followed a native focus. Reconsider when the catalog is whole.
        ready = stable && sample.native?.catalogComplete == true
        if let handoff, reading.contradictory || sample.native?.catalogComplete != true ||
            handoff.roster.contains(where: { group in group.members.contains { known[$0.number] != $0 } }) {
            self.handoff = nil
        }
        guard ready else {
            groups.removeAll { group in group.members.contains { known[$0.number] != $0 } }
            return
        }
        let next = reading.stages.compactMap { stage -> Group? in
            let members = stage.members.compactMap { known[$0] }
            guard !members.isEmpty, members.count == stage.members.count else { return nil }
            let stamp = members.map { "\($0.pid)-\($0.birth)-\($0.number)" }.sorted().joined(separator: ".")
            return Group(id: "\(scope.screen.uuidString)/\(scope.desktop.uuidString)/\(stamp)", current: stage.current, members: members, evidence: stage.evidence)
        }
        if groups != next { groups = next }
        if let lastMemberCycle, !next.contains(where: { $0.current && lastMemberCycle.matches($0) }) { self.lastMemberCycle = nil }
        if let handoff, !handoff.permits(next) { self.handoff = nil }
        lastChoice = lastChoice.filter { key, member in next.contains { $0.id == key && $0.members.contains(member) } }
        #if DEBUG
        guard completeMembership else { return }
        cycleTarget = AppleStageMergeFixture.cycleTarget
        AppleStageMergeFixture.offerFocusCycle(next) { [weak self] in
            guard let self else { return false }
            return self.completeMembership && self.ready && self.groups == next && self.handoff == nil && self.generation == token &&
                self.visible?() == true && scope == Home(self.currentSnapshot?(), scope.display)
        }
        AppleStageMergeFixture.nativeQualification(next) { [weak self] source, target in
            guard let self else { throw StageSwitchError.interrupted }
            try await self.merge(source, into: target) {
                self.generation == token && self.visible?() == true && self.handoff == nil &&
                    scope == Home(self.currentSnapshot?(), scope.display)
            }
        }
        #endif
    }

    static func roster(_ snapshot: DesktopSnapshot, display: String, nativeID: String, includingMinimized: Bool = false) -> [UInt32:DesktopWindowKey] {
        let candidates = snapshot.windows.compactMap { w -> DesktopWindowKey? in
            guard w.displayID == display, w.membership == .known(recordIDs: [nativeID]),
                  let m = w.metadata, m.fullScreen != true, includingMinimized || m.minimized != true,
                  m.minimized != true || (m.fullScreen == false && m.overviewOrdinaryRole == true),
                  m.overviewOrdinaryRole == true || w.canWitnessCurrentSpace else { return nil }
            return DesktopWindowKey(w)
        }
        return Dictionary(grouping: candidates, by: \.number).compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    var focusQualified: Bool { AppleStageProductAdmission.permits(.focus) || AppleStageMergeFixture.isRunning }
    func canFocus(_ group: Group) -> Bool {
        if AppleStageProductAdmission.permits(.focus) { return true }
        #if DEBUG
        if AppleStageMergeFixture.runsFocusCycle, group.members.first != cycleTarget { return false }
        #endif
        guard AppleStageMergeFixture.isRunning, let front = groups.first(where: \.current) else { return false }
        return AppleStageMergeFixture.permitsNativeFocus(Set(front.members), Set(group.members))
    }
    var mergeAvailable: Bool { handoff == nil && ready && (AppleStageMerge.isQualified || AppleStageMergeFixture.mergeEnabled) }


    func merge(_ source: Group, into destination: Group, current: @escaping @MainActor () -> Bool) async throws {
        guard mergeAvailable, completeMembership, source.id != destination.id, let scope = home, let refresh = refreshSnapshot,
              groups.contains(where: { $0.id == source.id }), groups.contains(where: { $0.id == destination.id })
        else { throw StageSwitchError.unavailable }
        let token = generation
        func allowed() -> Bool {
            current() && generation == token && visible?() == true && !Task.isCancelled &&
                WindowContentPreview.sessionAvailable() && StageManagerPreference.read() == true &&
                scope == Home(currentSnapshot?(), scope.display)
        }
        if !AppleStageMerge.isQualified {
            guard destination.current, AppleStageMergeFixture.canDrop(Set(source.members), Set(destination.members))
            else { throw StageSwitchError.unavailable }
        }
        if !destination.current {
            _ = try await choose(destination, window: nil, requireCompleteMembership: true, current: allowed)
        }
        guard allowed() else { throw StageSwitchError.interrupted }
        try await AppleStageMerge.perform(source: Set(source.members), destination: Set(destination.members), stillCurrent: allowed) {
            [weak self] remaining, expected in
            guard let self, allowed(), let snapshot = await refresh(), allowed(), scope == Home(snapshot, scope.display),
                  snapshot.native?.catalogComplete == true,
                  let display = snapshot.displays.first(where: { $0.id == scope.display }),
                  let usable = display.usable else { return nil }
            let prior = self.lastRead
            await self.observe(snapshot, scope: scope, token: token)
            guard allowed(), let system = self.latestSystem, system.timestamp > prior else { return nil }
            guard self.ready && self.completeMembership else {
                return .init(timestamp: system.timestamp, settled: false, current: [], strip: [], point: nil)
            }
            guard let active = self.groups.first(where: { $0.current }), let items = system.confirmedStrip(on: scope.frame) else { return nil }
            var strip = [Set<DesktopWindowKey>]()
            for item in items {
                let enrolled = Set(item.compactMap { self.keys[$0] })
                guard enrolled.count == item.count else { return nil }
                strip.append(enrolled)
            }
            let visible = CGRect(x: scope.frame.minX + usable.x, y: scope.frame.minY + usable.y,
                                 width: usable.width, height: usable.height)
            let point = self.mirror?.mergePoint(system: system, managed: Array(self.keys.keys), screen: scope.frame,
                visible: visible, source: Set(remaining.map(\.number)), destination: Set(expected.map(\.number)))
            return .init(timestamp: system.timestamp, settled: true, current: Set(active.members), strip: strip, point: point)
        }
    }

    struct Selection {
        let predecessor: UUID?
    }

    func acceptsSelection(_ group: Group) -> Bool { canFocus(group) && (ready || handoff?.includes(group) == true) }

    func selection(for group: Group) -> Selection? {
        guard canFocus(group), groups.contains(where: { $0.id == group.id }), let home, let snapshot = currentSnapshot?(),
              snapshot.native?.catalogComplete == true, home == Home(snapshot, home.display) else { return nil }
        if let handoff {
            guard handoff.includes(group), handoff.ownsForeground() else { self.handoff = nil; return nil }
            return Selection(predecessor: handoff.id)
        }
        return ready ? Selection(predecessor: nil) : nil
    }

    @discardableResult func choose(_ group: Group, window: DesktopWindowKey?, after predecessor: UUID? = nil, repeatCard: Bool = false, requireCompleteMembership: Bool = false,
                current: @escaping @MainActor () -> Bool) async throws -> AppleStageSelectionHandoff.Outcome {
        #if DEBUG
        let needsWholeRoster = requireCompleteMembership || AppleStageMergeFixture.runsFocusCycle
        #else
        let needsWholeRoster = requireCompleteMembership
        #endif
        let preceding = self.handoff
        guard canFocus(group), let scope = home, ready || (predecessor != nil && preceding?.id == predecessor),
              let refresh = refreshSnapshot, let original = groups.first(where: { $0.id == group.id }),
              Set(original.members) == Set(group.members) else { throw StageSwitchError.unavailable }
        let cycle = predecessor == nil ? lastMemberCycle : preceding?.memberCycle
        let next = repeatCard && window == nil ? cycle?.next(in: original, explicit: window,
            oneAtATime: AppleStageMemberCycle.oneAtATime(), completingPrevious: predecessor != nil) : nil
        guard let target = window ?? next ?? lastChoice[group.id] ?? original.members.first,
              original.members.contains(target) else { throw StageSwitchError.unavailable }
        let minimizedItem = minimizedMembership.admitted[target]
        var originalAX: AppleStageFocus?
        if let minimizedItem {
            guard ready, original.evidence == .nativeStripItem, minimizedItem == Set(original.members),
                  let witness = AppleStageFocus(target, display: scope.display, record: String(scope.record),
                                                uuid: scope.desktop, initiallyMinimized: true)
            else { throw StageSwitchError.unavailable }
            originalAX = witness
        }
        let token = generation, hid = NativeSelectionPermit.inputCounters()
        var watcher: AppleFocusHandoff?
        var transferred = false
        if predecessor == nil {
            guard let direct = AppleFocusHandoff(target: target) else { throw StageSwitchError.interrupted }
            watcher = direct
        }
        defer { if !transferred { watcher?.stop() } }
        func allowed() -> Bool {
            canFocus(group) && generation == token && current() && visible?() == true &&
                (watcher?.current() ?? preceding?.ownsForeground() ?? false) && WindowContentPreview.sessionAvailable() &&
                StageManagerPreference.read() == true && NativeSelectionPermit.inputCounters() == hid &&
                (next == nil || AppleStageMemberCycle.oneAtATime()) &&
                !Task.isCancelled && NSEvent.pressedMouseButtons == 0 && scope == Home(currentSnapshot?(), scope.display)
        }
        if let predecessor {
            guard let preceding, preceding.id == predecessor, preceding.includes(group) else { throw StageSwitchError.interrupted }
            var samples = AppleStageSelectionHandoff.Confirmations(after: lastRead)
            while true {
                guard allowed(), self.handoff?.id == predecessor, preceding.includes(group),
                      let next = await refresh(), scope == Home(next, scope.display), allowed() else { throw StageSwitchError.interrupted }
                await observe(next, scope: scope, token: token)
                guard allowed(), self.handoff?.id == predecessor else { throw StageSwitchError.interrupted }
                if samples.record(lastRead, exact: ready && preceding.focused(groups)) { break }
                try await Task.sleep(for: .milliseconds(80))
            }
            guard let next = AppleFocusHandoff(target: target) else { throw StageSwitchError.interrupted }
            watcher = next
            guard preceding.ownsForeground() else { throw StageSwitchError.interrupted }
        }
        guard allowed(), let fresh = await refresh(), scope == Home(fresh, scope.display), allowed() else { throw StageSwitchError.interrupted }
        await observe(fresh, scope: scope, token: token)
        guard allowed(), ready, !needsWholeRoster || completeMembership,
              groups.contains(where: { $0.id == group.id }), keys[target.number] == target,
              minimizedMembership.admitted[target] == minimizedItem,
              let focus = AppleStageFocus(target, display: scope.display, record: String(scope.record),
                                           uuid: scope.desktop, initiallyMinimized: minimizedItem != nil),
              originalAX.map({ focus.matches($0) }) ?? true else {
            throw StageSwitchError.unavailable
        }
        if let predecessor, self.handoff?.id != predecessor || preceding?.focused(groups) != true {
            throw StageSwitchError.interrupted
        }
        if let next {
            guard let active = groups.first(where: \.current),
                  cycle?.next(in: active, explicit: nil, oneAtATime: AppleStageMemberCycle.oneAtATime(),
                              completingPrevious: false) == next else { throw StageSwitchError.interrupted }
        } else if repeatCard, window == nil, AppleStageMemberCycle.oneAtATime(),
                  let active = groups.first(where: \.current), active.id == group.id, let cycle, cycle.matches(active) {
            // Apple may expose only the most recent document. Without another proven member
            // a repeat click must leave its current native focus and document alone.
            if predecessor != nil { self.handoff = nil; lastMemberCycle = cycle }
            return .unchanged
        }
        let switchesStage = !groups.contains { $0.id == group.id && $0.current }
        guard let watcher else { throw StageSwitchError.interrupted }
        self.handoff = nil
        lastMemberCycle = nil
        try focus.perform(current: allowed)
        didDispatch = switchesStage
        let memberCycle = AppleStageMemberCycle(group: original, selected: target, previous: cycle, focused: { focus.confirmed() })
        let dispatched = AppleStageSelectionHandoff(roster: groups, target: group, originalMembershipConfirmed: completeMembership, focusMatches: { focus.confirmed() },
            ownsForeground: { watcher.current() }, release: { watcher.stop() },
            deadline: .now.advanced(by: .seconds(4)), memberCycle: repeatCard ? memberCycle : nil,
            restoringNativeMinimizedWindow: minimizedItem == nil ? nil : target)
        self.handoff = dispatched
        transferred = true
        ready = false
        updates?.yield(())
        let deadline = ProcessInfo.processInfo.systemUptime + 4.0
        var confirmations = AppleStageSelectionHandoff.OutcomeConfirmations(after: lastRead)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard allowed(), let sample = await refresh(), scope == Home(sample, scope.display), allowed() else { throw StageSwitchError.interrupted }
            await observe(sample, scope: scope, token: token)
            guard allowed(), self.handoff?.id == dispatched.id else { throw StageSwitchError.interrupted }
            let exact = ready && dispatched.focused(groups)
            #if DEBUG
            if AppleStageMergeFixture.isRunning {
                AppleStageMergeFixture.noteFocus(groups, strip: latestSystem?.confirmedStrip(on: scope.frame), time: lastRead, exact: exact && completeMembership && dispatched.originalMembershipConfirmed)
            }
            #endif
            if let outcome = confirmations.record(lastRead, focused: exact,
                    preserved: dispatched.originalMembershipConfirmed && completeMembership),
               !needsWholeRoster || outcome == .preservedRoster {
                self.handoff = nil
                lastChoice[group.id] = target
                lastMemberCycle = repeatCard ? memberCycle : nil
                #if DEBUG
                if outcome == .preservedRoster { AppleStageMergeFixture.finishedFocus(target) }
                #endif
                return outcome
            }
        }
        throw StageSwitchError.unavailable
    }
}
