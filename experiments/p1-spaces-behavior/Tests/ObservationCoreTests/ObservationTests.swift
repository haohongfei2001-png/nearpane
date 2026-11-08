import Testing
import Foundation
import Darwin
@testable import ObservationCore

struct ObservationTests {
    private func stable(_ state: ObservationState = SyntheticFixture.state()) throws -> Assessment {
        var detector = try StableDetector()
        _ = try detector.ingest(SyntheticFixture.sample(1, state: state))
        _ = try detector.ingest(SyntheticFixture.sample(2, state: state))
        return try detector.ingest(SyntheticFixture.sample(3, state: state))
    }

    @Test func testRequiresRepeatedIdenticalSamplesDespiteDifferentTimestamps() throws {
        var detector = try StableDetector()
        #expect(try detector.ingest(SyntheticFixture.sample(1)).stability == .transient)
        #expect(try detector.ingest(SyntheticFixture.sample(2)).stability == .transient)
        let result = try detector.ingest(SyntheticFixture.sample(3))
        #expect(result.stability == .stable)
        #expect(result.identicalSamples == 3)
        #expect(result.candidateSinceRevision == 1)
        #expect(result.latestStableRevision == 3)
    }

    @Test func testAlternatingCurrentSpacesNeverBecomeStable() throws {
        var detector = try StableDetector()
        for revision in 1...10 {
            var state = SyntheticFixture.state()
            state.boundary.inventory.scopes[0].currentSpaceID = revision.isMultiple(of: 2) ? 8_001 : 8_002
            #expect(try detector.ingest(SyntheticFixture.sample(revision, state: state)).stability == .transient)
        }
    }

    @Test func testTopologyChangeInvalidatesStableAndRestartsEpoch() throws {
        var detector = try StableDetector()
        for revision in 1...3 { _ = try detector.ingest(SyntheticFixture.sample(revision)) }
        var state = SyntheticFixture.state()
        state.boundary.topology.displays[0].rotation = 90
        let result = try detector.ingest(SyntheticFixture.sample(4, state: state))
        #expect(result.stability == .transient)
        #expect(result.latestStableRevision == nil)
        #expect(result.topologyEpoch == 2)
        #expect(result.transitionReasons.contains("topology_changed"))
        _ = try detector.ingest(SyntheticFixture.sample(5, state: state))
        #expect(try detector.ingest(SyntheticFixture.sample(6, state: state)).stability == .stable)
    }

    @Test func testWindowOnscreenMembershipGeometryAndZOrderChangesResetStability() throws {
        let mutations: [(inout ObservationState) -> Void] = [
            { $0.windows[0].metadata.onscreen = false },
            { $0.windows[0].membership = Membership(status: .known, spaceIDs: [8_002]) },
            { $0.windows[0].metadata.bounds?.x = 99 },
            { $0.windows.append($0.windows[0]) },
            { $0.boundary.separateSpaces = true }
        ]
        for mutate in mutations {
            var detector = try StableDetector()
            for revision in 1...3 { _ = try detector.ingest(SyntheticFixture.sample(revision)) }
            var state = SyntheticFixture.state(); mutate(&state)
            let result = try detector.ingest(SyntheticFixture.sample(4, state: state))
            #expect(result.stability == .transient)
            #expect(result.latestStableRevision == nil)
        }
    }

    @Test func testIntraSampleChangesNeverContributeToStability() throws {
        var detector = try StableDetector()
        for revision in 1...4 {
            var sample = try SyntheticFixture.sample(revision)
            sample.afterBoundary.topology.displays[0].bounds.width = 1000
            sample.afterBoundary.inventory.scopes[0].currentSpaceID = 8_002
            sample.afterWindowFingerprint = "DIFFERENT"
            let result = try detector.ingest(sample)
            #expect(result.stability == .transient)
            #expect(result.identicalSamples == 0)
            #expect(result.transitionReasons.contains("topology_changed_during_sample"))
            #expect(result.transitionReasons.contains("inventory_changed_during_sample"))
            #expect(result.transitionReasons.contains("window_list_changed_during_sample"))
        }
    }

    @Test func testUnknownScopeIsNeverMappedToMainDisplay() throws {
        var state = SyntheticFixture.state()
        state.boundary.inventory.scopes[0].identifier = "Main"
        let result = try stable(state)
        #expect(result.stability == .stableIncomplete)
        #expect(result.incompleteness.contains("scope_display_unknown"))
        #expect(state.boundary.inventory.scopes[0].matchedDisplay(in: state.boundary.topology) == nil)
    }

    @Test func testMissingOrOutsideCurrentSpaceRemainsUnknown() throws {
        var state = SyntheticFixture.state()
        state.boundary.inventory.scopes[0].currentSpaceID = nil
        #expect(try stable(state).incompleteness.contains("current_space_missing"))
        #expect(try stable(state).stability == .stableIncomplete)
        state.boundary.inventory.scopes[0].currentSpaceID = 99_999
        #expect(try stable(state).incompleteness.contains("current_space_outside_scope"))
    }

