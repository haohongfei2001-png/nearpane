import Foundation
import LyricCore
import LyricPlayback
import Testing
@testable import LyricUI

@Suite("Playback-driven panel visibility")
struct PanelPresentationTests {
    @Test func startupPausedDoesNotAppearForAccessibilityControls() {
        var policy = LyricPanelVisibilityPolicy()
        let actual1 = policy.shouldPresent(snapshot(.paused), wasVisible: false, isInteracting: true)
        #expect(!actual1)
    }

    @Test func pauseKeepsExistingControlsOnlyUntilInteractionEnds() {
        var policy = LyricPanelVisibilityPolicy()
        let actual2 = policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false)
        #expect(actual2)
        let actual3 = policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: true)
        #expect(actual3)
        let actual4 = policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: true)
        #expect(actual4)
        let actual5 = policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: false)
        #expect(!actual5)
        let actual6 = policy.shouldPresent(snapshot(.paused), wasVisible: false, isInteracting: true)
        #expect(!actual6)
        let actual7 = policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false)
        #expect(actual7)
    }

    @Test(arguments: [LyricDomain.PlaybackState.stopped, .buffering, .unknown])
    func inactiveMetadataCannotKeepThePanelOpen(_ state: LyricDomain.PlaybackState) {
        var policy = LyricPanelVisibilityPolicy()
        let actual8 = policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false)
        #expect(actual8)
        let actual9 = policy.shouldPresent(snapshot(state), wasVisible: true, isInteracting: true)
        #expect(!actual9)
    }

    @Test func connectionOrAuthorizationStatusNeverCreatesAnEmptyPanel() {
        var policy = LyricPanelVisibilityPolicy()
        let unavailable = PlaybackSnapshot(player: .appleMusic, selection: nil, anchor: nil,
            state: .playing, statusMessage: "Authored authorization status", requiresAuthorization: true)
        let actual10 = policy.shouldPresent(unavailable, wasVisible: true, isInteracting: true)
        #expect(!actual10)
        let actual11 = policy.shouldPresent(.empty, wasVisible: false, isInteracting: false)
        #expect(!actual11)
    }

    @Test func pausedRetentionDoesNotFollowADifferentSong() {
        var policy = LyricPanelVisibilityPolicy()
        let actual12 = policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: true)
        #expect(actual12)
        let actual13 = policy.shouldPresent(snapshot(.paused, generation: 2), wasVisible: true, isInteracting: true)
        #expect(!actual13)
    }

    @Test func lateMetadataDoesNotDismissPausedControls() {
        var policy = LyricPanelVisibilityPolicy()
        let actual14 = policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: true)
        #expect(actual14)
        let actual15 = policy.shouldPresent(snapshot(.paused, artists: ["Authored artist"])
        #expect(actual15)
                                     wasVisible: true, isInteracting: true))
    }

    private let session = UUID()
    private func snapshot(_ state: LyricDomain.PlaybackState, generation: UInt64 = 1,
                          artists: [String] = []) -> PlaybackSnapshot {
        let selection = LyricDomain.Selection(playerBundleID: "test.visibility.player", sessionID: session,
            generation: generation, recording: .init(fingerprint: "visibility-\(generation)", platformIDs: [],
                isrc: nil, title: "Authored panel fixture", artists: artists, album: nil,
                durationMS: 60_000, versionTags: []))
        return .init(player: .appleMusic, selection: selection, anchor: nil, state: state)
    }
}
