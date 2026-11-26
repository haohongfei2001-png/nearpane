import Foundation
import LyricCore
import LyricPlayback
import Testing
@testable import LyricUI

@Suite("Playback-driven panel visibility")
struct PanelPresentationTests {
    @Test func startupPausedDoesNotAppearForAccessibilityControls() {
        var policy = LyricPanelVisibilityPolicy()
        #expect(!policy.shouldPresent(snapshot(.paused), wasVisible: false, isInteracting: true))
    }

    @Test func pauseKeepsExistingControlsOnlyUntilInteractionEnds() {
        var policy = LyricPanelVisibilityPolicy()
        #expect(policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false))
        #expect(policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: true))
        #expect(policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: true))
        #expect(!policy.shouldPresent(snapshot(.paused), wasVisible: true, isInteracting: false))
        #expect(!policy.shouldPresent(snapshot(.paused), wasVisible: false, isInteracting: true))
        #expect(policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false))
    }

    @Test(arguments: [LyricDomain.PlaybackState.stopped, .buffering, .unknown])
    func inactiveMetadataCannotKeepThePanelOpen(_ state: LyricDomain.PlaybackState) {
        var policy = LyricPanelVisibilityPolicy()
        #expect(policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: false))
        #expect(!policy.shouldPresent(snapshot(state), wasVisible: true, isInteracting: true))
    }

    @Test func connectionOrAuthorizationStatusNeverCreatesAnEmptyPanel() {
        var policy = LyricPanelVisibilityPolicy()
        let unavailable = PlaybackSnapshot(player: .appleMusic, selection: nil, anchor: nil,
            state: .playing, statusMessage: "Authored authorization status", requiresAuthorization: true)
        #expect(!policy.shouldPresent(unavailable, wasVisible: true, isInteracting: true))
        #expect(!policy.shouldPresent(.empty, wasVisible: false, isInteracting: false))
    }

    @Test func pausedRetentionDoesNotFollowADifferentSong() {
        var policy = LyricPanelVisibilityPolicy()
        #expect(policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: true))
        #expect(!policy.shouldPresent(snapshot(.paused, generation: 2), wasVisible: true, isInteracting: true))
    }

    @Test func lateMetadataDoesNotDismissPausedControls() {
        var policy = LyricPanelVisibilityPolicy()
        #expect(policy.shouldPresent(snapshot(.playing), wasVisible: false, isInteracting: true))
        #expect(policy.shouldPresent(snapshot(.paused, artists: ["Authored artist"]),
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
