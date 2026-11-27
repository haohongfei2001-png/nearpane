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

    @Test func quietLineRefreshFollowsBackgroundBoundariesAndFreshSeekPosition() async throws {
        let fixture = try ModelFixture(onlineEnabled: false)
        defer { fixture.remove() }
        let repository = LyricRepository(storageURL: fixture.directory, onlineEnabled: false)
        let text = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
        <body><div><p begin="0s" end="8s">First authored line<span ttm:role="x-bg" begin="3s" end="4s">Authored echo</span></p>
        <p begin="8s" end="20s">Second authored line</p></div></body></tt>
        """
        _ = try await repository.importLyrics(Data(text.utf8), format: .ttmlAppleAMLL, for: fixture.selection())
        let model = LyricAppModel(repository: repository, defaults: fixture.defaults)
        let stamp = PlaybackClock.now()
        model.receive(fixture.anchoredSnapshot(positionMS: 1_000, observedAt: stamp))
        await (try #require(model.lyricTask)).value
        #expect(model.frame.phase == .syncedLine)
        #expect(model.currentCue?.text == "First authored line")
        #expect(abs(model.nextRefreshDelay(at: stamp) - 2) < 0.0001)
        // No new published frame is needed to keep the clock current. Both the
        // background entry and its real end must still receive timely wakes.
        let insideEcho = LyricDomain.MonotonicStamp(nanoseconds: stamp.nanoseconds + 2_500_000_000,
                                                   clockDomainID: stamp.clockDomainID)
        #expect(model.projectedPosition(at: insideEcho) == 3_500)
        #expect(abs(model.nextRefreshDelay(at: insideEcho) - 0.5) < 0.0001)
        let afterEcho = LyricDomain.MonotonicStamp(nanoseconds: stamp.nanoseconds + 3_500_000_000,
                                                  clockDomainID: stamp.clockDomainID)
        #expect(abs(model.nextRefreshDelay(at: afterEcho) - 3.5) < 0.0001)

        let seekStamp = PlaybackClock.now()
        model.receive(fixture.anchoredSnapshot(positionMS: 8_000, observedAt: seekStamp))
        #expect(model.currentCue?.text == "Second authored line")
        #expect(model.backgroundText == nil)
        #expect(abs(model.nextRefreshDelay(at: seekStamp) - 12) < 0.0001)
        model.receive(fixture.anchoredSnapshot(positionMS: 1_000, observedAt: seekStamp, rate: 2))
        #expect(abs(model.nextRefreshDelay(at: seekStamp) - 1) < 0.0001)
        model.changeAdvance(to: 500)
        await (try #require(model.adjustmentTask)).value
        #expect(abs(model.nextRefreshDelay(at: seekStamp) - 0.75) < 0.0001)
        model.importLyrics(from: try fixture.file("[00:00]Replacement authored line\n[00:30]Later replacement"),
                           for: fixture.selection())
        await (try #require(model.lyricTask)).value
        #expect(model.currentCue?.text == "Replacement authored line")
        #expect(model.advanceMS == 0)
        #expect(abs(model.nextRefreshDelay(at: seekStamp) - 14.5) < 0.0001)
    }

    @Test func hiddenProgressExpiresTheOriginalAnchorEvenWithoutLyrics() async throws {
        let fixture = try ModelFixture(onlineEnabled: false)
        defer { fixture.remove() }
        let model = LyricAppModel(repository: LyricRepository(storageURL: fixture.directory, onlineEnabled: false),
                                  defaults: fixture.defaults)
        let stamp = PlaybackClock.now()
        model.receive(fixture.anchoredSnapshot(positionMS: 2_000, observedAt: stamp))
        await (try #require(model.lyricTask)).value
        #expect(model.document == nil)
        #expect(model.panelContent == .compact)
        #expect(abs(model.nextRefreshDelay(at: stamp) - 15.001) < 0.0001)
        let later = LyricDomain.MonotonicStamp(nanoseconds: stamp.nanoseconds + 12_000_000_000,
                                             clockDomainID: stamp.clockDomainID)
        #expect(model.projectedPosition(at: later) == 14_000)
        #expect(abs(model.nextRefreshDelay(at: later) - 3.001) < 0.0001)
        let expired = LyricDomain.MonotonicStamp(nanoseconds: stamp.nanoseconds + 15_001_000_000,
                                               clockDomainID: stamp.clockDomainID)
        #expect(model.projectedPosition(at: expired) == nil)
        model.receive(fixture.anchoredSnapshot(positionMS: nil, observedAt: stamp,
                                              state: .paused, rate: 0, quality: .unavailable))
        #expect(model.playbackPositionMS == nil)
        model.receive(fixture.anchoredSnapshot(positionMS: 7_000, observedAt: stamp, state: .paused, rate: 0))
        #expect(model.projectedPosition(at: expired) == 7_000)
    }

    @Test func hoverAndQualifiedTokenLyricsKeepTheirRefreshCadence() async throws {
        let fixture = try ModelFixture(onlineEnabled: false)
        defer { fixture.remove() }
        let repository = LyricRepository(storageURL: fixture.directory, onlineEnabled: false)
        _ = try await repository.importLyrics(Data("[00:00]<00:00>Authored <00:02>words<00:04>".utf8),
                                              format: .lrc, for: fixture.selection())
        let model = LyricAppModel(repository: repository, defaults: fixture.defaults)
        let stamp = PlaybackClock.now()
        model.receive(fixture.anchoredSnapshot(positionMS: 0, observedAt: stamp,
                                              quality: .verifiedSourceAnchor, expectedErrorMS: 100))
        await (try #require(model.lyricTask)).value
        #expect(model.frame.phase == .syncedToken)
        #expect(model.nextRefreshDelay(at: stamp) == 1)
        model.setControlsVisible(true)
        #expect(model.nextRefreshDelay(at: stamp) == 0.25)
        model.setControlsVisible(false)
        #expect(model.nextRefreshDelay(at: stamp) == 1)
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
    func anchoredSnapshot(positionMS: Int64?, observedAt: LyricDomain.MonotonicStamp,
                          state: LyricDomain.PlaybackState = .playing, rate: Double = 1,
                          quality: LyricDomain.ClockQuality = .coarseSourceAnchor,
                          expectedErrorMS: Int64? = nil) -> PlaybackSnapshot {
        let current = selection()
        return .init(player: .appleMusic, selection: current,
            anchor: .init(selection: current, positionMS: positionMS, observedAt: observedAt,
                          playbackRate: rate, state: state, quality: quality, expectedErrorMS: expectedErrorMS), state: state)
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
