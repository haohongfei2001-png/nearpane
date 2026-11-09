import AppKit
import RiftletCore
import RiftletUI
import RiftletAdapters
import RiftletCapture

/// The data plane: exactly one existing store plus its original importer and transfer coordinator.
/// A test may supply an isolated store and transport; the ordinary factory never creates a library.
@MainActor
final class TrayOwner {
    let store: QueueStore
    let transfer: TransferCoordinator
    let authority: SelectionAuthority
    let thumbnails: ThumbnailCache
    let captureEntry: Bool
    let defaultMode: ScreenshotMode
    let root: URL
    let importer: PrivateAssetImporter
    var mayObserveTestClaim: () -> Bool = { false }
    var checkAsset: (ImportedAsset) throws -> Void = { _ in }
    let pinTarget: () throws -> Task<TargetLease, Error>
    let checkPermission: (Bool, String?) async -> Bool
    private var captureController: InteractiveScreenshotController?
    let magnetEnabled: Bool
    var arrived: ((TrayArrival) -> Void)?
    var exposureChanged: (Bool) -> Void = { _ in }
    private var hasCapturePermission: () -> Bool = { true }
    private let makeSystemCapture: @MainActor () -> any SystemCaptureProcess
    private var systemCapture: SystemCaptureJob?
    private(set) var cancelled = false
    private var workCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var hasPendingWork: Bool { workCount > 0 }
    let notify: @MainActor () async -> Void
    let report: @MainActor (String) -> Void
    // Other objects/tasks that continue domain work retain this same lock, even after UI disable.
    private let ownership: ApplicationInstanceOwnership?

    static func existing(root: URL, testSession: URL? = nil, notify: @escaping @MainActor () async -> Void,
                         report: @escaping @MainActor (String) -> Void) async throws -> TrayOwner {
        let library = try await Task.detached(priority: .userInitiated) { try ExistingLibrary.open(root) }.value
        let prefs = try ScreenshotEntryPreferences.load(from: root.appendingPathComponent("capture-entry-settings.json"))
        let policy = OrdinaryCaptureConfiguration.admission
        guard policy.usesUnifiedProduct, policy.allowsInput else { throw LibraryError.incompatible }
        let browser = ChromeAppleEventsExecutor()
        var bound: BoundTestExecutor?
        if let testSession {
            guard let url = Bundle.main.url(forResource: "AcceptanceTargetGuard", withExtension: "js") else { throw WebAdapterError.programUnavailable }
            bound = BoundTestExecutor(directory: testSession, base: browser, guardSource: try String(contentsOf: url, encoding: .utf8))
        }
        let executor: any WebClickTargetPinning
        if let bound { executor = bound } else { executor = browser }
        let adapter = WebAttachmentAdapter(mediaDirectory: root.appendingPathComponent("media"),
            executor: executor, program: try ChatGPTWebPageProgram.load(), mode: .ordinaryProduct,
            profile: policy.observationProfile, productStore: library.store, productOrigins: policy.productOrigins)
        let checker = NativeAutomationPermissionChecker()
        let owner = TrayOwner(store: library.store, root: root, adapter: adapter, policy: policy.receiptPolicy,
                         captureEntry: prefs.builtInScreenshotEnabled, defaultMode: prefs.defaultMode,
                         ownership: library.lock, magnetEnabled: ArrivalMotionPreferences(url: root.appendingPathComponent("arrival-motion-settings.json")).mode == .magnet, pin: { try adapter.targetForClick() },
                         permission: { ask, session in await checker.check(askUserIfNeeded: ask && testSession == nil, expectedSession: session) == .granted },
                         notify: notify, report: report)
        if let bound {
            owner.mayObserveTestClaim = { bound.hasClaim }
            owner.checkAsset = { try bound.checkAsset($0) }
            owner.hasCapturePermission = { CGPreflightScreenCaptureAccess() }
        }
        // An explicit connection owns the original lock: finish already-journaled local imports
        // before projecting the queue. Never reinterpret an interrupted external transfer as a new click.
        let recovered = try await owner.importer.recover()
        if !recovered.invalid.isEmpty || !recovered.missing.isEmpty {
            report("部分截图缺失或无法校验，已保留原记录。")
        }
        return owner
    }

    init(store: QueueStore, root: URL, adapter: any AttachmentAdapter, policy: ReceiptPolicy,
         captureEntry: Bool, defaultMode: ScreenshotMode = .window, ownership: ApplicationInstanceOwnership? = nil, magnetEnabled: Bool = false,
         makeSystemCapture: @escaping @MainActor () -> any SystemCaptureProcess = { MacSystemCaptureProcess() },
         pin: @escaping () throws -> Task<TargetLease, Error>, permission: @escaping (Bool, String?) async -> Bool,
         notify: @escaping @MainActor () async -> Void, report: @escaping @MainActor (String) -> Void) {
        self.store = store; self.root = root; self.ownership = ownership; self.captureEntry = captureEntry
        self.defaultMode = defaultMode; self.pinTarget = pin; self.checkPermission = permission
        self.makeSystemCapture = makeSystemCapture
        self.magnetEnabled = magnetEnabled
        self.notify = notify; self.report = report
        let authority = SelectionAuthority()
        self.authority = authority
        let media = root.appendingPathComponent("media")
        thumbnails = ThumbnailCache(directory: media)
        importer = PrivateAssetImporter(privateRoot: root, store: store)
        transfer = TransferCoordinator(store: store, adapter: adapter, mediaDirectory: media, policy: policy,
            onChange: { [ownership] in await notify(); withExtendedLifetime(ownership) {} },
            onAcceptedSelectionFinished: { id in await authority.finish(id) },
            validateAcceptedSelection: { token in
                let authorized = await permission(false, token.target.sessionID)
                return await MainActor.run {
                    authorized && authority.permits(token, epoch: token.hostEpoch, foregroundSession: nil,
                        hidden: false, terminating: false, now: ProcessInfo.processInfo.systemUptime)
                }
            })
    }

