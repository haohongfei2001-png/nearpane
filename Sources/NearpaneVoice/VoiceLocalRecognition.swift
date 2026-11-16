import Foundation
import Observation
import SaytileKit

/// Nearpane owns the cache and the capture lifecycle. Saytile owns model integrity,
/// selection policy, the PCM recognizer and the snapshot taken for each new ticket.
@MainActor @Observable
final class VoiceLocalRecognition {
    static let preferred = LocalModelRecommendation.preferred
    let service: LocalASRService
    let canDownload: Bool
    private let preferences: UserDefaults
    private let pauseKey: String
    private(set) var selection: LocalASRID = .apple
    private(set) var status: LocalModelStatus?
    private(set) var problem: String?
    @ObservationIgnored var didSelect: ((LocalASRID) -> Void)?
    @ObservationIgnored private var failed: LocalASRID?
    @ObservationIgnored private var transfer: Task<Void, Never>?
    @ObservationIgnored private var attempted = false
    @ObservationIgnored private var generation = 0

    init(directory: URL, allowDownloads: Bool, helpers: URL? = nil, preferences: UserDefaults = .standard) {
        service = LocalASRService(root: directory.appending(path: "LocalModels"), helpers: helpers)
        self.preferences = preferences
        pauseKey = "nearpane.voice.pauseAutomatic." + VoiceRecognitionProfile.identifier(for: directory)
        #if arch(arm64)
        canDownload = allowDownloads
        #else
        canDownload = false
        #endif
    }

    func refresh() async {
        generation += 1
        let operation = generation
        let model = Self.preferred
        let state = await service.library.status(model)
        let ready = state.installed && failed != model ? await service.availability(model).installed : false
        guard generation == operation else { return }
        status = state
        let choice = LocalModelRecommendation.select(preferred: model, requested: nil,
                                                      available: ready ? [model, .apple] : [.apple])
        if selection != choice {
            selection = choice
            didSelect?(choice)
        }
    }

    func prepareForInput() async {
        await refresh()
        guard canDownload, status?.installed == false, !attempted, !preferences.bool(forKey: pauseKey) else { return }
        startTransfer()
    }

    func resume() {
        guard canDownload else { return }
        preferences.removeObject(forKey: pauseKey)
        failed = nil
        problem = nil
        if status?.installed == true { Task { await refresh() } }
        else { startTransfer() }
    }

    private func startTransfer() {
        guard transfer == nil else { return }
        attempted = true
        transfer = Task {
            if !Task.isCancelled, let job = await service.library.download(Self.preferred) {
                if Task.isCancelled { job.cancel() }
                await refresh()
                await job.value
            }
            transfer = nil
            await refresh()
        }
    }

    func pauseDownload() async {
        preferences.set(true, forKey: pauseKey)
        await stopTransfer()
    }

    func stopTransfer() async {
        let work = transfer
        work?.cancel()
        await service.library.pause(Self.preferred)
        await work?.value
        attempted = false
    }

    func unavailable(_ model: LocalASRID) async {
        guard model == selection, model != .apple else { return }
        failed = model
        problem = "中文模型暂不可用，后续录音使用系统识别。"
        await refresh()
    }
}
