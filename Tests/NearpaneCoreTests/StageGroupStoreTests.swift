import Foundation
import Testing
@testable import NearpaneCore

@Suite @MainActor struct StageGroupStoreTests {
    let first = UUID(), second = UUID()
    func window(_ number: UInt32, display: UUID, lifetime: UUID = UUID()) -> StageGroupWindow {
        .init(display: display, identity: .init(pid: Int32(number) + 10, birth: 10_000, number: number), lifetime: lifetime,
              layout: .init(x: 0.25, width: 0.5, height: 1))
    }

    @Test func namesSurviveReopenAndGroupingWithoutChangingScopeLayoutOrMembership() throws {
        let profile = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let store = StageGroupStore(profile: profile), scope = StageGroupScope(display: first, nativeSpace: UUID())
        func local(_ n: UInt32) -> StageGroupWindow {
            let w = window(n, display: first)
            return .init(display: first, identity: w.identity, lifetime: w.lifetime, layout: w.layout, nativeSpace: scope.nativeSpace)
        }
        let a = local(1), b = local(2)
        try store.observe([a, b])
        let original = store.directory
        let one = try #require(store.groups(in: scope).first)
        #expect(one.name == nil && one.members.count == 1)
        try store.rename(one, in: scope, to: "  调色 🎨  ")
        let named = try #require(store.groups(in: scope).first)
        #expect(named.id == one.id && named.name == "调色 🎨" && named.members == one.members)
        #expect(original.hasSameWindowGroups(as: store.directory, in: scope))
        #expect(StageGroupStore(profile: profile).groups(in: scope).first == named)
        #expect(throws: StageGroupError.staleBinding) { try store.rename(one, in: scope, to: "过期") }
        #expect(throws: StageGroupError.staleBinding) {
            try store.rename(named, in: .init(display: second, nativeSpace: scope.nativeSpace), to: "另一屏")
        }
        try store.join(b, to: a)
        let pair = try #require(store.groups(in: scope).first)
        #expect(pair.id == named.id && pair.name == named.name && pair.members.map(\.windowHint) == [a.identity, b.identity])
        #expect(!original.hasSameWindowGroups(as: store.directory, in: scope))
        #expect(throws: StageGroupError.staleBinding) { try store.rename(named, in: scope, to: "旧成员") }
        let elsewhere = StageGroupWindow(display: first, identity: b.identity, lifetime: b.lifetime, nativeSpace: UUID())
        #expect(throws: StageGroupError.staleBinding) { try store.detach(elsewhere, from: pair.id) }
        #expect(throws: StageGroupError.staleBinding) { try store.detach(b, from: UUID()) }
        #expect(store.groups(in: scope) == [pair])
        try store.detach(b, from: pair.id)
        let split = store.groups(in: scope)
        #expect(split.count == 2 && split[0].name == pair.name && split[1].name == nil)
        #expect(split[1].members == [pair.members[1]])
        try store.rename(split[0], in: scope, to: "  ")
        #expect(StageGroupStore(profile: profile).groups(in: scope).first?.name == nil)
    }

    @Test func oneSelectedMemberMovesAndTheOtherScreenKeepsItsGroup() throws {
        let store = StageGroupStore(profile: nil)
        let a = window(1, display: first), b = window(2, display: first), c = window(3, display: first)
        let remote = window(4, display: second)
        try store.observe([a, b, c, remote])
        try store.join(b, to: a)
        let oldPair = try #require(store.groups(on: first).first { $0.members.count == 2 })
        let slot = try #require(oldPair.members.first { $0.windowHint == b.identity })
        try store.join(b, to: c)
        #expect(store.groups(on: first).first { $0.id == oldPair.id }?.members.map(\.windowHint) == [a.identity])
        #expect(store.groups(on: first).last?.members.last?.id == slot.id)
        #expect(store.projectedGroups(on: first, among: [a, b, remote]).map(\.id) == [oldPair.id])
        #expect(throws: StageGroupError.self) { try store.join(b, to: remote) }
        #expect(store.groups(on: second).flatMap(\.members).map(\.windowHint) == [remote.identity])
        #expect(store.directory.displays.allSatisfy { $0.activeGroup == nil })
        try store.detach(b)
        #expect(store.groups(on: first).count == 3)
        try store.join(c, to: a)
        try store.dissolve(oldPair.id, on: first)
        #expect(store.groups(on: first).allSatisfy { $0.members.count == 1 })
    }

    @Test func reopenAndReusedNumberNeedExplicitBindingAndKeepLayout() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let store = StageGroupStore(profile: profile)
        let a = window(1, display: first), b = window(2, display: first)
        try store.observe([a, b])
        try store.join(a, to: b)
        let saved = store.directory
        let copy = StageGroupStore(profile: profile)
        #expect(copy.loadIssue == nil && copy.directory == saved)
        try copy.observe([a, b])
        #expect(copy.projectedGroups(on: first, among: [a, b]).isEmpty)
        try copy.rebind(a)
        #expect(copy.projectedGroups(on: first, among: [a, b]).isEmpty)
        try copy.rebind(b)
        #expect(copy.projectedGroups(on: first, among: [a, b]) == saved.displays.first?.groups)
        let reused = window(2, display: first)
        let wrongDisplay = window(2, display: second, lifetime: b.lifetime)
        try copy.observe([reused, wrongDisplay])
        #expect(copy.projectedGroups(on: first, among: [a, reused]).isEmpty)
        #expect(throws: StageGroupError.self) { try copy.rebind(wrongDisplay) }
        #expect(throws: StageGroupError.self) { try copy.join(reused, to: a) }
        #expect(copy.directory == saved)
    }

    @Test func explicitReassignmentAfterPhysicalMoveKeepsOnlyOneSlot() throws {
        let store = StageGroupStore(profile: nil), a = window(1, display: first), b = window(2, display: first)
        try store.observe([a, b])
        try store.join(b, to: a)
        let slot = try #require(store.groups(on: first).first?.members.last?.id)
        let arrived = window(2, display: second, lifetime: b.lifetime)
        try store.observe([arrived])
        #expect(store.previousDisplay(of: arrived) == first && store.groups(on: second).isEmpty)
        try store.assignToObservedDisplay(arrived)
        #expect(store.projectedGroups(on: second, among: [arrived]).first?.members.first?.id == slot)
        #expect(store.groups(on: first).first?.members.map(\.windowHint) == [a.identity])
    }

    @Test func currentScopeRebindIsAtomicAndPreservesWhollyAbsentHistory() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let scope = StageGroupScope(display: first, nativeSpace: UUID()), store = StageGroupStore(profile: profile)
        func local(_ n: UInt32) -> StageGroupWindow {
            let w = window(n, display: first)
            return .init(display: first, identity: w.identity, lifetime: w.lifetime, layout: w.layout, nativeSpace: scope.nativeSpace)
        }
        let original = [local(1), local(2), local(3), local(4)]
        try store.observe(original)
        try store.join(original[1], to: original[0])
        let saved = store.directory, reopened = StageGroupStore(profile: profile)
        let live = original.prefix(3).map {
            StageGroupWindow(display: $0.display, identity: $0.identity, lifetime: UUID(), layout: $0.layout, nativeSpace: $0.nativeSpace)
        }
        try reopened.observe(live)
        #expect(live.allSatisfy(reopened.needsRebinding))
        // A visible member of a saved pair cannot be rebound while its partner is absent.
        #expect(throws: StageGroupError.staleBinding) {
            try reopened.rebindCurrentScope([live[0], live[2]], in: scope, unchanged: saved)
        }
        #expect(live.allSatisfy(reopened.needsRebinding))
        try reopened.rebindCurrentScope(live, in: scope, unchanged: saved)
        #expect(live.allSatisfy { !reopened.needsRebinding($0) })
        #expect(reopened.projectedGroups(on: first, among: live).count == 2)
        #expect(reopened.directory == saved)
        #expect(reopened.groups(in: scope).flatMap(\.members).contains { $0.windowHint == original[3].identity })
        #expect(StageGroupStore(profile: profile).directory == saved)
    }

    @Test func currentScopeRebindRejectsAChangedPartitionWithoutBindingAnyMember() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let scope = StageGroupScope(display: first, nativeSpace: UUID()), store = StageGroupStore(profile: profile)
        let a = StageGroupWindow(display: first, identity: window(1, display: first).identity, lifetime: UUID(), nativeSpace: scope.nativeSpace)
        let b = StageGroupWindow(display: first, identity: window(2, display: first).identity, lifetime: UUID(), nativeSpace: scope.nativeSpace)
        try store.observe([a, b])
        let oldPartition = store.directory
        try store.join(b, to: a)
        let reopened = StageGroupStore(profile: profile)
        let new = [a, b].map { StageGroupWindow(display: first, identity: $0.identity, lifetime: UUID(), nativeSpace: scope.nativeSpace) }
        #expect(throws: StageGroupError.staleBinding) {
            try reopened.rebindCurrentScope(new, in: scope, unchanged: oldPartition)
        }
        #expect(new.allSatisfy(reopened.needsRebinding))
        #expect(throws: StageGroupError.staleBinding) {
            try reopened.rebindCurrentScope([new[0], new[0]], in: scope, unchanged: reopened.directory)
        }
        #expect(new.allSatisfy(reopened.needsRebinding))
    }

    @Test func unknownSystemOwnershipIsDistinctFromReadableFactoryDefault() {
        #expect(StageManagerPreference.read(effective: { nil }, confirmsUnset: { false }) == nil)
        #expect(StageManagerPreference.read(effective: { nil }, confirmsUnset: { true }) == false)
        #expect(StageManagerPreference.read(effective: { "bad" as CFString }, confirmsUnset: { true }) == nil)
        #expect(StageManagerPreference.read(effective: { kCFBooleanTrue }, confirmsUnset: { false }) == true)
        #expect(StageManagerPreference.read(effective: { kCFBooleanFalse }, confirmsUnset: { false }) == false)
        var effective: CFPropertyList?
        let duringTakeover = StageManagerPreference.read(effective: { effective }, confirmsUnset: {
            effective = kCFBooleanTrue
            return true
        })
        #expect(duringTakeover == nil)
    }

    @Test func duplicateOrMissingReadbackCannotPublishAGroupOrDeleteASlot() throws {
        let store = StageGroupStore(profile: nil), a = window(1, display: first), b = window(2, display: first)
        try store.observe([a, a])
        #expect(store.directory.displays.isEmpty)
        try store.observe([a, b])
        try store.join(a, to: b)
        let saved = store.directory
        try store.observe([])
        #expect(store.projectedGroups(on: first, among: [a, a, b]).isEmpty)
        #expect(store.projectedGroups(on: second, among: [a, b]).isEmpty)
        #expect(store.directory == saved)
    }

    @Test func unsupportedCorruptOrExternallyChangedDirectoryPreservesOriginalBytes() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let file = profile.appendingPathComponent("stage-groups-v1.json")
        let bytes = Data(#"{"version":99,"displays":[]}"#.utf8)
        let open = StageGroupStore(profile: profile)
        try bytes.write(to: file)
        for store in [open, StageGroupStore(profile: profile)] {
            #expect(throws: StageGroupError.self) { try store.observe([window(1, display: first)]) }
            #expect(store.directory.displays.isEmpty && store.loadIssue != nil)
            #expect(try Data(contentsOf: file) == bytes)
        }
        let invalid = Data([0xff])
        try invalid.write(to: file)
        #expect(StageGroupStore(profile: profile).loadIssue != nil)
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func diskWriteFailureNeverPublishesGroupOrBinding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = StageGroupStore(profile: file)
        let a = window(1, display: first)
        #expect(throws: (any Error).self) { try store.observe([a]) }
        #expect(store.directory.displays.isEmpty && store.projectedGroups(on: first, among: [a]).isEmpty)
        #expect(try Data(contentsOf: file) == Data([1]))
    }

    @Test func scopesSurviveIndependentDesktopSelectionAndNativeMoves() throws {
        let store = StageGroupStore(profile: nil), s1 = UUID(), s2 = UUID()
        func scoped(_ w: StageGroupWindow, space: UUID) -> StageGroupWindow {
            .init(display: w.display, identity: w.identity, lifetime: w.lifetime, layout: w.layout, nativeSpace: space)
        }
        let a = scoped(window(1, display: first), space: s1), b = scoped(window(2, display: first), space: s1)
        let c = scoped(window(3, display: first), space: s2), other = scoped(window(4, display: second), space: s1)
        let local = StageGroupScope(display: first, nativeSpace: s1), next = StageGroupScope(display: first, nativeSpace: s2)
        try store.observe([a,b,c,other])
        try store.join(b, to: a)
        #expect(throws: StageGroupError.self) { try store.join(c, to: a) }
        let pair = try #require(store.groups(in: local).first)
        let single = try #require(store.groups(in: next).first)
        try store.commitActivity(pair.id, preferred: pair.members[1].id, in: local, expected: store.directory)
        try store.commitActivity(single.id, preferred: single.members[0].id, in: next, expected: store.directory)
        #expect(store.activeGroup(in: local) == pair.id && store.activeGroup(in: next) == single.id)
        #expect(store.activeGroup(in: .init(display: second, nativeSpace: s1)) == nil)
        let moved = scoped(b, space: s2)
        try store.observe([moved, c])
        #expect(store.groups(in: local).first?.needsReorganization == true)
        #expect(store.activeGroup(in: local) == nil && store.activeGroup(in: next) == single.id)
        #expect(store.needsReassignment(moved) && store.groups(in: local).first?.members.count == 2)
        #expect(store.projectedGroups(on: first, among: [a,moved,c]).map(\.id) == [single.id])
        try store.assignToObservedDisplay(moved)
        try store.observe([a])
        #expect(store.groups(in: local).first?.needsReorganization == nil)
        #expect(store.groups(in: next).count == 2 && store.groups(in: local).first?.members.count == 1)
    }

    @Test func v1MigrationKeepsOriginalAndDoesNotGuessSpaceOrFocus() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let w = window(1, display: first)
        let oldSlot = StageGroupDirectory.Member(id: UUID(), windowHint: w.identity, layout: w.layout)
        let g = StageGroupDirectory.Group(id: UUID(), members: [oldSlot])
        let old = StageGroupDirectory(version: 1, displays: [.init(id: first, groups: [g], activeGroup: g.id)])
        let path = profile.appendingPathComponent("stage-groups-v1.json")
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: path)
        let store = StageGroupStore(profile: profile), space = UUID()
        let live = StageGroupWindow(display: first, identity: w.identity, lifetime: UUID(), nativeSpace: space)
        try store.observe([live])
        #expect(store.directory.displays.first?.activeGroup == nil && store.groups(on: first).first?.nativeSpace == nil)
        #expect(store.projectedGroups(on: first, among: [live]).isEmpty)
        try store.rebind(live)
        try store.observe([live])
        let copy = StageGroupStore(profile: profile)
        #expect(copy.directory == store.directory)
        #expect(copy.groups(in: .init(display: first, nativeSpace: space)).first?.members == [oldSlot])
        #expect(copy.activeGroup(in: .init(display: first, nativeSpace: space)) == nil)
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func confirmedDepartureRemovesOnlyTheBoundUnownedMember() throws {
        let store = StageGroupStore(profile: nil), scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
        let first = StageGroupWindow(display: scope.display, identity: .init(pid: 41, birth: 9, number: 1),
                                     lifetime: UUID(), nativeSpace: scope.nativeSpace)
        let second = StageGroupWindow(display: scope.display, identity: .init(pid: 41, birth: 9, number: 2),
                                      lifetime: UUID(), layout: .init(x: 0.5, width: 0.5, height: 1), nativeSpace: scope.nativeSpace)
        try store.observe([first, second])
        try store.join(first, to: second)
        let group = try #require(store.groups(in: scope).first)
        let id = ManagedWindowID(pid: 41, launch: 9, number: 1, element: UUID())
        let now = ProcessInfo.processInfo.systemUptime
        let proof = OrdinaryWindowClosure(id: id, destroyed: now - 0.2, firstAbsent: now - 0.1, secondAbsent: now)
        let stale = try #require(StageWindowDeparture.confirmed(proof, original: id, lifetime: UUID()))
        let exact = try #require(StageWindowDeparture.confirmed(proof, original: id, lifetime: first.lifetime))
        #expect(try store.retire([stale], unowned: { _ in true }).isEmpty)
        #expect(try store.retire([exact], unowned: { _ in false }).isEmpty)
        #expect(store.groups(in: scope) == [group])
        #expect(try store.retire([exact], unowned: { _ in true }) == [first.identity])
        #expect(store.groups(in: scope).first?.members == group.members.filter { $0.windowHint == second.identity })
        let reopened = StageGroupWindow(display: scope.display, identity: first.identity, lifetime: UUID(), nativeSpace: scope.nativeSpace)
        try store.observe([reopened])
        #expect(store.groups(in: scope).count == 2 && store.groups(in: scope).last?.id != group.id)
        #expect(try store.retire([exact], unowned: { _ in true }).isEmpty)
    }

    @Test func relativeFramesUseDisplayLocalUsableOrigin() {
        let rect = StageGroupWindow.relativeFrame(.init(x: -10, y: 20, width: 500, height: 380),
                                                  in: .init(x: 10, y: 20, width: 1000, height: 760))
        #expect(rect == .init(x: -0.02, y: 0, width: 0.5, height: 0.5))
        #expect(StageGroupWindow.relativeFrame(.init(width: .nan, height: 1), in: .init(width: 1, height: 1)) == nil)
    }
}
