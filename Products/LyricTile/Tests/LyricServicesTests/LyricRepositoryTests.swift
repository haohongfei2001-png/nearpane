import Foundation
import Testing
import LyricCore
@testable import LyricServices

@Suite("Provider and local ownership boundaries")
struct LyricRepositoryTests {
    @Test func providerIdentifiesClientAndFallsBackFromInvalidDraftToActualLRC() async throws {
        let transport = QueueTransport([ServiceFixture.response(try ServiceFixture.record(lyricsfile: "version: '99.0'", lrc: "[00:01.25]真实时码"))])
        let provider = LRCLIBProvider(configuration: .init(publicAppID: "public-test-id", minimumRequestIntervalMS: 0), transport: transport)
        let found = try await provider.exact(.init(requestID: UUID(), selection: ServiceFixture.selection()))
        let candidate = try #require(found)
        let document = try await provider.fetch(candidate)
        #expect(document.originalFormat == .lrc)
        #expect(document.lanes[0].cues[0].sourceStartMS == 1_250)
        #expect(document.source.rights.contentRights == .unresolved)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent")?.contains("LyricTile") == true)
        #expect(requests[0].value(forHTTPHeaderField: "Lrclib-App-Id") == "public-test-id")
        #expect(requests[0].value(forHTTPHeaderField: "Lrclib-Api-Key") == nil)
    }

