import Foundation
import Testing
@testable import NearpaneTray

struct FileTrayTests {
    @Test func mixedSlotsRetainBothLatestItemsAndNeverAddEmptyFrames() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(TrayContentSlot.visible(shots: [], files: [], camera: true) == [.camera, .folder])
        #expect(TrayContentSlot.visible(shots: [a], files: [b], camera: true) == [.shot(a), .camera, .folder, .file(b)])
        #expect(TrayContentSlot.visible(shots: [a, b], files: [c, d], camera: true) == [.shot(a), .shot(b), .camera, .file(c)])
        #expect(TrayContentSlot.visible(shots: [], files: [a, b, c, d], camera: true) == [.camera, .file(c), .file(b), .file(a)])
        #expect(TrayContentSlot.visible(shots: [a, b], files: [c, d], camera: true, capacity: 2) == [.shot(a), .file(c)])
    }

    @Test func expiryRemovesOnlyTheTileAndSameNamedImportsKeepTheirOwnBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrayFileStore(root: root.appendingPathComponent("saved"))
        let original = root.appendingPathComponent("draft.txt")
        try Data("one".utf8).write(to: original)
        let first = try await store.save(original)
        try Data("two".utf8).write(to: original)
        let second = try await store.save(original)
        #expect(first.id != second.id && first.url.lastPathComponent == second.url.lastPathComponent)
        #expect(try await store.recent(now: first.savedAt.addingTimeInterval(58)).count == 2)
        #expect(try await store.recent(now: second.savedAt.addingTimeInterval(62)).isEmpty)
        #expect(try Data(contentsOf: first.url) == Data("one".utf8))
        #expect(try Data(contentsOf: second.url) == Data("two".utf8))
    }
}
