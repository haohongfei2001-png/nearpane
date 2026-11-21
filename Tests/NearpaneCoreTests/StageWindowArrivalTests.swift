import Foundation
import Testing
@testable import NearpaneCore

@MainActor private final class ArrivalWindowProbe: StageEngineWindowWitness, StageEngineTransport {
    func mayManage(_ state: StageWindowState) -> Bool { true }
    var sample: StageWindowSample
    private(set) var calls = 0
    init(_ sample: StageWindowSample) { self.sample = sample }
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample { sample }
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool { true }
    func ordinary(_ command: StageWindowCommand, valid: @escaping @MainActor () -> Bool) async throws { calls += 1 }
    func submit(_ op: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) throws -> StageEngineReply {
        calls += 1; throw StageSwitchError.unavailable
    }
    func start(_ owner: StageEngineOwner, nativeID: UInt64) async throws { calls += 1 }
    func prepareHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws { calls += 1 }
    func verified(_ command: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws { calls += 1 }
    func revoke() {}
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply {
        calls += 1; throw StageSwitchError.unavailable
    }
    func close() async -> Bool { true }
}

@Suite @MainActor struct StageWindowArrivalTests {
    let scope = StageGroupScope(display: UUID(), nativeSpace: UUID()), epoch = UUID()
    let source = NativeSpaceWindow(pid: 401, birth: 3_000, number: 1)
    let sibling = NativeSpaceWindow(pid: 401, birth: 3_000, number: 2)
    let created = NativeSpaceWindow(pid: 401, birth: 3_000, number: 3)
    let work = SurfaceRect(x: 0, y: 23, width: 1200, height: 720)

    func state(_ key: NativeSpaceWindow) -> StageWindowState {
        .init(window: key, lifetime: UUID(), frame: .init(x: 40, y: 50, width: 600, height: 400), visibility: .visible)
    }

