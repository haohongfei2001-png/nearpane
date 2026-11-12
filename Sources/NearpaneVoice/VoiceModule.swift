import AppKit
import Combine
import NearpaneCore
import Observation
import SaytileKit
import SaytileVoiceUI

/// A presentation of Saytile's capture state, never an independent recognition state machine.
typealias PanelCaptureVisualState = VoicePanelState
struct PanelCapturePresentation: Equatable {
    let state: PanelCaptureVisualState
    let liveVoiceLevel: Double?
    init(_ capture: CaptureState, _ level: Float) {
        switch capture {
        case .speaking:
            state = .recognizing
            liveVoiceLevel = level.isFinite && level >= 0 ? Double(min(1, level)) : nil
        case .listening: state = .standby; liveVoiceLevel = nil
        case .paused, .starting, .interrupted: state = .paused; liveVoiceLevel = nil
        }
    }
}

@MainActor
protocol VoiceInput: AnyObject {
    func start(requestPermission: Bool) async throws
    func pause() async
    func retry(_ id: UUID) async throws
    func revokeCloud()
    func configure(_ configuration: RecognitionConfiguration) async
    func shutdown() async
}

@MainActor
private final class DomainInput: VoiceInput {
    let audio: AudioController
    private let recordings: SaytileStore
    var observation: AnyCancellable?
    private let requireExistingPermissions: Bool
    private let profile: VoiceRecognitionProfile?
    private var configuration = RecognitionConfiguration()
    init(store: SaytileStore, requireExistingPermissions: Bool, profile: VoiceRecognitionProfile?,
         credentials: NearpaneVoiceCredentials?, changed: @escaping (CaptureState, Float, String?) -> Void) {
        self.profile = profile
        recordings = store
        self.requireExistingPermissions = requireExistingPermissions
        audio = credentials?.controller(store: store, configuration: configuration)
            ?? AudioController(store: store, recognitionConfiguration: configuration)
        observation = Publishers.CombineLatest3(audio.$state, audio.$level, audio.$issue).sink {
            changed($0, $1, $2)
        }
    }
    func start(requestPermission: Bool) async throws {
        // Do not trigger engine asset installation as a side effect of trying the voice button.
        if VoiceInputRoute.current() == .disconnected { throw AudioFailure.message(VoiceInputRoute.disconnected.label) }
        try await prepareConfiguration()
        if !configuration.cloudEnabled {
            let availability = await AppleSpeechService.availability()
            guard availability.installed else { throw AudioFailure.message(availability.message) }
        }
        try Task.checkCancellation()
        await audio.start(requestPermission: requestPermission && !requireExistingPermissions)
    }
    func pause() async { await audio.pause() }
    func retry(_ id: UUID) async throws {
        let selected = try profile?.configurationForInput() ?? RecognitionConfiguration()
        await configure(selected)
        let expected = try await VoiceRecognitionProfile.retryConfiguration(selected, for: id, in: recordings)
        await audio.retry(recordingID: id, expectedConfiguration: expected)
    }
    private func prepareConfiguration() async throws {
        guard let profile else { return }
        try await configure(profile.configurationForInput())
    }
    func revokeCloud() { audio.revokeCloudRecognition() }
    func configure(_ value: RecognitionConfiguration) async {
        guard configuration != value else { return }
        configuration = value
        await audio.setRecognitionConfiguration(value)
    }
    func shutdown() async { observation = nil; await audio.shutdown() }
}

