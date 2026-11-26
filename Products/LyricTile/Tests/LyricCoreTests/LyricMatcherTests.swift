import Testing
@testable import LyricCore

@Suite("Recording identity before lyric richness")
struct LyricMatcherTests {
    @Test func durationMismatchCannotImproveAutomaticAcceptance() {
        let matcher = LyricMatcher()
        let target = CoreFixture.recording()
        let exact = matcher.evidence(for: CoreFixture.recording(duration: 60_000), against: target)
        let five = matcher.evidence(for: CoreFixture.recording(duration: 65_000), against: target)
        let nine = matcher.evidence(for: CoreFixture.recording(duration: 69_000), against: target)
        #expect(matcher.mayAutomaticallyAccept(exact))
        #expect(!matcher.mayAutomaticallyAccept(five))
        #expect(!matcher.mayAutomaticallyAccept(nine))
    }
    @Test func versionAndArtistConflictsOverrideMatchingID() {
        let matcher = LyricMatcher()
        let ids = [LyricDomain.PlatformTrackID(namespace: "test", value: "42")]
        let target = CoreFixture.recording(ids: ids)
        let live = CoreFixture.recording(title: "Test song (Live)", ids: ids)
        #expect(matcher.evidence(for: live, against: target).versionConflict)
        #expect(!matcher.mayAutomaticallyAccept(matcher.evidence(for: live, against: target)))
        let otherArtist = CoreFixture.recording(artists: ["Different artist"], ids: ids)
        #expect(!matcher.mayAutomaticallyAccept(matcher.evidence(for: otherArtist, against: target)))
    }
    @Test func platformNamespaceAndStorefrontArePartOfIdentity() {
        let matcher = LyricMatcher()
        let a = CoreFixture.recording(ids: [.init(namespace: "apple", value: "123", storefront: "cn")])
        let b = CoreFixture.recording(ids: [.init(namespace: "spotify", value: "123")])
        let c = CoreFixture.recording(ids: [.init(namespace: "apple", value: "123", storefront: "us")])
        #expect(!matcher.evidence(for: b, against: a).exactProviderIdentity)
        #expect(!matcher.evidence(for: c, against: a).exactProviderIdentity)
    }
    @Test func absentDurationIsNotPerfectEvidence() {
        let matcher = LyricMatcher()
        let evidence = matcher.evidence(for: CoreFixture.recording(duration: nil), against: CoreFixture.recording())
        #expect(evidence.durationDeltaMS == nil)
        #expect(!matcher.mayAutomaticallyAccept(evidence))
    }
}
