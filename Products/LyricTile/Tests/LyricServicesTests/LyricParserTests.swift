import Foundation
import Testing
import LyricCore
@testable import LyricServices

@Suite("Bounded real timing parsers")
struct LyricParserTests {
    @Test func lrcPreservesRepeatedOccurrencesAndOffsetWithoutInventedEnds() throws {
        let document = try ServiceFixture.parse("[offset:200]\n[00:01.25][00:03.000]雪落在桌边\n[00:05.000]", .lrc)
        let cues = document.lanes[0].cues
        #expect(cues.count == 3)
        #expect(cues.map(\.sourceStartMS) == [1_250, 3_000, 5_000])
        #expect(cues.allSatisfy { $0.sourceEndMS == nil && $0.tokens.isEmpty })
        #expect(Set(cues.map(\.id)).count == 3)
        #expect(document.sourceTiming.sourceAdvanceMS == 200)
    }

    @Test func enhancedLRCOnlyGivesAnEndWhereAnEndMarkerExists() throws {
        let document = try ServiceFixture.parse("[00:01.000]<00:01.000>Snow <00:02.000>arrives<00:03.000>", .enhancedLRC)
        let cue = try #require(document.lanes.first?.cues.first)
        #expect(cue.text == "Snow arrives")
        #expect(cue.tokens.count == 2)
        #expect(cue.tokens[0].sourceEndMS == nil)
        #expect(cue.tokens[1].sourceEndMS == 3_000)
        #expect(cue.sourceEndMS == 3_000)
    }

