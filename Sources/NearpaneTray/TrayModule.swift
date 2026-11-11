import AppKit
import NearpaneCore
import Observation
import RiftletCore
import RiftletCapture
import RiftletUI

@MainActor
struct TrayPress {
    let id: UUID
    let revision: Int64
    let epoch: UUID
    let target: Task<TargetLease, Error>
}

/// An ephemeral view of Riftlet's durable visibility/operations, not a Host queue.
@MainActor @Observable
public final class TrayModule: HostModule {
    typealias Open = (@escaping @MainActor () async -> Void, @escaping @MainActor (String) -> Void) async throws -> TrayOwner
    @ObservationIgnored private let open: Open
    @ObservationIgnored private var owner: TrayOwner?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var interaction = UUID()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var acceptedRows: [UUID: Int64] = [:]
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var observe: Task<Void, Never>?
    @ObservationIgnored private var pressTask: Task<TargetLease, Error>?
    @ObservationIgnored private var resolvingPresses: [UUID: Task<TargetLease, Error>] = [:]
    @ObservationIgnored var pointer = PointerSelectionGate()
    private(set) var rows: [AssetRecord] = []
    public var visibleIDs: [UUID] { rows.map(\.id) }
    private(set) var swallowing = Set<UUID>()
    private(set) var expanded = false
    public private(set) var active = false
    public private(set) var connected = false
    public private(set) var connecting = false
    public private(set) var localOnly = false
    public let productAttachments: Bool
    public private(set) var attachmentFeedback: String?
    @ObservationIgnored private var currentFeedbackAsset: UUID?
    @ObservationIgnored private var feedbackFromCurrentConnection = false
    @ObservationIgnored private var permissionRequest = UUID()
    private static let consentKey = "nearpane-draft-attachments-enabled-v1"
    private static let feedbackKey = "nearpane-last-selected-asset-v1"
    /// Only supplied by the marked secondary review with its own retained NSWindow.
    public var reviewCaptureWindow: (@MainActor () throws -> UInt32)?
    public private(set) var mayAttach = false
    public private(set) var captureEntry = false
    public private(set) var issue: String?
    private(set) var menuOrder = Array(TrayCapture.allCases)
    private var hidden = false
    private(set) var arrival: TrayArrival?
    private(set) var flyingID: UUID?
    @ObservationIgnored private var flight: MagnetFlightPresenter?

    func cancelArrival() { arrival = nil; flight?.cancel(); flyingID = nil }
    func presentArrival(_ row: AssetRecord, view: NSView, left: Bool, image: CGImage) {
        guard let hint = arrival, hint.id == row.id, !hidden, !pointer.isHolding,
              row.status == .pending, acceptedRows[row.id] == row.visibilityRevision,
              let window = view.window, window.isVisible, let screen = window.screen,
              !view.bounds.isEmpty, view.visibleRect.contains(view.bounds),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        arrival = nil
        let age = ProcessInfo.processInfo.systemUptime - hint.ready
        guard age >= 0, age < 0.45, let plan = hint.plan(image: row.image, screen: screen,
            target: window.convertToScreen(view.convert(view.bounds, to: nil)), left: left) else { return }
        let presenter = flight ?? MagnetFlightPresenter()
        flight = presenter
        let entry = epoch
        if presenter.start(assetID: row.id, image: image, plan: plan, backingScale: screen.backingScaleFactor,
            elapsedSinceAssetReady: age, onAnimationObservation: { [weak self] observation in
                guard let self, epoch == entry, let emit = acceptanceEvent else { return }
                switch observation.phase {
                case .started: emit("magnetAnimationStarted")
                case .stopped: emit(observation.finished == true ? "magnetAnimationFinished" : "magnetAnimationInterrupted")
                }
            }, onCompletion: { [weak self] _ in self?.flyingID = nil }) { flyingID = row.id }
    }
    @ObservationIgnored public var exposureChanged: ((Bool) -> Void)?
    @ObservationIgnored private var collection: TrayCollection?
    @ObservationIgnored private var collectionDrain: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var ownerDrain: Task<Void, Never>?
    public private(set) var collectionEnabled = false

    @ObservationIgnored var captureLocation: @MainActor () -> any CaptureLocationProviding = { SystemCaptureLocationProvider() }
    @ObservationIgnored private var collectionAttempt = UUID()
    public private(set) var hasSavedCollection = false

