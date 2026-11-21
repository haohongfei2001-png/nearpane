import Foundation
import Testing
@testable import NearpaneCore

@Suite @MainActor struct StageGroupStoreTests {
    let first = UUID(), second = UUID()
    func window(_ number: UInt32, display: UUID, lifetime: UUID = UUID()) -> StageGroupWindow {
        .init(display: display, identity: .init(pid: Int32(number) + 10, birth: 10_000, number: number), lifetime: lifetime,
              layout: .init(x: 0.25, width: 0.5, height: 1))
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

    @Test func unknownSystemOwnershipIsDistinctFromReadableFactoryDefault() {
        #expect(StageManagerPreference.configuration(nil, domainReadable: false) == nil)
        #expect(StageManagerPreference.configuration(nil, domainReadable: true) == false)
        #expect(StageManagerPreference.configuration("bad" as CFString, domainReadable: true) == nil)
        #expect(StageManagerPreference.configuration(kCFBooleanTrue, domainReadable: true) == true)
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

    @Test func relativeFramesUseDisplayLocalUsableOrigin() {
        let rect = StageGroupWindow.relativeFrame(.init(x: -10, y: 20, width: 500, height: 380),
                                                  in: .init(x: 10, y: 20, width: 1000, height: 760))
        #expect(rect == .init(x: -0.02, y: 0, width: 0.5, height: 0.5))
        #expect(StageGroupWindow.relativeFrame(.init(width: .nan, height: 1), in: .init(width: 1, height: 1)) == nil)
    }
}
