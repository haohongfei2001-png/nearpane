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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshID = 0
    private var limit = 60
    public private(set) var active = false
    private(set) var busy = false
    private(set) var capture: CaptureState = .paused
    private(set) var control = PanelCapturePresentation(.paused, 0)
    private(set) var rows: [Recording] = []
    private(set) var hasEarlier = false
    private(set) var issue: String?
    public var transcript: String { rows.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") }

    public convenience init(directory: URL) {
        self.init(openStore: { try SaytileStore(directory: directory) },
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
                do { try open() } catch { issue = "无法打开语音资料库；原有文字已保留。" }
                await refresh()
            }
        } else {
            try open()
            transition = Task { [weak self] in await self?.refresh() }
        }
    }

    private func open() throws { store = try openStore() }
    public func waitForTransition() async { await transition?.value }

    public func stop() {
        guard active else { return }
        active = false; generation += 1; updates?.cancel(); updates = nil
        let previous = transition, oldInput = input, oldStore = store
        input = nil; store = nil; rows = []; capture = .paused; control = .init(.paused, 0)
        busy = false; hasEarlier = false; issue = nil; limit = 60
        transition = Task {
            await previous?.value
            await oldInput?.shutdown()
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
            capture = state
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
            if capture.isRunning { await device.pause() }
            else { try await device.start() }
            guard active, generation == epoch else { return }
            trackRevisions(); await refresh()
        } catch { if generation == epoch { issue = error.localizedDescription } }
    }

    private func trackRevisions() {
        updates?.cancel()
        updates = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { break }
                guard let self, active else { break }
                await refresh()
                if !capture.isRunning && !rows.contains(where: { $0.recognitionState == .running || $0.recognitionState == .queued }) { break }
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
            if ordered != rows { rows = ordered }
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
    @discardableResult func saveEdit(_ id: UUID, text: String) async -> Bool {
        guard active, let store, rows.contains(where: { $0.id == id }) else { return false }
        let epoch = generation
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