@MainActor @Observable
public final class VoiceModule: HostModule {
    typealias MakeInput = (SaytileStore, @escaping (CaptureState, Float, String?) -> Void) -> any VoiceInput
    @ObservationIgnored private let openStore: () throws -> SaytileStore
    @ObservationIgnored private let makeInput: MakeInput
    @ObservationIgnored private var store: SaytileStore?
    @ObservationIgnored private var panelReads = 0
    @ObservationIgnored private var waitingForPanelReads: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var input: (any VoiceInput)?
    typealias ManualInputFactory = (SaytileStore) throws -> NearpaneManualInsertion
    @ObservationIgnored private var makeManualInput: ManualInputFactory?
    @ObservationIgnored private var manualInput: NearpaneManualInsertion?
    @ObservationIgnored private var manualTask: Task<Void, Never>?
    var offersManualInput: Bool { makeManualInput != nil }
    private(set) var inserting = false
    private(set) var insertionNotice: String?
    private(set) var recognitionProfile: VoiceRecognitionProfile?
    private(set) var changingRecognition = false
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var draftWrite: Task<Void, Never>?
    @ObservationIgnored private var revisionObserver: NSObjectProtocol?
    @ObservationIgnored private var notifiedRefresh: Task<Void, Never>?
    // Observed only in a dedicated acceptance session; text never leaves the domain.
    @ObservationIgnored public var acceptanceEvent: ((String) -> Void)?
    public var openRecordingIDs: [UUID] { rows.filter(\.isRecording).map(\.id) }
    @ObservationIgnored public var openingFailed: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshID = 0
    private var limit = 60
    public private(set) var active = false
    private(set) var busy = false
    public private(set) var capture: CaptureState = .paused
    private(set) var control = PanelCapturePresentation(.paused, 0)
    private(set) var history = VoiceHistoryProjection()
    private(set) var rows: [Recording] = []
    private(set) var hasEarlier = false
    private(set) var issue: String?
    public var transcript: String { rows.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") }

    public convenience init(directory: URL, requireExistingPermissions: Bool = false, allowAPISettings: Bool = false, allowManualInsertion: Bool = false) {
        let credentials = allowAPISettings && !requireExistingPermissions
            ? NearpaneVoiceCredentials(profileID: VoiceRecognitionProfile.identifier(for: directory)) : nil
        let profile = credentials.map { VoiceRecognitionProfile(directory: directory, credentials: $0) }
        self.init(openStore: {
            let parent = directory.deletingLastPathComponent()
            if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadNoPermission)
            }
            return try SaytileStore(directory: directory)
        },
                  makeInput: { DomainInput(store: $0, requireExistingPermissions: requireExistingPermissions,
                                           profile: profile, credentials: credentials, changed: $1) })
        recognitionProfile = profile
        if allowManualInsertion && !requireExistingPermissions { makeManualInput = { try NearpaneManualInsertion(store: $0) } }
    }
    init(openStore: @escaping () throws -> SaytileStore, recognitionProfile: VoiceRecognitionProfile? = nil,
         makeManualInput: ManualInputFactory? = nil, makeInput: @escaping MakeInput) {
        self.openStore = openStore; self.makeInput = makeInput; self.makeManualInput = makeManualInput
        self.recognitionProfile = recognitionProfile
    }

    public func start() throws {
        guard !active else { return }
        active = true; generation += 1; issue = nil
        let epoch = generation
        if let previous = transition {
            transition = Task { [weak self] in
                await previous.value
                guard let self, active, generation == epoch else { return }
                do { try open() } catch {
                    issue = "无法打开语音资料库；原有文字已保留。"
                    openingFailed?()
                    return
                }
                await refresh()
            }
        } else {
            try open()
            transition = Task { [weak self] in await self?.refresh() }
        }
    }

    private func open() throws {
        store = try openStore()
        guard revisionObserver == nil else { return }
        let epoch = generation
        // Both original ingress paths post after publishing to SaytileStore. A late correction
        // must reach a quiet panel even after the capture/status polling window has ended.
        revisionObserver = NotificationCenter.default.addObserver(forName: .init("SaytileRecognitionUpdated"),
            object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.didPublish(epoch) }
            }
    }

    private func didPublish(_ epoch: Int) {
        guard active, generation == epoch, notifiedRefresh == nil else { return }
        notifiedRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, active, generation == epoch else { return }
            notifiedRefresh = nil
            await refresh()
        }
    }
    public func waitForTransition() async { await transition?.value }

    public func stop() {
        guard active else { return }
        manualInput?.finish()
        manualInput = nil
        manualTask?.cancel()
        let endingInsertion = manualTask
        manualTask = nil
        inserting = false
        insertionNotice = nil
        active = false; generation += 1; updates?.cancel(); updates = nil
        if let revisionObserver { NotificationCenter.default.removeObserver(revisionObserver); self.revisionObserver = nil }
        notifiedRefresh?.cancel(); notifiedRefresh = nil
        let closingGeneration = generation
        let previous = transition, oldInput = input, oldStore = store, writes = draftWrite
        draftWrite = nil
        input = nil; store = nil; rows = []; history = VoiceHistoryProjection(); capture = .paused; control = .init(.paused, 0)
        busy = false; hasEarlier = false; issue = nil; limit = 60
        transition = Task {
            await previous?.value
            await endingInsertion?.value
            await oldInput?.shutdown()
            await writes?.value
            // Cancelling a view refresh does not cancel an already admitted SQLite read.
            // Keep the old store open across all awaits until that reader has left.
            if panelReads != 0 { await withCheckedContinuation { waitingForPanelReads = $0 } }
            do { try await oldStore?.close() }
            catch { if generation == closingGeneration { issue = "语音资料库未能正常关闭。" } }
        }
    }
    public func suspend() { stop() }
    public func resume() throws { try start() }
    public func perform(_ action: ModuleAction) throws {}
    public func snapshot() throws -> ModuleProjection { .init(message: "Voice module") }

    private func currentInput() throws -> any VoiceInput {
        if let input { return input }
        if store == nil { try open() }
        guard let store else { throw StoreError.missingRecording }
        let epoch = generation
        let input = makeInput(store) { [weak self] state, level, error in
            guard let self, active, generation == epoch else { return }
            let changed = capture != state
            capture = state
            if changed { acceptanceEvent?("captureState") }
            if changed && state == .speaking { trackRevisions() }
            control = .init(state, level)
            if case let .interrupted(reason) = state { issue = reason } else if let error { issue = error }
        }
        self.input = input
        return input
    }

    func toggle(requestPermission: Bool = true) async {
        guard active, !busy, !changingRecognition else { return }
        busy = true
        let epoch = generation
        defer { if generation == epoch { busy = false } }
        await waitForTransition()
        guard active, generation == epoch else { return }
        issue = nil
        do {
            let device = try currentInput()
            if capture.isRunning { acceptanceEvent?("userPause"); await device.pause() }
            else { acceptanceEvent?("userStart"); try await device.start(requestPermission: requestPermission) }
            guard active, generation == epoch else { return }
            trackRevisions(); await refresh()
        } catch { if generation == epoch { issue = error.localizedDescription } }
    }

    private func trackRevisions() {
        updates?.cancel()
        updates = Task { [weak self] in
            var quietReads = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: quietReads > 8 ? .seconds(3) : .milliseconds(400)) } catch { break }
                guard let self, active else { break }
                await refresh()
                if capture == .speaking { quietReads = 0; continue }
                quietReads += 1
                // Allow the last revision to land, then sleep until actual voice activity.
                // A permanently queued failure does not keep polling an idle database indefinitely.
                if quietReads >= 3 && !rows.contains(where: { $0.recognitionState == .running || $0.recognitionState == .queued }) { break }
                if quietReads >= 28 { break }
            }
        }
    }
    /// The first page and the count must share ownership of the same open store.
    /// A restart waits on the previous transition before opening the new store.
    func withPanelRead<T>(_ operation: (SaytileStore) async throws -> T) async throws -> T {
        guard active, let store else { throw CancellationError() }
        panelReads += 1
        defer {
            panelReads -= 1
            if panelReads == 0 {
                waitingForPanelReads?.resume()
                waitingForPanelReads = nil
            }
        }
        return try await operation(store)
    }

    public func refresh() async {
        guard active, store != nil else { return }
        let epoch = generation
        refreshID += 1
        let request = refreshID
        do {
            let requested = limit
            let (result, count) = try await withPanelRead { store in
                var result: [Recording] = []
                while result.count < requested {
                    let batch = min(1_000, requested - result.count)
                    let page = try await store.listPanelRecordings(createdSince: .distantPast, includingIDs: [],
                                                                  limit: batch, offset: result.count)
                    result += page
                    if page.count < batch { break }
                }
                let count = try await store.panelRecordingCount(createdSince: .distantPast, includingIDs: [])
                return (result, count)
            }
            guard active, generation == epoch, refreshID == request else { return }
            let ordered = Array(result.reversed())
            let start = max(0, count - result.count)
            if ordered != rows || history.entries.first?.position != ordered.first.map({ _ in Int64(start) }) {
                history = VoiceHistoryProjection(ordered, startPosition: start)
                rows = ordered
                acceptanceEvent?("voiceRows")
            }
            hasEarlier = count > result.count
        } catch { if generation == epoch { issue = "暂时无法读取文字；保留上次内容。" } }
    }
    /// The gesture captures both the visible revisions and its foreground field before any await.
    @discardableResult func insertDisplayedText() -> Task<Void, Never>? {
        guard active, !inserting, let store, let makeManualInput else { return nil }
        let visible = rows.filter { !$0.text.isEmpty }
        let revisions = visible.compactMap { row in row.preferredRevisionID.map { (row.id, $0, row.text) } }
        guard !revisions.isEmpty, revisions.count == visible.count else { return nil }
        let action: NearpaneManualInsertion
        do { action = try makeManualInput(store) }
        catch {
            switch error as? NativeInputError {
            case .permission: insertionNotice = "当前没有辅助功能权限，可复制文字。"
            case .noTarget: insertionNotice = "未找到前台输入框，可复制文字。"
            default: insertionNotice = "无法安全绑定当前输入框，可复制文字。"
            }
            return nil
        }
        manualInput = action
        inserting = true
        insertionNotice = nil
        let epoch = generation
        let task = Task {
            defer {
                action.finish()
                if epoch == generation { manualInput = nil; inserting = false; manualTask = nil }
            }
            do {
                try await action.bind()
                var frozen = [TranscriptRevision]()
                for (recording, revision, text) in revisions {
                    try Task.checkCancellation()
                    frozen.append(try await store.freezeRevision(recordingID: recording, revisionID: revision, text: text))
                }
                var confirmed = 0
                for item in frozen {
                    try Task.checkCancellation()
                    let result = await action.insert(recording: item.recordingID, revision: item.id)
                    guard epoch == generation else { return }
                    guard result == .confirmed else {
                        insertionNotice = (confirmed == 0 ? "" : "已确认 " + String(confirmed) + " 段。") + result.message
                        return
                    }
                    confirmed += 1
                }
                if epoch == generation { insertionNotice = "已插入 " + String(confirmed) + " 段文字。" }
            } catch {
                if epoch == generation { insertionNotice = "目标或文字已变化，已停止插入。" }
            }
        }
        manualTask = task
        return task
    }

    func copyLatestGroup(snapshot displayed: [UUID: String], to pasteboard: NSPasteboard) {
        guard active, let tail = rows.last, let group = history.entries.last?.group else { return }
        let members = history.entries.filter { $0.group == group }
        if !hasEarlier || members.count < rows.count {
            let text = members.map { displayed[$0.id] ?? $0.displayText }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
            return
        }
        var snapshot = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.displayText) })
        snapshot.merge(displayed) { _, rendered in rendered }
        let epoch = generation
        let change = pasteboard.changeCount
        Task {
            do {
                let text = try await withPanelRead { store in
                    try await store.nearpaneGroupText(through: tail.id, snapshot: snapshot,
                                                      idleInterval: VoiceHistoryProjection.idleInterval)
                }
                guard active, epoch == generation, !text.isEmpty, change == pasteboard.changeCount else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } catch { if active, epoch == generation { issue = "暂时无法读取此时间组。" } }
        }
    }

    func loadEarlier() async {
        limit += 60; await refresh()
    }
    func retry(_ id: UUID) async {
        guard active, !busy, !changingRecognition, rows.contains(where: { $0.id == id && $0.recognitionState == .failed }) else { return }
        if recognitionProfile?.enabled == true, capture == .speaking || capture == .starting {
            issue = "请等待本次讲话结束后重试。"
            return
        }
        busy = true
        let epoch = generation
        defer { if epoch == generation { busy = false } }
        do {
            let device = try currentInput()
            try await device.retry(id)
            guard active, epoch == generation else { return }
            trackRevisions(); await refresh()
        } catch { if epoch == generation { issue = error.localizedDescription } }
    }

    func enableAPI(language: LanguagePreference, workspace: String, region: String, expertKey: String,
                   fusionKey: String, consent: Bool) async throws {
        guard let recognitionProfile, !busy, !changingRecognition, capture == .paused else {
            throw AudioFailure.message("请先暂停收音，再启用 API。")
        }
        changingRecognition = true
        defer { changingRecognition = false }
        let value = try recognitionProfile.enable(language: language, workspace: workspace, region: region,
                                                  expertKey: expertKey, fusionKey: fusionKey, consent: consent)
        await input?.configure(value)
    }

    func disableAPI() async throws {
        guard let recognitionProfile, !changingRecognition else { throw AudioFailure.message("语音设置正在更新。") }
        changingRecognition = true
        defer { changingRecognition = false }
        let current = input
        current?.revokeCloud()
        let result = Result { try recognitionProfile.disable() }
        await current?.configure(RecognitionConfiguration())
        try result.get()
    }
    func editText(_ id: UUID) async -> String? {
        guard active, let store, let row = rows.first(where: { $0.id == id }) else { return nil }
        let epoch = generation
        await draftWrite?.value
        do {
            let text = try await store.loadDraft(recordingID: id) ?? row.text
            return generation == epoch ? text : nil
        } catch { if generation == epoch { issue = "暂时无法读取修改草稿。" }; return nil }
    }

    // Preserve typing in Saytile's own edit-draft table, in UI order. Never publish it as recognized text.
    func stageDraft(_ id: UUID, text: String) {
        guard active, let store else { return }
        acceptanceEvent?("userEdit")
        let previous = draftWrite, epoch = generation
        draftWrite = Task { [weak self] in
            await previous?.value
            do { try await store.saveDraft(recordingID: id, text: text) }
            catch { if self?.generation == epoch { self?.issue = "修改草稿未能保存。" } }
        }
    }

    func discardDraft(_ id: UUID) async -> Bool {
        guard active, let store else { return false }
        let epoch = generation
        await draftWrite?.value
        do { try await store.clearDraft(recordingID: id); return epoch == generation }
        catch { if epoch == generation { issue = "无法取消修改草稿。" }; return false }
    }

    @discardableResult func saveEdit(_ id: UUID, text: String) async -> Bool {
        guard active, let store, rows.contains(where: { $0.id == id }) else { return false }
        let epoch = generation
        await draftWrite?.value
        do {
            _ = try await store.saveEdit(recordingID: id, text: text)
            await refresh()
            return epoch == generation
        } catch {
            if epoch == generation { issue = "修改尚未保存，请重试。" }
            return false
        }
    }
}
