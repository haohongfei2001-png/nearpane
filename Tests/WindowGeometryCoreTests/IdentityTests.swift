import Foundation
import Testing
@testable import WindowGeometryCore

struct IdentityTests {
    let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let token = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let process = ProcessIdentity(pid: 42, launchEpochMicroseconds: 1_700_000_000_000_000)
    let frame = Rect(-500, 80, 400, 300)

    func cg(id: UInt32 = 7, title: String? = "fixture-a", frame: Rect? = nil,
            process: ProcessIdentity? = nil, onscreen: Bool? = true, layer: Int = 0) -> CGWindowMetadata {
        CGWindowMetadata(process: process ?? self.process, windowID: id, title: title,
                         frame: frame ?? self.frame, layer: layer, isOnscreen: onscreen)
    }
    func ax(token: UUID? = nil, title: String? = "fixture-a", identifier: String? = "fixture.id",
            frame: Rect? = nil, process: ProcessIdentity? = nil, minimized: Bool? = false,
            subrole: String? = "AXStandardWindow") -> AXWindowMetadata {
        AXWindowMetadata(process: process ?? self.process, elementToken: token ?? self.token,
                         identifier: identifier, title: title, subrole: subrole,
                         frame: frame ?? self.frame, minimized: minimized)
    }
    func snapshot(cg: [CGWindowMetadata]? = nil, ax: [AXWindowMetadata]? = nil,
                  revision: UInt64 = 1, session: UUID? = nil, sourceBuild: String = "synthetic-fixture-v1",
                  topology: String = "fixture-topology-v1",
                  begin: Double = 10, end: Double = 10.1, consistent: Bool = true, complete: Bool = true) -> WindowSnapshot {
        WindowSnapshot(stamp: SnapshotStamp(observerSession: session ?? self.session, revision: revision,
            sourceBuild: sourceBuild, topologyToken: topology, beganUptime: begin, endedUptime: end, consistent: consistent),
            cg: cg ?? [self.cg()], ax: ax ?? [self.ax()], complete: complete)
    }
    func rejection(_ expected: TargetRejection, _ block: () throws -> Void,
                   sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try block() }
    }
    func issue(_ snapshot: WindowSnapshot) throws -> WindowTarget {
        try TargetResolver.issue(windowID: 7, in: snapshot, now: 10.2)
    }

    @Test func testUniqueMatchIncludesLifecycleCGAXRevisionAndConfidence() throws {
        let s = snapshot(), target = try issue(s)
        #expect(target.cg.process == process)
        #expect(target.cg.windowID == 7)
        #expect(target.ax.elementToken == token)
        #expect(target.ax.identifier == "fixture.id")
        #expect(target.stamp == s.stamp)
        #expect(target.confidence == .corroboratedMetadata)
        #expect(throws: Never.self) { try TargetResolver.validate(target, in: s, now: 10.2) }
    }

    @Test func testAbsentAXIdentifierDoesNotPreventCorroboratedMatch() throws {
        let target = try issue(snapshot(ax: [ax(identifier: nil)]))
        #expect(target.ax.identifier == nil)
        #expect(target.confidence == .corroboratedMetadata)
    }

    @Test func testSameAppMultipleWindowsMatchWithoutUsingArrayOrder() {
        let second = Rect(100, 80, 400, 300), token2 = UUID()
        let cg = [cg(), cg(id: 8, title: "fixture-b", frame: second)]
        let ax = [ax(token: token2, title: "fixture-b", frame: second), ax()]
        let matches = WindowMatcher.matches(cg: cg, ax: ax)
        #expect(matches.map(\.axCandidateIndices) == [[1], [0]])
        #expect(matches.map(\.confidence) == [.corroboratedMetadata, .corroboratedMetadata])
    }

    @Test func testDifferentAppsWithSameTitleAndFrameRemainDistinct() {
        let other = ProcessIdentity(pid: 99, launchEpochMicroseconds: 4)
        let matches = WindowMatcher.matches(cg: [cg(), cg(id: 8, process: other)],
            ax: [ax(token: UUID(), process: other), ax()])
        #expect(matches.map(\.axCandidateIndices) == [[1], [0]])
    }

    @Test func testDocumentWindowNumberDoesNotOverrideDivergentOnscreenBounds() {
        // P4.7.2 observed these three rectangles for one process. Give both rows
        // matching synthetic titles so the rejection cannot depend on missing titles.
        let document = ax(frame: Rect(-681, 64, 562, 422))
        let visible = cg(id: 179888, frame: Rect(-64, 602, 49, 76))
        let other = cg(id: 179886, frame: Rect(0, 580, 500, 500), onscreen: false)
        let s = snapshot(cg: [other, visible], ax: [document])
        let matches = WindowMatcher.matches(cg: s.cg, ax: s.ax)
        #expect(matches.allSatisfy { $0.confidence == .unknown && $0.axCandidateIndices.isEmpty })
        rejection(.insufficientEvidence) {
            _ = try TargetResolver.issue(windowID: visible.windowID, in: s, now: 10.2)
        }
    }

    @Test func testSameTitleAndFrameMultipleAXCandidatesAreAmbiguous() {
        let s = snapshot(ax: [ax(), ax(token: UUID())])
        #expect(WindowMatcher.matches(cg: s.cg, ax: s.ax)[0].confidence == .ambiguous)
        rejection(.ambiguous) { _ = try issue(s) }
    }

    @Test func testOneAXCandidateSharedByTwoCGWindowsIsAmbiguous() {
        let s = snapshot(cg: [cg(), cg(id: 8)])
        #expect(WindowMatcher.matches(cg: s.cg, ax: s.ax).allSatisfy { $0.confidence == .ambiguous })
        rejection(.ambiguous) { _ = try issue(s) }
    }

    @Test func testGreedyUniqueAssignmentIsNotAccepted() {
        // A fits both AX windows; B only fits the first. Do not infer an assignment.
        let cg = [cg(frame: Rect(0, 0, 100, 100)), cg(id: 8, frame: Rect(-2, 0, 100, 100))]
        let ax = [ax(frame: Rect(0, 0, 100, 100)), ax(token: UUID(), frame: Rect(2, 0, 100, 100))]
        #expect(WindowMatcher.matches(cg: cg, ax: ax).allSatisfy { $0.confidence == .ambiguous })
    }

    @Test func testMissingEmptyOrRedactedTitlesKeepGeometryOnlyConfidence() {
        for title: String? in [nil, ""] {
            let s = snapshot(cg: [cg(title: title)])
            #expect(WindowMatcher.matches(cg: s.cg, ax: s.ax)[0].confidence == .geometryOnly)
            rejection(.insufficientEvidence) { _ = try issue(s) }
        }
        rejection(.insufficientEvidence) { _ = try issue(snapshot(ax: [ax(title: nil)])) }
    }

    @Test func testTitleMismatchIsNotOverriddenByExactGeometryOrIdentifier() {
        let s = snapshot(ax: [ax(title: "different")])
        #expect(WindowMatcher.matches(cg: s.cg, ax: s.ax)[0].confidence == .unknown)
        rejection(.insufficientEvidence) { _ = try issue(s) }
    }

    @Test func testDuplicateAXIdentifiersAreNotAssumedUnique() {
        let second = Rect(100, 100, 100, 100)
        let matches = WindowMatcher.matches(cg: [cg(), cg(id: 8, title: "b", frame: second)],
            ax: [ax(), ax(token: UUID(), title: "b", frame: second)])
        #expect(matches.allSatisfy { $0.confidence == .corroboratedMetadata })
        // Both AXIdentifier strings are the same, yet token + other evidence distinguish them.
    }

    @Test func testDuplicateCGIDsOrAXTokensAreAmbiguous() {
        rejection(.ambiguous) { _ = try issue(snapshot(cg: [cg(), cg()])) }
        let matches = WindowMatcher.matches(cg: [cg()], ax: [ax(), ax(title: "unrelated")])
        #expect(matches[0].confidence == .ambiguous)
    }

    @Test func testMissingProcessLifecycleAndPIDMismatchAreRejected() {
        let unknown = ProcessIdentity(pid: 42, launchEpochMicroseconds: nil)
        rejection(.missingLifecycle) { _ = try issue(snapshot(cg: [cg(process: unknown)], ax: [ax(process: unknown)])) }
        let other = ProcessIdentity(pid: 43, launchEpochMicroseconds: process.launchEpochMicroseconds)
        rejection(.insufficientEvidence) { _ = try issue(snapshot(ax: [ax(process: other)])) }
    }

    @Test func testToleranceBoundaryAndInvalidTolerances() {
        let atLimit = ax(frame: Rect(-498, 78, 402, 298))
        #expect(WindowMatcher.matches(cg: [cg()], ax: [atLimit])[0].confidence == .corroboratedMetadata)
        let beyond = ax(frame: Rect(-497.999, 80, 400, 300))
        #expect(WindowMatcher.matches(cg: [cg()], ax: [beyond])[0].confidence == .unknown)
        for tolerance in [-1, 2.1, Double.nan, Double.infinity] {
            #expect(WindowMatcher.matches(cg: [cg()], ax: [ax()], tolerance: tolerance)[0].confidence == .unknown)
        }
    }

    @Test func identityMatchingToleranceDoesNotAdmitDivergentPresentation() throws {
        let moving = snapshot(ax: [ax(frame: Rect(-499, 80, 400, 300))])
        #expect(WindowMatcher.matches(cg: moving.cg, ax: moving.ax)[0].confidence == .corroboratedMetadata)
        rejection(.insufficientEvidence) { _ = try issue(moving) }
        rejection(.invalidSnapshot) { _ = try issue(snapshot(consistent: false)) }
        #expect(try issue(snapshot(revision: 2)).stamp.revision == 2)
    }

    @Test func testZeroIDInvalidFrameAndNonwindowRoleCannotMatch() {
        #expect(WindowMatcher.matches(cg: [cg(id: 0)], ax: [ax()])[0].confidence == .unknown)
        #expect(WindowMatcher.matches(cg: [cg(frame: Rect(0, 0, 0, 0))], ax: [ax()])[0].confidence == .unknown)
        let invalidAX = AXWindowMetadata(process: process, elementToken: token, identifier: nil,
                                        title: "fixture-a", role: "AXButton", frame: frame)
        #expect(WindowMatcher.matches(cg: [cg()], ax: [invalidAX])[0].confidence == .unknown)
    }

    @Test func testOldRevisionCannotBeReboundEvenWithIdenticalIDsAndMetadata() throws {
        let target = try issue(snapshot())
        rejection(.revisionChanged) { try TargetResolver.validate(target, in: snapshot(revision: 2), now: 10.2) }
        rejection(.revisionChanged) { try TargetResolver.validate(target, in: snapshot(revision: 0), now: 10.2) }
    }

    @Test func testObserverRestartAndTopologyChangeInvalidateTargets() throws {
        let target = try issue(snapshot())
        rejection(.sessionChanged) { try TargetResolver.validate(target, in: snapshot(session: UUID()), now: 10.2) }
        rejection(.topologyChanged) { try TargetResolver.validate(target, in: snapshot(topology: "reconfigured"), now: 10.2) }
    }

    @Test func testSourceBuildCannotBeUnknownOrChanged() throws {
        let target = try issue(snapshot())
        rejection(.invalidSnapshot) { _ = try issue(snapshot(sourceBuild: "")) }
        rejection(.sourceChanged) { try TargetResolver.validate(target, in: snapshot(sourceBuild: "other-build"), now: 10.2) }
    }

    @Test func testPIDReuseWithSameCGIDIsRejected() throws {
        let target = try issue(snapshot()), restarted = ProcessIdentity(pid: 42, launchEpochMicroseconds: 1_700_000_000_000_001)
        rejection(.processChanged) {
            try TargetResolver.validate(target, in: snapshot(cg: [cg(process: restarted)], ax: [ax(process: restarted)]), now: 10.2)
        }
    }

    @Test func testCGIDReuseWithNewAXObjectIsRejected() throws {
        let target = try issue(snapshot())
        rejection(.axElementChanged) { try TargetResolver.validate(target, in: snapshot(ax: [ax(token: UUID())]), now: 10.2) }
    }

    @Test func testClosedTargetIsNotReplacedWithAnotherWindow() throws {
        let target = try issue(snapshot())
        rejection(.notFound) { try TargetResolver.validate(target, in: snapshot(cg: [], ax: []), now: 10.2) }
        rejection(.notFound) { try TargetResolver.validate(target, in: snapshot(cg: [cg(id: 8)]), now: 10.2) }
    }

    @Test func testFrameTitleAndAXIdentifierDriftRequireNewTarget() throws {
        let target = try issue(snapshot()), moved = Rect(-490, 80, 400, 300)
        let changed = [snapshot(cg: [cg(frame: moved)], ax: [ax(frame: moved)]),
                       snapshot(cg: [cg(title: "new")], ax: [ax(title: "new")]),
                       snapshot(ax: [ax(identifier: "new-id")])]
        for s in changed { rejection(.metadataChanged) { try TargetResolver.validate(target, in: s, now: 10.2) } }
    }

    @Test func testFormerlyUniqueTargetBecomingAmbiguousIsRejected() throws {
        let target = try issue(snapshot())
        rejection(.ambiguous) {
            try TargetResolver.validate(target, in: snapshot(ax: [ax(), ax(token: UUID())]), now: 10.2)
        }
    }

    @Test func testExpiryUsesStartTimeAndDoesNotRenewOnValidation() throws {
        let s = snapshot(), target = try issue(s)
        #expect(throws: Never.self) { try TargetResolver.validate(target, in: s, now: 10.5) }
        rejection(.expired) { try TargetResolver.validate(target, in: s, now: 10.500001) }
        rejection(.expired) { _ = try TargetResolver.issue(windowID: 7, in: s, now: 10.6) }
    }

    @Test func testPartialTransientSlowAndClockInvalidSnapshotsAreRejected() {
        let invalid = [snapshot(consistent: false), snapshot(complete: false), snapshot(begin: 9.8, end: 10.1),
                       snapshot(begin: 10.1, end: 10), snapshot(begin: .nan), snapshot(begin: -1),
                       snapshot(end: 10.3), snapshot(topology: ""), snapshot(revision: 0)]
        for s in invalid { rejection(.invalidSnapshot) { _ = try issue(s) } }
        rejection(.invalidSnapshot) { _ = try TargetResolver.issue(windowID: 7, in: snapshot(), now: .infinity) }
        rejection(.invalidSnapshot) {
            _ = try TargetResolver.issue(windowID: 7, in: snapshot(), now: 10.2, policy: TargetPolicy(maximumAge: .nan))
        }
    }

    @Test func testSameRevisionWithRewrittenCaptureTimesIsRejected() throws {
        let target = try issue(snapshot())
        rejection(.invalidSnapshot) { try TargetResolver.validate(target, in: snapshot(end: 10.15), now: 10.2) }
    }

    @Test func testMinimizedHiddenUnknownVisibilityAndNonstandardWindowsAreNotTargets() {
        let disallowed = [snapshot(cg: [cg(onscreen: false)]), snapshot(cg: [cg(onscreen: nil)]),
                          snapshot(cg: [cg(layer: 3)]), snapshot(ax: [ax(minimized: true)]),
                          snapshot(ax: [ax(minimized: nil)]), snapshot(ax: [ax(subrole: "AXDialog")]),
                          snapshot(ax: [ax(subrole: nil)])]
        for s in disallowed { rejection(.notVisibleStandardWindow) { _ = try issue(s) } }
    }

    @Test func testStaleIdentityBlocksPreviewHitRatherThanClickingThrough() throws {
        let s = snapshot(), target = try issue(s)
        let eligible = (try? TargetResolver.validate(target, in: s, now: 11)) != nil
        let regions = [HitRegion(key: "stale-front", bounds: frame, frontToBackIndex: 0, identityEligible: eligible),
                       HitRegion(key: "valid-back", bounds: frame, frontToBackIndex: 1, identityEligible: true)]
        #expect(try HitTesting.hit(Point(-400, 100), regions: regions) == .blocked("stale-front"))
    }
}
