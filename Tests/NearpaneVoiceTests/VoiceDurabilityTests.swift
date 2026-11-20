import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NearpaneVoice
@testable import SaytileKit

private final class DelayedRecognition: RecognitionSession {
    let recordingID: UUID
    private let job: Task<Void, Never>
    let earlyCancel = Mutex(false)

    init(recordingID: UUID, after: Duration, commit: @escaping @Sendable () async throws -> Void) {
        self.recordingID = recordingID
        let done = Completion()
        job = Task {
            defer { done.value.withLock { $0 = true } }
            do {
                try await Task.sleep(for: after)
                try Task.checkCancellation()
                try await commit()
            } catch is CancellationError {} catch { Issue.record("Synthetic recognition failed: \(error)") }
        }
        completion = done
    }

    private final class Completion: Sendable { let value = Mutex(false) }
    private let completion: Completion
    var isComplete: Bool { completion.value.withLock { $0 } }
    func append(_ data: Data) {}
    func finish() {}
    func cancel() {
        if !isComplete { earlyCancel.withLock { $0 = true } }
        job.cancel()
    }
    func wait() async { await job.value }
}

struct VoiceDurabilityTests {
    private func directory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data")
            .appendingPathComponent("voice-reopen-" + UUID().uuidString)
    }

    private func voiceFixture(_ store: SaytileStore, byte: UInt8 = 7) async throws -> (RecognitionTicket, URL, String) {
        let row = try await store.createRecording()
        let journal = try PCMJournal(directory: store.audioDirectory, recordingID: row.id)
        try journal.openChunk()
        try journal.append(Data(repeating: byte, count: 3_200))
        try journal.closeChunk()
        let url = store.audioDirectory.appendingPathComponent(journal.relativePath)
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        try await store.registerAudioChunk(recordingID: row.id, relativePath: journal.relativePath, frames: journal.frames)
        try await store.finishRecording(id: row.id)
        let ticket = try await store.beginRecognition(recordingID: row.id)
        try await store.applyRecognition(ticket: ticket, text: "样本", isFinal: false)
        return (ticket, url, hash)
    }

    @Test func gracefulShutdownKeepsLocalFinalAndUnfinishedAudioThroughReopen() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SaytileStore(directory: directory)
        let (done, _, doneAudio) = try await voiceFixture(store)
        let (pending, _, pendingAudio) = try await voiceFixture(store, byte: 11)
        let reads = Mutex([UUID: NearpaneVoiceReadback]())
        let worker = try CaptureWorker(store: store, ring: AudioRing(capacity: 1_024), sampleRate: 16_000,
            observedFinal: { proof in reads.withLock { $0[proof.recording] = proof } },
            update: { _, _ in }, failed: { _ in Issue.record("Unexpected recorder failure") })
        let controller = await AudioController(store: store, initialWorker: worker)
        let complete = DelayedRecognition(recordingID: done.recordingID, after: .milliseconds(120)) {
            try await store.applyRecognition(ticket: done, text: "合成短句", isFinal: true)
            try await store.finishRecognition(ticket: done)
        }
        let unfinished = DelayedRecognition(recordingID: pending.recordingID, after: .seconds(15)) {
            Issue.record("A timed-out session was allowed to commit")
        }
        let nonlocal = DelayedRecognition(recordingID: UUID(), after: .milliseconds(180)) {
            Issue.record("Cloud work outlived synchronous shutdown revocation")
        }
        await worker.retire(complete, isLocal: true)
        await worker.retire(unfinished, isLocal: true)
        await worker.retire(nonlocal, isLocal: false)
        #expect((await NearpaneVoiceReadback.read(done.recordingID, store: store)).state == .recoverable)
        await controller.shutdown()
        let snapshots = reads.withLock { $0 }
        #expect(snapshots.count == 2)
        #expect(!complete.earlyCancel.withLock { $0 })
        #expect(unfinished.earlyCancel.withLock { $0 })
        #expect(nonlocal.earlyCancel.withLock { $0 })
        let final = try #require(snapshots[done.recordingID])
        let timeout = try #require(snapshots[pending.recordingID])
        #expect(final.state == .final && final.audioSHA256 == doneAudio && final.frames == 1_600)
        let expected = SHA256.hash(data: Data("合成短句".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(final.finalSHA256 == expected)
        #expect(timeout.state == .recoverable && timeout.finalSHA256 == nil && timeout.audioSHA256 == pendingAudio)
        try await store.close()

        let reopened = try SaytileStore(directory: directory)
        let persisted = await NearpaneVoiceReadback.read(done.recordingID, store: reopened)
        let retryable = await NearpaneVoiceReadback.read(pending.recordingID, store: reopened)
        #expect(persisted.state == .final && persisted.audioSHA256 == doneAudio && persisted.finalSHA256 == expected)
        #expect(retryable.state == .recoverable && retryable.audioSHA256 == pendingAudio && retryable.finalSHA256 == nil)
        #expect(try await reopened.recording(id: pending.recordingID)?.recognitionState == .queued)
        if let destination = ProcessInfo.processInfo.environment["NEARPANE_P4_VOICE_RECEIPT"] {
            let json: [String: Any] = [
                "path": "AudioController.shutdown → pinned CaptureWorker → PCMJournal/SaytileStore → close/reopen",
                "inputs": "synthetic PCM and two controlled RecognitionSession completions; no audio device",
                "selectedProviderTested": false,
                "cloudCancelledBeforeGrace": nonlocal.earlyCancel.withLock { $0 },
                "delayedFinal": ["recording": done.recordingID.uuidString, "audioSHA256": doneAudio,
                    "finalSHA256": expected, "frames": persisted.frames, "state": persisted.state.rawValue] as [String: Any],
                "timeout": ["recording": pending.recordingID.uuidString, "audioSHA256": pendingAudio,
                    "finalSHA256": NSNull(), "frames": retryable.frames, "state": retryable.state.rawValue] as [String: Any],
            ]
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        try await reopened.close()
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["NEARPANE_P4_FILE_RECEIPT"] != nil))
    func recordLocalModelAvailabilityAndReplayThreeSyntheticFilesWhenInstalled() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["NEARPANE_P4_FILE_RECEIPT"])
        let directory = directory()
        let phrases = ["今天测试语音", "窗外正在下雨", "蓝色雨伞放在门口"]
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = await AppleSpeechService.availability()
        var records = [[String: Any]]()
        if availability.installed {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, phrase) in phrases.enumerated() {
                let input = directory.appendingPathComponent("synthetic-\(index).wav")
                let synth = Process()
                synth.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                synth.arguments = ["-v", "Tingting", "-r", "165", "-o", input.path, "--file-format=WAVE", "--data-format=LEI16@16000", phrase]
                try synth.run()
                synth.waitUntilExit()
                try #require(synth.terminationStatus == 0)
                let profile = directory.appendingPathComponent("voice-\(index)")
                let store = try SaytileStore(directory: profile)
                let controller = AudioController(store: store, startupRecoveryReady: false)
                let intent = UUID()
                controller.nearpaneCaptureIntent = intent
                let result = Mutex<NearpaneVoiceReadback?>(nil)
                controller.nearpaneLocalFinal = { id, proof in
                    if id == intent { result.withLock { $0 = proof } }
                }
                var record: [String: Any] = ["fixture": index + 1, "intent": intent.uuidString,
                    "sourceSHA256": SHA256.hash(data: try Data(contentsOf: input)).map { String(format: "%02x", $0) }.joined()]
                do {
                    _ = try await controller.replayLocalFixture(input)
                    let rows = try await store.listRecordings()
                    if rows.count == 1, let row = rows.first, let live = result.withLock({ $0 }), live.recording == row.id {
                        let normalized = row.text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
                            !CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
                        }
                        let heard = String(String.UnicodeScalarView(normalized))
                        record["recording"] = row.id.uuidString
                        record["preferredFinalExact"] = heard == phrase
                        record["leadingCharactersMatched"] = zip(heard, phrase).prefix(while: ==).count
                        record["state"] = live.state.rawValue
                        record["audioSHA256"] = live.audioSHA256
                        record["finalSHA256"] = live.finalSHA256
                        await controller.shutdown()
                        try await store.close()
                        let next = try SaytileStore(directory: profile)
                        let reopened = await NearpaneVoiceReadback.read(row.id, store: next)
                        let stable = live.state == .final && reopened.state == .final && reopened.frames == live.frames
                            && reopened.audioSHA256 == live.audioSHA256 && reopened.finalSHA256 == live.finalSHA256
                        record["reopened"] = stable
                        record["result"] = stable ? (heard == phrase ? "PASS" : "FAIL") : "UNKNOWN"
                        try await next.close()
                    } else {
                        record["result"] = "UNKNOWN"
                        await controller.shutdown()
                        try await store.close()
                    }
                } catch {
                    record["result"] = "UNKNOWN"
                    await controller.shutdown()
                    try? await store.close()
                }
                records.append(record)
            }
        }
        let report: [String: Any] = [
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": "Saytile default local SpeechAnalyzer / Chinese SpeechTranscriber",
            "input": "file only, 3 synthetic unprimed Tingting phrases; new controller and database per phrase in one process",
            "reachable": availability.supported, "installed": availability.installed,
            "status": availability.installed ? (records.allSatisfy { $0["result"] as? String == "PASS" } ? "PASS" :
                (records.contains { $0["result"] as? String == "FAIL" } ? "FAIL" : "UNKNOWN")) : "BLOCKED",
            "physicalColdStart": "NOT_RUN", "records": records
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    @Test func corruptWavAndErasureCannotBecomeFinal() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SaytileStore(directory: directory)
        let (ticket, url, _) = try await voiceFixture(store)
        try await store.applyRecognition(ticket: ticket, text: "完整", isFinal: true)
        try await store.finishRecognition(ticket: ticket)
        let before = try Data(contentsOf: url)
        try before.dropLast().write(to: url)
        let bad = await NearpaneVoiceReadback.read(ticket.recordingID, store: store)
        #expect(bad.state == .unverified && bad.audioSHA256 == nil && bad.finalSHA256 == nil)
        try before.write(to: url)
        try await store.deleteAudio(recordingID: ticket.recordingID)
        let deleted = await NearpaneVoiceReadback.read(ticket.recordingID, store: store)
        #expect(deleted.state == .discarded && deleted.audioSHA256 == nil)
        try await store.close()
    }

    @Test func prerollPreservesQuietOnsetBeforeVadVotesAndFinalPartialFrame() throws {
        let vad = try VoiceSegmenter()
        let quiet = (0..<3_200).map { Int16($0 % 15 - 7) }.withUnsafeBytes { Data($0) }
        var voiced = [Int16]()
        for i in 0..<5_397 {
            let t = Double(i) / 16_000
            let phase = 2 * Double.pi * 143 * t + 1.8 * sin(12 * t)
            voiced.append(Int16(8_000 * sin(phase) + 2_000 * sin(phase * 3)))
        }
        let source = quiet + voiced.withUnsafeBytes { Data($0) }
        var actual = Data(), sawBegin = false
        for event in vad.accept(source) + vad.finish() {
            switch event {
            case let .begin(frames, sample):
                #expect(!sawBegin && sample >= 3_200)
                sawBegin = true
                for frame in frames { actual.append(frame) }
            case let .audio(frame): actual.append(frame)
            case .end: break
            }
        }
        #expect(sawBegin && actual == source)
    }
}