    public func collect(from selected: URL) async { await collect(from: selected, provider: captureLocation()) }
    func collect(from selected: URL, provider: any CaptureLocationProviding, restoring: CaptureFolderConsent? = nil) async {
        guard let owner, collection == nil else { return }
        let ticket = UUID()
        collectionAttempt = ticket
        await collectionDrain?.value
        guard self.owner === owner, collection == nil, collectionAttempt == ticket else { return }
        do {
            guard try await !owner.store.capturePaused() else { issue = "Riftlet 已暂停截图收录。"; return }
            guard self.owner === owner, collection == nil, collectionAttempt == ticket else { return }
            let consent = try restoring ?? (productAttachments ? CaptureFolderConsent(selected: selected) : nil)
            let current = try TrayCollection(owner: owner, selected: selected, provider: provider, consent: consent) { [weak self] in
                guard let self, self.collectionAttempt == ticket else { return }
                self.stopCollecting()
                self.issue = "系统截图目录或访问条件已改变；收录已停止，请重新选择目录。"
            }
            collection = current
            try await current.binding.start()
            guard collection === current, collectionAttempt == ticket else { return }
            if let consent, restoring == nil { try consent.save(in: owner.root) }
            hasSavedCollection = consent != nil
            collectionEnabled = true; issue = nil
        } catch {
            if self.owner === owner, collectionAttempt == ticket {
                haltCollection(); issue = "未能收录系统截图，请重新选择当前系统截图目录。"
            }
        }
    }

    private func restoreCollection(in owner: TrayOwner) async {
        guard productAttachments, self.owner === owner else { return }
        do {
            guard let consent = try CaptureFolderConsent.read(in: owner.root) else { hasSavedCollection = false; return }
            hasSavedCollection = true
            let selected = try consent.directory()
            await collect(from: selected, provider: captureLocation(), restoring: consent)
        } catch { hasSavedCollection = true; issue = "原截图目录无法核对；请重新选择或忘记此授权。" }
    }

    /// Explicit stop forgets the picker grant. Closing the Host only stops this watch.
    public func stopCollecting() {
        haltCollection()
        guard productAttachments, let owner else { return }
        do { try CaptureFolderConsent.forget(in: owner.root); hasSavedCollection = false }
        catch { issue = "本次收录已停止，但未能移除保存的目录授权。" }
    }
    private func haltCollection() {
        collectionAttempt = UUID()
        guard let current = collection else { return }
        collection = nil; collectionEnabled = false
        let pin = owner, previous = collectionDrain
        collectionDrain = Task { await previous?.value; await current.binding.stop(); withExtendedLifetime(pin) {} }
    }
    public func finishStopping() async {
        await connectionTask?.value
        await collectionDrain?.value
        await ownerDrain?.value
    }


    public convenience init(existingRoot: URL, testSession: URL? = nil, localOnly: Bool = false, productAttachments: Bool = false) {
        let product = productAttachments && testSession == nil && !localOnly
        self.init(productAttachments: product) { change, error in
            try await TrayOwner.existing(root: existingRoot, testSession: testSession, localOnly: localOnly,
                                         productAttachments: product, notify: change, report: error)
        }
        self.localOnly = localOnly
    }
    init(productAttachments: Bool = false, open: @escaping Open) {
        self.productAttachments = productAttachments
        self.open = open
    }
    public func start() throws { active = true }
    public func stop() { active = false; disconnect() }
    public func suspend() { stop() }
    public func resume() throws { try start() }
    public func perform(_ action: ModuleAction) throws {}
    public func snapshot() throws -> ModuleProjection { .init(message: "Screenshot tray") }

    public func connect() async {
        guard active, !connecting, owner == nil else { return }
        connecting = true; issue = nil
        let entry = epoch
        let previous = connectionTask, closingCollection = collectionDrain, closingOwner = ownerDrain
        let task = Task { [weak self] in
            await previous?.value
            await closingCollection?.value
            await closingOwner?.value
            guard let self, active, epoch == entry else { return }
            await openConnection(entry)
        }
        connectionTask = task
        await task.value
        if epoch == entry { connecting = false; connectionTask = nil }
    }

