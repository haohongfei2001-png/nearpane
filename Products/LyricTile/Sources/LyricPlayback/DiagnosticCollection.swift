import Foundation
import LyricCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct DiagnosticCollectionResult: Codable, Sendable {
    public let outputDirectory: URL
    public let requestedSeconds: Int
    public let elapsedSeconds: Double
    public let snapshotCount: Int
    public let snapshotsWithRecording: Int
    public let observedPlayers: [PlayerID]
    public let distinctRecordingIdentities: Int
    public let completedRequestedWindow: Bool
    public let independentReferenceProvided: Bool
}

public enum DiagnosticCollectionError: Error, LocalizedError, Sendable {
    case invalidArguments(String)
    case destinationNotEmpty
    case noRealPlayback(URL)
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .destinationNotEmpty: "诊断输出目录必须不存在或为空；不会覆盖已有记录。"
        case .noRealPlayback(let url): "采集窗口内未收到真实曲目。请检查播放器是否播放、权限和媒体助手。日志已保留：\(url.path)"
        }
    }
}

extension PlaybackController {
    /// Explicit CLI/diagnostic use only. Read-only: no play, pause, seek, launch,
    /// recommendation, upload, fake input, or qualification is performed.
    public static func collectDiagnostics(player: PlayerID? = nil, seconds: Int = 60,
                                          outputDirectory: URL) async throws -> DiagnosticCollectionResult {
        try Task.checkCancellation()
        guard (1...3600).contains(seconds) else { throw DiagnosticCollectionError.invalidArguments("采集时长必须为 1…3600 秒。") }
        guard outputDirectory.isFileURL, outputDirectory.path.hasPrefix("/") else {
            throw DiagnosticCollectionError.invalidArguments("请提供明确的本地绝对输出目录。")
        }
        let recorder = try DiagnosticRecorder(directory: outputDirectory, requestedSeconds: seconds)
        let controller = PlaybackController()
        do {
            let environment = await diagnosticEnvironment(player: player, seconds: seconds)
            try Task.checkCancellation()
            try await recorder.writeEnvironment(environment)
            let updates = await controller.updates()
            await controller.start(preferred: player)
            await recorder.beginWindow()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await update in updates {
                        try Task.checkCancellation()
                        let source = try await controller.diagnosticReport()
                        try await recorder.record(update, source: source)
                    }
                }
                group.addTask { try await Task.sleep(for: .seconds(seconds)) }
                _ = try await group.next()
                group.cancelAll()
            }
            await controller.stop()
            let result = try await recorder.finish(completed: true)
            guard result.snapshotsWithRecording > 0 else { throw DiagnosticCollectionError.noRealPlayback(outputDirectory) }
            return result
        } catch {
            await controller.stop()
            _ = try? await recorder.finish(completed: false)
            throw error
        }
    }

    private static func diagnosticEnvironment(player: PlayerID?, seconds: Int) async -> Data {
        var fields: [String: JSONValue] = [
            "schemaVersion": .int(1), "dataOrigin": .string("real_player"),
            "requestedPlayer": player.map { .string($0.rawValue) } ?? .null,
            "requestedSeconds": .int(Int64(seconds)), "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            "macOSVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "systemBuild": .string(await PlayerEnvironment.systemBuild()),
            "hardwareMemoryBytes": .string(String(ProcessInfo.processInfo.physicalMemory)),
            "processorCount": .int(Int64(ProcessInfo.processInfo.processorCount)),
            "appBundleID": Bundle.main.bundleIdentifier.map(JSONValue.string) ?? .null,
            "appVersion": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map(JSONValue.string) ?? .null,
            "appBuild": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map(JSONValue.string) ?? .null,
            "appleEventsRevision": .string(AppleEventClient.revision), "mediaRemoteRevision": .string(MediaRemoteClient.revision),
            "packageSHA256": .null, "independentReferenceProvided": .bool(false),
            "timingClaim": .string("source observations only; no acoustic P95 is inferred")
        ]
        let inventory = await PlayerEnvironment.running()
        fields["runningPlayers"] = .array(inventory.map { .object([
            "player": .string($0.player.rawValue), "bundleID": .string($0.player.bundleID),
            "pid": .int(Int64($0.pid)), "processStartMicros": .string(String($0.startMicros)),
            "version": .string($0.version), "build": .string($0.build)]) })
        if let executable = Bundle.main.executableURL { fields["executableSHA256"] = executableHash(executable).map(JSONValue.string) ?? .null }
        #if os(macOS)
        let sipProbe = BoundedProcess(executable: URL(fileURLWithPath: "/usr/bin/csrutil"), arguments: ["status"], limit: 8192, timeout: 2)
        if let output = try? await sipProbe.run(), output.status == 0 {
            fields["sipStatus"] = .string(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } else { fields["sipStatus"] = .null }
        #endif
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(JSONValue.object(fields))) ?? Data("{}".utf8)
    }
    private static func executableHash(_ url: URL) -> String? {
        #if canImport(CryptoKit)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
        #else
        return nil
        #endif
    }
}