    @Test func testEveryUnknownMembershipCategoryStaysUnknown() throws {
        for status: MembershipStatus in [.empty, .nullResult, .unavailable, .malformed, .notQueried] {
            var state = SyntheticFixture.state()
            state.windows[0].membership = Membership(status: status)
            let result = try stable(state)
            #expect(result.stability == .stableIncomplete)
            #expect(result.incompleteness.contains("window_membership_unknown"))
            #expect(state.windows[0].membership.spaceIDs.isEmpty)
        }
        var state = SyntheticFixture.state()
        state.windows[0].membership = Membership(status: .known, spaceIDs: [8_001, 99_999])
        #expect(try stable(state).incompleteness.contains("membership_outside_inventory"))
    }

    @Test func testNullEmptyMalformedAnd64BitIDsStayDistinct() {
        #expect(parseInventory(nil).status == .nullResult)
        #expect(parseInventory([Any]()).status == .ok)
        #expect(parseInventory(["bad"]).status == .malformed)
        #expect(parseMembership(nil).status == .nullResult)
        #expect(parseMembership([Any]()).status == .empty)
        #expect(parseMembership([NSNumber(value: true)]).status == .malformed)
        #expect(parseMembership([NSNumber(value: -1)]).status == .malformed)
        #expect(parseMembership([NSNumber(value: 1.25)]).status == .malformed)
        #expect(parseMembership(["123"]).status == .malformed)
        let large = UInt64.max - 10
        #expect(parseMembership([NSNumber(value: large)]).spaceIDs == [large])
        #expect(parseMembership([NSNumber(value: 2), "bad"]).spaceIDs == [2])
        #expect(parseMembership([NSNumber(value: 2), "bad"]).status == .malformed)
        #expect(parseMembership([NSNumber(value: 2), NSNumber(value: 2)]).spaceIDs == [2, 2])
    }

    @Test func testParserPreservesMissingCurrentAndMalformedSpaceRecords() {
        let parsed = parseInventory([["Display Identifier": "Main", "Spaces": [["id64": NSNumber(value: 8001), "type": NSNumber(value: 0)], ["id64": "bad"]]]])
        #expect(parsed.status == .malformed)
        #expect(parsed.scopes[0].currentSpaceID == nil)
        #expect(parsed.scopes[0].spaces.count == 2)
        #expect(parsed.scopes[0].spaces[1].id == nil)
    }

    @Test func testGapsOutOfOrderAndSlowSamplesInvalidate() throws {
        var detector = try StableDetector()
        for revision in 1...3 { _ = try detector.ingest(SyntheticFixture.sample(revision)) }
        let gap = try detector.ingest(SyntheticFixture.sample(10))
        #expect(gap.identicalSamples == 1)
        #expect(gap.transitionReasons.contains("sampling_gap"))
        let outOfOrder = try detector.ingest(SyntheticFixture.sample(9))
        #expect(outOfOrder.identicalSamples == 0)
        #expect(outOfOrder.transitionReasons.contains("out_of_order_sample"))
        var slow = try SyntheticFixture.sample(11)
        slow.endedUptimeNS += 6_000_000_000
        #expect(try detector.ingest(slow).transitionReasons.contains("sample_too_slow"))
    }

    @Test func testMarkersInvalidateAndNeverSupplyObservedState() throws {
        var detector = try StableDetector()
        for revision in 1...3 { _ = try detector.ingest(SyntheticFixture.sample(revision)) }
        detector.operatorMarker()
        let result = try detector.ingest(SyntheticFixture.sample(4))
        #expect(result.identicalSamples == 1)
        #expect(result.latestStableRevision == nil)
        #expect(result.transitionReasons.contains("operator_marker"))
        var duringRead = try SyntheticFixture.sample(5)
        duringRead.observerIssues = ["operator_marker_during_sample"]
        #expect(try detector.ingest(duringRead).identicalSamples == 0)
    }

