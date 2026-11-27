import Foundation
import LyricCore
import LyricServices

// Live network observation through the production provider, matcher, parser and
// repository. These supplied metadata queries are not a real-player test, an
// independently verified audio corpus, or a representative catalogue sample.
// The output contains metadata and hashes only. Temporary lyric caches are
// removed when the probe exits and must not be uploaded as CI artifacts.

private struct Sample: Codable, Sendable {
    let id: String
    let category: String
    let title: String
    let artist: String
    let album: String?
    let durationMS: Int64?

    func selection(generation: UInt64, sessionID: UUID) -> LyricDomain.Selection {
        .init(playerBundleID: "com.holdsnow.lyrictile.service-probe", sessionID: sessionID,
            generation: generation, recording: .init(fingerprint: "service-probe:\(id)",
                platformIDs: [], isrc: nil, title: title, artists: [artist], album: album,
                durationMS: durationMS, versionTags: []))
    }
}

private struct RequestObservation: Codable, Sendable {
    let path: String
    let status: Int?
    let milliseconds: Double
    let bodyBytes: Int
    let retryAfter: String?
    let error: String?
}

private actor ObservedTransport: LyricsHTTPTransport {
    private let upstream = URLSessionLyricsTransport()
    private var observations: [RequestObservation] = []

    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await upstream.get(request)
            observations.append(.init(path: request.url?.path ?? "", status: response.status,
                milliseconds: elapsed(started), bodyBytes: response.body.count,
                retryAfter: response.headers["retry-after"], error: nil))
            return response
        } catch {
            observations.append(.init(path: request.url?.path ?? "", status: nil,
                milliseconds: elapsed(started), bodyBytes: 0, retryAfter: nil,
                error: error is CancellationError ? "cancelled" : "transport_error"))
            throw error
        }
    }

    func snapshot() -> [RequestObservation] { observations }
}

private struct CandidateObservation: Codable, Sendable {
    let providerRecordID: String
    let recording: LyricDomain.RecordingIdentity
    let timing: String
    let automaticallyAcceptable: Bool
    let titleSimilarity: Double?
    let mainArtistMatch: Bool?
    let albumMatch: Bool?
    let durationDeltaMS: Int64?
    let versionConflict: Bool
    let reasons: [String]

    init(_ candidate: LyricDomain.Candidate) {
        providerRecordID = candidate.providerRecordID
        recording = candidate.recording
        timing = candidate.availableTiming.rawValue
        automaticallyAcceptable = LyricMatcher().mayAutomaticallyAccept(candidate.evidence)
        titleSimilarity = candidate.evidence.titleSimilarity
        mainArtistMatch = candidate.evidence.mainArtistMatch
        albumMatch = candidate.evidence.albumMatch
        durationDeltaMS = candidate.evidence.durationDeltaMS
        versionConflict = candidate.evidence.versionConflict
        reasons = candidate.evidence.reasons
    }
}

private struct ResolutionObservation: Codable, Sendable {
    let kind: String
    var contentHash: String?
    var providerRecordID: String?
    var timing: String?
    var instrumental: Bool?
    var cueCount: Int?
    var tokenCount: Int?
    var candidateCount: Int?
    var candidates: [CandidateObservation]?
    var error: String?

    init(_ result: LyricResolution) {
        switch result {
        case .document(let document):
            kind = "document"
            contentHash = document.contentHash
            providerRecordID = document.source.providerRecordID
            timing = document.timingLevel.rawValue
            instrumental = document.instrumental
            cueCount = document.lanes.reduce(0) { $0 + $1.cues.count }
            tokenCount = document.lanes.reduce(0) { total, lane in
                total + lane.cues.reduce(0) { $0 + $1.tokens.count }
            }
        case .candidates(let values):
            kind = "candidates"
            candidateCount = values.count
            candidates = values.prefix(5).map(CandidateObservation.init)
        case .notFound: kind = "not_found"
        }
    }

    init(error: any Error) {
        kind = "error"
        // Never stringify arbitrary parser/server errors into an artifact: some
        // future error might include a copyrighted lyric or private response.
        if let failure = error as? LyricDomain.SourceFailure {
            self.error = switch failure {
            case .notFound: "not_found"
            case .rateLimited(let seconds): "rate_limited_\(seconds)_seconds"
            case .transportUnavailable: "transport_unavailable"
            case .invalidDocument: "invalid_document"
            case .unsupportedFormat: "unsupported_format"
            case .unsupportedTimingProfile: "unsupported_timing_profile"
            case .staleGeneration: "stale_generation"
            case .accessUnavailable: "access_unavailable"
            }
        } else { self.error = error is CancellationError ? "cancelled" : "repository_error" }
    }
}

private struct ReadObservation: Codable, Sendable {
    let resolution: ResolutionObservation
    let milliseconds: Double
    let networkRequests: Int
}

private struct SampleObservation: Codable, Sendable {
    let sample: Sample
    let first: ReadObservation
    let second: ReadObservation?
    let reopenedOffline: ReadObservation?
    let cacheVerified: Bool?
    let requests: [RequestObservation]
}