private struct DiagnosticAnchor: Codable, Sendable {
    let positionMS: Int64?
    let observedUptimeNanoseconds: UInt64
    let clockDomainID: UUID
    let rate: Double
    let quality: String
    let expectedErrorMS: Int64?
}
private struct DiagnosticUpdate: Codable, Sendable {
    let dataOrigin: String
    let receivedAt: Date
    let receivedEpochMicros: Int64
    let receivedUptimeNanoseconds: UInt64
    let player: PlayerID?
    let selection: LyricDomain.Selection?
    let anchor: DiagnosticAnchor?
    let state: String
    let capabilities: TransportCapabilities
    let artworkByteCount: Int
    let statusMessage: String?
    let requiresAuthorization: Bool
}

private actor DiagnosticRecorder {
    let directory: URL
    let requestedSeconds: Int
    private var started = ProcessInfo.processInfo.systemUptime
    private let events: FileHandle
    private let sources: FileHandle
    private var count = 0
    private var identifiedCount = 0
    private var players: Set<PlayerID> = []
    private var recordings: Set<String> = []
    private var result: DiagnosticCollectionResult?
    private var writtenBytes = 0

    init(directory: URL, requestedSeconds: Int) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            guard try manager.contentsOfDirectory(atPath: directory.path).isEmpty else { throw DiagnosticCollectionError.destinationNotEmpty }
        } else { try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        self.directory = directory; self.requestedSeconds = requestedSeconds
        events = try Self.exclusiveFile(directory.appendingPathComponent("events.ndjson"))
        sources = try Self.exclusiveFile(directory.appendingPathComponent("source.ndjson"))
    }
    private static func exclusiveFile(_ url: URL) throws -> FileHandle {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        throw DiagnosticCollectionError.invalidArguments("当前系统不支持安全的诊断文件创建。")
        #endif
    }
    func writeEnvironment(_ bytes: Data) throws {
        let handle = try Self.exclusiveFile(directory.appendingPathComponent("environment.json"))
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
    }
    func beginWindow() { started = ProcessInfo.processInfo.systemUptime }
    func record(_ snapshot: PlaybackSnapshot, source: Data) throws {
        guard result == nil else { return }
        let anchor = snapshot.anchor.map { DiagnosticAnchor(positionMS: $0.positionMS,
            observedUptimeNanoseconds: $0.observedAt.nanoseconds, clockDomainID: $0.observedAt.clockDomainID,
            rate: $0.playbackRate, quality: $0.quality.rawValue, expectedErrorMS: $0.expectedErrorMS) }
        let wallNow = Date()
        let entry = DiagnosticUpdate(dataOrigin: "real_player", receivedAt: wallNow,
            receivedEpochMicros: Int64(wallNow.timeIntervalSince1970 * 1_000_000), receivedUptimeNanoseconds: PlaybackClock.now().nanoseconds,
            player: snapshot.player, selection: snapshot.selection, anchor: anchor, state: snapshot.state.rawValue,
            capabilities: snapshot.capabilities, artworkByteCount: snapshot.artwork?.count ?? 0,
            statusMessage: snapshot.statusMessage, requiresAuthorization: snapshot.requiresAuthorization)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(entry)
        guard encoded.count <= 1024 * 1024, source.count <= 2 * 1024 * 1024 else { throw PlaybackError.outputLimit }
        // diagnosticReport is pretty JSON; compact it before writing one NDJSON record.
        let compact = try JSONEncoder().encode(JSONDecoder().decode(JSONValue.self, from: source))
        var eventLine = encoded; eventLine.append(10)
        var sourceLine = compact; sourceLine.append(10)
        guard writtenBytes + eventLine.count + sourceLine.count <= 128 * 1024 * 1024 else { throw PlaybackError.outputLimit }
        try events.write(contentsOf: eventLine); try sources.write(contentsOf: sourceLine)
        writtenBytes += eventLine.count + sourceLine.count
        count += 1
        if let player = snapshot.player { players.insert(player) }
        if let selected = snapshot.selection {
            identifiedCount += 1; recordings.insert(selected.playerBundleID + ":" + selected.recording.fingerprint)
        }
    }
    func finish(completed: Bool) throws -> DiagnosticCollectionResult {
        if let result { return result }
        let value = DiagnosticCollectionResult(outputDirectory: directory, requestedSeconds: requestedSeconds,
            elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started), snapshotCount: count,
            snapshotsWithRecording: identifiedCount, observedPlayers: PlayerID.allCases.filter(players.contains),
            distinctRecordingIdentities: recordings.count, completedRequestedWindow: completed, independentReferenceProvided: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summary = try Self.exclusiveFile(directory.appendingPathComponent("summary.json"))
        defer { try? summary.close(); try? events.close(); try? sources.close() }
        try events.synchronize(); try sources.synchronize()
        try summary.write(contentsOf: encoder.encode(value))
        result = value
        return value
    }
}
