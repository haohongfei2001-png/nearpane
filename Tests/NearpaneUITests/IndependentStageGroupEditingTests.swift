import Foundation
import Testing
@testable import NearpaneCore
@testable import NearpaneUI

@MainActor struct IndependentStageGroupEditingTests {
    let scope = StageGroupScope(display: UUID(), nativeSpace: UUID())

    func setup() throws -> (StageGroupStore, [StageGroupWindow], StageGroupDirectory.Group, StageGroupDirectory.Group) {
        let store = StageGroupStore(profile: nil)
        let ids = [NativeSpaceWindow(pid: 100, birth: 200, number: 1),
                   NativeSpaceWindow(pid: 100, birth: 200, number: 2),
                   NativeSpaceWindow(pid: 101, birth: 201, number: 3)]
        let windows = ids.enumerated().map { index, identity in
            StageGroupWindow(display: scope.display, identity: identity, lifetime: UUID(),
                layout: .init(x: Double(index) * 0.1, y: 0.1, width: 0.5, height: 0.5), nativeSpace: scope.nativeSpace)
        }
        try store.observe(windows)
        try store.join(windows[1], to: windows[0])
        let source = try #require(store.groups(in: scope).first { $0.members.count == 2 })
        let target = try #require(store.groups(in: scope).first { $0.members.count == 1 })
        return (store, windows, source, target)
    }

    @Test func returnedInactiveGroupJoinsCurrentGroupAcrossApplicationsAndKeepsItsExactWindows() throws {
        let (store, windows, source, target) = try setup()
        let plan = try IndependentStageGroupEditing.Plan(scope: scope, source: source, target: target)
        let observed = Dictionary(uniqueKeysWithValues: windows.map { ($0.identity, $0) })
        let result = try plan.apply(to: store, observed: observed)
        let merged = try #require(store.groups(in: scope).first)
        #expect(store.groups(in: scope).count == 1)
        #expect(result.group == target.id && result.window == windows[2].identity)
        #expect(Set(merged.members.map(\.windowHint)) == Set(windows.map(\.identity)))
        #expect(Set(merged.members.map(\.id)) == Set((source.members + target.members).map(\.id)))
        #expect(merged.members.allSatisfy { store.isBound($0, to: observed[$0.windowHint]!.lifetime) })
    }

    @Test func detachingOneOfTwoSameAppWindowsSelectsTheNewSingletonWithoutMovingItsSibling() throws {
        let (store, windows, source, target) = try setup()
        let member = try #require(source.members.first { $0.windowHint == windows[1].identity })
        let plan = try IndependentStageGroupEditing.Plan(scope: scope, source: source, detached: member.id)
        let result = try plan.apply(to: store, observed: Dictionary(uniqueKeysWithValues: windows.map { ($0.identity, $0) }))
        let single = try #require(store.groups(in: scope).first { $0.id == result.group })
        #expect(single.members.map(\.windowHint) == [windows[1].identity])
        #expect(single.members.first?.id == member.id && result.window == windows[1].identity)
        #expect(store.groups(in: scope).first { $0.id == source.id }?.members.map(\.windowHint) == [windows[0].identity])
        #expect(store.groups(in: scope).first { $0.id == target.id } == target)
    }

    @Test func staleUnselectedSiblingRejectsTheWholeEditBeforeTheFirstDirectoryWrite() throws {
        let (store, windows, source, target) = try setup()
        let plan = try IndependentStageGroupEditing.Plan(scope: scope, source: source, target: target)
        var observed = Dictionary(uniqueKeysWithValues: windows.map { ($0.identity, $0) })
        observed[windows[1].identity] = .init(display: scope.display, identity: windows[1].identity,
            lifetime: UUID(), layout: windows[1].layout, nativeSpace: scope.nativeSpace)
        let before = store.directory
        #expect(throws: (any Error).self) { try plan.apply(to: store, observed: observed) }
        #expect(store.directory == before)
    }

    @Test func aMenuOpenedForAnOlderRosterCannotEditTheNewPartition() throws {
        let (store, windows, source, target) = try setup()
        let plan = try IndependentStageGroupEditing.Plan(scope: scope, source: source, target: target)
        try store.detach(windows[1], from: source.id)
        let current = store.directory
        #expect(throws: (any Error).self) {
            try plan.apply(to: store, observed: Dictionary(uniqueKeysWithValues: windows.map { ($0.identity, $0) }))
        }
        #expect(store.directory == current)
    }
}