    @Test func testSanitizerRemovesIdentitiesNotesAndRawFingerprints() throws {
        let sample = try SyntheticFixture.sample(1)
        var detector = try StableDetector()
        let assessment = try detector.ingest(sample)
        let event = LogEvent(sessionID: "test", sequence: 0, kind: "sample", sample: sample, assessment: assessment)
        let sanitizer = Sanitizer()
        let safe = try sanitizer.data(for: event)
        let text = String(decoding: safe, as: UTF8.self)
        for secret in ["SYNTHETIC-PRIVATE-DISPLAY-UUID", "SYNTHETIC-PRIVATE-NAME", "\"id\":", "\"pid\":", "\"spaceIDs\":", assessment.topologyFingerprint, assessment.stateFingerprint] {
            #expect(!(text.contains(secret)))
        }
        #expect(try sanitizer.data(for: event) == safe)
        #expect(try Sanitizer().data(for: event) != safe) // Fresh per-session HMAC key.
        let marker = LogEvent(sessionID: "test", sequence: 1, kind: "operatorMarker",
                              marker: OperatorMarker(kind: .note, note: "SENSITIVE-DISPLAY-AND-WINDOW-NOTE"))
        let markerText = String(decoding: try sanitizer.data(for: marker), as: UTF8.self)
        #expect(!(markerText.contains("SENSITIVE-DISPLAY-AND-WINDOW-NOTE")))
        #expect(markerText.contains("operator_claim_only"))
    }

    @Test func testMarkerInputFragmentationOversizeAndIncompleteEOF() throws {
        let marker = OperatorMarker(kind: .beforeAction, action: .nativeSpaceChange, display: .A, trial: 1)
        let data = try canonicalData(marker)
        var lines = MarkerLines()
        #expect(lines.consume(data.prefix(10)).isEmpty)
        let result = lines.consume(data.dropFirst(10) + Data([10]))
        #expect(try result[0].get() == marker)
        #expect(lines.consume(Data(repeating: 65, count: 9000) + Data([10])).count == 1)
        #expect(lines.consume(Data("{\"kind\":".utf8)).isEmpty)
        #expect(lines.finish().count == 1)
        #expect(lines.consume(data + Data([10])).count == 1)
    }

    @Test func testPrivateLogPermissionsNoOverwriteSymlinkAndOutputCap() throws {
        let parent = "/private/tmp/nearpane-log-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let path = parent + "/session"
        let log = try PrivateSessionLog(directory: path)
        try log.append(kind: "sessionStart")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        for file in ["raw.jsonl", "sanitized.jsonl"] {
            #expect(try FileManager.default.attributesOfItem(atPath: path + "/" + file)[.posixPermissions] as? Int == 0o600)
        }
        #expect(throws: (any Error).self) { try PrivateSessionLog(directory: path) }
        let link = parent + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        #expect(throws: (any Error).self) { try PrivateSessionLog(directory: link) }
        let capped = try PrivateSessionLog(directory: parent + "/capped", maxBytes: 1)
        #expect(throws: (any Error).self) { try capped.append(kind: "sessionStart") }
        #expect(try Data(contentsOf: URL(fileURLWithPath: parent + "/capped/raw.jsonl")).count == 0)
        _ = chmod(path + "/raw.jsonl", 0o644)
        #expect(throws: (any Error).self) { try log.append(kind: "sample") }
    }

    @Test func testZOrderAndOSBuildArePartOfStateFingerprint() throws {
        var state = SyntheticFixture.state()
        var second = state.windows[0]
        second.metadata.id = 42
        state.windows.append(second)
        var detector = try StableDetector(requiredSamples: 2)
        _ = try detector.ingest(SyntheticFixture.sample(1, state: state))
        #expect(try detector.ingest(SyntheticFixture.sample(2, state: state)).stability == .stable)
        state.windows.reverse()
        #expect(try detector.ingest(SyntheticFixture.sample(3, state: state)).stability == .transient)
        _ = try detector.ingest(SyntheticFixture.sample(4, state: state))
        state.osBuild = "DIFFERENT-SYNTHETIC-BUILD"
        #expect(try detector.ingest(SyntheticFixture.sample(5, state: state)).stability == .transient)
    }

    @Test func testUnavailableInventoryAndMissingDisplayScopeCannotBeComplete() throws {
        var state = SyntheticFixture.state()
        state.boundary.inventory = Inventory(status: .unavailable, scopes: [])
        let result = try stable(state)
        #expect(result.stability == .stableIncomplete)
        #expect(result.incompleteness.contains("inventory_unavailable"))
        #expect(result.incompleteness.contains("display_scope_unresolved"))
    }

    @Test func testTopologyFingerprintCoversArrangementScaleAndMirror() throws {
        let original = SyntheticFixture.state().boundary.topology
        let originalHash = try fingerprint(original)
        var changed = original
        changed.displays[0].bounds.x = -1920
        #expect(try fingerprint(changed) != originalHash)
        changed = original; changed.displays[0].scale = 2
        #expect(try fingerprint(changed) != originalHash)
        changed = original; changed.displays[0].mirrorsDisplay = 99
        #expect(try fingerprint(changed) != originalHash)
        changed = original; changed.displays[0].isMain = false
        #expect(try fingerprint(changed) != originalHash)
    }

    @Test func testConfigurationCannotAllowOneSampleStability() {
        #expect(throws: (any Error).self) { try StableDetector(requiredSamples: 1) }
        #expect(throws: (any Error).self) { try StableDetector(maxGapNS: 0) }
    }
}
