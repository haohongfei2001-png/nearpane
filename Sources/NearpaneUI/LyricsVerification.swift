#if DEBUG && canImport(NearpaneLyricsModule)
import Foundation
import LyricCore
import LyricPlayback

/// DEBUG-only data for native view inspection. These frames are deliberately
/// labelled fixtures and never start a player, network lookup or audio session.
@MainActor
public extension EmbeddedModules {
    @discardableResult
    func installLyricsVerificationSnapshot(_ snapshot: PlaybackSnapshot, document: LyricDomain.Document? = nil) -> Bool {
        lyrics?.installVerificationSnapshot(snapshot, document: document) ?? false
    }

    var lyricsVerificationHeight: Double { lyrics?.height ?? 0 }
    var lyricsVerificationControlsVisible: Bool { lyrics?.module.model.controlsVisible ?? false }
    var lyricsVerificationOwnsSession: Bool { lyrics?.module.model.ownsSession ?? false }

    @discardableResult
    func clearLyricsVerificationControls() -> Bool {
        lyrics?.clearVerificationControls() ?? false
    }

    @discardableResult
    func installLyricsVerificationState(_ state: String) -> Bool {
        guard let lyrics else { return false }
        guard ["playing", "paused", "noLyrics", "exited", "idle"].contains(state) else { return false }
        if state == "exited" || state == "idle" {
            return lyrics.installVerificationSnapshot(.empty)
        }
        let recording = LyricDomain.RecordingIdentity(fingerprint: "nearpane-native-visual-fixture-v1",
            platformIDs: [], isrc: nil, title: "窗边的光 · 界面验收", artists: ["Nearpane 原创测试内容"],
            album: "原生视图检查", durationMS: 180_000, versionTags: [])
        let selection = LyricDomain.Selection(playerBundleID: PlayerID.appleMusic.bundleID,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000028")!, generation: 1, recording: recording)
        let playbackState: LyricDomain.PlaybackState = state == "paused" ? .paused : .playing
        let anchor = LyricDomain.PlaybackAnchor(selection: selection, positionMS: 42_000,
            observedAt: PlaybackClock.now(), playbackRate: playbackState == .playing ? 1 : 0,
            state: playbackState, quality: .coarseSourceAnchor, expectedErrorMS: nil)
        let snapshot = PlaybackSnapshot(player: .appleMusic, selection: selection, anchor: anchor,
            state: playbackState, capabilities: .init(canPlay: true, canPause: true, canNext: true,
                                                    canPrevious: true, canSeek: true))
        let rights = LyricDomain.RightsEvidence(apiAccess: .localFile, apiEvidenceURL: nil,
            contentRights: .documentedPermission, contentEvidenceURL: nil, reviewedAt: Date(timeIntervalSince1970: 0),
            evidenceRevision: "native-visual-fixture", territories: [], expiry: nil, cacheMaxAgeSeconds: nil,
            attributionText: "Nearpane native UI verification fixture; original test text")
        let source = LyricDomain.SourceProvenance(providerID: "local", providerRecordID: "native-ui-fixture",
            sourceURL: nil, fetchedAt: Date(timeIntervalSince1970: 0), revisionOrETag: nil,
            contributorCredit: "Nearpane 界面验收", rights: rights)
        let lines = ["把灯光留在窗边", "让思绪慢慢沉淀", "此刻的歌声在身边", "陪我走过每个瞬间", "风吹过安静的长街"]
        let cues = lines.enumerated().map { index, line in
            LyricDomain.Cue(id: "fixture-\(index)", text: line, sourceStartMS: Int64(index) * 20_000,
                sourceEndMS: Int64(index + 1) * 20_000, tokens: [], linkedCueID: nil, agentID: nil)
        }
        let document = LyricDomain.Document(id: UUID(uuidString: "00000000-0000-0000-0000-000000000029")!,
            schemaVersion: 1, contentHash: "native-visual-fixture-v1", recording: recording, source: source,
            originalFormat: .lrc, timingLevel: .line,
            sourceTiming: .init(sourceAdvanceMS: nil, interpretation: .absent, rawOffset: nil),
            lanes: [.init(id: "lead", kind: .lead, languageBCP47: "zh-Hans", cues: cues)], instrumental: false)
        let installed = lyrics.installVerificationSnapshot(snapshot, document: state == "noLyrics" ? nil : document)
        guard installed else { return false }
        lyrics.module.model.setControlsVisible(state == "paused" || state == "noLyrics")
        return installed
    }
}
#endif