    private func openConnection(_ entry: UUID) async {
        do {
            let value = try await open({ [weak self] in
                guard let self, epoch == entry else { return }; await refresh()
            }, { [weak self] message in
                guard let self, epoch == entry else { return }; issue = message
            })
            guard active, epoch == entry else { value.close(); return }
            value.arrived = { [weak self] evidence in
                guard let self, epoch == entry, !hidden else { return }
                cancelArrival(); arrival = evidence
            }
            value.exposureChanged = { [weak self] hidden in
                guard let self, self.epoch == entry else { return }; self.exposureChanged?(hidden)
            }
            value.reviewCaptureWindow = reviewCaptureWindow
            if productAttachments {
                let enabled = try await value.store.checkpoint(for: Self.consentKey) == Data([1])
                let last = try await value.store.checkpoint(for: Self.feedbackKey)
                guard active, epoch == entry else { value.close(); return }
                mayAttach = enabled
                currentFeedbackAsset = last.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) }
            }
            owner = value; connected = true; captureEntry = value.captureEntry
            // Current default is the rightmost system key; relative shortcuts follow the domain's preferred mode.
            let preferred = TrayCapture.allCases.first { $0.mode == value.defaultMode }
            menuOrder = ([preferred].compactMap { $0 } + TrayCapture.allCases.filter { $0 != preferred && $0 != .system }) + [.system]
            // No target discovery, external observation, capture or upload on opening a library.
            await refresh()
            if epoch == entry { await restoreCollection(in: value) }
        } catch { if epoch == entry { issue = (error as? LibraryError)?.localizedDescription ?? "无法连接此资料库。原文件已保留。" } }
    }
    public func disconnect() {
        haltCollection(); hasSavedCollection = false; cancelArrival(); flight?.close(); flight = nil; epoch = UUID(); cancelInteraction()
        let observing = observe
        observing?.cancel(); observe = nil
        if let owner {
            owner.close()
            if owner.hasPendingWork || observing != nil {
                let previous = ownerDrain
                ownerDrain = Task { await previous?.value; await observing?.value; await owner.finishWork() }
            }
        }
        owner = nil
        attachmentFeedback = nil; currentFeedbackAsset = nil; feedbackFromCurrentConnection = false
        permissionRequest = UUID()
        exposureChanged?(false)
        settle?.cancel(); settle = nil
        rows = []; acceptedRows = [:]; swallowing = []; expanded = false
        captureEntry = false; mayAttach = false; connected = false; connecting = false; issue = nil
    }
    public func authorizeAttachments() async {
        guard !localOnly, let owner else { return }
        let request = UUID()
        permissionRequest = request
        let allowed = await owner.checkPermission(true, nil)
        guard self.owner === owner, permissionRequest == request else { return }
        if !allowed {
            mayAttach = false
            cancelInteraction()
            observe?.cancel()
        }
        if productAttachments {
            do { try await owner.store.saveCheckpoint(Data([allowed ? 1 : 0]), for: Self.consentKey) }
            catch { issue = "未能保存草稿附加授权。"; return }
            guard self.owner === owner, permissionRequest == request else { return }
        }
        mayAttach = allowed
        if allowed && owner.mayObserveTestClaim() { scheduleObservation(owner) }
        issue = allowed ? nil : "尚未获得当前浏览器的草稿附加权限。"
    }
    public func disableAttachments() async {
        guard productAttachments, let owner else { return }
        permissionRequest = UUID()
        mayAttach = false
        cancelInteraction()
        observe?.cancel()
        do { try await owner.store.saveCheckpoint(Data([0]), for: Self.consentKey) }
        catch { if self.owner === owner { issue = "本次已关闭草稿附加，但未能保存设置。" } }
    }

    public func surfaceHidden(_ value: Bool) {
        hidden = value
        if value { cancelInteraction(); cancelArrival() }
    }
    func cancelInteraction() {
        interaction = UUID()
        for task in resolvingPresses.values { task.cancel() }
        resolvingPresses.removeAll()
        pointer.cancel(); pressTask?.cancel(); pressTask = nil; owner?.cancelPresses()
    }
    public func collapseMenu() { expanded = false }
    @ObservationIgnored public var acceptanceEvent: ((String) -> Void)?
    func toggleMenu() { if connected && captureEntry { cancelArrival(); expanded.toggle(); acceptanceEvent?("trayButton") } }
    func capture(_ action: TrayCapture) {
        guard active, !hidden, expanded, captureEntry else { return }
        owner?.capture(action)
    }
    func thumbnail(_ row: AssetRecord, pixels: Int, completion: @escaping (CGImage?) -> Void) {
        guard let owner else { completion(nil); return }
        owner.thumbnails.image(for: row.image, maxPixelSize: pixels, completion: completion)
    }
    func beginPress(_ row: AssetRecord) -> TrayPress? {
        guard active, !hidden, let owner, acceptedRows[row.id] == row.visibilityRevision,
              row.status != .missing, row.status != .used, row.status != .transferring else { return nil }
        guard mayAttach else { issue = "请先在设置中允许附加到草稿。"; return nil }
        do {
            try owner.checkAsset(row.image)
            let target = try owner.pinTarget()
            issue = nil
            pressTask = target
            return .init(id: row.id, revision: row.visibilityRevision, epoch: interaction, target: target)
        } catch { issue = "未能确认目标草稿，截图仍在托盘中。"; return nil }
    }
    func finishPress(_ press: TrayPress) async {
        guard let owner, press.epoch == interaction else { press.target.cancel(); return }
        pressTask = nil
        let click = UUID()
        resolvingPresses[click] = press.target
        defer { resolvingPresses[click] = nil }
        do {
            try await owner.performWork {
                let selection = try await owner.authority.accept(id: click, assetID: press.id, visibilityRevision: press.revision,
                    target: press.target, isCurrent: { self.active && !self.hidden && self.interaction == press.epoch &&
                        self.acceptedRows[press.id] == press.revision && self.mayAttach })
                if productAttachments {
                    do {
                        try await owner.store.saveCheckpoint(Data(press.id.uuidString.utf8), for: Self.feedbackKey)
                    } catch {
                        owner.authority.cancel(id: click)
                        throw error
                    }
                    guard self.owner === owner, interaction == press.epoch, mayAttach else {
                        owner.authority.cancel(id: click)
                        throw CancellationError()
                    }
                    currentFeedbackAsset = press.id
                    feedbackFromCurrentConnection = true
                }
                try await owner.transfer.select(selection)
            }
            guard self.owner === owner else { return }
            await refresh()
            scheduleObservation(owner)
        } catch {
            guard interaction == press.epoch else { return }
            issue = "未能确认附加；请检查原草稿。截图和原操作均已保留。"
            await refresh()
        }
    }
    private func scheduleObservation(_ value: TrayOwner) {
        guard observe == nil else { return }
        observe = Task { [weak self] in
            defer { if self?.owner === value { self?.observe = nil } }
            for delay in [1, 2, 4, 8] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, owner === value, mayAttach else { return }
                do {
                    guard !(try await value.store.unresolvedOperations()).isEmpty else { return }
                    try await value.performWork {
                        try await value.transfer.observePending { target in await value.checkPermission(false, target.sessionID) }
                    }
                    await refresh()
                } catch { if owner === value { issue = "无法确认原操作的状态。" }; return }
            }
        }
    }

    public func refresh() async {
        guard let owner, active else { return }
        revision += 1
        let request = revision
        do {
            // Riftlet returns chronological order; the tray presents new arrivals at the front.
            let next = Array(try await owner.store.assets().reversed())
            let ids = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0.visibilityRevision) })
            var starts = Set<UUID>()
            for row in rows where ids[row.id] == nil {
                if let record = try await owner.store.asset(id: row.id), record.visibility == .swallowed,
                   record.visibilityReason == .uploadStarted, let operation = record.activeOperationID,
                   try await owner.store.uploadStartReceipt(for: operation)?.outcome == .uploadStarted {
                    starts.insert(row.id)
                }
            }
            guard self.owner === owner, request == revision else { return }
            if productAttachments, let id = currentFeedbackAsset {
                let feedback = try await owner.feedback(for: id, live: feedbackFromCurrentConnection)
                guard self.owner === owner, request == revision, currentFeedbackAsset == id else { return }
                attachmentFeedback = feedback
            }
            acceptedRows = ids
            settle?.cancel()
            swallowing = starts
            guard !starts.isEmpty else { if rows != next { rows = next }; return }
            // Only a proven START animates. The presentation retains the old slot briefly; it is already non-interactive.
            settle = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard let self, self.owner === owner, request == revision else { return }
                rows = next; swallowing = []
            }
        } catch {
            if self.owner === owner && request == revision {
                acceptedRows = [:]; issue = "暂时无法读取队列；已停用上次快照的点击。"
            }
        }
    }
}
