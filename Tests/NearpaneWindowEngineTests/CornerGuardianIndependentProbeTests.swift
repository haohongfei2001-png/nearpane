import CNearpaneWindowEngine
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneWindowEngine

struct CornerGuardianIndependentProbeTests {
    private typealias Probe = CornerGuardianIndependentProbe
    private let source = SurfaceRect(x: 31, y: 56, width: 100, height: 155)

    private func request() -> Probe.Request {
        .init(challenge: UUID(), hostPID: 111, hostBirth: 140, hostHash: String(repeating: "1", count: 40),
              childPID: 211, childBirth: 240, childHash: String(repeating: "2", count: 40),
              window: .init(pid: 317, birth: 384, number: 87), executable: "/test-fixture",
              fixtureHash: String(repeating: "3", count: 40), display: UUID(), space: UUID(), nativeID: 22, issued: 100)
    }

    private func nativeRead() -> NPGuardianFixtureObservation {
        var raw = NPGuardianFixtureObservation()
        raw.size = UInt32(MemoryLayout.size(ofValue: raw))
        raw.version = 1
        raw.held_in_caller = 1
        raw.released = 1
        raw.signatures_closed = 1
        raw.same_geometry = 1
        var read = NPGuardianFixtureRead()
        read.uptime_ns = 140
        read.signature = 1
        read.kernel_generation = 1
        read.cg_owner = 1
        read.cg_onscreen = 1
        read.ax_trusted = 1
        read.native_sample_attempted = 1
        read.same_retained = 1
        read.ax = .init(x: source.x, y: source.y, width: source.width, height: source.height)
        read.cg = read.ax
        raw.first = read
        raw.second = read
        raw.second.uptime_ns = 170
        return raw
    }

