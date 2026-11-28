import AVFoundation
import Combine
import Foundation
import Synchronization
import Testing
import CAudio
@testable import SaytileKit

struct PCMPipelineTests {
    @Test func finalMandarinPunctuationIsBoundToItsRangeAndSurvivesRedelivery() {
        var transcript = SpeechResultAccumulator()
        _ = transcript.apply(start: 0, end: 1, text: "第一句 ，", isFinal: false)
        let otherRange = transcript.apply(start: 2, end: 2, text: "。", isFinal: true)
        #expect(otherRange.stableText == "" && otherRange.fullText == "第一句，")
        _ = transcript.apply(start: 1, end: 2, text: "第二句", isFinal: false)
        let final = transcript.apply(start: 2, end: 2, text: "。", isFinal: true, finalizedThrough: 2)
        #expect(final.fullText == "第一句，第二句。" && final.stableText == final.fullText && final.isCompletelyFinal)
        #expect(transcript.apply(start: 2, end: 2, text: "。", isFinal: true) == final)
        #expect(transcript.apply(start: 2, end: 2, text: "别的文字", isFinal: true) == final)
    }

    @MainActor @Test func coldCaptureWaitsForActualPCMAndAcceptsSilentInput() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data")
            .appendingPathComponent("cold-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SaytileStore(directory: root)
        let controller = AudioController(store: store, startupRecoveryReady: false)
        var states = [CaptureState]()
        let observation = controller.$state.sink { states.append($0) }
        defer { observation.cancel() }
        for frames in [0, 3_200] {
            let url = root.appendingPathComponent("silence-" + String(frames) + ".wav")
            do {
                let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                       channels: 1, interleaved: false))
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
                                           interleaved: false)
                if frames > 0 {
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
                    buffer.frameLength = UInt32(frames)
                    buffer.int16ChannelData![0].update(repeating: 0, count: frames)
                    try file.write(from: buffer)
                }
            }
            states.removeAll()
            _ = try await controller.replayLocalFixture(url, recordOnly: true)
            #expect(states.first == .starting)
            #expect(states.contains(.listening) == (frames > 0))
            #expect(states.last == .paused)
        }
        await controller.shutdown()
    }

    @Test func injectedSamplesDrainThroughTheDomainRingAndJournalWithoutRecognition() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data")
            .appendingPathComponent("pcm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SaytileStore(directory: root)
        let ring = try AudioRing(capacity: 65_536)
        let speaking = Mutex<[Bool]>([])
        let worker = try CaptureWorker(store: store, ring: ring, sampleRate: 16_000, recognitionEnabled: false,
            update: { voice, _ in speaking.withLock { $0.append(voice) } },
            failed: { message in Issue.record("Injected PCM failed: \(message)") })

        // A modulated voiced interval followed by enough silence for the real WebRTC VAD to close it.
        var frames = [Float](repeating: 0, count: 48_000)
        for i in 0..<19_200 {
            let t = Double(i) / 16_000
            let phase = 2 * Double.pi * 143 * t + 1.8 * sin(12 * t)
            frames[i] = Float((0.34 + 0.13 * sin(31 * t)) * (sin(phase) + 0.38 * sin(3 * phase)))
        }
        frames.withUnsafeBufferPointer { buffer in
            var channel = buffer.baseAddress!
            st_ring_write(ring.pointer, &channel, 1, UInt32(buffer.count))
        }
        await worker.start()
        await worker.stop()
        let states = speaking.withLock { $0 }
        #expect(states.contains(true) && states.last == false)
        #expect(st_ring_dropped(ring.pointer) == 0)
        let recordings = try await store.listRecordings()
        try #require(recordings.count == 1)
        let recording = recordings[0]
        #expect(!recording.isRecording && recording.audioState == .available && recording.duration > 0)
        #expect(recording.recognitionState != .completed && recording.text.isEmpty)
        #expect(try await store.revisions(recordingID: recording.id).isEmpty)
        let chunks = try await store.audioChunks(recordingID: recording.id)
        let chunk = try #require(chunks.first)
        #expect(chunks.count == 1 && chunk.recordingID == recording.id && chunk.frames > 16_000)
        let bytes = try Data(contentsOf: store.audioDirectory.appendingPathComponent(chunk.relativePath))
        #expect(bytes.count >= chunk.frames * 2 && bytes.contains { $0 != 0 })
    }
}
