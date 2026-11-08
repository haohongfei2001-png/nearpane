import Testing
import Foundation
import AppKit
@testable import SaytileKit
@testable import NearpaneVoice

@MainActor
final class ScriptedInput: VoiceInput {
    let update: (CaptureState, Float, String?) -> Void
    var retried: UUID?
    var closed = false
    init(_ update: @escaping (CaptureState, Float, String?) -> Void) { self.update = update }
    func start() async throws { update(.listening, 0, nil) }
    func pause() async { update(.paused, 0, nil) }
    func retry(_ id: UUID) async { retried = id }
    func shutdown() async { closed = true }
}

@MainActor @Suite(.serialized)
struct VoiceTests {
    func directory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data").appendingPathComponent("voice-" + UUID().uuidString)
    }

    @Test func captureButtonFollowsDomainIncludingSilenceAndLateEvents() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var input: ScriptedInput?
        let module = VoiceModule(openStore: { try SaytileStore(directory: dir) },
                                 makeInput: { _, update in let device = ScriptedInput(update); input = device; return device })
        try module.start()
        await module.waitForTransition()
        #expect(input == nil)
        #expect(module.control.state == .paused)
        await module.toggle()
        let device = try #require(input)
        #expect(module.control.state == .standby)
        device.update(.speaking, 0.2, nil)
        let quiet = try #require(module.control.liveVoiceLevel)
        device.update(.speaking, 0.9, nil)
        #expect(module.control.state == .recognizing)
        #expect(try #require(module.control.liveVoiceLevel) > quiet)
        device.update(.listening, 0.2, nil)
        #expect(module.control.state == .standby && module.control.liveVoiceLevel == nil)
        await module.toggle()
        #expect(module.control.state == .paused)
        module.stop()
        try module.start()
        await module.waitForTransition()
        device.update(.speaking, 1, nil)
        #expect(device.closed && module.control.state == .paused)
        module.stop(); await module.waitForTransition()
    }

    @Test func realStoreProjectsOneCorrectedStreamProtectsEditsAndRestoresAfterShutdown() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SaytileStore(directory: dir)
        let module = VoiceModule(openStore: { store }, makeInput: { _, update in ScriptedInput(update) })
        try module.start()
        await module.waitForTransition()
        let first = try await store.createRecording(createdAt: Date(timeIntervalSince1970: 10))
        let ticket = try await store.beginRecognition(recordingID: first.id)
        _ = try await store.applyRecognition(ticket: ticket, text: "合成测试 甲", isFinal: false)
        await module.refresh()
        #expect(module.transcript == "合成测试 甲")
        _ = try await store.applyRecognition(ticket: ticket, text: "合成测试，甲。", isFinal: true)
        await module.refresh()
        #expect(module.transcript == "合成测试，甲。")
        #expect(await module.saveEdit(first.id, text: "原话🪴"))
        _ = try await store.applyRecognition(ticket: ticket, text: "稍后修订", isFinal: true)
        let second = try await store.createRecording(createdAt: Date(timeIntervalSince1970: 20))
        let next = try await store.beginRecognition(recordingID: second.id)
        _ = try await store.applyRecognition(ticket: next, text: "第二段", isFinal: false)
        try await store.failRecognition(ticket: next, message: "synthetic interruption")
        await module.refresh()
        let expected = "原话🪴\n第二段"
        #expect(module.transcript == expected)
        #expect(module.rows.last?.recognitionState == .failed)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(VoiceSurface(module).copy(module.transcript, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(try !module.snapshot().message.contains("原话"))
        module.stop(); await module.waitForTransition()
        let restored = VoiceModule(directory: dir)
        try restored.start(); await restored.waitForTransition()
        #expect(restored.transcript == expected)
        #expect(restored.control.state == .paused)
        restored.stop(); await restored.waitForTransition()
    }

    @Test func originalLocalIngressPublishesARevisionToTheIdleHostWithoutPollingOrAudio() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SaytileStore(directory: dir)
        let module = VoiceModule(openStore: { store }, makeInput: { _, callback in
            Issue.record("A domain revision should not open the microphone.")
            return ScriptedInput(callback)
        })
        try module.start(); await module.waitForTransition()
        let row = try await store.createRecording()
        let ticket = try await store.beginRecognition(recordingID: row.id)
        let ingress = LocalCandidateIngress(store: store, ticket: ticket)
        let text = "这段原话。"
        try await ingress.receive(.init(text: text, stableUTF16Length: text.utf16.count, audioEndSeconds: 1.2,
                                       language: "zh", isComplete: true))
        try await ingress.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while module.transcript != text && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(module.transcript == text && module.rows.count == 1 && module.control.state == .paused)
        module.stop(); await module.waitForTransition()
    }

    @Test func offlineConfigurationRetainsOneLanguageExpertAndOneTextCore() throws {
        for language in [LanguagePreference.chinese, .english, .chineseEnglishMixed] {
            var config = RecognitionConfiguration()
            config.languagePreference = language
            #expect(!config.cloudEnabled)
            #expect(config.activeModels.filter { $0.purpose.isStreaming }.count == 1)
            #expect(config.activeModels.filter { $0.purpose == .textFusion }.map(\.model) == ["gpt-6-astra"])
        }
    }
}
