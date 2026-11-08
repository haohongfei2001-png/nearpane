import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RiftletCore
@testable import RiftletCapture
@testable import NearpaneTray

private func root() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data").appendingPathComponent("tray-" + UUID().uuidString, isDirectory: true)
}

private func makePNG(_ original: URL) throws {
    let ctx = try #require(CGContext(data: nil, width: 40, height: 17, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(CGColor(gray: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 17))
    let writer = try #require(CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, try #require(ctx.makeImage()), nil)
    try #require(CGImageDestinationFinalize(writer))
}

private actor Location: CaptureLocationProviding {
    let url: URL
    init(_ url: URL) { self.url = url }
    func currentDirectory() async throws -> URL { url }
    func start(onChange: @escaping @Sendable () async -> Void) async throws {}
    func stop() async {}
}

private actor Transport: AttachmentAdapter {
    nonisolated let id = "simulation"
    let target = TargetLease(adapterID: "simulation", surface: .simulation, applicationID: "fixture",
                             sessionID: "test", windowID: "1", documentID: "one", composerID: "one", draftGeneration: "1")
    var accepted = true
    var outcome: ReceiptOutcome = .unknown
    var appends = 0
    var observations = 0
    func configure(_ state: ReceiptOutcome, valid: Bool = true) { outcome = state; accepted = valid }
    func captureTarget() async throws -> TargetLease { target }
    func validate(_ value: TargetLease) async throws -> Bool { accepted && value == target }
    func append(_ request: TransferRequest) async throws -> TransferReceipt {
        appends += 1; return receipt(request)
    }
    func reconcile(_ request: TransferRequest) async throws -> TransferReceipt {
        observations += 1; return receipt(request)
    }
    private func receipt(_ r: TransferRequest) -> TransferReceipt {
        .init(operationID: r.operation.id, assetID: r.asset.id, attempt: r.operation.attempt, assetSHA256: r.asset.sha256,
              target: r.operation.target, outcome: outcome, profileID: "simulation-v1", attachmentID: r.operation.id.uuidString,
              positiveReady: outcome == .verifiedReady, belongsToOriginalDraft: true, hasError: outcome == .definitiveFailure,
              isUploading: outcome == .uploadStarted, safeToRetry: outcome == .definitiveFailure,
              uploadStartEvidence: outcome == .uploadStarted ? .init(profileID: "simulation-upload-start-v1",
                  signal: .correlatedProgress, evidenceID: "fixture-start", inputCount: 1) : nil)
    }
}

