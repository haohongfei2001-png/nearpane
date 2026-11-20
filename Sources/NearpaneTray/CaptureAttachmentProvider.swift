import AppKit
import CryptoKit
import Darwin
import NearpaneCore
import RiftletCapture
import RiftletCore

/// AppKit and Quartz both describe the display after physical rotation, using opposite vertical axes.
struct CaptureDisplay: Codable, Equatable, Sendable {
    let id: UInt32
    let uuid: UUID
    let appKit: CGRect
    let quartz: CGRect
    let scale: CGFloat
    let rotation: Int

    @MainActor static func current() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                let raw = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                let uuid = UUID(uuidString: CFUUIDCreateString(nil, raw) as String)
            else { return nil }
            return Self(
                id: id, uuid: uuid, appKit: screen.frame, quartz: CGDisplayBounds(id), scale: screen.backingScaleFactor,
                rotation: Int(CGDisplayRotation(id).rounded()) % 360)
        }
    }
    func quartzRect(_ clipped: CGRect) -> CGRect {
        CGRect(
            x: quartz.minX + clipped.minX - appKit.minX, y: quartz.minY + appKit.maxY - clipped.maxY,
            width: clipped.width, height: clipped.height)
    }
}

extension CGRect {
    fileprivate var measuresArea: Bool {
        !isNull && !isInfinite && [minX, minY, maxX, maxY, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

struct CaptureSelectionSource: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let windowID: UInt32
        let pid: Int32
        let processBirth: UInt64
        let applicationID: String?
        let quartzFrame: CGRect

        @MainActor static func observe(_ id: UInt32) -> Self? {
            guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]], rows.count == 1,
                let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id,
                let pid = row[kCGWindowOwnerPID as String] as? Int32,
                let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                let before = try? OrdinaryProcessImage.read(pid)
            else { return nil }
            let appID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard (try? OrdinaryProcessImage.read(pid)) == before else { return nil }
            return Self(windowID: id, pid: pid, processBirth: before.launch, applicationID: appID, quartzFrame: frame)
        }
    }
    let mode: String
    let selectedRect: CGRect?
    let quartzSelectionRect: CGRect?
    let selectedDisplayIDs: [UInt32]
    let displays: [CaptureDisplay]
    let windowID: UInt32?
    let owner: Window?
    let encodedWidth: Int?
    let encodedHeight: Int?

    static let systemPicker = Self(
        mode: "system", selectedRect: nil, selectedDisplayIDs: [], displays: [],
        windowID: nil, owner: nil, encodedWidth: nil, encodedHeight: nil)
    @MainActor init(_ result: InteractiveScreenshotCapture) {
        self.init(
            mode: result.mode.rawValue, selectedRect: result.rect, selectedDisplayIDs: result.displayIDs,
            displays: CaptureDisplay.current().filter { result.displayIDs.contains($0.id) }, windowID: result.windowID,
            owner: result.windowID.flatMap(Window.observe), encodedWidth: result.pixelWidth,
            encodedHeight: result.pixelHeight)
    }
    init(
        mode: String, selectedRect: CGRect?, selectedDisplayIDs: [UInt32], displays: [CaptureDisplay], windowID: UInt32?,
        owner: Window?, encodedWidth: Int?, encodedHeight: Int?
    ) {
        self.mode = mode
        self.selectedRect = selectedRect
        self.quartzSelectionRect = selectedRect.flatMap { rect in displays.first.map { $0.quartzRect(rect) } }
        self.selectedDisplayIDs = selectedDisplayIDs
        self.displays = displays
        self.windowID = windowID
        self.owner = owner
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
    }

    enum Coverage: String, Codable {
        case exact, windowGeometryOnly, explicitRegion, systemPickerUnknown, mixedScaleUnknown, windowMarginsUnknown,
            missingIdentity, invalid
    }
    func coverage(width: Int, height: Int) -> Coverage {
        guard mode != "system" else { return .systemPickerUnknown }
        guard ScreenshotMode(rawValue: mode) != nil, let rect = selectedRect, rect.measuresArea,
            width == encodedWidth, height == encodedHeight, width > 0, height > 0, let first = displays.first,
            displays.count == selectedDisplayIDs.count, Set(selectedDisplayIDs).count == selectedDisplayIDs.count,
            Set(displays.map(\.id)) == Set(selectedDisplayIDs), Set(displays.map(\.uuid)).count == displays.count
        else { return .invalid }
        var clips = [CGRect]()
        for display in displays {
            guard display.appKit.measuresArea, display.quartz.measuresArea,
                display.appKit.minX == display.quartz.minX,
                display.appKit.maxY + display.quartz.minY == first.appKit.maxY + first.quartz.minY,
                [0, 90, 180, 270].contains(display.rotation),
                display.appKit.size == display.quartz.size,
                display.scale.isFinite, display.scale > 0
            else { return .invalid }
            let clip = rect.intersection(display.appKit)
            guard !clip.isNull, !clip.isEmpty,
                !clips.contains(where: { $0.intersects(clip) && !$0.intersection(clip).isEmpty })
            else { return .invalid }
            clips.append(clip)
        }
        guard abs(clips.reduce(0) { $0 + $1.width * $1.height } - rect.width * rect.height) < 0.001 else { return .invalid }
        let quartz = zip(displays, clips).reduce(CGRect.null) { $0.union($1.0.quartzRect($1.1)) }
        guard quartz == quartzSelectionRect else { return .invalid }
        guard displays.allSatisfy({ $0.scale == first.scale }) else { return .mixedScaleUnknown }
        let expected = CGSize(width: (rect.width * first.scale).rounded(), height: (rect.height * first.scale).rounded())
        if mode == ScreenshotMode.window.rawValue {
            guard let owner, owner.windowID == windowID else { return .missingIdentity }
            guard quartz == owner.quartzFrame else { return .invalid }
            if CGFloat(width) >= expected.width && CGFloat(height) >= expected.height
                && CGSize(width: width, height: height) != expected
            {
                return .windowMarginsUnknown
            }
        }
        guard CGSize(width: width, height: height) == expected else { return .invalid }
        if mode == ScreenshotMode.fullScreen.rawValue && (displays.count != 1 || rect != first.appKit) { return .invalid }
        // The pinned public request omits the frozen owner PID. A post-capture process
        // sample can bracket this geometry read, but cannot prove the original process birth.
        if mode == ScreenshotMode.window.rawValue { return .windowGeometryOnly }
        return mode == ScreenshotMode.region.rawValue ? .explicitRegion : .exact
    }
}

