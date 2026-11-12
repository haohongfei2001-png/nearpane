import Foundation
import SaytileKit

/// Deterministic input for the executable-bound, disposable window-comparison session.
@MainActor package final class SharedVoiceReviewInput {
    private final class Input: VoiceInput {
        var changed: ((CaptureState, Float, String?) -> Void)?
        func start(requestPermission: Bool) async throws { changed?(.listening, 0, nil) }
        func pause() async { changed?(.paused, 0, nil) }
        func retry(_ id: UUID) async throws { throw CocoaError(.featureUnsupported) }
        func revokeCloud() {}
        func configure(_ configuration: RecognitionConfiguration) async {}
        func shutdown() async { changed = nil }
    }
    private let input: Input
    package let module: VoiceModule
    package init(directory: URL) {
        let device = Input()
        input = device
        module = VoiceModule(openStore: { try SaytileStore(directory: directory) }, makeInput: { _, changed in
            device.changed = changed
            return device
        })
    }
    package func seed() async throws {
        await module.waitForTransition()
        try await module.withPanelRead { store in
            guard try await store.listRecordings(limit: 1).isEmpty else { throw CocoaError(.fileWriteFileExists) }
            let row = try await store.createRecording()
            let ticket = try await store.beginRecognition(recordingID: row.id)
            _ = try await store.applyRecognition(ticket: ticket, text: "把今天的讨论记下来。\n下午三点继续。", isFinal: false)
        }
        await module.refresh()
    }
    package func listen() async { await module.toggle(requestPermission: false) }
    package func speak() { input.changed?(.speaking, 1, nil) }
    package func finishPhrase() { input.changed?(.listening, 0, nil) }
}