@MainActor @Suite(.serialized)
struct TrayDomainTests {
    @Test func oneStoreOwnsUnknownReconciliationRevivalRetryAndPositiveSwallow() async throws {
        let dir = root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"), mode: .simulation)
        let image = ImportedAsset(sourceKey: "fixture", fileName: "fixture.png", sha256: String(repeating: "a", count: 64),
                                  byteCount: 7, pixelWidth: 160, pixelHeight: 90, mediaType: "image/png", origin: .synthetic)
        let media = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: media.appendingPathComponent(image.fileName))
        _ = try await store.importAsset(image)
        let adapter = Transport()
        let module = TrayModule { change, error in
            TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: true,
                      pin: { Task { try await adapter.captureTarget() } }, permission: { _,_ in true },
                      notify: change, report: error)
        }
        try module.start()
        await module.connect()
        #expect(module.connected && !module.mayAttach)
        #expect(module.beginPress(try #require(module.rows.first)) == nil)
        await module.authorizeAttachments()
        func click() async throws {
            let first = try #require(module.rows.first)
            let press = try #require(module.beginPress(first))
            await module.finishPress(press)
        }
        try await click()
        #expect(try await store.asset(id: image.id)?.status == .unknown)
        #expect(module.rows.map(\.id) == [image.id] && module.swallowing.isEmpty)
        let old = try #require(try await store.asset(id: image.id)?.activeOperationID)
        try await click()
        #expect(await adapter.appends == 1)
        #expect(await adapter.observations > 0)
        await adapter.configure(.definitiveFailure)
        try await click()
        #expect(try await store.operation(id: old)?.phase == .failed)
        #expect(try await store.asset(id: image.id)?.status == .failed && module.rows.count == 1)
        await adapter.configure(.uploadStarted)
        try await click()
        #expect(await adapter.appends == 2)
        #expect(try await store.asset(id: image.id)?.visibilityReason == .uploadStarted)
        #expect(module.swallowing == [image.id])
        try await Task.sleep(for: .milliseconds(180))
        #expect(module.rows.isEmpty)
        #expect(try await store.history().count == 1)
        #expect(try await store.asset(id: image.id)?.status != .used)
        module.disconnect()
        await module.connect()
        #expect(module.rows.isEmpty && !module.mayAttach)
        #expect(await adapter.appends == 2)
        module.stop()
    }

    @Test func staleDraftAndCancelledPressNeverInput() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"), mode: .simulation)
        let record = try await store.importAsset(.init(sourceKey: "change", fileName: "x.png", sha256: String(repeating: "f", count: 64),
            byteCount: 1, pixelWidth: 16, pixelHeight: 9, mediaType: "image/png", origin: .synthetic))
        let adapter = Transport()
        let module = TrayModule { change, error in
            TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: false,
                      pin: { Task { try await adapter.captureTarget() } }, permission: { _,_ in true }, notify: change, report: error)
        }
        try module.start(); await module.connect(); await module.authorizeAttachments()
        let press = try #require(module.beginPress(record))
        module.surfaceHidden(true); await module.finishPress(press)
        #expect(await adapter.appends == 0)
        module.surfaceHidden(false)
        let second = try #require(module.beginPress(record))
        await adapter.configure(.verifiedReady, valid: false)
        await module.finishPress(second)
        #expect(await adapter.appends == 0 && module.rows.map(\.id) == [record.id])
        module.stop()
    }

    @Test func hideAndShowWhileDraftResolutionIsPendingCannotReplayTheClick() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"), mode: .simulation)
        let media = dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: media.appendingPathComponent("frame.png"))
        let row = try await store.importAsset(.init(sourceKey: "frame", fileName: "frame.png", sha256: String(repeating: "a", count: 64),
            byteCount: 7, pixelWidth: 20, pixelHeight: 10, mediaType: "image/png", origin: .synthetic))
        let adapter = Transport()
        var releasePin: CheckedContinuation<Void, Never>?
        let module = TrayModule { change, error in
            TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: true,
                pin: { Task { @MainActor in
                    await withCheckedContinuation { releasePin = $0 }
                    return try await adapter.captureTarget()
                } }, permission: { _,_ in true }, notify: change, report: error)
        }
        try module.start(); await module.connect(); await module.authorizeAttachments()
        let press = try #require(module.beginPress(row))
        var processing = false
        let finishing = Task { @MainActor in processing = true; await module.finishPress(press) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (!processing || releasePin == nil) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(processing)
        let gate = try #require(releasePin)
        module.surfaceHidden(true); module.surfaceHidden(false)
        gate.resume(); await finishing.value
        #expect(await adapter.appends == 0)
        #expect(try await store.asset(id: row.id)?.status == .pending && module.issue == nil)
        module.stop()
    }

    @Test func explicitConnectionRecoversAnInterruptedImportOnceWithoutAnyExternalInput() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try ApplicationInstanceOwnership(root: dir)
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let output = dir.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = output.appendingPathComponent("fixture.png")
        try makePNG(source)
        let original = try Data(contentsOf: source)
        let broken = PrivateAssetImporter(privateRoot: dir, store: store, fault: { context in
            if context.boundary == .mediaSynced { throw SimulatedImportInterruption(boundary: .mediaSynced) }
        })
        await #expect(throws: SimulatedImportInterruption.self) {
            _ = try await broken.importBuiltInScreenshot(original: source, outputDirectory: output)
        }
        #expect(try await store.assets().isEmpty)
        lock.close()
        let module = TrayModule(existingRoot: dir)
        try module.start()
        #expect(module.rows.isEmpty && !module.connected)
        await module.connect()
        let row = try #require(module.rows.first)
        #expect(module.rows.count == 1 && row.status == .pending && !module.mayAttach)
        module.disconnect(); await module.connect()
        #expect(module.rows.map(\.id) == [row.id] && !module.mayAttach)
        #expect(try Data(contentsOf: source) == original)
        module.stop()
    }

    @Test func existingLibraryRejectsMissingBusyAndWrongFormatWithoutCreatingAQueue() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: LibraryError.self) { try ExistingLibrary.open(dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let held = try ApplicationInstanceOwnership(root: dir)
        let db = dir.appendingPathComponent("queue.sqlite")
        let original = Data("not a database".utf8)
        try original.write(to: db)
        #expect(throws: LibraryError.busy) { try ExistingLibrary.open(dir) }
        held.close()
        #expect(throws: LibraryError.incompatible) { try ExistingLibrary.open(dir) }
        #expect(try Data(contentsOf: db) == original)
    }

    @Test func independentProcessHoldingTheRiftletLockIsRejectedBeforeAnyProductionFormatWrite() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ApplicationInstanceOwnership(root: dir)
        let database = dir.appendingPathComponent("queue.sqlite")
        _ = try QueueStore(databaseURL: database)
        first.close()
        let before = try Data(contentsOf: database)
        let process = Process(), input = Pipe(), signal = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", """
            import fcntl, select, sys
            with open(sys.argv[1], "r+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                print("1", flush=True)
                select.select([sys.stdin], [], [], 15)
            """, dir.appendingPathComponent("instance.lock").path]
        process.standardInput = input; process.standardOutput = signal
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try #require(try signal.fileHandleForReading.read(upToCount: 1) == Data("1".utf8))
        let module = TrayModule(existingRoot: dir)
        try module.start(); await module.connect()
        #expect(!module.connected && module.issue == LibraryError.busy.localizedDescription)
        #expect(try Data(contentsOf: database) == before)
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        await module.connect()
        #expect(module.connected && module.rows.isEmpty && !module.mayAttach)
        module.disconnect(); await module.finishStopping()
        let nextOwner = try ApplicationInstanceOwnership(root: dir)
        nextOwner.close(); module.stop()
    }

    @Test func reopenWaitsForAnEarlierConnectionAndItsAdmittedWorkToReleaseOwnership() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"), mode: .simulation)
        var openGate: CheckedContinuation<Void, Never>?
        var workGate: CheckedContinuation<Void, Never>?
        var opens = 0
        weak var lastOwner: TrayOwner?
        let adapter = Transport()
        let module = TrayModule { change, error in
            opens += 1
            if opens == 1 { await withCheckedContinuation { openGate = $0 } }
            let owner = TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: false,
                                  pin: { Task { try await adapter.captureTarget() } }, permission: { _, _ in false },
                                  notify: change, report: error)
            lastOwner = owner
            return owner
        }
        try module.start()
        let first = Task { await module.connect() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while openGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        let releaseOpening = try #require(openGate)
        module.disconnect()
        let next = Task { await module.connect() }
        await Task.yield()
        #expect(opens == 1)
        releaseOpening.resume(); await first.value; await next.value
        try #require(opens == 2 && module.connected)
        let owner = try #require(lastOwner)
        let admitted = Task { try await owner.performWork { await withCheckedContinuation { workGate = $0 } } }
        while workGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        let releaseWork = try #require(workGate)
        module.stop()
        var drained = false
        let stopping = Task { await module.finishStopping(); drained = true }
        await Task.yield()
        #expect(!drained && !module.connected)
        releaseWork.resume(); try await admitted.value; await stopping.value
        #expect(drained)
    }

    @Test func actualFolderWatcherImportsOnlyTaggedNewScreenshotIntoTheOriginalStore() async throws {
        let base = root(); defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("library"), source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let module = TrayModule { change, error in
            TrayOwner(store: store, root: dir, adapter: UnavailableAdapter(), policy: .init(), captureEntry: true,
                      pin: { throw LibraryError.incompatible }, permission: { _,_ in false }, notify: change, report: error)
        }
        try module.start(); await module.connect()
        await module.collect(from: source, provider: Location(base.appendingPathComponent("not-authorized")))
        #expect(!module.collectionEnabled)
        await module.collect(from: source, provider: Location(source))
        try #require(module.collectionEnabled)
        try makePNG(source.appendingPathComponent("ordinary.png"))
        let file = source.appendingPathComponent("generated.png")
        try makePNG(file)
        let metadata = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        try #require(metadata.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0) } == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while module.rows.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(module.rows.map(\.image.origin) == [.systemScreenshot])
        #expect(try await store.assets().map(\.id) == module.rows.map(\.id))
        module.stop(); await module.finishStopping()
    }

    @Test func realImporterAndThumbnailUseSameExistingLibraryAndPreserveMediaAcrossReconnect() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try ApplicationInstanceOwnership(root: dir)
        let db = dir.appendingPathComponent("queue.sqlite")
        _ = try QueueStore(databaseURL: db) // initialize ONLY the test fixture, never the app path
        lock.close()
        let owner = try await TrayOwner.existing(root: dir, notify: {}, report: { _ in })
        let output = dir.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = output.appendingPathComponent("synthetic.png")
        try makePNG(original)
        let image = try await owner.importer.importBuiltInScreenshot(original: original, outputDirectory: output)
        #expect(image.image.origin == .applicationScreenshot)
        #expect(try await owner.store.assets().map(\.id) == [image.id])
        let rendered: CGImage? = await withCheckedContinuation { continuation in
            owner.thumbnails.image(for: image.image, maxPixelSize: 80) { continuation.resume(returning: $0) }
        }
        #expect(rendered != nil && image.image.pixelWidth == 40 && image.image.pixelHeight == 17)
        let media = dir.appendingPathComponent("media").appendingPathComponent(image.image.fileName)
        #expect(try Data(contentsOf: media) == Data(contentsOf: original))
        #expect(throws: LibraryError.busy) { try ExistingLibrary.open(dir) }
        owner.close()
        // Reopening a read/write handle on the very same DB sees the same ID, not a mirrored Host record.
        let same = try QueueStore(databaseURL: db)
        #expect(try await same.assets().map(\.id) == [image.id])
    }
}

@MainActor private final class SyntheticCaptureChild: SystemCaptureProcess {
    var shouldFail = false
    var output: URL?
    var ended: (@MainActor @Sendable (Int32) async -> Void)?
    var terminations = 0
    func start(output: URL, ended: @escaping @MainActor @Sendable (Int32) async -> Void) throws {
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        self.output = output; self.ended = ended
    }
    func terminate() { terminations += 1 } // The test controls when the OS callback actually arrives.
}

extension TrayDomainTests {
    @Test func captureLaunchFailureAndUserCancellationReleaseExactlyOneJob() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let child = SyntheticCaptureChild(), adapter = Transport()
        var reports = 0
        let owner = TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: true,
            makeSystemCapture: { child }, pin: { throw CancellationError() }, permission: { _,_ in false },
            notify: {}, report: { _ in reports += 1 })
        child.shouldFail = true
        owner.capture(.system)
        #expect(!owner.hasPendingWork && reports == 1)
        child.shouldFail = false
        owner.capture(.system)
        #expect(owner.hasPendingWork)
        let end = try #require(child.ended)
        await end(1); await end(1)
        await owner.finishWork()
        #expect(!owner.hasPendingWork && reports == 2 && child.terminations == 0)
        #expect(try await store.assets().isEmpty)
    }

    @Test func successfulChildDrainsOnlyAfterDelayedImportCallbackAndIgnoresDuplicateExit() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let child = SyntheticCaptureChild(), adapter = Transport()
        var finish: CheckedContinuation<Void,Never>?
        var notifications = 0, drained = false
        let owner = TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: true,
            makeSystemCapture: { child }, pin: { throw CancellationError() }, permission: { _,_ in false },
            notify: { notifications += 1; await withCheckedContinuation { finish = $0 } }, report: { _ in })
        owner.capture(.system)
        try makePNG(try #require(child.output))
        let end = try #require(child.ended)
        let waiter = Task { await owner.finishWork(); drained = true }
        let callback = Task { await end(0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while finish == nil && ContinuousClock.now < deadline { await Task.yield() }
        let release = try #require(finish)
        owner.close(); await end(0)
        #expect(owner.hasPendingWork && !drained && child.terminations == 0 && notifications == 1)
        release.resume(); await callback.value; await waiter.value
        #expect(drained && !owner.hasPendingWork)
        #expect(try await store.assets().count == 1)
    }

    @Test func disconnectAndImmediateReconnectWaitForTheActualChildExit() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let child = SyntheticCaptureChild(), adapter = Transport()
        var opens = 0, drained = false
        weak var current: TrayOwner?
        let module = TrayModule { change,error in
            opens += 1
            let owner = TrayOwner(store: store, root: dir, adapter: adapter, policy: .init(), captureEntry: true,
                ownership: try ApplicationInstanceOwnership(root: dir), makeSystemCapture: { child },
                pin: { throw CancellationError() }, permission: { _,_ in false }, notify: change, report: error)
            current = owner; return owner
        }
        try module.start(); await module.connect(); current?.capture(.system)
        let end = try #require(child.ended)
        try makePNG(try #require(child.output))
        module.disconnect()
        let waiter = Task { await module.finishStopping(); drained = true }
        let reconnect = Task { await module.connect() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!drained && opens == 1 && child.terminations == 1 && !module.connected)
        #expect(throws: LibraryError.busy) { try ExistingLibrary.open(dir) }
        child.ended = nil
        await end(0); await waiter.value; await reconnect.value
        #expect(drained && opens == 2 && module.connected)
        await end(0)
        #expect(try await store.assets().isEmpty)
        module.stop(); await module.finishStopping()
    }
}
