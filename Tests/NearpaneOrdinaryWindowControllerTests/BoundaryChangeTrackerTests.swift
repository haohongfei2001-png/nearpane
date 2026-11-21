import Foundation
import NearpaneCore
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct BoundaryChangeTrackerTests {
    private let frame = SurfaceRect(x: -824, y: 80, width: 320, height: 240)
    private let otherFrame = SurfaceRect(x: -790, y: 80, width: 320, height: 240)

    @Test func observationRequiresAnEventAQuietIntervalAndReleasedMouse() throws {
        var tracker = BoundaryChangeTracker()
        #expect(!tracker.pending)
        #expect(throws: Refusal.self) { try tracker.offer(frame, at: 10, buttonDown: false) }
        tracker.received(at: 10)
        #expect(tracker.pending)
        #expect(throws: Refusal.self) { try tracker.offer(frame, at: 10.24, buttonDown: false) }
        #expect(throws: Refusal.self) { try tracker.offer(frame, at: 11, buttonDown: true) }
        let ticket = try tracker.offer(frame, at: 11.01, buttonDown: false)
        #expect(tracker.revision == ticket)
        #expect(throws: Refusal.self) { try tracker.consume(ticket, frame: frame, at: 11.02, buttonDown: true) }
        try tracker.consume(ticket, frame: frame, at: 11.04, buttonDown: false)
        #expect(!tracker.pending)
        #expect(throws: Refusal.self) { try tracker.consume(ticket, frame: frame, at: 11.05, buttonDown: false) }
    }

    @Test func validationRequiresFreshMonotonicTimeAndExactOfferedFrame() throws {
        var tracker = BoundaryChangeTracker()
        tracker.received(at: 5)
        let ticket = try tracker.offer(frame, at: 5.5, buttonDown: false)
        for t in [Double.nan, .infinity, 5.49, 8.51] {
            #expect(throws: Refusal.self) { try tracker.validate(ticket, frame: frame, at: t, buttonDown: false) }
        }
        #expect(throws: Refusal.self) { try tracker.validate(ticket, frame: otherFrame, at: 5.6, buttonDown: false) }
        #expect(throws: Refusal.self) { try tracker.validate(UUID(), frame: frame, at: 5.6, buttonDown: false) }
        try tracker.validate(ticket, frame: frame, at: 8.5, buttonDown: false)
    }

    @Test func laterEventInvalidatesTicketEvenWhenGeometryReturnsToSameFrame() throws {
        var tracker = BoundaryChangeTracker()
        tracker.received(at: 4)
        let previous = try tracker.offer(frame, at: 4.4, buttonDown: false)
        tracker.received(at: 4.5)
        #expect(throws: Refusal.self) { try tracker.offer(frame, at: 4.6, buttonDown: false) }
        let current = try tracker.offer(frame, at: 4.9, buttonDown: false)
        #expect(previous != current)
        #expect(throws: Refusal.self) { try tracker.consume(previous, frame: frame, at: 5, buttonDown: false) }
        try tracker.consume(current, frame: frame, at: 5, buttonDown: false)
    }

    @Test func invalidWindowFramesNeverCreateAUsableTicket() throws {
        var tracker = BoundaryChangeTracker()
        tracker.received(at: 20)
        let revision = try #require(tracker.revision)
        let invalid = SurfaceRect(x: 0, y: 0, width: 0, height: 200)
        #expect(throws: Refusal.self) { try tracker.offer(invalid, at: 21, buttonDown: false) }
        #expect(throws: Refusal.self) { try tracker.validate(revision, frame: invalid, at: 21.1, buttonDown: false) }
    }

    @Test func physicalOwnershipPermitsPartialOverflowOnlyOnTheEnrolledDisplay() {
        let display = BoundaryDisplayWitness(id: "side", bounds: .init(x: -800, y: 0, width: 800, height: 1280))
        #expect(boundaryGeometryPermitted(frame, enrolled: display, current: display, intersecting: ["side"]))
        for intersections in [[], ["main"], ["side","main"], ["side","side"]] as [[String]] {
            #expect(!boundaryGeometryPermitted(frame, enrolled: display, current: display, intersecting: intersections))
        }
        let fullyOff = SurfaceRect(x: -1120, y: 80, width: 320, height: 240)
        #expect(!boundaryGeometryPermitted(fullyOff, enrolled: display, current: display, intersecting: ["side"]))
    }

    @Test func matchingCoordinatesCannotInheritAReplacedOrReconfiguredDisplay() {
        let display = BoundaryDisplayWitness(id: "side", bounds: .init(x: -800, y: 0, width: 800, height: 1280))
        let replaced = BoundaryDisplayWitness(id: "replacement", bounds: display.bounds)
        let rotated = BoundaryDisplayWitness(id: "side", bounds: .init(x: -1280, y: 0, width: 1280, height: 800))
        for current in [replaced, rotated] {
            #expect(!boundaryGeometryPermitted(frame, enrolled: display, current: current, intersecting: [current.id]))
        }
    }
}
