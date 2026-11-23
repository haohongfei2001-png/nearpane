import Foundation
import Testing
@testable import NearpaneCore

@MainActor private final class Session: StageWindowSession {
    var generation = UUID(), sequence: UInt64 = 0
    var qualifiedHiddenState: StageWindowState.Visibility? = .parked
    let evidence = UUID()
    var engineOwner: StageEngineOwner? {
        let env = StageEngineEnvironment(osBuild:"26A428", engineRevision:String(repeating:"1",count:40), hostCDHash:String(repeating:"2",count:40),
            hardware:"test", topology:"test", windowClass:"ordinary-standard", sipEnabled:true)
        return .init(qualification:.init(backend:.corner, environment:env, evidence:evidence, checks:[:]), generation:generation)
    }
    let scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
    let work = SurfaceRect(width: 900, height: 700)
    var windows = [NativeSpaceWindow: StageWindowState](), focus: NativeSpaceWindow?
    var foreignFocusScope: StageGroupScope?
    var writes = [(StageWindowAction, NativeSpaceWindow)]()
    var excluded = Set<NativeSpaceWindow>()
    func mayManage(_ state: StageWindowState) -> Bool { !excluded.contains(state.window) }
    var afterWrite: (() throws -> Void)?
    var beforeRead: (() -> Void)?
    func read(_ scope: StageGroupScope) throws -> StageWindowSample {
        sequence += 1
        beforeRead?()
        return .init(scope: self.scope, generation: generation, sequence: sequence, workArea: work,
                     windows: windows, focus: focus, nativeID: 4, foreignFocusScope: foreignFocusScope)
    }
    func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) throws {
        guard before == windows[before.window], self.generation == generation, self.scope == scope else { throw StageSwitchError.interrupted }
        writes.append((action, before.window))
        switch action {
        case .hide: windows[before.window]?.visibility = .parked
        case .show: windows[before.window]?.visibility = .visible
        case .place(let r): windows[before.window]?.frame = r
        case .focus: focus = before.window
        }
        try afterWrite?()
    }
}

@Suite @MainActor struct StageGroupCoordinatorTests {
    private func fixture() throws -> (URL, StageGroupStore, StageGroupCoordinator, Session, [StageGroupDirectory.Group]) {
        let profile = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let store = StageGroupStore(profile: profile), runtime = Session()
        for n in 1...5 {
            let id = NativeSpaceWindow(pid: n == 2 ? 11 : Int32(10+n), birth: 100, number: UInt32(n))
            let frame = SurfaceRect(x: Double(n*50), y: 30, width: 200, height: 120)
            let live = StageGroupWindow(display: runtime.scope.display, identity: id, lifetime: UUID(),
                                        layout: StageGroupWindow.relativeFrame(frame, in: runtime.work), nativeSpace: runtime.scope.nativeSpace)
            runtime.windows[id] = .init(window: id, lifetime: live.lifetime, frame: frame, visibility: n == 5 ? .minimized : .visible)
            if n <= 3 { try store.observe([live]) }
            if n == 1 { runtime.focus = id }
        }
        return (profile, store, try StageGroupCoordinator(store: store, profile: profile), runtime, store.groups(in: runtime.scope))
    }

