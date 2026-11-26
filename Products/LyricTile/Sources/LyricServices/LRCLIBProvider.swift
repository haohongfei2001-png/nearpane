import Foundation
import LyricCore

public struct LRCLIBConfiguration: Sendable {
    public var userAgent: String
    public var publicAppID: String?
    public var rights: LyricDomain.RightsEvidence
    public var releaseDisposition: LyricDomain.ProviderReleaseDisposition
    public var minimumRequestIntervalMS: Int64
    public init(userAgent: String = "LyricTile/1.0 (https://github.com/haohongfei2001-png/nearpane)",
                publicAppID: String? = nil, rights: LyricDomain.RightsEvidence? = nil,
                releaseDisposition: LyricDomain.ProviderReleaseDisposition = .internalResearch,
                minimumRequestIntervalMS: Int64 = 350) {
        self.userAgent = userAgent; self.publicAppID = publicAppID
        self.rights = rights ?? .init(apiAccess: .publishedTerms,
            apiEvidenceURL: URL(string: "https://lrclib.net/docs.txt"), contentRights: .unresolved,
            contentEvidenceURL: nil, reviewedAt: Date(timeIntervalSince1970: 1_795_651_200), evidenceRevision: "docs-2026-11-26",
            territories: [], expiry: nil, cacheMaxAgeSeconds: nil, attributionText: "Lyrics via LRCLIB")
        self.releaseDisposition = releaseDisposition
        self.minimumRequestIntervalMS = max(0, minimumRequestIntervalMS)
    }
}

public struct RawLyricPayload: Sendable, Codable {
    public let format: LyricDomain.Format
    public let bytes: Data
    public init(format: LyricDomain.Format, bytes: Data) { self.format = format; self.bytes = bytes }
}

