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
    var onShutdown: (() -> Void)?
    var permissionDenied = false
    private(set) var permissionRequests: [Bool] = []
    init(_ update: @escaping (CaptureState, Float, String?) -> Void) { self.update = update }
    func start(requestPermission: Bool) async throws {
        permissionRequests.append(requestPermission)
        if permissionDenied { throw CocoaError(.fileReadNoPermission) }
        update(.listening, 0, nil)
    }
    func pause() async { update(.paused, 0, nil) }
    func retry(_ id: UUID) async { retried = id }
    func shutdown() async { closed = true; onShutdown?() }
}

@MainActor @Suite(.serialized)
struct VoiceTests {
    func directory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data").appendingPathComponent("voice-" + UUID().uuidString)
    }

    @Test func compactVoiceUsesTheExistingDeviceWithoutRequestingPermission() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var devices: [ScriptedInput] = []
        let module = VoiceModule(openStore: { try SaytileStore(directory: dir) }, makeInput: { _, update in
            let device = ScriptedInput(update)
            devices.append(device)
            return device
        })
        try module.start()
        await module.waitForTransition()
        await module.toggle(requestPermission: false)
        let device = try #require(devices.first)
        #expect(device.permissionRequests == [false] && module.capture == .listening)
        device.update(.speaking, 0.6, nil)
        #expect(module.control.state == .recognizing)
        await module.toggle(requestPermission: false)
        #expect(module.capture == .paused && !device.closed)
        await module.toggle()
        #expect(devices.count == 1 && device.permissionRequests == [false, true])
        module.stop()
        await module.waitForTransition()
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

extension VoiceTests {
    @Test func selectableTranscriptProvidesTheEditActionOnItsActualNativeMenu() throws {
        let app = NSApplication.shared
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TranscriptLine.TextView(frame: window.contentView!.bounds)
        window.contentView = view
        view.isEditable = false; view.isSelectable = true
        view.string = "synthetic selectable transcript"
        var calls = 0
        view.editLine = { calls += 1 }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .init(x: 12,y: 12),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        for _ in 0..<2 {
            let menu = try #require(view.menu(for: event))
            let matches = menu.items.filter { $0.title == "修改这段文字…" }
            #expect(matches.count == 1)
            let item = try #require(matches.first)
            #expect(item.target === view)
            let action = try #require(item.action)
            #expect(app.sendAction(action, to: item.target, from: item))
        }
        #expect(calls == 2 && !view.isEditable && view.isSelectable)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func restartDrainsAnAdmittedPanelReadBeforeClosingTheFirstStore() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var opens = 0
        var retired = false
        let module = VoiceModule(openStore: {
            opens += 1
            return try SaytileStore(directory: dir)
        }, makeInput: { _, update in
            let device = ScriptedInput(update)
            device.onShutdown = { retired = true }
            return device
        })
        try module.start()
        await module.waitForTransition()
        await module.toggle(requestPermission: false)
        var release: CheckedContinuation<Void, Never>?
        let read = Task {
            try await module.withPanelRead { store in
                _ = try await store.listRecordings()
                await withCheckedContinuation { release = $0 }
                return try await store.panelRecordingCount(createdSince: .distantPast, includingIDs: [])
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while release == nil && ContinuousClock.now < deadline { await Task.yield() }
        let gate = try #require(release)
        module.stop()
        try module.start()
        while !retired && ContinuousClock.now < deadline { await Task.yield() }
        #expect(retired)
        #expect(opens == 1)
        gate.resume()
        #expect(try await read.value == 0)
        await module.waitForTransition()
        #expect(opens == 2 && module.issue == nil)
        module.stop()
        await module.waitForTransition()
    }

    @Test func lateInputAndRevisionNotificationsCannotSurviveRepeatedRestarts() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        weak var device: ScriptedInput?
        var denied = true
        let module = VoiceModule(openStore: { try SaytileStore(directory: dir) }, makeInput: { _, update in
            let input = ScriptedInput(update)
            input.permissionDenied = denied
            device = input
            return input
        })
        try module.start()
        for _ in 0..<16 {
            await module.waitForTransition()
            await module.toggle()
            #expect(denied ? module.issue != nil && module.capture == .paused : module.capture == .listening)
            let old = try #require(device)
            NotificationCenter.default.post(name: .init("SaytileRecognitionUpdated"), object: nil)
            module.stop()
            try module.start()
            await module.waitForTransition()
            old.update(.speaking, 1, "retired input")
            #expect(old.closed)
            #expect(module.capture == .paused)
            #expect(module.issue == nil)
            #expect(module.transcript.isEmpty)
            denied.toggle()
        }
        module.stop(); await module.waitForTransition()
        #expect(device == nil)
        let reopened = try SaytileStore(directory: dir)
        #expect(try await reopened.listRecordings().isEmpty)
        try await reopened.close()
    }

    @Test func acceptanceRecordsOnlyExplicitPauseAndTheDomainsOpenRecording() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SaytileStore(directory: dir)
        var input: ScriptedInput?, events: [String] = []
        let module = VoiceModule(openStore: { store }, makeInput: { _, update in
            let device = ScriptedInput(update); input = device; return device
        })
        module.acceptanceEvent = { events.append($0) }
        try module.start(); await module.waitForTransition(); await module.toggle()
        let recording = try await store.createRecording()
        let ticket = try await store.beginRecognition(recordingID: recording.id)
        input?.update(.speaking, 0.3, nil)
        await module.refresh()
        #expect(module.openRecordingIDs == [recording.id])
        _ = try await store.applyRecognition(ticket: ticket,text: "Synthetic result",isFinal: true)
        try await store.finishRecording(id: recording.id); try await store.finishRecognition(ticket: ticket)
        input?.update(.listening, 0, nil); await module.refresh()
        #expect(module.openRecordingIDs.isEmpty && module.control.state == .standby)
        #expect(try await store.latestFinalRevision(recordingID: recording.id)?.recordingID == recording.id)
        #expect(!events.contains("userPause"))
        await module.toggle()
        #expect(events.suffix(2) == ["userPause","captureState"])
        module.stop(); await module.waitForTransition()
    }
}
