#if DEBUG && canImport(NearpaneLyricsModule)
import Foundation
import Testing
import LyricCore
import LyricPlayback
@testable import NearpaneUI

@MainActor struct FullscreenLyricMountTests {
    @Test func withdrawingOnePresentationCannotUnmountTheOtherLyricsCard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearpane-lyric-mount-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lyrics = HostLyrics(directory: directory, verificationOnly: true)
        let recording = LyricDomain.RecordingIdentity(fingerprint: "mount-fixture", platformIDs: [], isrc: nil,
            title: "挂载测试", artists: [], album: nil, durationMS: 100_000, versionTags: [])
        let selection = LyricDomain.Selection(playerBundleID: PlayerID.appleMusic.bundleID,
            sessionID: UUID(), generation: 1, recording: recording)
        let snapshot = PlaybackSnapshot(player: .appleMusic, selection: selection, anchor: nil, state: .paused,
            capabilities: .init(canPlay: true, canPause: true, canNext: false, canPrevious: false, canSeek: false))
        try lyrics.start()
        #expect(lyrics.installVerificationSnapshot(snapshot))
        lyrics.setHostHidden(false)
        let ordinary = UUID(), fullscreen = UUID()
        lyrics.setMounted(true, surface: ordinary)
        lyrics.setMounted(true, surface: fullscreen)
        #expect(lyrics.module.model.isVisible)
        lyrics.setMounted(false, surface: ordinary)
        #expect(lyrics.module.model.isVisible)
        // Duplicate disappearance is harmless and cannot remove another view's token.
        lyrics.setMounted(false, surface: ordinary)
        #expect(lyrics.module.model.isVisible)
        lyrics.setMounted(false, surface: fullscreen)
        #expect(!lyrics.module.model.isVisible)
        #expect(!lyrics.module.model.ownsSession)
        lyrics.stop()
    }
}
#endif
