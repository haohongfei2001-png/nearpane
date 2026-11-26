import Foundation
import Testing
@testable import LyricCore

@Suite("Real anchor projection")
struct LyricTimelineTests {
    @Test func appliesSignedSourceAndPerDocumentUserAdvance() throws {
        let document = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: 1_000),
                                                  CoreFixture.cue("b", start: 1_500, end: 3_000)], advance: 100)
        let adjustment = LyricDomain.UserTimingAdjustment(recordingFingerprint: "recording",
            documentContentHash: document.contentHash, userAdvanceMS: 200)
        let frame = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 1_000),
            at: CoreFixture.stamp(1_500), document: document, adjustment: adjustment)
        #expect(frame.lookupMS == 1_800)
        #expect(frame.presentedCues.map(\.cueID) == ["b"])
        #expect(frame.phase == .syncedLine)
    }

    @Test func pauseFreezesAndSeekRebasesWithoutNewGeneration() throws {
        let document = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: nil),
                                                  CoreFixture.cue("b", start: 3_000, end: nil)])
        let timeline = LyricTimeline()
        let paused = try timeline.frame(anchor: CoreFixture.anchor(position: 900, state: .paused),
            at: CoreFixture.stamp(100_000), document: document, adjustment: nil)
        #expect(paused.lookupMS == 900)
        let sought = try timeline.frame(anchor: CoreFixture.anchor(position: 3_500),
            at: CoreFixture.stamp(1_000), document: document, adjustment: nil)
        #expect(sought.selection.generation == paused.selection.generation)
        #expect(sought.presentedCues.map(\.cueID) == ["b"])
    }

    @Test func aHealthyUnmeasuredAnchorAllowsLinesButNeverInventsWordAccuracy() throws {
        let token = LyricDomain.Token(id: "word", text: "雪", rangeInCue: .init(location: 0, length: 1),
                                    sourceStartMS: 0, sourceEndMS: 2_000)
        let cue = LyricDomain.Cue(id: "a", text: "雪", sourceStartMS: 0, sourceEndMS: 2_000,
                                 tokens: [token], linkedCueID: nil, agentID: nil)
        let document = CoreFixture.document(cues: [cue], timing: .token)
        let line = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 500),
            at: CoreFixture.stamp(1_000), document: document, adjustment: nil)
        #expect(line.phase == .syncedLine)
        #expect(line.presentedCues.first?.activeTokenIDs.isEmpty == true)
        let word = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 500, quality: .verifiedSourceAnchor, error: 180),
            at: CoreFixture.stamp(1_000), document: document, adjustment: nil)
        #expect(word.phase == .syncedToken)
        #expect(word.presentedCues.first?.activeTokenIDs == ["word"])
    }

    @Test func staleOrUnavailableOrExpiredAnchorsDoNotRunSyntheticProgress() throws {
        let document = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: nil)])
        for quality in [LyricDomain.ClockQuality.stale, .unavailable] {
            let frame = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 100, quality: quality),
                at: CoreFixture.stamp(1_500), document: document, adjustment: nil)
            #expect(frame.phase == .positionUnavailable)
            #expect(frame.lookupMS == nil)
        }
        let expired = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 100),
            at: CoreFixture.stamp(17_000), document: document, adjustment: nil)
        #expect(expired.phase == .positionUnavailable)
        #expect(expired.lookupMS == nil)
    }

    @Test func unknownEndsStayUnknownWhileDisplayCanHoldUntilNextCue() throws {
        let unknown = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: nil),
                                                 CoreFixture.cue("b", start: 5_000, end: nil)])
        let frame = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 3_000),
            at: CoreFixture.stamp(1_000), document: unknown, adjustment: nil)
        #expect(frame.phase == .syncedLine)
        #expect(frame.presentedCues.first?.displayHoldUntilMS == 5_000)
        #expect(unknown.lanes[0].cues[0].sourceEndMS == nil)
        let known = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: 2_000),
                                               CoreFixture.cue("b", start: 5_000, end: nil)])
        let gap = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 3_000),
            at: CoreFixture.stamp(1_000), document: known, adjustment: nil)
        #expect(gap.phase == .interlude)
    }

    @Test func overlappingCuesRemainSimultaneous() throws {
        let document = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: 5_000),
                                                  CoreFixture.cue("b", start: 1_000, end: 3_000)])
        let frame = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 2_000),
            at: CoreFixture.stamp(1_000), document: document, adjustment: nil)
        #expect(Set(frame.presentedCues.map(\.cueID)) == ["a", "b"])
    }

    @Test func unknownFormatOffsetAndDifferentDocumentAdjustmentAreNotApplied() throws {
        let base = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: nil)])
        let unknown = LyricDomain.Document(id: base.id, schemaVersion: 1, contentHash: base.contentHash,
            recording: base.recording, source: base.source, originalFormat: .lyricsfileV1Draft,
            timingLevel: .line, sourceTiming: .init(sourceAdvanceMS: nil, interpretation: .unresolved, rawOffset: "500"),
            lanes: base.lanes, instrumental: false)
        let frame = try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 100),
            at: CoreFixture.stamp(1_000), document: unknown,
            adjustment: .init(recordingFingerprint: "recording", documentContentHash: "different", userAdvanceMS: 1_000))
        #expect(frame.lookupMS == 100)
    }

    @Test func differentMonotonicDomainsAndDifferentRecordingAreRejected() throws {
        let document = CoreFixture.document(cues: [CoreFixture.cue("a", start: 0, end: nil)])
        #expect(throws: LyricTimelineError.differentClockDomains) {
            try LyricTimeline().frame(anchor: CoreFixture.anchor(position: 0),
                at: .init(nanoseconds: 1_000_000_000, clockDomainID: UUID()), document: document, adjustment: nil)
        }
        let other = CoreFixture.recording(fingerprint: "other")
        let anchor = LyricDomain.PlaybackAnchor(selection: .init(playerBundleID: "test", sessionID: CoreFixture.session,
                generation: 1, recording: other), positionMS: 0, observedAt: CoreFixture.stamp(1_000),
                playbackRate: 1, state: .playing, quality: .coarseSourceAnchor, expectedErrorMS: nil)
        #expect(throws: LyricTimelineError.differentRecording) {
            try LyricTimeline().frame(anchor: anchor, at: CoreFixture.stamp(1_000), document: document, adjustment: nil)
        }
    }
}