    @Test func rateLimitIsNotNegativeCachedAndRetryAfterIsEnforcedBeforeNextRequest() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = QueueTransport([.init(status: 429, headers: ["Retry-After": "60"], body: Data("edge rate limit".utf8))])
        let provider = LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport)
        let repository = LyricRepository(storageURL: location, provider: provider)
        for _ in 0..<2 {
            do {
                _ = try await repository.resolve(ServiceFixture.selection())
                Issue.record("A rate-limited request must fail explicitly.")
            } catch let error as LyricDomain.SourceFailure {
                if case let .rateLimited(seconds) = error { #expect(seconds >= 59) }
                else { Issue.record("Expected rate-limit error, got \(error)") }
            }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func trueEmptySearchCanBeNegativeCachedAndDoesNotMeanInstrumental() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = QueueTransport([.init(status: 404), ServiceFixture.response(Data("[]".utf8))])
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        for _ in 0..<2 {
            let result = try await repository.resolve(ServiceFixture.selection())
            guard case .notFound = result else { Issue.record("404 is absence, not instrumental."); return }
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func importsBindingsAndVersionSpecificOffsetsSurviveClearAndRestart() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let selection = ServiceFixture.selection()
        let repository = LyricRepository(storageURL: location, onlineEnabled: false)
        let document = try await repository.importLyrics(Data("[00:01]原创绑定歌词".utf8), format: .lrc, for: selection)
        try await repository.setAdvance(300, for: selection.recording, document: document)
        try await repository.clearCache()
        let restarted = LyricRepository(storageURL: location, onlineEnabled: false)
        let result = try await restarted.resolve(selection)
        guard case let .document(restored) = result else { Issue.record("The user binding was lost."); return }
        #expect(restored.contentHash == document.contentHash)
        #expect(await restarted.adjustment(for: selection.recording, document: restored)?.userAdvanceMS == 300)
        let anotherVersion = try ServiceFixture.parse("[00:02]不同的原创版本", .lrc)
        #expect(await restarted.adjustment(for: selection.recording, document: anotherVersion) == nil)
    }

    @Test func explicitVersionSearchBypassesExistingLocalBinding() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let record = try ServiceFixture.record()
        let transport = QueueTransport([ServiceFixture.response(Data([UInt8(91)] + Array(record) + [UInt8(93)]))])
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        _ = try await repository.importLyrics(Data("[00:01]本地绑定".utf8), format: .lrc, for: ServiceFixture.selection())
        let candidates = try await repository.searchCandidates(for: ServiceFixture.selection())
        #expect(candidates.count == 1)
        #expect(await transport.requests.count == 1)
    }

    @Test func aLateNetworkResponseCannotReplaceANewerRecording() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = SuspendedTransport(response: ServiceFixture.response(try ServiceFixture.record()))
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        let oldTask = Task { try await repository.resolve(ServiceFixture.selection()) }
        await transport.waitUntilRequested()
        let newer = ServiceFixture.selection(2, fingerprint: "new-recording", title: "New recording")
        _ = try await repository.importLyrics(Data("[00:00]新的原创歌词".utf8), format: .lrc, for: newer)
        await transport.finish()
        do {
            _ = try await oldTask.value
            Issue.record("Old generation should not publish.")
        } catch let error as LyricDomain.SourceFailure {
            guard case .staleGeneration = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        let current = try await repository.resolve(newer)
        guard case let .document(document) = current else { Issue.record("New binding missing."); return }
        #expect(document.recording.fingerprint == "new-recording")
    }

    @Test func aLocalImportSupersedesAnInFlightLookupForTheSameRecording() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = SuspendedTransport(response: ServiceFixture.response(try ServiceFixture.record()))
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        let selection = ServiceFixture.selection()
        let lookup = Task { try await repository.resolve(selection) }
        await transport.waitUntilRequested()
        let imported = try await repository.importLyrics(Data("[00:02]用户选择的原创歌词".utf8),
                                                          format: .lrc, for: selection)
        await transport.finish()
        do {
            _ = try await lookup.value
            Issue.record("An earlier lookup must not replace the user's import.")
        } catch let error as LyricDomain.SourceFailure {
            guard case .staleGeneration = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        let result = try await repository.resolve(selection)
        guard case let .document(current) = result else { Issue.record("The local binding is missing."); return }
        #expect(current.contentHash == imported.contentHash)
        let automatic = try FileManager.default.contentsOfDirectory(at: location.appendingPathComponent("Automatic"),
                                                                     includingPropertiesForKeys: nil)
        #expect(automatic.isEmpty)
    }

    @Test func reEnablingOnlineLookupDoesNotReviveAnEarlierRequest() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = SuspendedTransport([
            ServiceFixture.response(try ServiceFixture.record(lrc: "[00:01]旧请求的原创歌词")),
            ServiceFixture.response(try ServiceFixture.record(lrc: "[00:02]新请求的原创歌词"))
        ])
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        let selection = ServiceFixture.selection()
        let lookup = Task { try await repository.resolve(selection) }
        await transport.waitUntilRequested()
        await repository.setOnlineEnabled(false)
        await repository.setOnlineEnabled(true)
        await transport.finish()
        do {
            _ = try await lookup.value
            Issue.record("An offline transition must invalidate work even after lookup is re-enabled.")
        } catch is CancellationError { }
        let result = try await repository.resolve(selection)
        guard case let .document(document) = result else { Issue.record("A new online lookup should recover."); return }
        #expect(document.lanes[0].cues[0].text == "新请求的原创歌词")
        #expect(await transport.requests.count == 2)
    }

    @Test func cacheClearPreventsALateEmptySearchFromRecreatingNegativeCache() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = SuspendedTransport([
            .init(status: 404), ServiceFixture.response(Data("[]".utf8)),
            ServiceFixture.response(try ServiceFixture.record())
        ], suspendAt: 1)
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        let selection = ServiceFixture.selection()
        let lookup = Task { try await repository.resolve(selection) }
        await transport.waitUntilRequested()
        try await repository.clearCache()
        await transport.finish()
        let oldResult = try await lookup.value
        guard case .notFound = oldResult else { Issue.record("Expected the original empty search result."); return }
        let refreshed = try await repository.resolve(selection)
        guard case .document = refreshed else { Issue.record("The cleared miss was incorrectly restored."); return }
        #expect(await transport.requests.count == 3)
    }

    @Test func boundedAutomaticEvictionDoesNotEvictProtectedBinding() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = QueueTransport([
            ServiceFixture.response(try ServiceFixture.record(id: 1)),
            ServiceFixture.response(try ServiceFixture.record(id: 2, title: "Second original"))
        ])
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport),
            cachePolicy: .init(maximumBytes: 64 * 1024, maximumEntries: 1))
        let first = ServiceFixture.selection()
        let result = try await repository.resolve(first)
        guard case let .document(document) = result else { Issue.record("Expected real mocked-provider result."); return }
        try await repository.bind(document, to: first.recording)
        let second = ServiceFixture.selection(2, fingerprint: "second", title: "Second original")
        _ = try await repository.resolve(second)
        let automaticFiles = try FileManager.default.contentsOfDirectory(at: location.appendingPathComponent("Automatic"), includingPropertiesForKeys: nil)
        #expect(automaticFiles.count == 1)
        let restarted = LyricRepository(storageURL: location, onlineEnabled: false)
        let restored = try await restarted.resolve(first)
        guard case let .document(value) = restored else { Issue.record("Protected binding was evicted."); return }
        #expect(value.contentHash == document.contentHash)
    }

    @Test func offlinePreferenceMakesNoRequests() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = QueueTransport([])
        let repository = LyricRepository(storageURL: location, onlineEnabled: false,
                                         provider: LRCLIBProvider(transport: transport))
        _ = try await repository.resolve(ServiceFixture.selection())
        #expect(await transport.requests.isEmpty)
    }

    @Test func lateMetadataDoesNotInheritAnEarlierNegativeQueryCache() async throws {
        let location = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: location) }
        let transport = QueueTransport([.init(status: 404), ServiceFixture.response(Data("[]".utf8)),
                                        ServiceFixture.response(try ServiceFixture.record())])
        let repository = LyricRepository(storageURL: location,
            provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
        let complete = ServiceFixture.selection()
        let partialIdentity = LyricDomain.RecordingIdentity(fingerprint: complete.recording.fingerprint,
            platformIDs: [], isrc: nil, title: complete.recording.title, artists: complete.recording.artists,
            album: nil, durationMS: nil, versionTags: [])
        let partial = LyricDomain.Selection(playerBundleID: complete.playerBundleID, sessionID: complete.sessionID,
                                            generation: complete.generation, recording: partialIdentity)
        let first = try await repository.resolve(partial)
        guard case .notFound = first else { Issue.record("Expected an initial unmatched query."); return }
        let second = try await repository.resolve(complete)
        guard case .document = second else { Issue.record("Late metadata was incorrectly negative-cached."); return }
        #expect(await transport.requests.count == 3)
    }

    @Test func reentrantProviderCallsStaySequential() async throws {
        let transport = ConcurrentTrackingTransport()
        let provider = LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try await provider.search(.init(requestID: UUID(), selection: ServiceFixture.selection()))
                }
            }
            try await group.waitForAll()
        }
        #expect(await transport.maximumActive == 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LyricTileTest-" + UUID().uuidString, isDirectory: true)
    }
}

