import AppKit
import Combine
import NearpaneCore
import Observation
import SaytileKit

/// A presentation of Saytile's capture state, never an independent recognition state machine.
enum PanelCaptureVisualState { case paused, standby, recognizing }
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
    func start() async throws
    func pause() async
    func retry(_ id: UUID) async
    func shutdown() async
}

@MainActor
private final class DomainInput: VoiceInput {
    let audio: AudioController
    var observation: AnyCancellable?
    init(store: SaytileStore, changed: @escaping (CaptureState, Float, String?) -> Void) {
        // Never load the standalone app's defaults, credentials, direct input target or cloud consents.
        audio = AudioController(store: store, recognitionConfiguration: RecognitionConfiguration())
        observation = Publishers.CombineLatest3(audio.$state, audio.$level, audio.$issue).sink {
            changed($0, $1, $2)
        }
    }
    func start() async throws {
        // Do not trigger engine asset installation as a side effect of trying the voice button.
        let availability = await AppleSpeechService.availability()
        guard availability.installed else { throw AudioFailure.message(availability.message) }
        try Task.checkCancellation()
        await audio.start()
    }
    func pause() async { await audio.pause() }
    func retry(_ id: UUID) async { await audio.retry(recordingID: id) }
    func shutdown() async { observation = nil; await audio.shutdown() }
}

@MainActor @Observable
public final class VoiceModule: HostModule {
    typealias MakeInput = (SaytileStore, @escaping (CaptureState, Float, String?) -> Void) -> any VoiceInput
    @ObservationIgnored private let openStore: () throws -> SaytileStore
    @ObservationIgnored private let makeInput: MakeInput
    @ObservationIgnored private var store: SaytileStore?
    @ObservationIgnored private var input: (any VoiceInput)?
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
    private(set) var rows: [Recording] = []
    private(set) var hasEarlier = false
    private(set) var issue: String?
    public var transcript: String { rows.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") }

    public convenience init(directory: URL) {
        self.init(openStore: {
            let parent = directory.deletingLastPathComponent()
            if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadNoPermission)
            }
            return try SaytileStore(directory: directory)
        },
                  makeInput: { DomainInput(store: $0, changed: $1) })
    }
    init(openStore: @escaping () throws -> SaytileStore, makeInput: @escaping MakeInput) {
        self.openStore = openStore; self.makeInput = makeInput
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
        active = false; generation += 1; updates?.cancel(); updates = nil
        if let revisionObserver { NotificationCenter.default.removeObserver(revisionObserver); self.revisionObserver = nil }
        notifiedRefresh?.cancel(); notifiedRefresh = nil
        let previous = transition, oldInput = input, oldStore = store, writes = draftWrite
        draftWrite = nil
        input = nil; store = nil; rows = []; capture = .paused; control = .init(.paused, 0)
        busy = false; hasEarlier = false; issue = nil; limit = 60
        transition = Task {
            await previous?.value
            await oldInput?.shutdown()
            await writes?.value
            do { try await oldStore?.close() }
            catch { self.issue = "语音资料库未能正常关闭。" }
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

    func toggle() async {
        guard active, !busy else { return }
        busy = true
        let epoch = generation
        defer { if generation == epoch { busy = false } }
        await waitForTransition()
        guard active, generation == epoch else { return }
        issue = nil
        do {
            let device = try currentInput()
            if capture.isRunning { acceptanceEvent?("userPause"); await device.pause() }
            else { acceptanceEvent?("userStart"); try await device.start() }
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
    public func refresh() async {
        guard active, let store else { return }
        let epoch = generation
        refreshID += 1
        let request = refreshID
        do {
            let requested = limit
            var result: [Recording] = []
            while result.count < requested {
                let batch = min(1_000, requested - result.count)
                let page = try await store.listPanelRecordings(createdSince: .distantPast, includingIDs: [],
                                                              limit: batch, offset: result.count)
                result += page
                if page.count < batch { break }
            }
            let count = try await store.panelRecordingCount(createdSince: .distantPast, includingIDs: [])
            guard active, generation == epoch, refreshID == request else { return }
            let ordered = Array(result.reversed())
            if ordered != rows { rows = ordered; acceptanceEvent?("voiceRows") }
            hasEarlier = count > result.count
        } catch { if generation == epoch { issue = "暂时无法读取文字；保留上次内容。" } }
    }
    func loadEarlier() async {
        limit += 60; await refresh()
    }
    func retry(_ id: UUID) async {
        guard active, !busy, rows.contains(where: { $0.id == id && $0.recognitionState == .failed }) else { return }
        let epoch = generation
        do {
            let device = try currentInput()
            await device.retry(id)
            guard active, epoch == generation else { return }
            trackRevisions(); await refresh()
        } catch { if epoch == generation { issue = "无法重试；文字和原音保留在资料库中。" } }
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