public actor LRCLIBProvider: LyricSourceProviding {
    private let configuration: LRCLIBConfiguration
    private let transport: any LyricsHTTPTransport
    private let gate = LyricsRequestGate()
    private let parser = LyricParser()
    private let matcher = LyricMatcher()
    private var nextRequestUptime: TimeInterval = 0
    private var blockedUntilUptime: TimeInterval = 0
    private var recordCache: [Int64: Record] = [:]
    private var recordOrder: [Int64] = []
    private var payloads: [String: RawLyricPayload] = [:]
    private var payloadOrder: [String] = []

    public init(configuration: LRCLIBConfiguration = .init(),
                transport: any LyricsHTTPTransport = URLSessionLyricsTransport()) {
        self.configuration = configuration; self.transport = transport
    }

    public func descriptor() -> LyricDomain.ProviderDescriptor {
        .init(providerID: "lrclib", displayName: "LRCLIB", codeLicenseSPDX: nil,
              rights: configuration.rights, releaseDisposition: configuration.releaseDisposition)
    }

    public func exact(_ request: LyricDomain.Request) async throws -> LyricDomain.Candidate? {
        let recording = request.selection.recording
        if let platformID = recording.platformIDs.first(where: { $0.namespace == "lrclib" }),
           let id = Int64(platformID.value), id > 0 {
            do {
                let data = try await perform(path: "/api/get/\(id)", query: [])
                let record = try decodeRecord(data)
                guard record.id == id else { throw invalid("The lyric service returned a different record.") }
                remember(record)
                return candidate(record, request: request)
            } catch LyricDomain.SourceFailure.notFound { /* Continue with full metadata. */ }
        }
        guard let title = recording.title, !title.isEmpty, let artist = recording.artists.first, !artist.isEmpty else { return nil }
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album = recording.album, !album.isEmpty { items.append(.init(name: "album_name", value: album)) }
        if let duration = recording.durationMS, duration >= 1_000, duration <= 3_600_000 {
            items.append(.init(name: "duration", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(duration) / 1_000)))
        }
        do {
            let data = try await perform(path: "/api/get", query: items)
            let record = try decodeRecord(data)
            remember(record)
            return candidate(record, request: request)
        } catch LyricDomain.SourceFailure.notFound { return nil }
    }

    public func search(_ request: LyricDomain.Request) async throws -> [LyricDomain.Candidate] {
        let recording = request.selection.recording
        guard let title = recording.title, !title.isEmpty else { return [] }
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist = recording.artists.first, !artist.isEmpty { items.append(.init(name: "artist_name", value: artist)) }
        let data = try await perform(path: "/api/search", query: items)
        let records: [Record]
        do { records = try JSONDecoder().decode([Record].self, from: data) }
        catch { throw invalid("The lyric service returned invalid search data.") }
        return records.prefix(40).map { record in
            remember(record)
            return candidate(record, request: request)
        }.sorted { rank($0) > rank($1) }
    }

    public func fetch(_ candidate: LyricDomain.Candidate) async throws -> LyricDomain.Document {
        try Task.checkCancellation()
        guard candidate.providerID == "lrclib", let id = Int64(candidate.providerRecordID), id > 0 else {
            throw LyricDomain.SourceFailure.accessUnavailable
        }
        let record: Record
        if let cached = recordCache[id] { record = cached }
        else {
            let data = try await perform(path: "/api/get/\(id)", query: [])
            record = try decodeRecord(data)
        }
        guard record.id == id else { throw invalid("The lyric service returned a different record.") }
        remember(record)
        let source = LyricDomain.SourceProvenance(providerID: "lrclib", providerRecordID: String(id),
            sourceURL: URL(string: "https://lrclib.net/api/get/\(id)"), fetchedAt: Date(), revisionOrETag: nil,
            contributorCredit: nil, rights: configuration.rights)
        let target = candidate.request.selection.recording
        if record.instrumental {
            let raw = Data("lrclib:\(id):instrumental".utf8)
            return .init(id: UUID(), schemaVersion: 1, contentHash: ContentDigest.sha256(raw),
                recording: target, source: source, originalFormat: .lyricsfileV1Draft, timingLevel: .none,
                sourceTiming: .init(sourceAdvanceMS: 0, interpretation: .absent, rawOffset: nil), lanes: [], instrumental: true)
        }
        let formats: [(String?, LyricDomain.Format)] = [
            (record.lyricsfile, .lyricsfileV1Draft), (record.syncedLyrics, .lrc), (record.plainLyrics, .plainText)
        ]
        var lastFailure: (any Error)?
        for (text, format) in formats {
            guard let text, !text.isEmpty else { continue }
            try Task.checkCancellation()
            let bytes = Data(text.utf8)
            do {
                let document = try parser.parse(bytes, format: format, recording: target, source: source)
                remember(payload: .init(format: format, bytes: bytes), hash: document.contentHash)
                return document
            } catch { lastFailure = error }
        }
        if let lastFailure { throw lastFailure }
        throw LyricDomain.SourceFailure.notFound
    }

    public func rawPayload(contentHash: String) -> RawLyricPayload? { payloads[contentHash] }

    public func clearMemoryCache() {
        recordCache.removeAll(); recordOrder.removeAll()
        payloads.removeAll(); payloadOrder.removeAll()
    }

    private func perform(path: String, query: [URLQueryItem]) async throws -> Data {
        try await gate.acquire()
        do {
            let result = try await performSerial(path: path, query: query)
            await gate.release()
            return result
        } catch {
            await gate.release()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    private func performSerial(path: String, query: [URLQueryItem]) async throws -> Data {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if blockedUntilUptime > now {
            throw LyricDomain.SourceFailure.rateLimited(retryAfterSeconds: secondsRemaining(blockedUntilUptime - now))
        }
        if nextRequestUptime > now {
            try await Task.sleep(for: .seconds(nextRequestUptime - now))
        }
        var components = URLComponents()
        components.scheme = "https"; components.host = "lrclib.net"; components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, !configuration.userAgent.isEmpty else {
            throw LyricDomain.SourceFailure.accessUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 12
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appID = configuration.publicAppID { request.setValue(appID, forHTTPHeaderField: "Lrclib-App-Id") }
        let response: LyricsHTTPResponse
        do { response = try await transport.get(request) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw LyricDomain.SourceFailure.transportUnavailable
        }
        nextRequestUptime = ProcessInfo.processInfo.systemUptime + Double(configuration.minimumRequestIntervalMS) / 1_000
        if response.status == 429 || response.status == 503 {
            let retry = retryDelay(response.headers["retry-after"])
            let jitter = min(30, retry * Double.random(in: 0...0.3))
            blockedUntilUptime = ProcessInfo.processInfo.systemUptime + retry + jitter
            if response.status == 429 {
                throw LyricDomain.SourceFailure.rateLimited(retryAfterSeconds: secondsRemaining(retry + jitter))
            }
            throw LyricDomain.SourceFailure.transportUnavailable
        }
        if response.status == 404 { throw LyricDomain.SourceFailure.notFound }
        if response.status == 401 || response.status == 403 { throw LyricDomain.SourceFailure.accessUnavailable }
        guard response.status == 200 else { throw LyricDomain.SourceFailure.transportUnavailable }
        guard response.body.count <= 8 * 1024 * 1024,
              response.headers["content-type"]?.lowercased().contains("json") == true else {
            throw invalid("The lyric service did not return bounded JSON data.")
        }
        return response.body
    }
    private func retryDelay(_ raw: String?) -> Double {
        guard let raw else { return 60 }
        if let numeric = Double(raw), numeric.isFinite, numeric >= 0 { return max(1, numeric) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(1, date.timeIntervalSinceNow) }
        return 60
    }
    private func secondsRemaining(_ value: Double) -> Int64 {
        value >= Double(Int64.max) ? Int64.max : max(1, Int64(value.rounded(.up)))
    }
    private func decodeRecord(_ data: Data) throws -> Record {
        do { return try JSONDecoder().decode(Record.self, from: data) }
        catch { throw invalid("The lyric service returned an invalid record.") }
    }
    private func candidate(_ record: Record, request: LyricDomain.Request) -> LyricDomain.Candidate {
        let identity = record.identity
        return .init(request: request, providerID: "lrclib", providerRecordID: String(record.id), recording: identity,
            evidence: matcher.evidence(for: identity, against: request.selection.recording),
            availableTiming: record.hasWordSync == true ? .token : (record.syncedLyrics?.isEmpty == false ? .line : .none))
    }
    private func rank(_ candidate: LyricDomain.Candidate) -> Double {
        let e = candidate.evidence
        return (matcher.mayAutomaticallyAccept(e) ? 100 : 0) + (e.titleSimilarity ?? 0) * 20
            + (e.mainArtistMatch == true ? 10 : 0) + (e.albumMatch == true ? 3 : 0)
            - (e.versionConflict || e.mainArtistConflict ? 100 : 0)
            - Double(min(e.durationDeltaMS ?? 60_000, 60_000)) / 1_000
    }
    private func remember(_ record: Record) {
        recordCache[record.id] = record
        recordOrder.removeAll { $0 == record.id }; recordOrder.append(record.id)
        while recordOrder.count > 32 || recordCache.values.reduce(0, { $0 + $1.payloadBytes }) > 8 * 1024 * 1024 {
            recordCache.removeValue(forKey: recordOrder.removeFirst())
        }
    }
    private func remember(payload: RawLyricPayload, hash: String) {
        payloads[hash] = payload
        payloadOrder.removeAll { $0 == hash }; payloadOrder.append(hash)
        while payloadOrder.count > 16 || payloads.values.reduce(0, { $0 + $1.bytes.count }) > 16 * 1024 * 1024 {
            payloads.removeValue(forKey: payloadOrder.removeFirst())
        }
    }

    private struct Record: Decodable, Sendable {
        let id: Int64
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let hasWordSync: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let lyricsfile: String?
        var payloadBytes: Int {
            (lyricsfile?.utf8.count ?? 0) + (syncedLyrics?.utf8.count ?? 0) + (plainLyrics?.utf8.count ?? 0)
        }
        var identity: LyricDomain.RecordingIdentity {
            let milliseconds: Int64? = duration.flatMap { seconds in
                guard seconds.isFinite, seconds >= 0, seconds * 1_000 < Double(Int64.max) else { return nil }
                return Int64((seconds * 1_000).rounded())
            }
            return .init(fingerprint: "lrclib:\(id)", platformIDs: [.init(namespace: "lrclib", value: String(id))],
                isrc: nil, title: trackName, artists: [artistName], album: albumName,
                durationMS: milliseconds, versionTags: [])
        }
    }
}
