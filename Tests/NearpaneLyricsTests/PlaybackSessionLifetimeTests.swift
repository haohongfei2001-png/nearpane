import AppKit
import Foundation
import Testing
@testable import LyricCore
@testable import LyricPlayback
@testable import LyricUI
@testable import NearpaneLyricsModule

struct PlaybackSessionLifetimeTests {
    private func observation(player: PlayerID = .appleMusic, state: LyricDomain.PlaybackState = .playing,
                             title: String? = "A real song", id: String? = "track-one",
                             processStart: UInt64 = 100) -> PlayerObservation {
        let process = PlayerProcess(player: player, pid: 42, startMicros: processStart, version: "fixture")
        return PlayerObservation(process: process, mediaPID: 42, mediaProcessStart: processStart,
            title: title, artist: "Artist", album: "Album", platformID: id, durationMS: 180_000,
            positionMS: 42_000, state: state, rate: state == .playing ? 1 : 0,
            stamp: PlaybackClock.now(), capabilities: .init(canPlay: true, canPause: true),
            artwork: nil, artworkURL: nil, sourceIsCurrent: true)
    }

    private func snapshot(_ observation: PlayerObservation, selection: LyricDomain.Selection?) -> PlaybackSnapshot {
        .init(player: observation.process.player, selection: selection, anchor: nil,
              state: observation.state, capabilities: observation.capabilities)
    }

    @Test func pausedSessionSurvivesWithoutPointerOrPreviousVisibleSurface() throws {
        var tracker = PlaybackSelectionTracker()
        let paused = observation(state: .paused)
        let selectionValue = tracker.update(paused)
        let selection = try #require(selectionValue)
        var policy = LyricPanelVisibilityPolicy()
        let value = snapshot(paused, selection: selection)
        // There is no wall-clock timeout in this decision. Repeated dormant
        // refreshes, mounting and unmounting all preserve the same session.
        for index in 0..<1_000 {
            let observed1 = policy.shouldPresent(value, wasVisible: index % 2 == 0, isInteracting: false)
            #expect(observed1)
        }
        let observed2 = policy.shouldPresent(value, wasVisible: false, isInteracting: true)
        #expect(observed2)
        let observed3 = !policy.shouldPresent(.empty, wasVisible: true, isInteracting: true)
        #expect(observed3)
    }

    @Test func initialIdlePlayerDoesNotCreateAnEmptyLyricSlot() {
        var tracker = PlaybackSelectionTracker()
        let observed4 = tracker.update(observation(state: .stopped, title: nil, id: nil)) == nil
        #expect(observed4)
        let observed5 = tracker.update(observation(state: .unknown, title: nil, id: nil)) == nil
        #expect(observed5)
        let observed6 = tracker.update(observation(state: .stopped)) == nil
        #expect(observed6)
        var policy = LyricPanelVisibilityPolicy()
        let observed7 = !policy.shouldPresent(snapshot(observation(), selection: nil), wasVisible: true, isInteracting: true)
        #expect(observed7)
    }

    @Test func establishedSessionSurvivesStoppedAndSparseResponsesButNotProcessRestart() throws {
        var tracker = PlaybackSelectionTracker()
        let firstValue = tracker.update(observation())
        let first = try #require(firstValue)
        let sparse = observation(state: .unknown, title: nil, id: nil)
        let observed8 = tracker.update(sparse) == first
        #expect(observed8)
        let observed9 = tracker.update(observation(state: .stopped)) == first
        #expect(observed9)
        let observed10 = tracker.update(observation(state: .unknown, title: nil, id: nil, processStart: 200)) == nil
        #expect(observed10)
        let restartedValue = tracker.update(observation(state: .paused, processStart: 200))
        let restarted = try #require(restartedValue)
        #expect(restarted.sessionID != first.sessionID)
    }

    @Test func metadataContinuityNeverCarriesAcrossTrackOrNativeSessionChanges() {
        let original = observation(state: .paused)
        var sparse = observation(state: .paused, title: nil, id: nil)
        sparse.artist = nil; sparse.album = nil; sparse.positionMS = nil
        let merged = PlaybackObservationContinuity.merging(sparse, with: original)
        #expect(merged.title == original.title)
        #expect(merged.platformID == original.platformID)
        #expect(merged.positionMS == nil) // Never manufacture a source clock.
        let next = observation(state: .playing, title: nil, id: "track-two")
        #expect(PlaybackObservationContinuity.merging(next, with: original).title == nil)
        let restarted = observation(state: .paused, title: nil, id: nil, processStart: 200)
        #expect(PlaybackObservationContinuity.merging(restarted, with: original).title == nil)
    }