struct CaptureArtifact: Codable, Equatable {
    let captureID: UUID
    let assetID: UUID
    let fileURL: URL
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Local immutable events. Staging + exclusive hard-link prevents a partial or overwritten terminal receipt.
struct TrayEvidenceLedger {
    struct Event: Codable {
        let intentID: UUID
        let stage: String
        var monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        var action: String
        var source: CaptureSelectionSource?
        var asset: CaptureArtifact?
        var target: TargetLease?
        var browserAddress: DraftAddress?
        var surface: DraftSurface?
        var assetID: UUID?
        var sourceSHA256: String?
        var operationID: UUID?
        var invocationID: UUID?
        var dispatch: String
        var independentObservation: String
        var state: String
        var timedOut: Bool?
        var cleanup: String
    }
    let directory: URL
    init(root: URL) { directory = root.appendingPathComponent("capture-attachment-evidence-v1", isDirectory: true) }
    func recordObservation(_ event: Event) throws {
        // Concurrent refreshes and later process connections may witness the same durable state.
        do { try append(event) } catch let error as POSIXError where error.code == .EEXIST {}
    }
    func append(_ event: Event) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EIO) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            ["intent", "providerStart", "dispatch", "terminal", "readback", "uploadStart", "timeout"].contains(event.stage)
        else { throw POSIXError(.EACCES) }
        let scratch = "." + UUID().uuidString
        let final = event.intentID.uuidString + "." + event.stage + ".json"
        let temporary = openat(fd, scratch, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard temporary >= 0 else { throw POSIXError(.EIO) }
        defer {
            close(temporary)
            unlinkat(fd, scratch, 0)
        }
        let writer = FileHandle(fileDescriptor: temporary, closeOnDealloc: false)
        try writer.write(contentsOf: JSONEncoder().encode(event))
        try writer.synchronize()
        guard linkat(fd, scratch, fd, final, 0) == 0 else { throw POSIXError(errno == EEXIST ? .EEXIST : .EIO) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}

/// All image collection, decoding for import, and queue mutation still run in the locked Riftlet components.
@MainActor protocol CaptureAttachmentProvider {
    func began(_ id: UUID, mode: String) throws
    func startingCapture(_ id: UUID, mode: String, nativeState: String) throws
    func completed(_ id: UUID, source: CaptureSelectionSource, url: URL, directory: URL, captureHash: String?) async throws
        -> AssetRecord
    func failed(_ id: UUID, mode: String, state: String, dispatched: String, timeout: Bool?, cleanup: String) throws
    func reconcileAttachment(operationID: UUID, policy: ReceiptPolicy, observationExpired: Bool) async throws
    func requestedAttachment(_ id: UUID, assetID: UUID, sha256: String) throws
    func haltedAttachment(_ id: UUID, assetID: UUID, state: String, capability: DraftCapabilityFailure?) throws
    func routedAttachment(_ id: UUID, assetID: UUID, target: TargetLease, surface: DraftBoundSurface?) async throws
    func inspectAttachment(_ id: UUID, assetID: UUID, target: TargetLease?, handedOff: Bool, policy: ReceiptPolicy)
        async throws
}

@MainActor struct RiftletCaptureAttachmentProvider: CaptureAttachmentProvider {
    let ledger: TrayEvidenceLedger
    let store: QueueStore
    let importer: PrivateAssetImporter
    let root: URL
    func began(_ id: UUID, mode: String) throws {
        try ledger.append(
            .init(
                intentID: id, stage: "intent", action: mode, dispatch: "notIssued", independentObservation: "notRun",
                state: "requested", cleanup: "notStarted"))
    }
    func startingCapture(_ id: UUID, mode: String, nativeState: String) throws {
        try ledger.append(
            .init(
                intentID: id, stage: "providerStart", action: mode, dispatch: nativeState,
                independentObservation: "pending", state: "awaitingProvider", cleanup: "pending"))
    }
    func requestedAttachment(_ id: UUID, assetID: UUID, sha256: String) throws {
        try ledger.append(
            .init(
                intentID: id, stage: "intent", action: "attach", assetID: assetID, sourceSHA256: sha256,
                dispatch: "notIssued", independentObservation: "notRun", state: "requested", cleanup: "notStarted"))
    }
    func haltedAttachment(_ id: UUID, assetID: UUID, state: String, capability: DraftCapabilityFailure?) throws {
        var event = TrayEvidenceLedger.Event(
            intentID: id, stage: "terminal", action: "attach", assetID: assetID,
            dispatch: "notIssued", independentObservation: "noBrowserInput", state: state, cleanup: "selectionReleased")
        switch capability {
        case .noWriter(_, let bound), .loginRequired(let bound):
            event.browserAddress = bound.address
            event.surface = bound.surface
            event.independentObservation = "selectedSurfaceRead"
        case .indexedTab(let address):
            event.browserAddress = address
            event.independentObservation = "stableTabIDAbsent"
        case .readUnavailable, .none: break
        }
        do { try ledger.append(event) } catch let error as POSIXError where error.code == .EEXIST {}
    }
    private struct RouteIntent: Codable {
        let id: UUID
        let assetID: UUID
        let target: TargetLease
    }
    private func pinKey(_ assetID: UUID, _ target: TargetLease) -> String? {
        target.clickBindingID.map { "nearpane-capture-attachment-pin-v1:" + assetID.uuidString + ":" + $0.uuidString }
    }
    private func preservedIntent(for op: TransferOperation) async throws -> UUID? {
        guard let key = pinKey(op.assetID, op.target), let data = try await store.checkpoint(for: key) else { return nil }
        let registered = try JSONDecoder().decode(RouteIntent.self, from: data)
        guard registered.target == op.target, registered.assetID == op.assetID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return registered.id
    }
    func routedAttachment(_ id: UUID, assetID: UUID, target: TargetLease, surface: DraftBoundSurface?) async throws {
        try ledger.append(
            .init(
                intentID: id, stage: "dispatch", action: "attach", target: target, browserAddress: surface?.address,
                surface: surface?.surface, assetID: assetID, dispatch: "handedToRiftlet", independentObservation: "pending",
                state: "bound", cleanup: "pending"))
        if let key = pinKey(assetID, target) {
            // Written before transfer.select; a crash before the post-dispatch callback must preserve its original owner.
            _ = try await store.saveCheckpointIfAbsent(
                try JSONEncoder().encode(RouteIntent(id: id, assetID: assetID, target: target)), for: key)
        }
    }
    private func operationKey(_ id: UUID) -> String { "nearpane-capture-attachment-v1:" + id.uuidString }
    func inspectAttachment(_ id: UUID, assetID: UUID, target: TargetLease?, handedOff: Bool, policy: ReceiptPolicy)
        async throws
    {
        guard handedOff, let target, let row = try await store.asset(id: assetID),
            let opID = row.activeOperationID, let op = try await store.operation(id: opID),
            op.assetID == assetID, op.target == target
        else {
            try ledger.append(
                .init(
                    intentID: id, stage: "terminal", action: "attach", target: target, assetID: assetID,
                    dispatch: handedOff ? "handedToRiftlet" : "notIssued", independentObservation: "noMatchingOperation",
                    state: handedOff ? "unknown" : "refused", cleanup: "selectionReleased"))
            return
        }
        let original = try await preservedIntent(for: op) ?? id
        let bound = try await store.saveCheckpointIfAbsent(Data(original.uuidString.utf8), for: operationKey(op.id))
        guard bound == Data(id.uuidString.utf8) else {
            try ledger.append(
                .init(
                    intentID: id, stage: "terminal", action: "attach", target: target, assetID: assetID, operationID: op.id,
                    dispatch: "handedToRiftlet", independentObservation: "previousOperation", state: "noNewOperation",
                    cleanup: "originalOperationRetained"))
            return
        }
        try await readback(id, row: row, op: op, policy: policy, initial: true, observationExpired: false)
    }
    func reconcileAttachment(operationID: UUID, policy: ReceiptPolicy, observationExpired: Bool = false) async throws {
        guard let op = try await store.operation(id: operationID), let row = try await store.asset(id: op.assetID),
            row.activeOperationID == operationID
        else { return }
        let key = operationKey(operationID)
        var bytes = try await store.checkpoint(for: key)
        if bytes == nil, let original = try await preservedIntent(for: op) {
            bytes = try await store.saveCheckpointIfAbsent(Data(original.uuidString.utf8), for: key)
        }
        guard let bytes, let id = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else { return }
        try await readback(id, row: row, op: op, policy: policy, initial: false, observationExpired: observationExpired)
    }
    private func readback(
        _ id: UUID, row: AssetRecord, op: TransferOperation, policy: ReceiptPolicy, initial: Bool, observationExpired: Bool
    ) async throws {
        let trigger = try await store.dispatchInvocationID(for: op.id)
        let start = try await store.uploadStartReceipt(for: op.id)
        let final = try await store.receipt(for: op.id)
        let mode = await store.mode
        let matches = { (receipt: TransferReceipt) in
            receipt.operationID == op.id && receipt.assetID == row.id && receipt.assetSHA256 == row.image.sha256
                && receipt.target == op.target && receipt.attempt == op.attempt
        }
        let provenStart =
            start.map { matches($0) && policy.allowsUploadStart(receipt: $0, asset: row.image, mode: mode) } == true
            && trigger != nil
        if provenStart {
            try ledger.recordObservation(
                .init(
                    intentID: id, stage: "uploadStart", action: "attach", target: op.target,
                    assetID: row.id, sourceSHA256: row.image.sha256, operationID: op.id, invocationID: trigger,
                    dispatch: "dispatchIntentCheckpoint",
                    independentObservation: "matchingUploadStartReceipt", state: "uploadStarted",
                    cleanup: "originalOperationRetained"))
        }
        var state = "unknown"
        var observation = "durableOperation:" + op.phase.rawValue
        if provenStart, let final, matches(final), op.phase == .succeeded, row.status == .used,
            policy.allowsConsumption(receipt: final, asset: row.image, mode: mode)
        {
            state = "adapterVerifiedReady"
            observation = "matchingUploadAndRenderedDraftReceipts"
        } else if op.phase == .failed {
            state = "failed"
        }
        let terminal = !op.phase.isUnresolved
        guard terminal || initial || observationExpired else { return }
        let stage = terminal ? "terminal" : observationExpired ? "timeout" : "readback"
        let event = TrayEvidenceLedger.Event(
            intentID: id, stage: stage, action: "attach", target: op.target, assetID: row.id, sourceSHA256: row.image.sha256,
            operationID: op.id, invocationID: trigger,
            dispatch: trigger == nil ? "noDispatchCheckpoint" : "dispatchIntentCheckpoint",
            independentObservation: observation,
            state: state, timedOut: terminal ? false : observationExpired ? true : nil,
            cleanup: terminal ? "selectionReleased" : "originalOperationRetained")
        try ledger.recordObservation(event)
    }
    func failed(_ id: UUID, mode: String, state: String, dispatched: String, timeout: Bool? = nil, cleanup: String) throws {
        try ledger.append(
            .init(
                intentID: id, stage: "terminal", action: mode, dispatch: dispatched, independentObservation: "notConfirmed",
                state: state, timedOut: timeout, cleanup: cleanup))
    }
    func completed(_ id: UUID, source: CaptureSelectionSource, url: URL, directory: URL, captureHash: String?) async throws
        -> AssetRecord
    {
        try ledger.append(
            .init(
                intentID: id, stage: "dispatch", action: source.mode, source: source, dispatch: "captureReturned",
                independentObservation: "pending", state: "received", cleanup: "pending"))
        if let w = source.encodedWidth, let h = source.encodedHeight, source.coverage(width: w, height: h) == .invalid {
            try failed(
                id, mode: source.mode, state: "invalidSelectionGeometry", dispatched: "captureReturned",
                cleanup: "sourceRetained")
            throw CocoaError(.fileReadCorruptFile)
        }
        let row: AssetRecord
        do { row = try await importer.importBuiltInScreenshot(original: url, outputDirectory: directory) } catch {
            try failed(
                id, mode: source.mode, state: "importFailed", dispatched: "captureReturned", cleanup: "sourceRetained")
            throw error
        }
        let image = row.image
        let artifact = CaptureArtifact(
            captureID: id, assetID: row.id,
            fileURL: root.appendingPathComponent("media").appendingPathComponent(image.fileName), sha256: image.sha256,
            pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
        let stored = try? await store.asset(id: row.id)
        let dims = await ScreenshotArchiveMedia.shared.verifiedDimensions(image, root: root)
        let intact =
            stored?.image == image && dims == CGSize(width: image.pixelWidth, height: image.pixelHeight)
            && (captureHash == nil || captureHash == image.sha256)
        let cover = source.coverage(width: image.pixelWidth, height: image.pixelHeight)
        let cleanup = FileManager.default.fileExists(atPath: url.path) ? "sourceRetained" : "sourceRemoved"
        try ledger.append(
            .init(
                intentID: id, stage: "terminal", action: source.mode, source: source, asset: artifact,
                dispatch: "captureReturned",
                independentObservation: intact ? "durableRowAndFileHashAndDimensions" : "missingOrMismatchedIndependentRead",
                state: intact ? cover.rawValue : "unconfirmed", timedOut: false, cleanup: cleanup))
        guard intact, cover != .invalid else { throw CocoaError(.fileReadCorruptFile) }
        return row
    }
}