private actor QueueTransport: LyricsHTTPTransport {
    private var responses: [LyricsHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [LyricsHTTPResponse]) { self.responses = responses }
    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LyricDomain.SourceFailure.transportUnavailable }
        return responses.removeFirst()
    }
}

private actor SuspendedTransport: LyricsHTTPTransport {
    private var responses: [LyricsHTTPResponse]
    private let suspendAt: Int
    private(set) var requests: [URLRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    init(response: LyricsHTTPResponse) { responses = [response]; suspendAt = 0 }
    init(_ responses: [LyricsHTTPResponse], suspendAt: Int = 0) {
        self.responses = responses; self.suspendAt = suspendAt
    }
    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        let index = requests.count
        requests.append(request)
        guard !responses.isEmpty else { throw LyricDomain.SourceFailure.transportUnavailable }
        let response = responses.removeFirst()
        if index == suspendAt {
            await withCheckedContinuation { continuation in
                pending = continuation; started = true
                startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
            }
        }
        return response
    }
    func waitUntilRequested() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func finish() { pending?.resume(); pending = nil }
}

private actor ConcurrentTrackingTransport: LyricsHTTPTransport {
    private var active = 0
    private(set) var maximumActive = 0
    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
        return ServiceFixture.response(Data("[]".utf8))
    }
}

