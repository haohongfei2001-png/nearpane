import Foundation

actor MediaRemoteClient {
    static let revision = "2ef957c736256cee7905c9f3f1c7e279087bf195"
    private let directory: URL
    private var jobs: [UUID: BoundedProcess] = [:]
    init(directory: URL? = nil) {
        #if DEBUG
        if directory == nil, let developmentPath = ProcessInfo.processInfo.environment["LYRICTILE_MEDIA_HELPER"], developmentPath.hasPrefix("/") {
            self.directory = URL(fileURLWithPath: developmentPath, isDirectory: true)
            return
        }
        #endif
        self.directory = directory ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("MediaRemote", isDirectory: true)
    }
    private func job(_ arguments: [String], artwork: Bool = false, stream: Bool = false,
                     chunk: (@Sendable (Data) -> Bool)? = nil) throws -> BoundedProcess {
        #if !os(macOS)
        throw PlaybackError.unavailable("MediaRemote 需要 macOS。")
        #else
        let script = directory.appendingPathComponent("mediaremote-adapter.pl")
        let framework = directory.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path) else {
            throw PlaybackError.unavailable("安装包未包含媒体助手；请重新安装完整版本。")
        }
        return BoundedProcess(executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [script.path, framework.path] + arguments,
            limit: artwork ? 12 * 1024 * 1024 : 512 * 1024, timeout: stream ? nil : 6,
            chunk: chunk)
        #endif
    }
    private func run(_ arguments: [String], artwork: Bool = false) async throws -> Data {
        let id = UUID(); let process = try job(arguments, artwork: artwork)
        jobs[id] = process; defer { jobs.removeValue(forKey: id) }
        let result = try await process.run()
        guard result.status == 0 else {
            // Keep bounded helper diagnostics available without pretending exit=0
            // proves transport success. Caller still performs actual readback.
            let message = String(data: result.stderr.prefix(2048), encoding: .utf8) ?? "媒体助手退出"
            throw PlaybackError.unavailable(message)
        }
        return result.data
    }
    func read(target: PlayerID? = nil, artwork: Bool = false) async throws -> [MediaRemotePayload] {
        var arguments = ["get", "--micros", "--allow-missing-title"]
        if !artwork { arguments.append("--no-artwork") }
        if let target { arguments.append("--bundle-id=\(target.bundleID)") }
        return try MediaRemotePayload.decodeGet(await run(arguments, artwork: artwork), target: target)
    }
    func stream() throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let id = UUID()
        let process = try job(["stream", "--micros", "--no-artwork", "--allow-missing-title", "--debounce=80"], stream: true) { data in
            switch continuation.yield(data) {
            case .enqueued: return true
            case .dropped, .terminated: return false
            @unknown default: return false
            }
        }
        jobs[id] = process
        let task = Task {
            do {
                _ = try await process.run()
                continuation.finish(throwing: PlaybackError.unavailable("媒体助手连接已结束"))
            } catch { continuation.finish(throwing: error) }
            self.jobs.removeValue(forKey: id)
        }
        continuation.onTermination = { @Sendable _ in process.cancel(); task.cancel() }
        return stream
    }
    func send(_ command: TransportCommand) async throws {
        if case .seek(let milliseconds) = command {
            _ = try await run(["seek", try MediaTime.seekMicros(milliseconds)])
        } else if let id = command.remoteCommandID {
            _ = try await run(["send", String(id)])
        } else { throw PlaybackError.unsupported }
    }
    func stop() async {
        let pending = Array(jobs.values); jobs.removeAll()
        for process in pending { process.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for process in pending { group.addTask { await process.cancelAndWait() } }
        }
    }
}
