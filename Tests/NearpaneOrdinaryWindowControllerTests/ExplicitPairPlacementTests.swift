import ApplicationServices
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneOrdinaryWindowController

struct ExplicitPairPlacementTests {
    let a = ManagedWindowID(pid: 71, launch: 100, number: 44, element: UUID())
    let b = ManagedWindowID(pid: 72, launch: 201, number: 45, element: UUID())
    let desktop = OrdinaryDesktopIdentity(display: "test", record: "41", uuid: UUID())
    let left = SurfaceRect(x: 100, y: 40, width: 500, height: 780)
    let right = SurfaceRect(x: 600, y: 40, width: 501, height: 780)
    var plan: OrdinaryWindowPairPlacement { .init(desktop: desktop, left: a, right: b, leftFrame: left, rightFrame: right) }

    @Test func oldWireRequestsHaveNoPairAndExplicitWritesRetainTheTwoExactSlots() throws {
        let normal = OrdinaryWindowRequest(.write, pid: a.pid, launch: a.launch, bundle: "fixture", id: a,
                                           expected: left, destination: right)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let original = try encoder.encode(normal)
        #expect((try JSONSerialization.jsonObject(with: original) as? [String: Any])?["pairPlacement"] == nil)
        #expect(try decoder.decode(OrdinaryWindowRequest.self, from: original).pairPlacement == nil)
        let scoped = OrdinaryWindowRequest(.write, pid: a.pid, launch: a.launch, bundle: "fixture", id: a,
                                           expected: right, destination: left, pairPlacement: plan)
        let reopened = try decoder.decode(OrdinaryWindowRequest.self, from: encoder.encode(scoped))
        #expect(reopened.desktop == nil && reopened.pairPlacement == plan)
        #expect(try PairPlacementGeometry.companion(plan, for: a, destination: left) == b)
        #expect(try PairPlacementGeometry.companion(plan, for: b, destination: right) == a)
        #expect(throws: Refusal.self) { try PairPlacementGeometry.companion(plan, for: a, destination: right) }
        let reused = ManagedWindowID(pid: a.pid, launch: a.launch + 1, number: a.number, element: a.element)
        #expect(throws: Refusal.self) { try PairPlacementGeometry.companion(plan, for: reused, destination: left) }
        let sameCG = ManagedWindowID(pid: b.pid, launch: b.launch, number: a.number, element: b.element)
        let duplicate = OrdinaryWindowPairPlacement(desktop: desktop, left: a, right: sameCG, leftFrame: left, rightFrame: right)
        #expect(throws: Refusal.self) { try PairPlacementGeometry.companion(duplicate, for: a, destination: left) }
        let overlap = OrdinaryWindowPairPlacement(desktop: desktop, left: a, right: b, leftFrame: left, rightFrame: left)
        #expect(throws: Refusal.self) { try PairPlacementGeometry.companion(overlap, for: a, destination: left) }
    }

    @Test func onlyAffirmativelyUnpublishedAllowsTryingAnUnwitnessedSize() {
        let target = SurfaceRect(width: 500, height: 600)
        let actual = OrdinaryMinimumEvidence.classify(.success, size: CGSize(width: 650, height: 300), declared: nil)
        #expect(!actual.permits(target, lastPublished: nil))
        #expect(actual.permits(.init(width: 651, height: 300), lastPublished: nil))
        #expect(OrdinaryMinimumEvidence.classify(.attributeUnsupported, size: nil, declared: nil).permits(target, lastPublished: nil))
        #expect(OrdinaryMinimumEvidence.classify(.noValue, size: nil, declared: ["AXSize"]).permits(target, lastPublished: nil))
        for unknown in [OrdinaryMinimumEvidence.classify(.noValue, size: nil, declared: nil),
                        .classify(.noValue, size: nil, declared: ["AXMinSize"]), .classify(.cannotComplete, size: nil, declared: []),
                        .classify(.success, size: CGSize(width: CGFloat.nan, height: 400), declared: nil)] {
            #expect(!unknown.permits(target, lastPublished: nil))
        }
        let priorFloor = SurfaceRect(width: 650, height: 300)
        let allowedAfterWithdrawal = OrdinaryMinimumEvidence.unpublished.permits(target, lastPublished: priorFloor)
        #expect(allowedAfterWithdrawal == false)
    }

