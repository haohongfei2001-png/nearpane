import Foundation
import Testing
@testable import NearpaneCore

struct DesktopReaderFrameTests {
    @Test func frameHasPortableBoundedNetworkLength() throws {
        #expect(try DesktopReaderFrame.header(length: 8192, limit: 8192) == Data([0, 0, 32, 0]))
        #expect(try DesktopReaderFrame.length(Data([0, 16, 0, 0]), limit: 1_048_576) == 1_048_576)
        for size in [-1, 0, 8193] {
            #expect(throws: (any Error).self) { try DesktopReaderFrame.header(length: size, limit: 8192) }
        }
        for header in [Data(), Data([0, 1]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255])] {
            #expect(throws: (any Error).self) { try DesktopReaderFrame.length(header, limit: 1_048_576) }
        }
    }

    private func issueFacts(frame: SurfaceRect = .init(width: 200, height: 100),
                            left: WindowMembership? = .known(recordIDs: ["12"])) -> CatalogIssueWindowFacts {
        func sample(_ frame: SurfaceRect) -> CatalogIssueWindowFacts.Sample {
            .init(pid: 31, birth: 90, frame: frame, reportedOnscreen: false,
                  observedOnscreen: false, active: false, ordered: nil, ownerUnhidden: true)
        }
        return .init(issueIndex: 0, number: 82, first: sample(.init(width: 200, height: 100)), second: sample(frame),
                     left: left, right: .unknown,
                     role: .init(firstPID: 31, source: .current, ownerRead: true, windowRead: true,
                                 everyNumberKnown: true, allRolesRead: true, ordinary: true, minimized: false, fullscreen: false))
    }

    private func issueSnapshot(_ facts: [CatalogIssueWindowFacts]? = nil) -> DesktopSnapshot {
        var snapshot = NativeDesktopPreviewTests().sample()
        snapshot.native = .init(population: .workWindows, accessibility: .available, spaces: .observed,
                                rows: [], windowLimitReached: false, beganUptime: 40, endedUptime: 41,
                                stageManagerEnabled: false, catalogComplete: false)
        snapshot.native?.catalogIssues = ["membershipChanged:pid=31,window=82"]
        snapshot.native?.catalogIssueWindows = facts
        return snapshot
    }

    @Test func catalogFailureFactsAreOptionalAndDoNotRepairTheFailedDirectory() throws {
        let old = issueSnapshot(), oldBytes = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        #expect((object["native"] as? [String: Any])?["catalogIssueWindows"] == nil)
        let legacy = try JSONDecoder().decode(DesktopSnapshot.self, from: oldBytes)
        #expect(legacy == old && legacy.isStructurallyValid && legacy.native?.catalogIssueWindows == nil)
        let current = issueSnapshot([issueFacts()])
        let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(current))
        #expect(decoded == current && decoded.isStructurallyValid)
        #expect(decoded.native?.catalogComplete == false && decoded.native?.catalogIssues == old.native?.catalogIssues)
        #expect(decoded.windows == old.windows && decoded.capabilities == old.capabilities)
    }

    @Test func catalogFailureFactsBoundMembershipAndCanEncodeInvalidDiagnosticFrames() throws {
        let ids = [String(repeating: "x", count: 81)] + (1...11).map(String.init)
        for invalid in [Double.infinity, Double.nan] {
            let facts = issueFacts(frame: .init(x: invalid, width: 200, height: 100), left: .known(recordIDs: ids))
            #expect(facts.second.frame == nil && !facts.second.frameValid)
            #expect(facts.left.state == .known && facts.left.recordCount == 12 && facts.left.recordIDs.count == 7)
            #expect(facts.left.truncated && facts.right.state == .unknown)
            let snapshot = issueSnapshot([facts])
            let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(snapshot))
            #expect(decoded == snapshot && decoded.isStructurallyValid)
        }
        #expect(CatalogIssueWindowFacts.Membership(nil).state == .unavailable)
    }

    @Test(arguments: ["samples", "issue-index", "role-owner", "membership-count", "membership-id", "frame"])
    func malformedCatalogFailureFactsCannotBypassTheWireBounds(_ mutation: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(issueSnapshot([issueFacts()]))) as? [String: Any])
        var native = try #require(object["native"] as? [String: Any])
        var samples = try #require(native["catalogIssueWindows"] as? [[String: Any]])
        switch mutation {
        case "samples": samples = Array(repeating: samples[0], count: CatalogIssueWindowFacts.limit + 1)
        case "issue-index": samples[0]["issueIndex"] = 32
        case "role-owner":
            var role = try #require(samples[0]["role"] as? [String: Any]); role["firstPID"] = 32; samples[0]["role"] = role
        case "membership-count", "membership-id":
            var left = try #require(samples[0]["left"] as? [String: Any])
            let ids = mutation == "membership-count" ? (1...9).map(String.init) : [String(repeating: "x", count: 81)]
            left["recordIDs"] = ids; left["recordCount"] = ids.count; left["truncated"] = false; samples[0]["left"] = left
        default:
            var sample = try #require(samples[0]["second"] as? [String: Any])
            var frame = try #require(sample["frame"] as? [String: Any]); frame["width"] = -1
            sample["frame"] = frame; samples[0]["second"] = sample
        }
        native["catalogIssueWindows"] = samples; object["native"] = native
        let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.isStructurallyValid)
    }
}
