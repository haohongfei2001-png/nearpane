import Foundation
import LyricCore

public enum LyricResolution: Sendable {
    case document(LyricDomain.Document)
    case candidates([LyricDomain.Candidate])
    case notFound
}

public enum LyricRepositoryError: Error, LocalizedError, Sendable {
    case storageUnavailable, corruptIndex, corruptDocument, invalidAdjustment
    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "歌词存储暂时不可用。"
        case .corruptIndex: "歌词索引无法读取，原始绑定文件仍已保留。"
        case .corruptDocument: "已保存的歌词文件无法读取。"
        case .invalidAdjustment: "歌词校准必须在提前或延后 10 秒以内。"
        }
    }
}

public struct LyricCachePolicy: Sendable {
    public let maximumBytes: Int
    public let maximumEntries: Int
    public let maximumAgeSeconds: TimeInterval
    public init(maximumBytes: Int = 64 * 1024 * 1024, maximumEntries: Int = 256,
                maximumAgeSeconds: TimeInterval = 7 * 24 * 60 * 60) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.maximumAgeSeconds = max(0, maximumAgeSeconds)
    }
}

/// Private local storage and bounded automatic cache. All file I/O runs on this actor, not MainActor.
/// Release optimization does not change access: onlineEnabled is the user's explicit preference.
public actor LyricRepository {
    private let storageURL: URL
    private let provider: LRCLIBProvider
    private let policy: LyricCachePolicy
    private let parser = LyricParser()
    private let matcher = LyricMatcher()
    private var onlineEnabled: Bool
    private var loaded = false
    private var index = StoreIndex()
    private var active: SelectionKey?
    private var cacheEpoch: UInt64 = 0

    public init(storageURL: URL, onlineEnabled: Bool = true,
                provider: LRCLIBProvider = LRCLIBProvider(), cachePolicy: LyricCachePolicy = .init()) {
        self.storageURL = storageURL; self.onlineEnabled = onlineEnabled
        self.provider = provider; self.policy = cachePolicy
    }

    public func setOnlineEnabled(_ enabled: Bool) { onlineEnabled = enabled }

    public func resolve(_ selection: LyricDomain.Selection) async throws -> LyricResolution {
        try activate(selection)
        try loadIfNeeded()
        let fingerprint = selection.recording.fingerprint
        if let bound = index.bindings[fingerprint] {
            return .document(try readDocument(file: bound, protected: true, for: selection.recording))
        }
        if let cached = try cachedDocument(for: selection.recording) { return .document(cached) }
        guard onlineEnabled else { return .notFound }
        if let until = index.notFoundUntil[fingerprint], until > Date() { return .notFound }
        let descriptor = await provider.descriptor()
        try ensureNetworkCurrent(selection)
        guard descriptor.releaseDisposition != .disabled else { throw LyricDomain.SourceFailure.accessUnavailable }
        let request = LyricDomain.Request(requestID: UUID(), selection: selection)
        let epoch = cacheEpoch
        var exactAlternative: LyricDomain.Candidate?
        if let exact = try await provider.exact(request) {
            try ensureNetworkCurrent(selection)
            if matcher.mayAutomaticallyAccept(exact.evidence) {
                return .document(try await fetchAndCache(exact, epoch: epoch))
            }
            exactAlternative = exact
        }
        try ensureNetworkCurrent(selection)
        var candidates = try await provider.search(request)
        try ensureNetworkCurrent(selection)
        if let exactAlternative, !candidates.contains(where: { $0.providerRecordID == exactAlternative.providerRecordID }) {
            candidates.append(exactAlternative)
        }
        let accepted = candidates.filter { matcher.mayAutomaticallyAccept($0.evidence) }
        if accepted.count == 1 { return .document(try await fetchAndCache(accepted[0], epoch: epoch)) }
        if !candidates.isEmpty { return .candidates(candidates) }
        index.notFoundUntil[fingerprint] = Date().addingTimeInterval(5 * 60)
        pruneNegativeEntries()
        try saveIndex()
        return .notFound
    }

    /// An explicit "choose version" action bypasses bindings and positive/negative cache preference.
    public func searchCandidates(for selection: LyricDomain.Selection) async throws -> [LyricDomain.Candidate] {
        try activate(selection)
        guard onlineEnabled else { throw LyricDomain.SourceFailure.accessUnavailable }
        let descriptor = await provider.descriptor()
        try ensureNetworkCurrent(selection)
        guard descriptor.releaseDisposition != .disabled else { throw LyricDomain.SourceFailure.accessUnavailable }
        let candidates = try await provider.search(.init(requestID: UUID(), selection: selection))
        try ensureNetworkCurrent(selection)
        return candidates
    }

    public func fetch(_ candidate: LyricDomain.Candidate) async throws -> LyricDomain.Document {
        try ensureCurrent(candidate.request.selection)
        guard onlineEnabled else { throw LyricDomain.SourceFailure.accessUnavailable }
        return try await fetchAndCache(candidate, epoch: cacheEpoch)
    }

    public func importLyrics(_ data: Data, format: LyricDomain.Format,
                             for selection: LyricDomain.Selection) async throws -> LyricDomain.Document {
        try activate(selection)
        try loadIfNeeded()
        let rights = LyricDomain.RightsEvidence(apiAccess: .localFile, apiEvidenceURL: nil,
            contentRights: .userProvidedUnverified, contentEvidenceURL: nil, reviewedAt: Date(),
            evidenceRevision: nil, territories: [], expiry: nil, cacheMaxAgeSeconds: nil, attributionText: "本地歌词")
        let source = LyricDomain.SourceProvenance(providerID: "local", providerRecordID: nil, sourceURL: nil,
            fetchedAt: Date(), revisionOrETag: nil, contributorCredit: nil, rights: rights)
        let document = try parser.parse(data, format: format, recording: selection.recording, source: source)
        try ensureCurrent(selection)
        try storeBinding(document, raw: .init(format: format, bytes: data), for: selection.recording)
        return document
    }

    public func bind(_ document: LyricDomain.Document, to recording: LyricDomain.RecordingIdentity) async throws {
        try loadIfNeeded()
        let raw = await provider.rawPayload(contentHash: document.contentHash)
        try Task.checkCancellation()
        try storeBinding(document, raw: raw, for: recording)
    }

    public func adjustment(for recording: LyricDomain.RecordingIdentity,
                           document: LyricDomain.Document) async -> LyricDomain.UserTimingAdjustment? {
        do { try loadIfNeeded() } catch { return nil }
        guard let value = index.adjustments[adjustmentKey(recording, document)] else { return nil }
        return .init(recordingFingerprint: recording.fingerprint, documentContentHash: document.contentHash,
                     userAdvanceMS: value)
    }

    public func setAdvance(_ milliseconds: Int64, for recording: LyricDomain.RecordingIdentity,
                           document: LyricDomain.Document) async throws {
        guard (-10_000...10_000).contains(milliseconds) else { throw LyricRepositoryError.invalidAdjustment }
        try loadIfNeeded()
        index.adjustments[adjustmentKey(recording, document)] = milliseconds
        try saveIndex()
    }

    /// Only automatic artifacts are removed. User imports/bindings and their offsets are protected.
    public func clearCache() async throws {
        try loadIfNeeded()
        cacheEpoch &+= 1
        do {
            if FileManager.default.fileExists(atPath: automaticURL.path) { try FileManager.default.removeItem(at: automaticURL) }
            try createPrivateDirectory(automaticURL)
        } catch { throw LyricRepositoryError.storageUnavailable }
        index.automatic.removeAll(); index.notFoundUntil.removeAll()
        try saveIndex()
        await provider.clearMemoryCache()
    }

    public func sourceDescriptor() async -> LyricDomain.ProviderDescriptor { await provider.descriptor() }

    private func fetchAndCache(_ candidate: LyricDomain.Candidate, epoch: UInt64) async throws -> LyricDomain.Document {
        let selection = candidate.request.selection
        try ensureNetworkCurrent(selection)
        let document = try await provider.fetch(candidate)
        try ensureNetworkCurrent(selection)
        let raw = await provider.rawPayload(contentHash: document.contentHash)
        try ensureNetworkCurrent(selection)
        if epoch == cacheEpoch {
            try loadIfNeeded()
            try storeAutomatic(document, raw: raw)
        }
        return document
    }

    private func activate(_ selection: LyricDomain.Selection) throws {
        try Task.checkCancellation()
        let key = SelectionKey(selection)
        if let active, active.bundleID == key.bundleID, active.sessionID == key.sessionID,
           key.generation < active.generation { throw LyricDomain.SourceFailure.staleGeneration }
        active = key
    }
    private func ensureCurrent(_ selection: LyricDomain.Selection) throws {
        try Task.checkCancellation()
        guard active == SelectionKey(selection) else { throw LyricDomain.SourceFailure.staleGeneration }
    }
    private func ensureNetworkCurrent(_ selection: LyricDomain.Selection) throws {
        try ensureCurrent(selection)
        guard onlineEnabled else { throw CancellationError() }
    }
    private struct SelectionKey: Equatable {
        let bundleID: String; let sessionID: UUID; let generation: UInt64
        init(_ selection: LyricDomain.Selection) {
            bundleID = selection.playerBundleID; sessionID = selection.sessionID; generation = selection.generation
        }
    }

    private var automaticURL: URL { storageURL.appendingPathComponent("Automatic", isDirectory: true) }
    private var protectedURL: URL { storageURL.appendingPathComponent("Bindings", isDirectory: true) }
    private var indexURL: URL { storageURL.appendingPathComponent("index-v1.json") }
    private let maximumDocumentBytes = 32 * 1024 * 1024
    private let maximumIndexBytes = 4 * 1024 * 1024

    private struct CacheEntry: Codable {
        let file: String
        let bytes: Int
        var accessedAt: Date
        let expiresAt: Date
    }
    private struct StoreIndex: Codable {
        var version = 1
        var automatic: [String: CacheEntry] = [:]
        var bindings: [String: String] = [:]
        var adjustments: [String: Int64] = [:]
        var notFoundUntil: [String: Date] = [:]
    }
    private struct Envelope: Codable {
        let document: LyricDomain.Document
        let raw: RawLyricPayload?
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        do {
            try createPrivateDirectory(storageURL)
            try createPrivateDirectory(automaticURL)
            try createPrivateDirectory(protectedURL)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let bytes = try boundedRead(indexURL, maximum: maximumIndexBytes)
                let saved: StoreIndex
                do { saved = try JSONDecoder().decode(StoreIndex.self, from: bytes) }
                catch { throw LyricRepositoryError.corruptIndex }
                guard saved.version == 1, saved.automatic.count <= 10_000, saved.bindings.count <= 10_000,
                      saved.adjustments.count <= 20_000, saved.notFoundUntil.count <= 10_000,
                      saved.automatic.values.allSatisfy({ $0.bytes >= 0 && $0.bytes <= maximumDocumentBytes }) else {
                    throw LyricRepositoryError.corruptIndex
                }
                index = saved
            }
            loaded = true
            try evictAutomatic()
            // A crash between writing a document and its index must not leak unbounded cache files.
            let referenced = Set(index.automatic.values.map(\.file))
            for file in try FileManager.default.contentsOfDirectory(at: automaticURL, includingPropertiesForKeys: nil) {
                if !referenced.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            }
        } catch let error as LyricRepositoryError { throw error }
        catch { throw LyricRepositoryError.storageUnavailable }
    }
    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= Int64(maximum) else { throw LyricRepositoryError.corruptDocument }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximum else { throw LyricRepositoryError.corruptDocument }
        return bytes
    }
    private func saveIndex() throws {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(index)
            guard data.count <= maximumIndexBytes else { throw LyricRepositoryError.storageUnavailable }
            try data.write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch { throw LyricRepositoryError.storageUnavailable }
    }
    private func filename(_ document: LyricDomain.Document) -> String {
        ContentDigest.sha256("\(document.source.providerID)|\(document.source.providerRecordID ?? "local")|\(document.recording.fingerprint)|\(document.contentHash)|\(document.schemaVersion)") + ".json"
    }
    private func safeURL(file: String, protected: Bool) throws -> URL {
        guard file.count == 69, file.hasSuffix(".json"), file.dropLast(5).allSatisfy(\.isHexDigit) else {
            throw LyricRepositoryError.corruptDocument
        }
        return (protected ? protectedURL : automaticURL).appendingPathComponent(file)
    }
    private func writeEnvelope(_ document: LyricDomain.Document, raw: RawLyricPayload?, protected: Bool) throws -> (String, Int) {
        let file = filename(document)
        do {
            let data = try JSONEncoder().encode(Envelope(document: document, raw: raw))
            guard data.count <= maximumDocumentBytes else { throw LyricRepositoryError.storageUnavailable }
            try data.write(to: safeURL(file: file, protected: protected), options: .atomic)
            return (file, data.count)
        } catch { throw LyricRepositoryError.storageUnavailable }
    }
    private func readDocument(file: String, protected: Bool,
                              for recording: LyricDomain.RecordingIdentity) throws -> LyricDomain.Document {
        do {
            let bytes = try boundedRead(safeURL(file: file, protected: protected), maximum: maximumDocumentBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            let document = envelope.document
            guard document.schemaVersion == 1, document.recording.fingerprint == recording.fingerprint else {
                throw LyricRepositoryError.corruptDocument
            }
            if let raw = envelope.raw, ContentDigest.sha256(raw.bytes) != document.contentHash {
                throw LyricRepositoryError.corruptDocument
            }
            try ParsedLyrics(lanes: document.lanes, timing: document.sourceTiming, instrumental: document.instrumental).validate()
            return rebind(document, to: recording)
        } catch { throw LyricRepositoryError.corruptDocument }
    }
    private func rebind(_ document: LyricDomain.Document, to recording: LyricDomain.RecordingIdentity) -> LyricDomain.Document {
        .init(id: document.id, schemaVersion: document.schemaVersion, contentHash: document.contentHash,
            recording: recording, source: document.source, originalFormat: document.originalFormat,
            timingLevel: document.timingLevel, sourceTiming: document.sourceTiming,
            lanes: document.lanes, instrumental: document.instrumental)
    }
    private func cachedDocument(for recording: LyricDomain.RecordingIdentity) throws -> LyricDomain.Document? {
        guard var entry = index.automatic[recording.fingerprint] else { return nil }
        guard entry.expiresAt > Date() else {
            index.automatic.removeValue(forKey: recording.fingerprint)
            try? FileManager.default.removeItem(at: safeURL(file: entry.file, protected: false))
            try saveIndex(); return nil
        }
        do {
            let document = try readDocument(file: entry.file, protected: false, for: recording)
            entry.accessedAt = Date(); index.automatic[recording.fingerprint] = entry
            try saveIndex()
            return document
        } catch {
            index.automatic.removeValue(forKey: recording.fingerprint)
            try? FileManager.default.removeItem(at: safeURL(file: entry.file, protected: false))
            try saveIndex(); return nil
        }
    }
    private func storeAutomatic(_ document: LyricDomain.Document, raw: RawLyricPayload?) throws {
        let rights = document.source.rights
        var lifetime = policy.maximumAgeSeconds
        if let permittedAge = rights.cacheMaxAgeSeconds { lifetime = min(lifetime, Double(max(0, permittedAge))) }
        if let expiry = rights.expiry { lifetime = min(lifetime, max(0, expiry.timeIntervalSinceNow)) }
        guard lifetime > 0, policy.maximumEntries > 0, policy.maximumBytes > 0 else { return }
        let old = index.automatic[document.recording.fingerprint]
        let (file, bytes) = try writeEnvelope(document, raw: raw, protected: false)
        index.automatic[document.recording.fingerprint] = .init(file: file, bytes: bytes, accessedAt: Date(),
                                                               expiresAt: Date().addingTimeInterval(lifetime))
        if let old, old.file != file { try? FileManager.default.removeItem(at: safeURL(file: old.file, protected: false)) }
        index.notFoundUntil.removeValue(forKey: document.recording.fingerprint)
        try evictAutomatic()
        try saveIndex()
    }
    private func storeBinding(_ document: LyricDomain.Document, raw: RawLyricPayload?,
                              for recording: LyricDomain.RecordingIdentity) throws {
        let rebound = rebind(document, to: recording)
        let (file, _) = try writeEnvelope(rebound, raw: raw, protected: true)
        index.bindings[recording.fingerprint] = file
        index.notFoundUntil.removeValue(forKey: recording.fingerprint)
        try saveIndex()
    }
    private func evictAutomatic() throws {
        let now = Date()
        let ordered = index.automatic.sorted { $0.value.accessedAt < $1.value.accessedAt }
        var total = index.automatic.values.reduce(0) { $0 + max(0, $1.bytes) }
        for (key, entry) in ordered {
            if entry.expiresAt <= now || index.automatic.count > policy.maximumEntries || total > policy.maximumBytes {
                try? FileManager.default.removeItem(at: safeURL(file: entry.file, protected: false))
                index.automatic.removeValue(forKey: key)
                total -= max(0, entry.bytes)
            }
        }
    }
    private func pruneNegativeEntries() {
        index.notFoundUntil = index.notFoundUntil.filter { $0.value > Date() }
        if index.notFoundUntil.count > 256 {
            let sorted = index.notFoundUntil.sorted { $0.value > $1.value }
            index.notFoundUntil = Dictionary(uniqueKeysWithValues: sorted.prefix(256).map { ($0.key, $0.value) })
        }
    }
    private func adjustmentKey(_ recording: LyricDomain.RecordingIdentity, _ document: LyricDomain.Document) -> String {
        ContentDigest.sha256(recording.fingerprint + "|" + document.contentHash)
    }
}