private struct ProbeReport: Codable {
    let schemaVersion = 1
    let generatedAt: String
    let evidenceClass = "live_network_production_provider_and_repository"
    let actualPlayerPlayback = false
    let independentlyVerifiedAudioIdentity = false
    let sampleDescription = "Ten fixed supplied-metadata queries; observational, not a catalogue coverage estimate. Duration/version differences remain visible in candidate results."
    let lyricTextIncluded = false
    let temporaryCacheRemoved: Bool
    let results: [SampleObservation]
}

private func elapsed(_ start: TimeInterval) -> Double {
    ((ProcessInfo.processInfo.systemUptime - start) * 1000 * 100).rounded() / 100
}

private func read(_ repository: LyricRepository, selection: LyricDomain.Selection,
                  transport: ObservedTransport) async -> ReadObservation {
    let before = await transport.snapshot().count
    let started = ProcessInfo.processInfo.systemUptime
    let result: ResolutionObservation
    do { result = ResolutionObservation(try await repository.resolve(selection)) }
    catch { result = ResolutionObservation(error: error) }
    let after = await transport.snapshot().count
    return .init(resolution: result, milliseconds: elapsed(started), networkRequests: after - before)
}

private func runProbe(output: URL) async throws {
    let samples: [Sample] = [
        .init(id: "zh-qingtian", category: "chinese", title: "晴天", artist: "周杰伦", album: "叶惠美", durationMS: 269_000),
        .init(id: "zh-daoxiang", category: "chinese", title: "稻香", artist: "周杰伦", album: "魔杰座", durationMS: 223_000),
        .init(id: "zh-shinian", category: "chinese", title: "十年", artist: "陈奕迅", album: "黑·白·灰", durationMS: 205_000),
        .init(id: "en-yellow", category: "english", title: "Yellow", artist: "Coldplay", album: "Parachutes", durationMS: 269_000),
        .init(id: "en-hello", category: "english", title: "Hello", artist: "Adele", album: "25", durationMS: 295_000),
        .init(id: "en-shape-of-you", category: "english", title: "Shape of You", artist: "Ed Sheeran", album: "÷", durationMS: 234_000),
        .init(id: "en-live-version", category: "version_query", title: "Yellow (Live)", artist: "Coldplay", album: nil, durationMS: nil),
        .init(id: "instrumental", category: "instrumental", title: "Nuvole Bianche", artist: "Ludovico Einaudi", album: "Una Mattina", durationMS: 358_000),
        .init(id: "missing-duration", category: "incomplete_metadata_control", title: "Yellow", artist: "Coldplay", album: nil, durationMS: nil),
        .init(id: "nonexistent", category: "nonexistent_control", title: "LyricTile Verification 52b4ac754e55 No Such Recording", artist: "HOLDSNOW Service Probe", album: nil, durationMS: 61_000)
    ]
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LyricServiceProbe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sessionID = UUID()
    let transport = ObservedTransport()
    let provider = LRCLIBProvider(transport: transport)
    var results: [SampleObservation] = []
    for (index, sample) in samples.enumerated() {
        let startRequests = await transport.snapshot().count
        let storage = temporary.appendingPathComponent(sample.id, isDirectory: true)
        let repository = LyricRepository(storageURL: storage, provider: provider)
        let selection = sample.selection(generation: UInt64(index + 1), sessionID: sessionID)
        let first = await read(repository, selection: selection, transport: transport)
        var second: ReadObservation?
        var reopened: ReadObservation?
        var cacheVerified: Bool?
        if first.resolution.kind == "document" || first.resolution.kind == "not_found" {
            second = await read(repository, selection: selection, transport: transport)
            let offline = LyricRepository(storageURL: storage, onlineEnabled: false, provider: provider)
            reopened = await read(offline, selection: selection, transport: transport)
            cacheVerified = second?.networkRequests == 0
                && second?.resolution.kind == first.resolution.kind
                && second?.resolution.contentHash == first.resolution.contentHash
            if first.resolution.kind == "document" {
                cacheVerified = cacheVerified == true && reopened?.networkRequests == 0
                    && reopened?.resolution.kind == "document"
                    && reopened?.resolution.contentHash == first.resolution.contentHash
            }
        }
        let requests = Array((await transport.snapshot()).dropFirst(startRequests))
        results.append(.init(sample: sample, first: first, second: second, reopenedOffline: reopened,
                             cacheVerified: cacheVerified, requests: requests))
        print("\(sample.id): \(first.resolution.kind), \(first.milliseconds) ms, \(first.networkRequests) requests")
    }
    // Clear sensitive temporary content before writing the shareable observation.
    try FileManager.default.removeItem(at: temporary)
    let report = ProbeReport(generatedAt: ISO8601DateFormatter().string(from: Date()), temporaryCacheRemoved: true, results: results)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: output, options: .atomic)
    print("Wrote metadata-only observations to \(output.path)")
}

let arguments = CommandLine.arguments
guard let option = arguments.firstIndex(of: "--output"), arguments.indices.contains(option + 1) else {
    throw NSError(domain: "LyricServiceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: LyricServiceProbe --output /path/to/observations.json"])
}
try await runProbe(output: URL(fileURLWithPath: arguments[option + 1]))
