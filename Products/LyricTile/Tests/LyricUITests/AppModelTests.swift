import Foundation
import LyricCore
import LyricPlayback
import LyricServices
import Testing
@testable import LyricUI

@Suite("UI lyric request ownership")
@MainActor
struct AppModelTests {
    @Test func localImportSurvivesLateAutomaticResolution() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let transport = DeferredUITransport(response: try fixture.response())
        let repository = fixture.repository(transport: transport)
        let model = LyricAppModel(repository: repository, defaults: fixture.defaults)
        model.receive(fixture.snapshot())
        let oldRequest = try #require(model.lyricTask)
        await transport.waitUntilRequested()

        model.importLyrics(from: try fixture.file("[00:01]Local authored replacement"), for: fixture.selection())
        let importedRequest = try #require(model.lyricTask)
        await importedRequest.value
        await transport.finish()
        await oldRequest.value

        #expect(oldRequest.isCancelled)
        #expect(model.document?.lanes.first?.cues.first?.text == "Local authored replacement")
        #expect(model.document?.source.providerID == "local")
        #expect(model.lyricFailure == nil)
        #expect(model.actionMessage == nil)
        #expect(!model.isResolving)
    }

    @Test func localImportInvalidatesAnOutstandingVersionSearch() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let transport = DeferredUITransport(response: try fixture.response(search: true))
        let repository = fixture.repository(transport: transport)
        _ = try await repository.importLyrics(Data("[00:01]Original local fixture".utf8), format: .lrc,
                                              for: fixture.selection())
        let model = LyricAppModel(repository: repository, defaults: fixture.defaults)
        model.receive(fixture.snapshot())
        let initial = try #require(model.lyricTask)
        await initial.value
        model.searchCandidates()
        let search = try #require(model.candidateTask)
        await transport.waitUntilRequested()

        model.importLyrics(from: try fixture.file("[00:02]User selected a different file"), for: fixture.selection())
        let imported = try #require(model.lyricTask)
        await imported.value
        await transport.finish()
        await search.value

        #expect(search.isCancelled)
        #expect(model.candidates.isEmpty)
        #expect(!model.isSearchingCandidates)
        #expect(model.actionMessage == nil)
        #expect(model.document?.lanes.first?.cues.first?.text == "User selected a different file")
    }

    @Test func failedTimingSaveCannotReportAnErrorOnTheNextRecording() async throws {
        let fixture = try ModelFixture(onlineEnabled: false)
        defer { fixture.remove() }
        let repository = LyricRepository(storageURL: fixture.directory, onlineEnabled: false)
        _ = try await repository.importLyrics(Data("[00:01]Timing adjustment fixture".utf8), format: .lrc,
                                              for: fixture.selection())
        let model = LyricAppModel(repository: repository, defaults: fixture.defaults)
        model.receive(fixture.snapshot())
        let initial = try #require(model.lyricTask)
        await initial.value

        // A directory at the index path forces an actual disk save failure after
        // the task starts. The player changes before its completion reaches UI.
        let index = fixture.directory.appendingPathComponent("index-v1.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        model.changeAdvance(to: 300)
        let oldAdjustment = try #require(model.adjustmentTask)
        #expect(model.isSavingAdjustment)
        model.receive(fixture.snapshot(generation: 2))

        #expect(!model.isSavingAdjustment)
        await oldAdjustment.value
        let current = try #require(model.lyricTask)
        await current.value
        #expect(oldAdjustment.isCancelled)
        #expect(model.snapshot.selection?.generation == 2)
        #expect(model.advanceMS == 0)
        #expect(model.actionMessage == nil)
        #expect(model.lyricFailure == nil)
    }
}

@MainActor
private struct ModelFixture {
    let directory: URL
    let defaults: UserDefaults
    let defaultsName: String
    let sessionID = UUID()

    init(onlineEnabled: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricUI-" + UUID().uuidString,
                                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "LyricUI.test." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        var settings = LyricSettings()
        settings.onlineLyrics = onlineEnabled
        settings.save(to: defaults)
    }
    func selection(generation: UInt64 = 1) -> LyricDomain.Selection {
        .init(playerBundleID: "test.ui.player", sessionID: sessionID, generation: generation,
              recording: .init(fingerprint: "ui-recording-\(generation)", platformIDs: [], isrc: nil,
                               title: "UI authored song", artists: ["UI authored artist"],
                               album: "UI authored album", durationMS: 60_000, versionTags: []))
    }
    func snapshot(generation: UInt64 = 1) -> PlaybackSnapshot {
        .init(player: .appleMusic, selection: selection(generation: generation), anchor: nil, state: .paused)
    }
    func file(_ text: String) throws -> URL {
        let url = directory.appendingPathComponent("authored-import.lrc")
        try Data(text.utf8).write(to: url)
        return url
    }
    func repository(transport: any LyricsHTTPTransport) -> LyricRepository {
        LyricRepository(storageURL: directory,
                        provider: LRCLIBProvider(configuration: .init(minimumRequestIntervalMS: 0), transport: transport))
    }
    func response(search: Bool = false) throws -> LyricsHTTPResponse {
        let object: [String: Any] = ["id": 1, "trackName": "UI authored song", "artistName": "UI authored artist",
                                    "albumName": "UI authored album", "duration": 60, "instrumental": false,
                                    "hasWordSync": false, "syncedLyrics": "[00:01]Late authored provider result"]
        let bytes = try JSONSerialization.data(withJSONObject: search ? [object] as Any : object as Any)
        return .init(status: 200, headers: ["content-type": "application/json"], body: bytes)
    }
    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Deliberately ignores cancellation until released, as a completed HTTP reply may
/// already be in flight when the user imports a file or changes recordings.
private actor DeferredUITransport: LyricsHTTPTransport {
    private let response: LyricsHTTPResponse
    private var pending: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(response: LyricsHTTPResponse) { self.response = response }
    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        await withCheckedContinuation { continuation in
            pending = continuation
            started = true
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
        return response
    }
    func waitUntilRequested() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() { pending?.resume(); pending = nil }
}