    private func packet(_ q: Probe.Request, _ edited: (inout [String: Any]) -> Void = { _ in },
                        native: (inout NPGuardianFixtureObservation) -> Void = { _ in }) throws -> Data {
        var r = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as? [String: Any])
        let requestOnly = ["issued", "executable"]
        for key in requestOnly { r.removeValue(forKey: key) }
        var raw = nativeRead()
        native(&raw)
        r["started"] = 120
        r["ended"] = 190
        r["responsibleBefore"] = q.childPID
        r["responsibleAfter"] = q.childPID
        r["axBefore"] = true
        r["axAfter"] = true
        r["receiptCode"] = 0
        r["observation"] = withUnsafeBytes(of: &raw) { Data($0).base64EncodedString() }
        edited(&r)
        return try JSONSerialization.data(withJSONObject: r)
    }

    @Test func authenticProtocolPreservesTheActualReaderAndReleasesItsReference() throws {
        let q = request()
        let evidence = try Probe.decode(packet(q), for: q, registeredFrame: source, now: 200)
        #expect(evidence.host.pid == q.hostPID && evidence.guardian.pid == q.childPID)
        #expect(evidence.temporaryRetention == "ORIGINAL_OBJECT_OBSERVED_TWICE_THEN_RELEASED")
        #expect(evidence.matchesHostRegisteredGeometry == true)
        #expect(evidence.samples.map(\.uptimeNS) == [140, 170])
        #expect(evidence.samples.allSatisfy { $0.guardianAXTrusted && $0.heldGuardianReferenceMatches })
    }

    @Test func effectiveGrantCannotBeReportedAsIndependentWhenAttributedElsewhere() throws {
        let q = request()
        let attributed = try packet(q, { $0["responsibleBefore"] = q.hostPID; $0["responsibleAfter"] = q.hostPID },
                                    native: {
            $0.held_in_caller = 0
            $0.released = 0
            $0.first.native_sample_attempted = 0
            $0.second.native_sample_attempted = 0
            $0.first.same_retained = 0
            $0.second.same_retained = 0
        })
        let r = try Probe.decode(attributed, for: q, registeredFrame: source, now: 200)
        #expect(r.effectiveAccessibility == "GRANTED_TO_CALLING_PROCESS")
        #expect(r.permissionAttribution == "ANOTHER_PROCESS_IS_RESPONSIBLE")
        #expect(r.temporaryRetention == "NOT_ATTEMPTED_WITH_UNCERTAIN_ATTRIBUTION")
        let borrowed = try Probe.decode(packet(q, {
            $0["responsibleBefore"] = q.hostPID; $0["responsibleAfter"] = q.hostPID
        }), for: q, registeredFrame: source, now: 200)
        #expect(borrowed.heldInGuardian && borrowed.temporaryObjectReleased)
        #expect(borrowed.temporaryRetention == "ORIGINAL_OBJECT_READ_DURING_PARENT_GRANT")
        #expect(borrowed.permissionAttribution == "ANOTHER_PROCESS_IS_RESPONSIBLE")
        let unknown = Probe.permission(child: q.childPID, before: true, after: true, responsibleBefore: -1, responsibleAfter: -1)
        #expect(unknown.effective == "GRANTED_TO_CALLING_PROCESS" && unknown.attribution == "UNKNOWN")
        let changed = try packet(q, { $0["responsibleAfter"] = q.hostPID })
        let changedRead = try Probe.decode(changed, for: q, registeredFrame: source, now: 200)
        #expect(changedRead.temporaryRetention == "UNKNOWN_ATTRIBUTION_CHANGED_DURING_READ" && changedRead.heldInGuardian)
    }

    @Test func revokedPermissionMissingHandleOrFailedScopeCannotConfirmRetention() throws {
        let q = request()
        for mode in ["revoked", "lostObject", "mismatchedFrame", "scopeDenied", "noRelease"] {
            let data = try packet(q, { if mode == "revoked" { $0["axAfter"] = false } }, native: {
                switch mode {
                case "lostObject": $0.second.same_retained = 0
                case "mismatchedFrame": $0.same_geometry = 0
                case "scopeDenied": $0.second.native_sample_code = 5
                case "noRelease": $0.released = 0
                default: break
                }
            })
            let evidence = try Probe.decode(data, for: q, registeredFrame: source, now: 200)
            #expect(evidence.temporaryRetention == "UNKNOWN")
        }
        let other = SurfaceRect(x: 45, y: 56, width: 100, height: 155)
        let moved = try Probe.decode(packet(q), for: q, registeredFrame: other, now: 200)
        #expect(moved.matchesHostRegisteredGeometry == false)
    }

    @Test func receiptsRejectForeignChallengeSiblingReplacedProcessOrFakeClocks() throws {
        let q = request()
        let changes: [[String: Any]] = [
            ["challenge": UUID().uuidString], ["hostPID": 114], ["hostBirth": 144], ["hostHash": "new"],
            ["childPID": 214], ["childBirth": 243], ["childHash": "other"], ["fixtureHash": "other"],
            ["responsibleBefore": 918], ["axBefore": false],
            ["space": UUID().uuidString], ["nativeID": 18],
            ["window": ["pid": 317, "birth": 384, "number": 86]], ["observation": "AA=="],
            ["started": 99], ["ended": 201],
        ]
        for delta in changes {
            let data = try packet(q, { $0.merge(delta) { _, new in new } })
            #expect(throws: (any Error).self) { try Probe.decode(data, for: q, registeredFrame: source, now: 200) }
        }
        let outOfRange = try packet(q, native: { $0.first.uptime_ns = 90 })
        #expect(throws: (any Error).self) { try Probe.decode(outOfRange, for: q, registeredFrame: source, now: 200) }
    }

    @Test @MainActor func unregisteredFixtureNeverStartsAChildOrChangesAWAL() async {
        let u = URL(fileURLWithPath: "/")
        let host = CornerGuardianFixtureReport.sample(pid: 0, birth: 0, number: 0, executable: u, cdhash: "",
                                                     scope: nil, nativeID: nil)
        let r = await Probe.sample(host: host, executable: u)
        #expect(r.reason == "hostDidNotConfirmExactlyOneRegisteredFixtureWindow")
        #expect(r.status == "BLOCKED" && r.evidence == nil && r.childExit == nil)
        #expect(r.currentWALRead == "NOT_RUN" && r.park == "NOT_RUN")
        #expect(r.windowWrites == 0 && !r.mayPark && r.permissionRequests == 0)
    }
}
