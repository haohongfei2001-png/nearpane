import Foundation
import Testing
@testable import NearpaneTray

private actor PausedFileStore: TrayFileStorage {
    nonisolated let root: URL
    private let backing: TrayFileStore
    let entered: AsyncStream<Void>.Continuation
    private var waiting: CheckedContinuation<Void, Never>?
    private var first = true

    init(root: URL, entered: AsyncStream<Void>.Continuation) {
        self.root = root
        self.entered = entered
        backing = TrayFileStore(root: root)
    }

    func save(_ source: URL) async throws -> SavedTrayFile {
        if first {
            first = false
            await withCheckedContinuation { waiting = $0; entered.yield() }
        }
        return try await backing.save(source)
    }

    func recent(now: Date) async throws -> [SavedTrayFile] { try await backing.recent(now: now) }
    func release() { waiting?.resume(); waiting = nil }
}

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

    @Test @MainActor func shutdownWaitsForWholeAdmittedFileDropAndReopenReadsItsOriginalContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = ["A", "B", "C"].map { root.appendingPathComponent($0) }
        for f in originals { try Data(f.lastPathComponent.utf8).write(to: f) }
        let started = AsyncStream<Void>.makeStream()
        let store = PausedFileStore(root: root.appendingPathComponent("saved"), entered: started.continuation)
        let module = TrayModule(fileStore: store, open: { _, _ in throw CancellationError() })
        try module.start()
        let importing = Task { await module.importFiles(Array(originals.prefix(2))) }
        var signal = started.stream.makeAsyncIterator()
        _ = await signal.next()
        #expect(await module.updateRequiresTrayToFinish())
        module.stop()
        await module.importFiles([originals[2]])
        var ended = 0
        let entered = AsyncStream<Void>.makeStream()
        let stops = (0..<2).map { _ in
            Task { entered.continuation.yield(); await module.finishStopping(); ended += 1 }
        }
        var arrivals = entered.stream.makeAsyncIterator()
        _ = await arrivals.next(); _ = await arrivals.next()
        #expect(ended == 0)
        await store.release()
        await importing.value
        for task in stops { await task.value }
        #expect(ended == 2 && module.fileImports == 0 && module.files.isEmpty)
        let fresh = TrayFileStore(root: store.root)
        let items = try await fresh.recent()
        #expect(Set(items.map { $0.url.lastPathComponent }) == Set(["A", "B"]))
        for file in items {
            #expect(try Data(contentsOf: file.url) == Data(file.url.lastPathComponent.utf8))
        }
    }
}
