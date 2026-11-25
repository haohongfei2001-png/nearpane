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
    }
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
    private(set) var ready = false
    @ObservationIgnored private var home: Home?
    @ObservationIgnored private var mirror: AppleStageMirror?
    @ObservationIgnored private var keys = [UInt32:DesktopWindowKey]()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var didDispatch = false
    @ObservationIgnored private let minimize = AppleStageMinimizeObserver()
    @ObservationIgnored private var lastChoice: [String:DesktopWindowKey] = [:]
    @ObservationIgnored private var currentSnapshot: (@MainActor () -> DesktopSnapshot?)?
    @ObservationIgnored private var refreshSnapshot: (@MainActor () async -> DesktopSnapshot?)?
    @ObservationIgnored private var visible: (@MainActor () -> Bool)?
    @ObservationIgnored private var updates: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var latestSystem: AppleStageSystemRead?
    @ObservationIgnored private var lastRead: UInt64 = 0

    func matches(_ snapshot: DesktopSnapshot, display: String) -> Bool {
        guard let home else { return false }
        return home == Home(snapshot, display)
    }
    private func clear() {
        minimize.stop()
        if !groups.isEmpty { groups = [] }
        ready = false; keys = [:]; lastChoice = [:]; mirror = nil; home = nil; lastRead = 0; latestSystem = nil
        didDispatch = false
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
        let clock = Task { @MainActor in
            while !Task.isCancelled {
                wake.yield(())
                do { try await Task.sleep(for: .milliseconds(ready ? 1800 : 250)) } catch { break }
            }
        }
        let listener = NSWorkspace.shared.notificationCenter
        let notices = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                       NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification].map { name in
            listener.addObserver(forName: name, object: nil, queue: nil) { _ in wake.yield(()) }
        }
        defer {
            clock.cancel()
            for notice in notices { listener.removeObserver(notice) }
            if generation == token {
                clear(); self.visible = nil; currentSnapshot = nil; refreshSnapshot = nil; updates = nil
            }
        }
        for await _ in events {
            guard generation == token, !Task.isCancelled else { return }
            guard visible(), WindowContentPreview.sessionAvailable() else { clear(); continue }
            guard let sample = snapshot() else { ready = false; minimize.stop(); continue }
            guard let scope = Home(sample, display) else {
                // The surface owns the read-only departing snapshot during brief catalog gaps.
                if sample.native?.windowLimitReached == true { ready = false; minimize.stop() }
                else { clear() }
                continue
            }
            await observe(sample, scope: scope, token: token)
        }
    }

    private func observe(_ sample: DesktopSnapshot, scope: Home, token: UUID) async {
        let known = Self.roster(sample, display: scope.display, nativeID: String(scope.record))
        let single = sample.displays.count == 1
        let raw = await Task.detached(priority: .utility) { AppleStageSystemRead.capture(singleDisplay: single) }.value
        guard generation == token, !Task.isCancelled, visible?() == true,
              scope == Home(currentSnapshot?(), scope.display) else { return }
        guard let raw else { ready = false; return }
        // An asynchronous collector from before a selection may finish after the newer read.
        guard raw.timestamp > lastRead else { return }
        if scope != home || known.contains(where: { keys[$0.key] != nil && keys[$0.key] != $0.value }) {
            clear()
            home = scope
            mirror = AppleStageMirror(display: scope.screen, space: scope.record)
        }
        latestSystem = raw
        lastRead = raw.timestamp
        keys = known
        minimize.update(targets: Array(Self.roster(sample, display: scope.display, nativeID: String(scope.record), includingMinimized: true).values)) { [weak self] in self?.updates?.yield(()) }
        let transition = didDispatch
        didDispatch = false
        guard let reading = mirror?.read(raw, managed: known.keys.sorted(), screen: scope.frame, transition: transition)
        else { ready = false; return }
        let stable = reading.settled && !reading.contradictory
        // A partially classified scan can paint its last group but cannot attest that
        // every member followed a native focus. Reconsider when the catalog is whole.
        ready = stable && sample.native?.catalogComplete == true
        guard ready else {
            groups.removeAll { group in group.members.contains { known[$0.number] != $0 } }
            return
        }
        let next = reading.stages.compactMap { stage -> Group? in
            let members = stage.members.compactMap { known[$0] }
            guard !members.isEmpty, members.count == stage.members.count else { return nil }
            let stamp = members.map { "\($0.pid)-\($0.birth)-\($0.number)" }.sorted().joined(separator: ".")
            return Group(id: "\(scope.screen.uuidString)/\(scope.desktop.uuidString)/\(stamp)", current: stage.current, members: members)
        }
        if groups != next { groups = next }
        lastChoice = lastChoice.filter { key, member in next.contains { $0.id == key && $0.members.contains(member) } }
    }

    static func roster(_ snapshot: DesktopSnapshot, display: String, nativeID: String, includingMinimized: Bool = false) -> [UInt32:DesktopWindowKey] {
        let candidates = snapshot.windows.compactMap { w -> DesktopWindowKey? in
            guard w.displayID == display, w.membership == .known(recordIDs: [nativeID]),
                  let m = w.metadata, m.fullScreen != true, includingMinimized || m.minimized != true,
                  m.overviewOrdinaryRole == true || w.canWitnessCurrentSpace else { return nil }
            return DesktopWindowKey(w)
        }
        return Dictionary(grouping: candidates, by: \.number).compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    var mergeAvailable: Bool { ready && AppleStageMerge.isQualified }

    func merge(_ source: Group, into destination: Group, current: @escaping @MainActor () -> Bool) async throws {
        guard mergeAvailable, source.id != destination.id, let scope = home, let refresh = refreshSnapshot,
              groups.contains(where: { $0.id == source.id }), groups.contains(where: { $0.id == destination.id })
        else { throw StageSwitchError.unavailable }
        let token = generation
        func allowed() -> Bool {
            current() && generation == token && visible?() == true && !Task.isCancelled &&
                WindowContentPreview.sessionAvailable() && StageManagerPreference.read() == true &&
                scope == Home(currentSnapshot?(), scope.display)
        }
        if !destination.current { try await choose(destination, window: nil, current: allowed) }
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
            guard self.ready else {
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

    func choose(_ group: Group, window: DesktopWindowKey?, current: @escaping @MainActor () -> Bool) async throws {
        guard let scope = home, ready, let refresh = refreshSnapshot, let target = window ?? lastChoice[group.id] ?? group.members.first,
              group.members.contains(target), let original = groups.first(where: { $0.id == group.id }),
              Set(original.members) == Set(group.members) else { throw StageSwitchError.unavailable }
        let token = generation, hid = NativeSelectionPermit.inputCounters()
        func allowed() -> Bool {
            generation == token && current() && visible?() == true && WindowContentPreview.sessionAvailable() &&
                StageManagerPreference.read() == true && NativeSelectionPermit.inputCounters() == hid &&
                !Task.isCancelled && NSEvent.pressedMouseButtons == 0 && scope == Home(currentSnapshot?(), scope.display)
        }
        guard allowed(), let fresh = await refresh(), scope == Home(fresh, scope.display), allowed() else { throw StageSwitchError.interrupted }
        await observe(fresh, scope: scope, token: token)
        guard allowed(), ready, groups.contains(where: { $0.id == group.id }), keys[target.number] == target,
              let focus = AppleStageFocus(target, display: scope.display, record: String(scope.record), uuid: scope.desktop) else {
            throw StageSwitchError.unavailable
        }
        let switchesStage = !groups.contains { $0.id == group.id && $0.current }
        try focus.perform(current: allowed)
        didDispatch = switchesStage
        ready = false
        updates?.yield(())
        let deadline = ProcessInfo.processInfo.systemUptime + 4.0
        var confirmations = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard allowed(), let sample = await refresh(), scope == Home(sample, scope.display), allowed() else { throw StageSwitchError.interrupted }
            await observe(sample, scope: scope, token: token)
            guard allowed() else { throw StageSwitchError.interrupted }
            if ready && groups.contains(where: { $0.current && Set($0.members) == Set(group.members) }) && focus.confirmed() {
                confirmations += 1
                if confirmations == 2 { lastChoice[group.id] = target; return }
            } else { confirmations = 0 }
        }
        throw StageSwitchError.unavailable
    }
}