    @Test func bothMembersMustStayExclusiveOnTheCurrentOrdinarySpaceAndBothAppearOnceInItsList() {
        let record: [String:Any] = ["id64": UInt64(41), "type": 0, "uuid": desktop.uuid.uuidString]
        func matches(_ fa: [UInt64], _ fb: [UInt64], _ reverse: [UInt32], current: UInt64 = 41) -> Bool {
            let current: [String:Any] = ["id64": current, "type": 0, "uuid": desktop.uuid.uuidString]
            let row: [String:Any] = ["Display Identifier": "test", "Current Space": current, "Spaces": [record]]
            return OrdinaryDesktopMembership.pairMatches(a.number, b.number, on: desktop, inventory: [row],
                                                         forwardA: fa, forwardB: fb, reverse: reverse)
        }
        #expect(matches([41], [41], [44,9,45]))
        #expect(!matches([42], [41], [44,45]))
        #expect(!matches([41], [42], [44,45]))
        #expect(!matches([41], [41,42], [44,45]))
        #expect(!matches([41], [41], [44]))
        #expect(!matches([41], [41], [44,44,45]))
        #expect(!matches([41], [41], [44,45], current: 42))
    }

    @Test func wideShortOriginalAndNarrowTallReadbackNeverInventNarrowShortFloor() {
        let original = SurfaceRect(x: 32, y: 150, width: 900, height: 460)
        let split = SurfaceRect(x: 600, y: 40, width: 501, height: 780)
        var sizes = OrdinaryWitnessedSizes()
        sizes.original = original
        #expect(!sizes.allowsOrdinary(split, currentFloor: sizes.minimum(at: original)))
        sizes.confirmed(split)
        #expect(sizes.minimum(at: split) == .init(width: 501, height: 780))
        #expect(sizes.allowsOrdinary(split, currentFloor: sizes.minimum(at: split)))
        #expect(sizes.allowsOrdinary(original, currentFloor: sizes.minimum(at: split)))
        #expect(!sizes.allowsOrdinary(.init(width: 501, height: 460), currentFloor: sizes.minimum(at: split)))
        #expect(!sizes.allowsOrdinary(.init(width: 1, height: 1), currentFloor: sizes.minimum(at: split)))
    }

    @Test func everyRouteSubmitsOnlyTheRequestedSizeIncludingTheReturnToOriginal() {
        let initial = SurfaceRect(x: 32, y: 150, width: 900, height: 460)
        for (from, to) in [(initial,right),(right,initial),(left,right),(right,right)] {
            let route = PairPlacementGeometry.steps(from: from, to: to)
            var previous = from, resized = 0
            for next in route {
                let size = previous.width != next.width || previous.height != next.height
                let position = previous.x != next.x || previous.y != next.y
                #expect(size != position)
                if size { resized += 1; #expect(next.width == to.width && next.height == to.height) }
                #expect(next.x >= min(from.x,to.x) && next.y >= min(from.y,to.y))
                #expect(next.x+next.width <= max(from.x+from.width,to.x+to.width))
                #expect(next.y+next.height <= max(from.y+from.height,to.y+to.height))
                previous = next
            }
            #expect(previous == to)
            #expect(resized == ((from.width == to.width && from.height == to.height) ? 0 : 1))
        }
    }

    @Test func acceptedAXSetWithNoMovementClampMismatchedSourcesOrMissingNotificationIsNotAVerifiedStep() {
        func read(_ ax: SurfaceRect, _ cg: SurfaceRect, notices: Int) -> OrdinaryGeometryReadback {
            .assess(from: left, to: right, ax: ax, cg: cg, notifications: notices)
        }
        #expect(read(left,left,notices:1) == .pending)
        #expect(read(right,left,notices:1) == .pending)
        #expect(read(right,right,notices:0) == .pending)
        #expect(read(right,right,notices:2) == .pending)
        let clamped = SurfaceRect(x: right.x, y: right.y, width: right.width + 24, height: right.height)
        #expect(read(clamped,clamped,notices:1) == .unexpected)
        #expect(read(right,right,notices:1) == .confirmed)
    }
}