    func cancelPresses() {
        let ids = authority.cancel()
        guard !ids.isEmpty else { return }
        workCount += 1
        Task {
            defer { endWork() }
            try? await transfer.cancelAcceptedSelections(ids: ids, reason: "Tray interaction ended")
        }
    }
    // Keep the existing lock until imports, previously admitted inputs and their journal writes settle.
    func performWork<T>(_ operation: () async throws -> T) async throws -> T {
        guard !cancelled else { throw CancellationError() }
        workCount += 1
        defer { endWork() }
        return try await operation()
    }
    private func endWork() {
        workCount -= 1
        guard workCount == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func finishWork() async {
        guard hasPendingWork else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    func close() {
        guard !cancelled else { return }
        cancelled = true; cancelPresses()
        captureController?.setEnabled(false); captureController = nil
        if let job = systemCapture, !job.completing { job.process.terminate() }
        exposureChanged(false); thumbnails.clear()
    }

    func capture(_ action: TrayCapture) {
        guard !cancelled, captureEntry, systemCapture == nil else { return }
        guard hasCapturePermission() else { report("本次验收需要已授权的屏幕捕获权限。"); return }
        let output = root.appendingPathComponent("captures", isDirectory: true)
        if action == .system {
            guard captureController?.isActive != true else { return }
            do {
                guard output.standardizedFileURL == output.resolvingSymlinksInPath() else { throw LibraryError.incompatible }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                // screencapture refuses dot-prefixed output names, even on a successful selection.
                let target = output.appendingPathComponent(UUID().uuidString + ".png")
                let job = SystemCaptureJob(makeSystemCapture())
                job.owner = self
                systemCapture = job
                workCount += 1
                do {
                    try job.process.start(output: target) { [weak self, weak job] status in
                        guard let self, let job, self.systemCapture === job, !job.completing else { return }
                        job.completing = true
                        defer { self.systemCapture = nil; job.owner = nil; self.endWork() }
                        guard !self.cancelled else { return }
                        self.exposureChanged(false)
                        guard status == 0, FileManager.default.fileExists(atPath: target.path) else {
                            self.report("未取得截图，队列保持不变。")
                            return
                        }
                        await self.importCapture(target, directory: output)
                    }
                    exposureChanged(true)
                } catch {
                    job.owner = nil
                    systemCapture = nil
                    endWork()
                    throw error
                }
            } catch { exposureChanged(false); report("无法启动系统截图。") }
        } else {
            let controller = captureController ?? InteractiveScreenshotController(outputDirectory: output)
            captureController = controller
            controller.onCapture = { [weak self] capture in
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == capture.displayID }
                let source = capture.displayIDs.count == 1 ? screen.map { RiftArrivalSource(rect: capture.rect,
                    displayID: capture.displayID, displayFrame: $0.frame, backingScale: $0.backingScaleFactor) } : nil
                Task { await self?.importCapture(capture.sourceURL, directory: output, source: source) }
            }
            controller.onCaptureVisibilityChanged = { [weak self] in self?.exposureChanged($0) }
            controller.onError = { [weak self] error in self?.report(error.localizedDescription) }
            controller.start(mode: action.mode ?? defaultMode)
        }
    }

    private func importCapture(_ url: URL, directory: URL, source: RiftArrivalSource? = nil) async {
        guard !cancelled else { return }
        do {
            let row = try await performWork {
                try await importer.importBuiltInScreenshot(original: url, outputDirectory: directory)
            }
            if !cancelled, magnetEnabled, let source {
                arrived?(.init(id: row.id, ready: ProcessInfo.processInfo.systemUptime, source: .selected(source)))
            }
            await notify()
        } catch { report("未能收录截图；原文件已保留。") }
    }
}

public enum TrayCapture: CaseIterable, Hashable {
    case region, window, fullScreen, system
    var mode: ScreenshotMode? {
        switch self { case .region: .region; case .window: .window; case .fullScreen: .fullScreen; case .system: nil }
    }
    var label: String {
        switch self { case .region: "区域截图"; case .window: "窗口截图"; case .fullScreen: "全屏截图"; case .system: "系统截图" }
    }
    var symbol: String {
        switch self { case .region: "viewfinder"; case .window: "macwindow"; case .fullScreen: "display"; case .system: "camera" }
    }
}
