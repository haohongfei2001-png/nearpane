import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@Suite @MainActor struct StageWindowOwnershipTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    }

    @Test func pendingLayoutExcludesItsExactWindowsAndStillProtectsUpdate() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OrdinaryJournal(support: root)
        let id = ManagedWindowID(pid: 101, launch: 2048, number: 13, element: UUID())
        let frame = SurfaceRect(x: 0, y: 0, width: 200, height: 100)
        let entry = OrdinaryJournal.Entry(id: id, bundle: "test.window", original: frame, confirmed: frame)
        try withExtendedLifetime(journal.lock()) {
            try journal.publish(.init(version: 1, session: UUID(), status: "pending", display: "fixture", entries: [entry]))
        }
        let bytes = try Data(contentsOf: journal.file)
        let manager = OrdinaryWindowManager(support: root)
        #expect(manager.blocksUpdateRelaunch)
        #expect(manager.stageWindowExclusions == [NativeSpaceWindow(pid: 101, birth: 2048, number: 13)])
        #expect(try Data(contentsOf: journal.file) == bytes)
    }

    @Test func unreadableOwnershipCannotAuthorizeAWindow() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OrdinaryJournal(support: root)
        try withExtendedLifetime(journal.lock()) { try Data("broken".utf8).write(to: journal.file) }
        let manager = OrdinaryWindowManager(support: root)
        #expect(manager.stageWindowExclusions == nil && manager.blocksUpdateRelaunch)
        #expect(try Data(contentsOf: journal.file) == Data("broken".utf8))
    }

    @Test func bothWritersContendForSameFileLeaseButSiblingIsIndependent() throws {
        let birth = UInt64.random(in: 1...UInt64.max)
        let id = ManagedWindowID(pid: getpid(), launch: birth, number: 11, element: UUID())
        let key = NativeSpaceWindow(pid: id.pid, birth: birth, number: id.number)
        try withExtendedLifetime(OrdinaryFileLease.forWindow(id)) {
            #expect(throws: WorkspaceFailure.self) { try OrdinaryFileLease.forWindow(key) }
            _ = try OrdinaryFileLease.forWindow(.init(pid: id.pid, birth: birth, number: 12))
        }
        _ = try OrdinaryFileLease.forWindow(key)
    }
}
