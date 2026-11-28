import Foundation
import NearpaneCore
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct TargetedCurrentFocusTests {
    let display = UUID().uuidString, a = UUID(), b = UUID(), fingerprint = String(repeating: "a", count: 64)
    var order: [SpaceRecord] { [.init(id: "41", isCurrent: true, ordinaryUUID: a), .init(id: "53", isCurrent: false, fullscreenUUID: b)] }
    var scope: OrdinaryFocusScope { OrdinaryFocusScope(display: display, topology: fingerprint, order: order)! }

    @Test func unchangedInventoryAndKnownChangesAreDistinctFromUnreadableEvidence() {
        let first: [String: Any] = ["id64": UInt64(41), "type": 0, "uuid": a.uuidString]
        let second: [String: Any] = ["id64": UInt64(53), "type": 4, "uuid": b.uuidString]
        func result(_ current: [String: Any], _ records: [[String: Any]], _ owner: String? = nil) -> OrdinaryFocusScopeEvidence {
            let row: [String: Any] = ["Display Identifier": owner ?? display, "Current Space": current, "Spaces": records]
            return CurrentFocusScope.inventory([row], for: scope)
        }
        #expect(result(first, [first, second]) == .confirmed)
        #expect(result(first, [second, first]) == .changed)
        #expect(result(first, [first]) == .changed)
        #expect(result(first, [first, second], UUID().uuidString) == .changed)
        #expect(result(second, [first, second]) == .changed)
        var other = first
        other["uuid"] = UUID().uuidString
        #expect(result(other, [first, second]) == .changed)
        #expect(result(first, [other, second]) == .changed)
        other = second
        other["type"] = 0
        #expect(result(first, [first, other]) == .changed)
        other = second
        other.removeValue(forKey: "uuid")
        #expect(result(first, [first, other]) == .fullRosterRequired)
        #expect(result([:], [first, second]) == .fullRosterRequired)
        #expect(CurrentFocusScope.inventory(nil, for: scope) == .fullRosterRequired)
        #expect(CurrentFocusScope.topology(fingerprint, for: scope) == .confirmed)
        #expect(CurrentFocusScope.topology(String(repeating: "f", count: 64), for: scope) == .changed)
        #expect(CurrentFocusScope.topology(nil, for: scope) == .fullRosterRequired)
    }

    @Test func bothDirectionsAndTheOriginalAXAndSurfaceMustAgree() {
        func membership(_ forward: [UInt64]?, _ reverse: [UInt32]?) -> OrdinaryFocusScopeEvidence {
            CurrentFocusScope.membership(number: 75, record: 41, forward: forward, reverse: reverse)
        }
        #expect(membership([41], [100, 75]) == .confirmed)
        #expect(membership(nil, [75]) == .fullRosterRequired)
        #expect(membership([41], nil) == .fullRosterRequired)
        #expect(membership([41, 53], nil) == .changed)
        #expect(membership([53], [75]) == .changed)
        #expect(membership(nil, [100]) == .changed)
        #expect(membership([41], [75, 75]) == .fullRosterRequired)
        #expect(CurrentFocusScope.decide(.fullRosterRequired, .changed) == .changed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: [(75, true), (80, false)]) == .confirmed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: [(75, false)]) == .changed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: [(75, true), (75, false)]) == .changed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: [(81, true), (nil, false)]) == .changed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: []) == .changed)
        #expect(CurrentFocusScope.retainedIdentity(75, candidates: [(nil, true)]) == .fullRosterRequired)
        let frame = SurfaceRect(width: 100, height: 80)
        func surface(_ owner: Int32 = 17, layer: Int = 0, visible: Bool = true, drawn: Bool = true, actual: SurfaceRect? = nil) -> OrdinaryFocusScopeEvidence {
            CurrentFocusScope.surface(owner: owner, pid: 17, layer: layer, visible: visible, drawn: drawn, frame: actual ?? frame, expected: frame)
        }
        #expect(surface() == .confirmed)
        #expect(surface(18) == .changed)
        #expect(surface(layer: 3) == .changed)
        #expect(surface(visible: false) == .changed)
        #expect(surface(drawn: false) == .changed)
        #expect(surface(actual: .init(x: 1, width: 100, height: 80)) == .changed)
    }

    @Test func theFreshStepGrantIsBoundToUninterruptedInputAndPostGrantSystemEvidence() throws {
        var input: [UInt32] = [0, 0, 0, 0, 0], events = [String]()
        try CurrentFocusScope.authorizeStep(input: { input }, permit: { events.append("intent") }, revalidate: { events.append("read") })
        #expect(events == ["intent", "read"])
        #expect(throws: Refusal.self) {
            try CurrentFocusScope.authorizeStep(input: { input }, permit: {}, revalidate: { input[3] += 1 })
        }
        #expect(throws: CancellationError.self) {
            try CurrentFocusScope.authorizeStep(input: { input }, permit: { throw CancellationError() },
                                                revalidate: { Issue.record("A canceled intent cannot reach the post-grant read") })
        }
        #expect(throws: Refusal.self) {
            try CurrentFocusScope.authorizeStep(input: { input }, permit: {}, revalidate: { throw Refusal("changed") })
        }
    }

    @Test func archivedPairGeometryMissingPublicFlagsAndHardConflictsHaveDistinctReasons() throws {
        // P2 scoped-final measured the target's exact AX/CG rectangle before/after the failed click.
        let rect = SurfaceRect(x: 585, y: 367, width: 320, height: 193)
        var trace = CurrentFocusScope.Trace()
        #expect(CurrentFocusScope.surface(owner: 42, pid: 42, layer: 0, visible: nil, drawn: true,
                                          frame: rect, expected: rect, trace: trace) == .fullRosterRequired)
        #expect(trace.findings.map(\.reason) == [.surfaceVisibility])
        #expect(trace.findings.first?.observed == nil)
        trace = CurrentFocusScope.Trace()
        #expect(CurrentFocusScope.surface(owner: 42, pid: 42, layer: 0, visible: false, drawn: nil,
                                          frame: rect, expected: rect, trace: trace) == .changed)
        #expect(trace.findings.contains { $0.reason == .surfaceVisibility && $0.state == .changed && $0.observed == 0 })
        trace = CurrentFocusScope.Trace()
        #expect(CurrentFocusScope.surface(owner: 41, pid: 42, layer: 0, visible: nil, drawn: nil,
                                          frame: rect, expected: rect, trace: trace) == .changed)
        #expect(trace.findings.contains { $0.reason == .surfaceOwner && $0.state == .changed })
        let screen = SurfaceRect(width: 1470, height: 956)
        let usable = SurfaceRect(x: 0, y: 33, width: 1470, height: 923)
        let published = DisplayObservation(id: display, frame: screen, rotationDegrees: 0, backingScale: 2, usable: usable)
        let expected = try #require(OrdinaryFocusScope(display: display, topology: fingerprint, order: order,
                                                       physicalDisplay: published, separateSpaces: true))
        var actual = published
        actual.usable = screen
        trace = CurrentFocusScope.Trace()
        #expect(CurrentFocusScope.physical(([actual], true, "other"), for: expected, point: .opening, trace: trace) == .changed)
        #expect(trace.findings.map(\.reason) == [.usableFrame, .physicalTopology])
        #expect(trace.findings.first?.observed == 10)
        let encoded = String(decoding: try JSONEncoder().encode(trace.findings), as: UTF8.self)
        #expect(!encoded.contains(display) && !encoded.contains("1470"))
    }

    @Test func probeOnlyAcceptsTheNonDispatchingListInspectionAndRelease() {
        let allowed: [OrdinaryWindowRequest.Action] = [.list, .inspectFocusScope, .release]
        let readOnly = allowed.allSatisfy { $0.allowedForFocusScopeProbe }
        #expect(readOnly)
        let denied: [OrdinaryWindowRequest.Action] = [.focusCurrent, .write, .prepare, .verify, .refresh, .observeBoundary,
            .acknowledgeBoundary, .watchCreated, .takeCreated, .endCreated, .checkFocusPermission, .requestFocusPermission]
        #expect(denied.allSatisfy { !$0.allowedForFocusScopeProbe })
    }

    @Test func onlyOneCurrentOrdinaryRecordCanBeEnrolledAndOnlyTheSelectedControlGetsTheRequest() throws {
        #expect(OrdinaryFocusScope(display: display, topology: "partial", order: order) == nil)
        #expect(OrdinaryFocusScope(display: display, topology: fingerprint, order: [order[0], order[0]]) == nil)
        #expect(OrdinaryFocusScope(display: display, topology: fingerprint, order: [.init(id: "53", isCurrent: true, fullscreenUUID: b)]) == nil)
        #expect(OrdinaryFocusScope(display: display, topology: fingerprint, order: [.init(id: "41", isCurrent: true)]) == nil)
        let id = ManagedWindowID(pid: 17, launch: 746, number: 75, element: UUID())
        let request = OrdinaryWindowRequest(.inspectFocusScope, pid: id.pid, launch: id.launch, bundle: "org.example.fixture",
            id: id, expected: .init(width: 100, height: 80), focusDisplay: display, focusSpace: "41", focusScope: scope)
        let returned = try JSONDecoder().decode(OrdinaryWindowRequest.self, from: JSONEncoder().encode(request))
        #expect(returned.id == id && returned.focusScope == scope && returned.destination == nil)
        #expect(!returned.action.allowedForStillPreview && returned.action != .focusCurrent)
        let legacy = OrdinaryWindowRequest(.list, pid: id.pid, launch: id.launch, bundle: "org.example.fixture")
        #expect(try JSONDecoder().decode(OrdinaryWindowRequest.self, from: JSONEncoder().encode(legacy)).focusScope == nil)
    }
}
