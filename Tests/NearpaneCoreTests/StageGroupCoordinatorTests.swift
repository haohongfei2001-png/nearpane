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
    var afterWrite: (() throws -> Void)?
    func read(_ scope: StageGroupScope) throws -> StageWindowSample {
        sequence += 1
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
        await #expect(throws: StageSwitchError.incomplete) { try await engine.activate(groups[1].id, member: nil, in: runtime.scope, consent: true, session: runtime) }
        #expect(runtime.writes.isEmpty)
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