    @Test func lrcxUsesUTF16GraphemeBoundariesAndKeepsTranslationSeparate() throws {
        let text = "[00:01.000]A👩‍💻B\n[00:01.000][tt]<0,0><100,1><300,6><400,7><400>\n[00:01.000][tr:zh-Hans]原创测试"
        let document = try ServiceFixture.parse(text, .lrcx)
        let cue = try #require(document.lanes.first?.cues.first)
        #expect(cue.tokens.map(\.text) == ["A", "👩‍💻", "B"])
        #expect(cue.tokens[1].rangeInCue == .init(location: 1, length: 5))
        #expect(document.lanes.contains { $0.kind == .translation && $0.languageBCP47 == "zh-Hans" })
        #expect(throws: (any Error).self) {
            try ServiceFixture.parse("[00:01]👩‍💻\n[00:01][tt]<0,0><100,2><200,5>", .lrcx)
        }
    }

    @Test func ttmlKeepsWordTimesTranslationLanguageAndBackgroundOverlap() throws {
        let xml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="zh-Hans">
        <body><div><p begin="1s" end="3s"><span begin="1s" end="2000ms">握</span><span begin="2s" end="3s">雪</span><span ttm:role="x-translation" xml:lang="en">Hold snow</span><span ttm:role="x-bg" begin="1.5s" end="2.5s">回声</span></p></div></body>
        </tt>
        """
        let document = try ServiceFixture.parse(xml, .ttmlAppleAMLL)
        let main = try #require(document.lanes.first { $0.kind == .lead }?.cues.first)
        #expect(main.text == "握雪")
        #expect(main.tokens.map(\.sourceStartMS) == [1_000, 2_000])
        #expect(main.tokens.map(\.sourceEndMS) == [2_000, 3_000])
        let translation = try #require(document.lanes.first { $0.kind == .translation })
        #expect(translation.languageBCP47 == "en")
        #expect(translation.cues[0].linkedCueID == main.id)
        #expect(document.lanes.first { $0.kind == .background }?.cues[0].sourceStartMS == 1_500)
    }

    @Test func ttmlRejectsEntitiesAndUnimplementedTimeBasesInsteadOfReturningZero() {
        let bad = [
            "<!DOCTYPE tt [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><tt><body><p begin='1s'>&x;</p></body></tt>",
            "<tt><body><p begin='20f'>test</p></body></tt>",
            "<tt><body timeContainer='seq'><p begin='1s'>test</p></body></tt>",
            "<tt><body><p begin='NaN'>test</p></body></tt>",
            "<tt><body><p begin='5s' end='1s'>test</p></body></tt>"
        ]
        for input in bad { #expect(throws: (any Error).self) { try ServiceFixture.parse(input, .ttmlAppleAMLL) } }
    }

    @Test func lyricsfileIsStrictVersionedYAMLAndUnknownOffsetRemainsUnknown() throws {
        let document = try ServiceFixture.parse(ServiceFixture.lyricsfile, .lyricsfileV1Draft)
        #expect(document.timingLevel == .token)
        #expect(document.sourceTiming.interpretation == .unresolved)
        #expect(document.sourceTiming.sourceAdvanceMS == nil)
        #expect(document.sourceTiming.rawOffset == "200")
        #expect(document.lanes[0].cues[0].tokens[0].sourceEndMS == nil)
        #expect(document.lanes[0].cues[0].sourceEndMS == nil)
        let broken = [
            ServiceFixture.lyricsfile.replacingOccurrences(of: "version: '1.0'", with: "version: '2.0'"),
            ServiceFixture.lyricsfile.replacingOccurrences(of: "version: '1.0'", with: "version: 1.0"),
            ServiceFixture.lyricsfile + "\nversion: '1.0'", // duplicate root key
            ServiceFixture.lyricsfile.replacingOccurrences(of: "start_ms: 1000", with: "start_ms: -1"),
            "version: '1.0'\nmetadata: &m {title: test, artist: test}\nlines: [*m]",
            "version: '1.0'\nmetadata: !custom {title: test, artist: test}\nplain: test",
            ServiceFixture.lyricsfile + "\n---\nversion: '1.0'"
        ]
        for input in broken { #expect(throws: (any Error).self) { try ServiceFixture.parse(input, .lyricsfileV1Draft) } }
    }

    @Test func lyricsfilePlainBlockIsDataAndInstrumentalMustBeExplicit() throws {
        let plain = try ServiceFixture.parse("""
        version: '1.0'
        metadata: {title: Test, artist: Test}
        plain: |
          Literal &anchor and *alias stay text.
          [An original annotation]
        """, .lyricsfileV1Draft)
        #expect(plain.timingLevel == .none)
        #expect(!plain.instrumental)
        let instrumental = try ServiceFixture.parse("""
        version: '1.0'
        metadata: {title: Test, artist: Test, instrumental: true}
        """, .lyricsfileV1Draft)
        #expect(instrumental.instrumental)
        #expect(instrumental.lanes.isEmpty)
    }

    @Test func plaintextDoesNotAcquireAnyTimeAndLimitsRejectBeforeLargeTrees() throws {
        let plain = try ServiceFixture.parse("Original\n原创\n", .plainText)
        #expect(plain.timingLevel == .none)
        #expect(plain.lanes[0].cues.allSatisfy { $0.sourceStartMS == nil && $0.sourceEndMS == nil && $0.tokens.isEmpty })
        #expect(throws: (any Error).self) { try ServiceFixture.parse(String(repeating: "x", count: 2_097_153), .plainText) }
        let nested = "version: '1.0'\nmetadata: {title: Test, artist: Test}\nunknown: "
            + String(repeating: "[", count: 100) + "1" + String(repeating: "]", count: 100)
        #expect(throws: (any Error).self) { try ServiceFixture.parse(nested, .lyricsfileV1Draft) }
    }

    @Test func decodedQRCAndYRCPreserveAbsoluteWordDurations() throws {
        let qrc = try ServiceFixture.parse("[1000,2000]握(1000,1000)雪(2000,1000)", .qrcPlaintext)
        let yrc = try ServiceFixture.parse("[1000,2000](1000,1000,0)握(2000,1000,0)雪", .yrcPlaintext)
        #expect(qrc.lanes[0].cues[0].text == "握雪")
        #expect(yrc.lanes[0].cues[0].tokens.map(\.sourceEndMS) == [2_000, 3_000])
    }
}

enum ServiceFixture {
    static let session = UUID()
    static func selection(_ generation: UInt64 = 1, fingerprint: String = "recording", title: String = "Original test") -> LyricDomain.Selection {
        .init(playerBundleID: "test.player", sessionID: session, generation: generation,
              recording: .init(fingerprint: fingerprint, platformIDs: [], isrc: nil, title: title,
                artists: ["Original artist"], album: "Original album", durationMS: 60_000, versionTags: []))
    }
    static var source: LyricDomain.SourceProvenance {
        .init(providerID: "test", providerRecordID: nil, sourceURL: nil, fetchedAt: Date(), revisionOrETag: nil,
            contributorCredit: nil, rights: .init(apiAccess: .localFile, apiEvidenceURL: nil,
                contentRights: .userProvidedUnverified, contentEvidenceURL: nil, reviewedAt: Date(),
                evidenceRevision: nil, territories: [], expiry: nil, cacheMaxAgeSeconds: nil, attributionText: nil))
    }
    static func parse(_ text: String, _ format: LyricDomain.Format) throws -> LyricDomain.Document {
        try LyricParser().parse(Data(text.utf8), format: format, recording: selection().recording, source: source)
    }
    static let lyricsfile = """
    version: '1.0'
    metadata:
      title: 'Original test'
      artist: 'Original artist'
      offset_ms: 200
    lines:
      - text: 'Snow falls'
        start_ms: 1000
        words:
          - text: 'Snow '
            start_ms: 1000
          - text: 'falls'
            start_ms: 2000
    """
    static func record(id: Int = 1, title: String = "Original test", lyricsfile: String? = nil,
                       lrc: String? = "[00:01]Original test line", plain: String? = nil,
                       instrumental: Bool = false) throws -> Data {
        var object: [String: Any] = ["id": id, "trackName": title, "artistName": "Original artist",
            "albumName": "Original album", "duration": 60, "instrumental": instrumental, "hasWordSync": lyricsfile != nil]
        object["lyricsfile"] = lyricsfile
        object["syncedLyrics"] = lrc
        object["plainLyrics"] = plain
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func response(_ body: Data, status: Int = 200) -> LyricsHTTPResponse {
        .init(status: status, headers: ["content-type": "application/json"], body: body)
    }
}