    @Test func threeGroupsRequireConsentFocusOwnershipAndFullReadback() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let untouched = runtime.windows.filter { $0.key.number >= 4 }
        await #expect(throws: StageSwitchError.unavailable) { try await engine.activate(groups[0].id, member: nil, in: runtime.scope, consent: false, session: runtime) }
        runtime.focus = untouched.keys.first { $0.number == 4 }
        await #expect(throws: StageSwitchError.incomplete) { try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime) }
        #expect(runtime.writes.isEmpty)
        runtime.focus = groups[0].members[0].windowHint
        for i in [0,1,2,0] {
            try await engine.activate(groups[i].id, member: nil, in: runtime.scope, consent: true, session: runtime)
            let id = groups[i].members[0].windowHint
            #expect(runtime.focus == id && runtime.windows[id]?.visibility == .visible)
            #expect(runtime.windows.filter { $0.key != id && $0.key.number <= 3 }.values.allSatisfy { $0.visibility == .parked })
            #expect(runtime.windows.filter { $0.key.number >= 4 } == untouched)
            #expect(store.activeGroup(in: runtime.scope) == groups[i].id)
        }
        #expect(!engine.requiresRecovery)
    }

    @Test func switchAwayAndBackPreservesBothManuallyMovedFramesOfTheComposite() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let a = groups[0].members[0], b = groups[1].members[0], other = groups[2]
        func live(_ m: StageGroupDirectory.Member) throws -> StageGroupWindow {
            let w = try #require(runtime.windows[m.windowHint])
            return .init(display: runtime.scope.display, identity: w.window, lifetime: w.lifetime,
                         layout: m.layout, nativeSpace: runtime.scope.nativeSpace)
        }
        try store.join(try live(b), to: try live(a))
        let group = try #require(store.groups(in: runtime.scope).first { $0.members.count == 2 })
        try store.rename(group, in: runtime.scope, to: "两份文档")
        try await engine.activate(group.id, member: a.id, in: runtime.scope, consent: true, session: runtime)
        let left = SurfaceRect(x: 21, y: 34, width: 420, height: 510)
        let right = SurfaceRect(x: 461, y: 54, width: 376, height: 482)
        runtime.windows[a.windowHint]?.frame = left
        runtime.windows[b.windowHint]?.frame = right
        let bystanders = runtime.windows.filter { $0.key.number > 3 }
        try await engine.activate(other.id, member: nil, in: runtime.scope, consent: true, session: runtime)
        let saved = try #require(StageGroupStore(profile: p).groups(in: runtime.scope).first { $0.id == group.id })
        #expect(saved.name == "两份文档" && saved.members.map(\.layout) ==
                [StageGroupWindow.relativeFrame(left, in: runtime.work), StageGroupWindow.relativeFrame(right, in: runtime.work)])
        runtime.writes.removeAll()
        try await engine.activate(group.id, member: b.id, in: runtime.scope, consent: true, session: runtime)
        #expect(runtime.windows[a.windowHint]?.frame == left && runtime.windows[b.windowHint]?.frame == right)
        #expect(!runtime.writes.contains { if case .place = $0.0 { true } else { false } })
        #expect(runtime.windows.filter { $0.key.number > 3 } == bystanders && runtime.focus == b.windowHint)
    }

    @Test func anUnconfirmedHideNeverPublishesTheDepartingLayout() async throws {
        let (p, _, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let a = groups[0].members[0]
        runtime.windows[a.windowHint]?.frame.x += 150
        runtime.afterWrite = { [unowned runtime] in
            if case .hide? = runtime.writes.last?.0 { runtime.generation = UUID() }
        }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(StageGroupStore(profile: p).groups(in: runtime.scope).first?.members.first?.layout == a.layout)
        #expect(runtime.writes.filter { $0.0 == .hide }.count == 1)
    }

    @Test func selectingTheAlreadyVisibleSingletonKeepsItsCurrentFrameAndDoesNotDispatch() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let group = groups[0], a = group.members[0]
        try await engine.activate(group.id, member: a.id, in: runtime.scope, consent: true, session: runtime)
        let moved = SurfaceRect(x: 73, y: 59, width: 518, height: 408)
        runtime.windows[a.windowHint]?.frame = moved
        runtime.writes.removeAll()
        try await engine.activate(group.id, member: a.id, in: runtime.scope, consent: true, session: runtime)
        #expect(runtime.writes.isEmpty && runtime.windows[a.windowHint]?.frame == moved)
        #expect(store.groups(in: runtime.scope).first?.members.first?.layout == StageGroupWindow.relativeFrame(moved, in: runtime.work))
    }

    @Test func firstClickFocusesSelectedGroupBeforeHidingOutgoingWindow() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let other = StageGroupWindow(display: UUID(), identity: .init(pid: 14, birth: 101, number: 13),
                                     lifetime: UUID(), nativeSpace: UUID())
        runtime.afterWrite = { try store.observe([other], preserving: runtime.scope.display) }
        try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        #expect(runtime.writes.first?.0 == .focus && runtime.writes.first?.1 == groups[1].members[0].windowHint)
        #expect(store.activeGroup(in: runtime.scope) == groups[1].id)
        #expect(store.groups(on: other.display).first?.members.first?.windowHint == other.identity)
        #expect(!engine.requiresRecovery)
    }

    @Test func supersededLastReadCannotPublishLayoutAndNextSelectionCanProceed() async throws {
        let (p, _, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let a = groups[0], member = a.members[0]
        try await engine.activate(a.id, member: nil, in: runtime.scope, consent: true, session: runtime)
        runtime.windows[member.windowHint]?.frame.x += 48
        runtime.writes.removeAll()
        let original = StageGroupStore(profile: p).groups(in: runtime.scope)
        var reads = 0
        runtime.beforeRead = { reads += 1 }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(a.id, member: nil, in: runtime.scope, consent: true, session: runtime,
                                      current: { reads < 5 })
        }
        #expect(reads == 5 && runtime.writes.isEmpty && !engine.requiresRecovery)
        #expect(StageGroupStore(profile: p).groups(in: runtime.scope) == original)
        runtime.beforeRead = nil
        try await engine.activate(groups[2].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        #expect(StageGroupStore(profile: p).activeGroup(in: runtime.scope) == groups[2].id)
    }

    @Test func supersededAfterFocusDoesNotHideOrRefocusUnasked() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        var current = true
        runtime.afterWrite = { current = false }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime,
                                      current: { current })
        }
        #expect(runtime.writes.map(\.0) == [.focus] && runtime.focus == groups[1].members[0].windowHint)
        #expect(store.activeGroup(in: runtime.scope) == nil)
        #expect(try StageGroupCoordinator(store: store, profile: p).requiresRecovery)
    }

    @Test func focusCannotTakeOwnershipOfUserGeometry() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let target = groups[1].members[0].windowHint
        runtime.afterWrite = { [unowned runtime] in
            if runtime.writes.last?.0 == .focus { runtime.windows[target]?.frame.x += 30 }
        }
        await #expect(throws: StageSwitchError.incomplete) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.map(\.0) == [.focus] && store.activeGroup(in: runtime.scope) == nil && engine.requiresRecovery)
    }

    @Test func lossOfAnIndividualWindowLeaseStopsEvenWhenItsGeometryIsUnchanged() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let target = groups[1].members[0].windowHint
        runtime.afterWrite = { [unowned runtime] in runtime.excluded.insert(target) }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.map(\.0) == [.focus] && engine.requiresRecovery && store.activeGroup(in: runtime.scope) == nil)
    }

    @Test func changedDisplayOfFocusCannotPassTheBackendStartReadback() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let other = StageGroupScope(display: UUID(), nativeSpace: UUID())
        runtime.beforeRead = { [unowned runtime] in
            if runtime.sequence == 2 { runtime.foreignFocusScope = other }
        }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.isEmpty && !engine.requiresRecovery && store.activeGroup(in: runtime.scope) == nil)
    }

    @Test func movingParkedWindowBetweenReadbacksLeavesHideUnconfirmed() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        var postHideReads = 0
        runtime.beforeRead = { [unowned runtime] in
            if let (action, window) = runtime.writes.last, action == .hide {
                postHideReads += 1
                if postHideReads == 2 { runtime.windows[window]?.frame.y += 12 }
            }
        }
        await #expect(throws: StageSwitchError.incomplete) {
            try await engine.activate(groups[0].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.map(\.0) == [.hide] && store.activeGroup(in: runtime.scope) == nil && engine.requiresRecovery)
    }

    @Test func focusTakeoverAfterHideNeverRefocusesOrCommitsTheSwitch() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let user = try #require(runtime.windows.keys.first { $0.number == 4 })
        runtime.afterWrite = { runtime.focus = user }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[0].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.focus == user && runtime.writes.count == 1 && engine.requiresRecovery)
        #expect(store.activeGroup(in: runtime.scope) == nil)
    }

    @Test func unknownAfterIssuedIsDurableAndNeverReplayed() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        runtime.afterWrite = { throw StageSwitchError.interrupted }
        await #expect(throws: StageSwitchError.self) { try await engine.activate(groups[0].id, member: nil, in: runtime.scope, consent: true, session: runtime) }
        let restarted = try StageGroupCoordinator(store: store, profile: p)
        #expect(restarted.requiresRecovery && store.activeGroup(in: runtime.scope) == nil && runtime.writes.count == 1)
        await #expect(throws: StageSwitchError.recoveryRequired) { try await restarted.recover(runtime) }
        #expect(runtime.writes.count == 1)
    }

    @Test func groupSelectionUsesItsLastExactMemberAndPreservesSiblingFocusChoices() async throws {
        let (profile, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: profile) }
        func live(_ member: StageGroupDirectory.Member) throws -> StageGroupWindow {
            let s = try #require(runtime.windows[member.windowHint])
            return .init(display: runtime.scope.display, identity: s.window, lifetime: s.lifetime, nativeSpace: runtime.scope.nativeSpace)
        }
        let a = groups[0].members[0], b = groups[1].members[0]
        try store.join(live(b), to: live(a))
        let both = try #require(store.groups(in: runtime.scope).first { $0.members.count == 2 })
        try await engine.activate(both.id, member: b.id, in: runtime.scope, consent: true, session: runtime)
        try await engine.activate(groups[2].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        let saved = try #require(store.groups(in: runtime.scope).first { $0.id == both.id })
        #expect(saved.focusMember()?.id == b.id && saved.focusMember(requested: UUID()) == nil)
        try await engine.activate(both.id, member: nil, in: runtime.scope, consent: true, session: runtime)
        #expect(runtime.focus == b.windowHint && runtime.windows[a.windowHint]?.visibility == .visible &&
                runtime.windows[b.windowHint]?.visibility == .visible && runtime.windows[groups[2].members[0].windowHint]?.visibility == .parked)
    }

    @Test(arguments: [1, 3]) func userFocusBetweenPrimitivesOrAtFinalReadSurvivesRecovery(_ boundary: Int) async throws {
        let (profile, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: profile) }
        let bystander = try #require(runtime.windows.keys.first { $0.number == 4 })
        var readsAfterWrite = 0
        runtime.beforeRead = { [unowned runtime] in
            guard runtime.writes.count == boundary else { return }
            readsAfterWrite += 1
            if readsAfterWrite == 3 { runtime.focus = bystander }
        }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.count == boundary && runtime.focus == bystander && store.activeGroup(in: runtime.scope) == nil)
        let restarted = try StageGroupCoordinator(store: store, profile: profile)
        #expect(restarted.requiresRecovery)
        await #expect(throws: StageSwitchError.recoveryRequired) { try await restarted.recover(runtime) }
        #expect(runtime.writes.count == boundary && runtime.focus == bystander)
    }

    @Test func reservedMemberProtectsWholeCompositeWhileOtherGroupsSwitch() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        let protected = groups[2].members[0].windowHint
        let sibling = try #require(runtime.windows.values.first { $0.window.number == 4 })
        func live(_ state: StageWindowState) -> StageGroupWindow {
            .init(display: runtime.scope.display, identity: state.window, lifetime: state.lifetime, nativeSpace: runtime.scope.nativeSpace)
        }
        try store.observe([live(sibling)])
        try store.join(live(sibling), to: live(try #require(runtime.windows[protected])))
        runtime.excluded = [protected]
        let composite = try #require(store.groups(in: runtime.scope).first { $0.members.count == 2 })
        let before = runtime.windows
        await #expect(throws: StageSwitchError.incomplete) {
            try await engine.activate(composite.id, member: nil, in: runtime.scope, consent: true, session: runtime)
        }
        #expect(runtime.writes.isEmpty)
        for index in [0, 1, 0] {
            try await engine.activate(groups[index].id, member: nil, in: runtime.scope, consent: true, session: runtime)
            #expect(store.activeGroup(in: runtime.scope) == groups[index].id)
            #expect(runtime.windows[protected] == before[protected] && runtime.windows[sibling.window] == sibling)
        }
        #expect(runtime.writes.allSatisfy { ![protected, sibling.window].contains($0.1) })
    }

    @Test func latePhysicalChangeProtectsBystandersAndTheLastVerifiedGroup() async throws {
        let (p, store, engine, runtime, groups) = try fixture()
        defer { try? FileManager.default.removeItem(at: p) }
        try await engine.activate(groups[0].id, member: nil, in: runtime.scope, consent: true, session: runtime)
        let userWindow = try #require(runtime.windows.keys.first { $0.number == 4 })
        runtime.afterWrite = {
            runtime.generation = UUID()
            runtime.windows[userWindow]?.frame.x = 317
            engine.invalidate()
        }
        await #expect(throws: StageSwitchError.self) { try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime) }
        let count = runtime.writes.count
        await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.recover(runtime) }
        #expect(runtime.writes.count == count && runtime.windows[userWindow]?.frame.x == 317)
        #expect(store.activeGroup(in: runtime.scope) == groups[0].id)
    }
}