    @Test func metadataGapKeepsGenerationAndRealTrackChangeReplacesIt() throws {
        var tracker = PlaybackSelectionTracker()
        let first = observation()
        let selectionValue = tracker.update(first)
        let selection = try #require(selectionValue)
        let gap = PlaybackObservationContinuity.merging(observation(state: .paused, title: nil, id: nil), with: first)
        let observed11 = tracker.update(gap) == selection
        #expect(observed11)
        let changedValue = tracker.update(observation(title: "Second song", id: "track-two"))
        let changed = try #require(changedValue)
        #expect(changed.generation > selection.generation)
        #expect(changed.recording.title == "Second song")
    }

    @Test func unrelatedPlayerExitDoesNotReplaceCurrentPausedSelection() {
        let music = observation(state: .paused)
        let spotify = observation(player: .spotify, state: .paused)
        let before = PlaybackSourcePolicy.choose(preferred: nil, previous: .appleMusic, currentSource: nil,
            observations: [.appleMusic: music, .spotify: spotify], available: [.appleMusic, .spotify], transitions: [:])
        let after = PlaybackSourcePolicy.choose(preferred: nil, previous: before, currentSource: nil,
            observations: [.appleMusic: music], available: [.appleMusic], transitions: [:])
        #expect(before == .appleMusic)
        #expect(after == .appleMusic)
        #expect(PlaybackSourcePolicy.choose(preferred: nil, previous: after, currentSource: nil,
            observations: [:], available: [], transitions: [:]) == nil)
    }

    @Test func exitedPlayerCannotWinFromAStaleObservationDictionary() {
        let stale = observation(state: .playing)
        let other = observation(player: .spotify, state: .paused)
        #expect(PlaybackSourcePolicy.choose(preferred: nil, previous: .appleMusic, currentSource: .appleMusic,
            observations: [.appleMusic: stale, .spotify: other], available: [.spotify], transitions: [.appleMusic: 4]) == .spotify)
    }

    @Test @MainActor func everyLyricManagementRequestRoutesIntoHostWithoutCreatingWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nearpane-lyrics-route-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
        let module = NearpaneLyricsModule(storageURL: root, defaults: defaults)
        var destinations: [LyricAuxiliaryPage] = []
        module.openManagementPage = { destinations.append($0) }
        for page in [LyricAuxiliaryPage.settings, .fullLyrics, .source, .adjustment, .candidates, .settings] {
            module.model.show(page)
        }
        #expect(destinations == [.settings, .fullLyrics, .source, .adjustment, .candidates, .settings])
        #expect(!module.isPresented)
        #expect(!module.model.ownsSession)
        #expect(Set(NSApplication.shared.windows.map(\.windowNumber)) == windowNumbers)
    }

    #if DEBUG
    @Test @MainActor func confirmedPausedProgressDoesNotVanishOnIncompletePollOrAdvanceOverTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nearpane-lyrics-pause-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricAppModel(storageURL: root, defaults: defaults)
        var tracker = PlaybackSelectionTracker()
        let source = observation(state: .paused)
        let selectedValue = tracker.update(source)
        let selected = try #require(selectedValue)
        let stamp = PlaybackClock.now()
        let anchor = LyricDomain.PlaybackAnchor(selection: selected, positionMS: 42_000,
            observedAt: stamp, playbackRate: 0, state: .paused, quality: .coarseSourceAnchor, expectedErrorMS: nil)
        model.installVerificationSnapshot(.init(player: .appleMusic, selection: selected, anchor: anchor, state: .paused))
        #expect(model.projectedPosition(at: .init(nanoseconds: stamp.nanoseconds + 86_400_000_000_000,
            clockDomainID: stamp.clockDomainID)) == 42_000)
        model.receive(.init(player: .appleMusic, selection: selected, anchor: nil, state: .paused))
        #expect(model.playbackPositionMS == 42_000)
        model.receive(.empty)
        #expect(model.playbackPositionMS == nil)
        #expect(model.snapshot.selection == nil)
    }

    @Test @MainActor func firstPausedObservationNeverReusesAPlayingAnchorAsConfirmedProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "nearpane-lyrics-clock-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LyricAppModel(storageURL: root, defaults: defaults)
        var tracker = PlaybackSelectionTracker()
        let selectedValue = tracker.update(observation())
        let selected = try #require(selectedValue)
        let anchor = LyricDomain.PlaybackAnchor(selection: selected, positionMS: 42_000,
            observedAt: PlaybackClock.now(), playbackRate: 1, state: .playing,
            quality: .coarseSourceAnchor, expectedErrorMS: nil)
        model.installVerificationSnapshot(.init(player: .appleMusic, selection: selected, anchor: anchor, state: .playing))
        model.receive(.init(player: .appleMusic, selection: selected, anchor: nil, state: .paused))
        #expect(model.playbackPositionMS == nil)
    }
    #endif
}
