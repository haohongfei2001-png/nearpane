import CryptoKit
import Foundation
import RiftletCapture
import RiftletCore
import Testing

@testable import NearpaneTray

@MainActor @Suite struct CaptureAttachmentProviderTests {
    private func display(
        _ id: UInt32, _ frame: CGRect, quartz: CGRect? = nil, scale: CGFloat = 2,
        rotation: Int = 0
    ) -> CaptureDisplay {
        .init(id: id, uuid: UUID(), appKit: frame, quartz: quartz ?? frame, scale: scale, rotation: rotation)
    }

    private func selection(
        _ mode: ScreenshotMode, _ frame: CGRect, _ displays: [CaptureDisplay],
        _ width: Int, _ height: Int, window: CaptureSelectionSource.Window? = nil
    ) -> CaptureSelectionSource {
        .init(
            mode: mode.rawValue, selectedRect: frame, selectedDisplayIDs: displays.map(\.id), displays: displays,
            windowID: mode == .window ? 97 : nil, owner: window, encodedWidth: width, encodedHeight: height)
    }

    @Test func retinaPortraitAndNegativeOriginsUseBothDisplayCoordinateSystems() {
        let screen = display(
            8, CGRect(x: -60, y: 20, width: 60, height: 100),
            quartz: CGRect(x: -60, y: -20, width: 60, height: 100), rotation: 90)
        let crop = CGRect(x: -40, y: 60, width: 25, height: 15)
        let quartzCrop = CGRect(x: -40, y: 25, width: 25, height: 15)
        #expect(screen.quartzRect(crop) == quartzCrop)
        #expect(selection(.fullScreen, screen.appKit, [screen], 120, 200).coverage(width: 120, height: 200) == .exact)
        #expect(selection(.region, crop, [screen], 50, 30).coverage(width: 50, height: 30) == .explicitRegion)
        let owner = CaptureSelectionSource.Window(
            windowID: 97, pid: 7, processBirth: 45, applicationID: "test.fixture", quartzFrame: quartzCrop)
        #expect(
            selection(.window, crop, [screen], 50, 30, window: owner).coverage(width: 50, height: 30) == .windowGeometryOnly)
        #expect(
            selection(.window, crop, [screen], 80, 70, window: owner).coverage(width: 80, height: 70)
                == .windowMarginsUnknown)
        #expect(selection(.window, crop, [screen], 50, 30).coverage(width: 50, height: 30) == .missingIdentity)
        #expect(selection(.region, crop, [screen], 50, 30).coverage(width: 25, height: 15) == .invalid)
    }

    @Test func crossDisplayGeometryDistinguishesContiguousMixedScaleGapsAndMirroring() {
        let left = display(1, CGRect(x: -100, y: 0, width: 100, height: 100))
        let right = display(2, CGRect(x: 0, y: 0, width: 100, height: 100))
        let crop = CGRect(x: -10, y: 5, width: 20, height: 85)
        #expect(selection(.region, crop, [left, right], 40, 170).coverage(width: 40, height: 170) == .explicitRegion)
        #expect(selection(.fullScreen, crop, [left, right], 40, 170).coverage(width: 40, height: 170) == .invalid)
        let external = display(2, right.appKit, scale: 1, rotation: 180)
        #expect(selection(.region, crop, [left, external], 40, 170).coverage(width: 40, height: 170) == .mixedScaleUnknown)
        let shifted = display(2, right.appKit.offsetBy(dx: 5, dy: 0))
        #expect(selection(.region, crop, [left, shifted], 40, 170).coverage(width: 40, height: 170) == .invalid)
        let wrongQuartz = display(2, right.appKit, quartz: right.appKit.offsetBy(dx: 0, dy: 3))
        #expect(selection(.region, crop, [left, wrongQuartz], 40, 170).coverage(width: 40, height: 170) == .invalid)
        let mirror = display(2, left.appKit)
        #expect(selection(.region, left.appKit, [left, mirror], 200, 200).coverage(width: 200, height: 200) == .invalid)
        #expect(selection(.region, left.appKit, [left, left], 200, 200).coverage(width: 200, height: 200) == .invalid)
        #expect(CaptureSelectionSource.systemPicker.coverage(width: 2400, height: 1000) == .systemPickerUnknown)
    }

    private func isolatedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "nearpane-p3-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func provider(_ root: URL) throws -> RiftletCaptureAttachmentProvider {
        let store = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite"))
        return .init(ledger: .init(root: root), store: store, importer: .init(privateRoot: root, store: store), root: root)
    }

    private func source(_ root: URL) throws -> (URL, Data) {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNQ91/l1DGH4cwql/K0UAAk9wVzjPxe1gAAAABJRU5ErkJggg=="
            ))
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captures, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = captures.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: file, options: .withoutOverwriting)
        return (file, png)
    }

    private func event(_ p: RiftletCaptureAttachmentProvider, _ id: UUID, _ phase: String) throws -> TrayEvidenceLedger.Event
    {
        let path = p.ledger.directory.appendingPathComponent(id.uuidString + "." + phase + ".json")
        return try JSONDecoder().decode(TrayEvidenceLedger.Event.self, from: Data(contentsOf: path))
    }

    @Test func lockedImporterAndIndependentBytesMustMatchBeforeCaptureIsVerified() async throws {
        let root = try isolatedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try provider(root)
        let id = UUID()
        let (url, png) = try source(root)
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let frame = CGRect(x: 10, y: 10, width: 1, height: 1)
        let display = display(5, CGRect(x: 0, y: 0, width: 60, height: 60))
        let crop = selection(.region, frame, [display], 2, 2)
        try p.began(id, mode: "region")
        let row = try await p.completed(
            id, source: crop, url: url, directory: url.deletingLastPathComponent(), captureHash: hash)
        let observed = try event(p, id, "terminal")
        #expect(observed.source == crop)
        #expect(observed.asset?.captureID == id)
        #expect(observed.asset?.assetID == row.id)
        #expect(observed.asset?.sha256 == hash)
        #expect(observed.asset?.pixelWidth == 2 && observed.asset?.pixelHeight == 2)
        #expect(observed.state == "explicitRegion")
        #expect(observed.independentObservation == "durableRowAndFileHashAndDimensions")
        #expect(FileManager.default.fileExists(atPath: try #require(observed.asset?.fileURL.path)))
        let restarted = try provider(root)
        #expect(try await restarted.store.asset(id: row.id)?.image == row.image)
        let second = UUID()
        let (differentURL, _) = try source(root)
        try p.began(second, mode: "region")
        await #expect(throws: (any Error).self) {
            _ = try await p.completed(
                second, source: crop, url: differentURL, directory: differentURL.deletingLastPathComponent(),
                captureHash: String(repeating: "0", count: 64))
        }
        #expect(try event(p, second, "terminal").state == "unconfirmed")
        #expect(try event(p, id, "terminal").asset?.sha256 == hash)
    }

    @Test func immutableLedgerPreservesTimeoutCancellationAndRejectsSymlinkDirectory() throws {
        let root = try isolatedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try provider(root)
        let id = UUID()
        try p.began(id, mode: "region")
        #expect(throws: (any Error).self) { try p.began(id, mode: "system") }
        try p.failed(
            id, mode: "region", state: "captureFailed", dispatched: "selectionConfirmed", timeout: true,
            cleanup: "requestRetired")
        #expect(throws: (any Error).self) {
            try p.failed(
                id, mode: "region", state: "cancelled", dispatched: "selectionConfirmed", timeout: nil,
                cleanup: "requestRetired")
        }
        let terminated = try event(p, id, "terminal")
        #expect(terminated.timedOut == true && terminated.cleanup == "requestRetired")
        let other = try isolatedRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createSymbolicLink(
            at: TrayEvidenceLedger(root: other).directory, withDestinationURL: p.ledger.directory)
        #expect(throws: (any Error).self) { try provider(other).began(UUID(), mode: "system") }
    }

    @Test func operationEvidencePreservesOriginalUnknownOnTimeoutDuplicateAndRestart() async throws {
        let root = try isolatedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try provider(root)
        let capture = UUID()
        let first = UUID()
        let second = UUID()
        let (url, _) = try source(root)
        try p.began(capture, mode: "system")
        let row = try await p.completed(
            capture, source: .systemPicker, url: url, directory: url.deletingLastPathComponent(), captureHash: nil)
        let target = TargetLease(
            adapterID: "chatgpt-web", surface: .webChat, applicationID: "com.google.Chrome",
            sessionID: "isolated-process", windowID: "18", tabID: "27", documentID: "fixture", composerID: "editor",
            draftGeneration: "1", clickBindingID: UUID())
        let policy = OrdinaryCaptureConfiguration.admission.receiptPolicy
        let op = try await p.store.prepare(assetID: row.id, target: target)
        try p.requestedAttachment(first, assetID: row.id, sha256: row.image.sha256)
        try await p.routedAttachment(first, assetID: row.id, target: target, surface: nil)
        try await p.inspectAttachment(first, assetID: row.id, target: target, handedOff: true, policy: policy)
        let initial = try event(p, first, "readback")
        #expect(initial.operationID == op.id && initial.timedOut == nil && initial.state == "unknown")
        let restarted = try provider(root)
        try await restarted.reconcileAttachment(operationID: op.id, policy: policy, observationExpired: true)
        let late = try event(restarted, first, "timeout")
        #expect(late.timedOut == true && late.operationID == op.id && late.cleanup == "originalOperationRetained")
        try p.requestedAttachment(second, assetID: row.id, sha256: row.image.sha256)
        try await p.inspectAttachment(second, assetID: row.id, target: target, handedOff: true, policy: policy)
        #expect(try event(p, second, "terminal").state == "noNewOperation")
        #expect(try await p.store.operation(id: op.id)?.attempt == 1)
    }

    @Test func recoveredDispatchReadsOnlyOriginalIntentAndRequiresBothAdmittedReceipts() async throws {
        let root = try isolatedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite"), mode: .simulation)
        let p = RiftletCaptureAttachmentProvider(
            ledger: .init(root: root), store: store, importer: .init(privateRoot: root, store: store), root: root)
        let id = UUID()
        let click = UUID()
        let retry = UUID()
        let image = ImportedAsset(
            id: id, sourceKey: "p3-generated", fileName: id.uuidString + ".png", sha256: String(repeating: "b", count: 64),
            byteCount: 4, pixelWidth: 1, pixelHeight: 1, mediaType: "image/png", origin: .synthetic)
        _ = try await store.importAsset(image)
        let target = TargetLease(
            adapterID: "simulation", surface: .simulation, applicationID: "test.fixture", sessionID: "test",
            windowID: "5", tabID: "7", documentID: "fixture", composerID: "composer", draftGeneration: "1",
            clickBindingID: UUID())
        let policy = ReceiptPolicy()
        try p.requestedAttachment(click, assetID: id, sha256: image.sha256)
        try await p.routedAttachment(click, assetID: id, target: target, surface: nil)
        let op = try await store.prepare(assetID: id, target: target)
        _ = try await store.markDispatchIntent(op.id)
        // Simulate process termination between transfer.select and its observation callback.
        let reopenedStore = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite"), mode: .simulation)
        let observer = RiftletCaptureAttachmentProvider(
            ledger: .init(root: root), store: reopenedStore,
            importer: .init(privateRoot: root, store: reopenedStore), root: root)
        try observer.requestedAttachment(retry, assetID: id, sha256: image.sha256)
        try await observer.routedAttachment(retry, assetID: id, target: target, surface: nil)
        try await observer.inspectAttachment(retry, assetID: id, target: target, handedOff: true, policy: policy)
        #expect(try event(observer, retry, "terminal").state == "noNewOperation")
        try await observer.reconcileAttachment(operationID: op.id, policy: policy, observationExpired: true)
        #expect(try event(observer, click, "timeout").invocationID != nil)
        let start = TransferReceipt(
            operationID: op.id, assetID: id, attempt: op.attempt, assetSHA256: image.sha256, target: target,
            outcome: .uploadStarted, profileID: "simulation-v1", attachmentID: "fixture-file",
            belongsToOriginalDraft: true, isUploading: true,
            uploadStartEvidence: .init(
                profileID: "simulation-upload-start-v1", signal: .correlatedProgress, evidenceID: "fixture-progress"))
        _ = try await store.apply(start, policy: policy)
        try await observer.reconcileAttachment(operationID: op.id, policy: policy, observationExpired: false)
        #expect(try event(observer, click, "uploadStart").state == "uploadStarted")
        #expect(throws: (any Error).self) { _ = try event(observer, click, "terminal") }
        let final = TransferReceipt(
            operationID: op.id, assetID: id, attempt: op.attempt, assetSHA256: image.sha256, target: target,
            outcome: .verifiedReady, profileID: "simulation-v1", attachmentID: "fixture-file",
            positiveReady: true, belongsToOriginalDraft: true)
        _ = try await store.apply(final, policy: policy)
        try await observer.reconcileAttachment(operationID: op.id, policy: policy, observationExpired: false)
        #expect(try event(observer, click, "terminal").state == "adapterVerifiedReady")
        #expect(try event(observer, click, "timeout").state == "unknown")
    }

    @Test func allTwelveRoutesExplicitlySeparateBrowserAndServiceSupport() throws {
        for browser in DraftBrowser.allCases {
            for service in DraftService.allCases {
                let url = try #require(URL(string: "https://" + service.rawValue + "/"))
                let route = try #require(DraftCapability.route(browserID: browser.rawValue, url: url))
                #expect(route.service == service && route.browser == browser)
                let audited = browser == .chrome && service == .chatGPT
                #expect((route.writerID != nil) == audited)
                #expect(route.acceptsSelectedDraft(url) == audited)
            }
        }
        let chrome = DraftBrowser.chrome.rawValue
        for raw in [
            "http://chatgpt.com/", "https://chatgpt.com.evil.invalid/", "https://u@chatgpt.com/",
            "https://chatgpt.com:8443/",
        ] {
            #expect(DraftCapability.route(browserID: chrome, url: try #require(URL(string: raw))) == nil)
        }
        let settings = try #require(URL(string: "https://chatgpt.com/settings"))
        #expect(
            try #require(DraftCapability.route(browserID: chrome, url: settings)).acceptsSelectedDraft(settings) == false)
    }
}