enum CoreFixture {
    static let clock = UUID()
    static let session = UUID()
    static func stamp(_ milliseconds: UInt64) -> LyricDomain.MonotonicStamp {
        .init(nanoseconds: milliseconds * 1_000_000, clockDomainID: clock)
    }
    static func recording(fingerprint: String = "recording", title: String = "Test song", artists: [String] = ["Test artist"],
                          duration: Int64? = 60_000, ids: [LyricDomain.PlatformTrackID] = [],
                          versionTags: [String] = [], isrc: String? = nil) -> LyricDomain.RecordingIdentity {
        .init(fingerprint: fingerprint, platformIDs: ids, isrc: isrc, title: title,
              artists: artists, album: "Test album", durationMS: duration, versionTags: versionTags)
    }
    static func cue(_ id: String, start: Int64, end: Int64?) -> LyricDomain.Cue {
        .init(id: id, text: "Original test line", sourceStartMS: start, sourceEndMS: end,
              tokens: [], linkedCueID: nil, agentID: nil)
    }
    static func anchor(position: Int64, state: LyricDomain.PlaybackState = .playing,
                       quality: LyricDomain.ClockQuality = .coarseSourceAnchor, error: Int64? = nil) -> LyricDomain.PlaybackAnchor {
        .init(selection: .init(playerBundleID: "test", sessionID: session, generation: 1, recording: recording()),
              positionMS: position, observedAt: stamp(1_000), playbackRate: 1, state: state,
              quality: quality, expectedErrorMS: error)
    }
    static func document(cues: [LyricDomain.Cue], advance: Int64 = 0,
                         timing: LyricDomain.TimingLevel = .line) -> LyricDomain.Document {
        let rights = LyricDomain.RightsEvidence(apiAccess: .localFile, apiEvidenceURL: nil,
            contentRights: .userProvidedUnverified, contentEvidenceURL: nil, reviewedAt: Date(),
            evidenceRevision: nil, territories: [], expiry: nil, cacheMaxAgeSeconds: nil, attributionText: nil)
        let source = LyricDomain.SourceProvenance(providerID: "test", providerRecordID: nil, sourceURL: nil,
            fetchedAt: Date(), revisionOrETag: nil, contributorCredit: nil, rights: rights)
        return .init(id: UUID(), schemaVersion: 1, contentHash: UUID().uuidString, recording: recording(),
            source: source, originalFormat: .lrc, timingLevel: timing,
            sourceTiming: .init(sourceAdvanceMS: advance, interpretation: .normalizedKnownFormat, rawOffset: String(advance)),
            lanes: [.init(id: "lead", kind: .lead, languageBCP47: nil, cues: cues)], instrumental: false)
    }
}
