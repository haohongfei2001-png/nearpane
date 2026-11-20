import CryptoKit
import Darwin
import Foundation

/// A finished local recognition is verified from the same durable recording and
/// immutable revision. A user-edited preferred revision is never overwritten.
public struct NearpaneVoiceReadback: Sendable {
    public enum State: String, Sendable { case final, recoverable, discarded, unverified }
    public let recording: UUID
    public let state: State
    public let audioSHA256: String?
    public let finalSHA256: String?
    public let frames: Int64

    public static func read(_ id: UUID, store: SaytileStore) async -> Self {
        func result(_ state: State, audio: String? = nil, text: String? = nil, frames: Int64 = 0) -> Self {
            .init(recording: id, state: state, audioSHA256: audio, finalSHA256: text, frames: frames)
        }
        do {
            guard let before = try await store.recording(id: id) else { return result(.discarded) }
            guard !before.isRecording else { return result(.unverified) }
            if before.audioState == .deletePending || before.audioState == .deleted { return result(.discarded) }
            let chunks = try await store.audioChunks(recordingID: id)
            let root = open(store.audioDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard root >= 0 else { return result(.unverified) }
            defer { close(root) }
            let directory = openat(root, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else { return result(.unverified) }
            defer { close(directory) }
            var hash = SHA256(), total: Int64 = 0
            for chunk in chunks {
                let path = chunk.relativePath.split(separator: "/")
                guard path.count == 2, path[0] == id.uuidString,
                      path[1].hasSuffix(".wav"), UUID(uuidString: String(path[1].dropLast(4))) != nil,
                      chunk.frames >= 0, chunk.frames <= (Int64(UInt32.max) - 36) / 2 else { return result(.unverified) }
                let descriptor = openat(directory, String(path[1]), O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                guard descriptor >= 0 else { return result(.unverified) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_size == 44 + 2 * chunk.frames,
                      let header = try handle.read(upToCount: 44),
                      header == PCMJournal.header(frames: chunk.frames) else { return result(.unverified) }
                hash.update(data: header)
                var bytes: Int64 = 0
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    bytes += Int64(data.count)
                    hash.update(data: data)
                }
                guard bytes == chunk.frames * 2 else { return result(.unverified) }
                total += chunk.frames
            }
            guard total > 0, before.audioState == .available, before.sampleRate == 16_000,
                  abs(before.duration * before.sampleRate - Double(total)) < 0.5 else { return result(.unverified) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let final = try await store.latestFinalRevision(recordingID: id)
            guard let after = try await store.recording(id: id), after == before else { return result(.unverified) }
            if before.recognitionState == .completed, let final,
               final.id == before.preferredRevisionID, final.recordingID == id, !final.text.isEmpty {
                let text = SHA256.hash(data: Data(final.text.utf8)).map { String(format: "%02x", $0) }.joined()
                return result(.final, audio: digest, text: text, frames: total)
            }
            return result(.recoverable, audio: digest, frames: total)
        } catch { return result(.unverified) }
    }
}

// The capture worker owns these tasks. Graceful exit gives only already-open,
// on-device recognizers a shared deadline. It starts no recognition or network request.
extension CaptureWorker {
    func retire(_ session: any RecognitionSession, isLocal: Bool) {
        retired.removeAll { $0.isComplete }
        retired.append(session)
        guard isLocal else { return }
        let id = session.recordingID
        localReadbacks[id] = Task {
            await session.wait()
            if let observedFinal {
                let proof = await NearpaneVoiceReadback.read(id, store: store)
                observedFinal(proof)
            }
            localReadbacks.removeValue(forKey: id)
        }
    }

    static func finishForShutdown(_ workers: [CaptureWorker], grace: Duration = .seconds(5)) async {
        // Paid work retains its original cancellation policy even when another worker is finishing locally.
        for worker in workers { await worker.cancelNonlocalSessions() }
        let deadline = ContinuousClock.now.advanced(by: grace)
        for worker in workers { await worker.allowLocalFinals(until: deadline) }
        for worker in workers {
            await worker.cancelRecognitionAndWait()
            await worker.joinLocalReadbacks()
        }
    }

    private func cancelNonlocalSessions() {
        for session in retired where !session.isComplete && localReadbacks[session.recordingID] == nil {
            session.cancel()
        }
    }

    private func allowLocalFinals(until deadline: ContinuousClock.Instant) async {
        while !localReadbacks.isEmpty && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
    }

    private func joinLocalReadbacks() async {
        for task in Array(localReadbacks.values) { await task.value }
    }
}
