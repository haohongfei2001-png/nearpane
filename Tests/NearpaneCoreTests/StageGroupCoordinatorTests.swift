import Foundation
import Testing
@testable import NearpaneCore

@MainActor private final class Session: StageWindowSession {
    var generation = UUID(), sequence: UInt64 = 0
    var qualifiedHiddenState: StageWindowState.Visibility? = .minimized
    let scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
    let work = SurfaceRect(width: 900, height: 700)
    var windows = [NativeSpaceWindow: StageWindowState](), focus: NativeSpaceWindow?
    var writes = [(StageWindowAction, NativeSpaceWindow)]()
    var excluded = Set<NativeSpaceWindow>()
    func mayManage(_ state: StageWindowState) -> Bool { !excluded.contains(state.window) }
    var afterWrite: (() throws -> Void)?
    var beforeRead: (() -> Void)?
    func read(_ scope: StageGroupScope) throws -> StageWindowSample {
        sequence += 1
        beforeRead?()
        return .init(scope: self.scope, generation: generation, sequence: sequence, workArea: work, windows: windows, focus: focus)
    }
    func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) throws {
        guard before == windows[before.window], self.generation == generation, self.scope == scope else { throw StageSwitchError.interrupted }
        writes.append((action, before.window))
        switch action {
        case .hide: windows[before.window]?.visibility = .minimized
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
            #expect(runtime.windows.filter { $0.key != id && $0.key.number <= 3 }.values.allSatisfy { $0.visibility == .minimized })
            #expect(runtime.windows.filter { $0.key.number >= 4 } == untouched)
            #expect(store.activeGroup(in: runtime.scope) == groups[i].id)
        }
        #expect(!engine.requiresRecovery)
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