    func sample(_ sequence: UInt64, _ windows: [StageWindowState], _ focus: NativeSpaceWindow?,
                scope other: StageGroupScope? = nil, epoch otherEpoch: UUID? = nil, native: UInt64 = 5) -> StageWindowSample {
        .init(scope: other ?? scope, generation: otherEpoch ?? epoch, sequence: sequence, workArea: work,
              windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.window, $0) }), focus: focus, nativeID: native)
    }

    func groupWindow(_ s: StageWindowState) -> StageGroupWindow {
        .init(display: scope.display, identity: s.window, lifetime: s.lifetime, nativeSpace: scope.nativeSpace)
    }

    func activate(_ store: StageGroupStore, _ existing: [StageWindowState]) throws -> StageGroupStore.ArrivalBaseline {
        try store.observe(existing.map(groupWindow))
        let group = try #require(store.groups(in: scope).first(where: { $0.members.first?.windowHint == source }))
        let member = try #require(group.members.first)
        try store.commitActivity(group.id, preferred: member.id, in: scope, expected: store.directory)
        return try #require(store.arrivalBaseline(sample(1, existing, source)))
    }

    @Test func confirmedEventPreservesSelectionAndPersistsWithoutRestoringAuthority() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StageGroupStore(profile: dir)
        let old = [state(source), state(sibling)], target = state(created)
        let baseline = try activate(store, old)
        let selected = store.groups(in: scope).first?.selectedMember
        let after = old + [target]
        try store.recordCreatedWindow(created, since: baseline, first: sample(2, after, created), second: sample(3, after, created))
        let active = try #require(store.groups(in: scope).first { $0.id == baseline.group })
        #expect(active.verifiedActive == true && active.selectedMember == selected)
        #expect(active.members.map(\.windowHint) == [source, created])
        #expect(active.members.last?.layout == StageGroupWindow.relativeFrame(target.frame, in: work))
        #expect(store.groups(in: scope).last?.members.map(\.windowHint) == [sibling])
        let reopened = StageGroupStore(profile: dir)
        #expect(reopened.directory == store.directory)
        #expect(reopened.arrivalBaseline(sample(4, after, created)) == nil)
        #expect(throws: StageGroupError.self) {
            try store.recordCreatedWindow(created, since: baseline, first: sample(4, after, created), second: sample(5, after, created))
        }
    }

    @Test func initialWindowsAndExplicitlyDetachedMembersAreNeverReclaimed() throws {
        let store = StageGroupStore(profile: nil)
        let a = state(source), b = state(sibling)
        _ = try activate(store, [a, b])
        try store.join(groupWindow(b), to: groupWindow(a))
        try store.detach(groupWindow(b))
        let baseline = try activate(store, [a, b])
        let saved = store.directory
        #expect(throws: StageGroupError.self) {
            try store.recordCreatedWindow(sibling, since: baseline, first: sample(2, [a, b], source), second: sample(3, [a, b], source))
        }
        let reused = state(.init(pid: source.pid, birth: source.birth, number: sibling.number))
        let partial = try #require(store.arrivalBaseline(sample(4, [a], source)))
        #expect(throws: StageGroupError.self) {
            try store.recordCreatedWindow(sibling, since: partial, first: sample(5, [a, reused], source), second: sample(6, [a, reused], source))
        }
        #expect(store.directory == saved)
    }

    @Test func anyChangeInScopeFocusOriginOrTheRestOfTheRosterWithholdsTheMetadataWrite() throws {
        let store = StageGroupStore(profile: nil)
        let old = [state(source), state(sibling)], n = state(created)
        let baseline = try activate(store, old)
        #expect(store.arrivalBaseline(sample(1, old, sibling)) == nil)
        let before = store.directory, all = old + [n], first = sample(2, all, source)
        var hidden = n; hidden.visibility = .minimized
        var resized = old[0]; resized.frame = .init(width: 900, height: 600)
        let reopened = state(created), extra = state(.init(pid: source.pid, birth: source.birth, number: 8))
        let invalid = [
            sample(3, all, sibling), sample(3, all, nil), sample(3, all, created), sample(2, all, source),
            sample(3, all, source, scope: .init(display: UUID(), nativeSpace: scope.nativeSpace)),
            sample(3, all, source, scope: .init(display: scope.display, nativeSpace: UUID())),
            sample(3, all, source, epoch: UUID()), sample(3, all, source, native: 8),
            sample(3, old + [hidden], source), sample(3, [old[0], reopened], source),
            sample(3, old + [reopened], source), sample(3, [resized, old[1], n], source),
            sample(3, all + [extra], source)
        ]
        for changed in invalid {
            #expect(throws: StageGroupError.self) { try store.recordCreatedWindow(created, since: baseline, first: first, second: changed) }
        }
        for foreign in [NativeSpaceWindow(pid: source.pid + 1, birth: source.birth, number: 5),
                        .init(pid: source.pid, birth: source.birth + 1, number: 6)] {
            let altered = old + [state(foreign)]
            #expect(throws: StageGroupError.self) {
                try store.recordCreatedWindow(foreign, since: baseline, first: sample(2, altered, source), second: sample(3, altered, source))
            }
        }
        // Two equally wrong reads still cannot conceal a closure, a new lifetime, or a bystander's move.
        for altered in [[old[0], n], [state(source), old[1], n], [resized, old[1], n], old + [hidden], all + [extra]] {
            #expect(throws: StageGroupError.self) {
                try store.recordCreatedWindow(created, since: baseline, first: sample(2, altered, source), second: sample(3, altered, source))
            }
        }
        #expect(store.directory == before)
    }

    @Test func withdrawnActivityOrConcurrentDirectoryEditCannotCommitAnEarlierEvent() throws {
        let store = StageGroupStore(profile: nil), a = state(source), n = state(created)
        let baseline = try activate(store, [a]), after = [a, n]
        try store.withdrawActivity(in: [scope])
        #expect(store.arrivalBaseline(sample(2, [a], source)) == nil)
        let saved = store.directory
        #expect(throws: StageGroupError.self) {
            try store.recordCreatedWindow(created, since: baseline, first: sample(2, after, source), second: sample(3, after, source))
        }
        #expect(store.directory == saved)
    }

    @Test func freshReadbackCannotExtendAnExistingOwnerToAnyNewOrReopenedWindow() async throws {
        let env = StageEngineEnvironment(osBuild: "fixture", engineRevision: "fixture", hostCDHash: "fixture",
                                         hardware: "fixture", topology: "fixture", windowClass: "ordinary", sipEnabled: true)
        let qualification = StageEngineQualification(backend: .corner, environment: env, evidence: UUID(), checks: [:])
        let owner = StageEngineOwner(qualification: qualification, generation: epoch)
        let a = state(source), n = state(created), reopened = state(source)
        let probe = ArrivalWindowProbe(sample(1, [a], source))
        let session = StageEngineSession(owner: owner, witness: probe, transport: probe)
        _ = try await session.read(scope)
        probe.sample = sample(2, [reopened, n], created)
        let later = try await session.read(scope)
        #expect(later.windows.count == 2)
        session.intentIsCurrent = { true }
        for target in [n, reopened] {
            for action in [StageWindowAction.hide, .show, .focus, .place(work)] {
                let command = StageWindowCommand(intent: UUID(), group: UUID(), member: UUID(), generation: epoch,
                    scope: scope, nativeID: 5, action: action, before: target, restoring: false, restoreFrame: nil)
                await #expect(throws: StageSwitchError.interrupted) { try await session.dispatch(command) }
            }
        }
        #expect(probe.calls == 0)
    }
}
