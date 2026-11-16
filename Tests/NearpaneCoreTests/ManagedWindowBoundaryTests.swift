import Foundation
import Testing
@testable import NearpaneCore

struct ManagedWindowBoundaryTests {
    let work = SurfaceRect(x: -700, y: 24, width: 700, height: 1200)
    let minimum = SurfaceRect(width: 100, height: 80)

    @Test func eachEdgeAndCornerIsClampedWithoutResizing() throws {
        let samples: [(SurfaceRect, SurfaceRect)] = [
            (.init(x: -720, y: 60, width: 200, height: 120), .init(x: -700, y: 60, width: 200, height: 120)),
            (.init(x: -180, y: 60, width: 200, height: 120), .init(x: -200, y: 60, width: 200, height: 120)),
            (.init(x: -500, y: 10, width: 200, height: 120), .init(x: -500, y: 24, width: 200, height: 120)),
            (.init(x: -500, y: 1130, width: 200, height: 120), .init(x: -500, y: 1104, width: 200, height: 120)),
            (.init(x: 10, y: -10, width: 200, height: 120), .init(x: -200, y: 24, width: 200, height: 120))
        ]
        for (current, expected) in samples {
            #expect(try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum) == expected)
        }
    }

    @Test func oversizeDimensionsShrinkOnlyAsFarAsRequired() throws {
        let wide = SurfaceRect(x: -800, y: 100, width: 800, height: 240)
        #expect(try ManagedWindowBoundary.correction(frame: wide, in: work, minimum: minimum)
            == SurfaceRect(x: -700, y: 100, width: 700, height: 240))
        let tall = SurfaceRect(x: -500, y: 0, width: 250, height: 1300)
        #expect(try ManagedWindowBoundary.correction(frame: tall, in: work, minimum: minimum)
            == SurfaceRect(x: -500, y: 24, width: 250, height: 1200))
        let huge = SurfaceRect(x: -900, y: -100, width: 1000, height: 1500)
        #expect(try ManagedWindowBoundary.correction(frame: huge, in: work, minimum: minimum) == work)
    }

    @Test func containedWindowAndFullWorkRectRequireNoWrite() throws {
        let current = SurfaceRect(x: -600, y: 100, width: 300, height: 200)
        #expect(try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum) == nil)
        #expect(try ManagedWindowBoundary.correction(frame: work, in: work, minimum: work) == nil)
    }

    @Test func fractionalOverflowIsNotHiddenByATolerance() throws {
        let current = SurfaceRect(x: -200.0 + 0.25, y: 40, width: 200, height: 120)
        #expect(try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum)
            == SurfaceRect(x: -200, y: 40, width: 200, height: 120))
    }

    @Test func minimumSizeConflictsNeverExpandOrUndersizeAWindow() {
        let current = SurfaceRect(x: -600, y: 40, width: 200, height: 120)
        for min in [SurfaceRect(width: 201, height: 80), .init(width: 100, height: 121),
                    .init(width: 701, height: 80), .init(width: 100, height: 1201),
                    .init(width: .nan, height: 80), .init(width: 100, height: .infinity),
                    .init(width: 0, height: 80), .init(width: 100, height: -1)] {
            #expect(throws: WorkspaceFailure.minimumSize) {
                try ManagedWindowBoundary.correction(frame: current, in: work, minimum: min)
            }
        }
        let oversized = SurfaceRect(x: -800, y: 0, width: 800, height: 1300)
        #expect(throws: WorkspaceFailure.minimumSize) {
            try ManagedWindowBoundary.correction(frame: oversized, in: work, minimum: .init(width: 701, height: 80))
        }
    }

    @Test func invalidGeometryFailsBeforeAnyCorrectionIsOffered() {
        let valid = SurfaceRect(x: -500, y: 40, width: 200, height: 120)
        for invalid in [SurfaceRect(x: .nan, y: 40, width: 200, height: 120),
                        .init(x: -500, y: .infinity, width: 200, height: 120),
                        .init(x: -500, y: 40, width: 0, height: 120),
                        .init(x: -500, y: 40, width: 200, height: -1),
                        .init(x: Double.greatestFiniteMagnitude, width: Double.greatestFiniteMagnitude, height: 120)] {
            #expect(throws: WorkspaceFailure.invalidLayout) {
                try ManagedWindowBoundary.correction(frame: invalid, in: work, minimum: minimum)
            }
            #expect(throws: WorkspaceFailure.invalidLayout) {
                try ManagedWindowBoundary.correction(frame: valid, in: invalid, minimum: minimum)
            }
            #expect(throws: WorkspaceFailure.invalidLayout) {
                try ManagedWindowBoundary.correction(frame: valid, in: work, minimum: minimum, others: [invalid])
            }
        }
    }

    @Test func clampCannotInvadeAnAuthorizedSiblingAndInBoundsOverlapAlsoRefuses() {
        let sibling = SurfaceRect(x: -250, y: 40, width: 250, height: 200)
        for current in [SurfaceRect(x: -150, y: 40, width: 200, height: 120),
                        .init(x: -400, y: 40, width: 200, height: 120)] {
            #expect(throws: WorkspaceFailure.conflict) {
                try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum, others: [sibling])
            }
        }
    }

    @Test func touchingEdgesAndCornersAreAllowedButPositiveOverlapIsNot() throws {
        let current = SurfaceRect(x: -500, y: 40, width: 200, height: 120)
        let adjacent = SurfaceRect(x: -300, y: 40, width: 200, height: 120)
        let corner = SurfaceRect(x: -300, y: 160, width: 200, height: 120)
        #expect(try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum,
                                                   others: [adjacent, corner]) == nil)
        let overlap = SurfaceRect(x: -300.25, y: 40, width: 200, height: 120)
        #expect(throws: WorkspaceFailure.conflict) {
            try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum, others: [overlap])
        }
    }

    @Test func unresolvedSiblingBoundsPreventAGuessedCorrection() {
        let current = SurfaceRect(x: -720, y: 40, width: 200, height: 120)
        let outside = SurfaceRect(x: -200, y: 300, width: 220, height: 120)
        #expect(throws: WorkspaceFailure.conflict) {
            try ManagedWindowBoundary.correction(frame: current, in: work, minimum: minimum, others: [outside])
        }
    }

    @Test func dockedAndFloatingUseTheExistingWorkRectRatherThanPanelVisibility() throws {
        let screen = SurfaceRect(x: -800, width: 800, height: 1280)
        let window = SurfaceRect(x: -150, y: 40, width: 150, height: 120)
        var settings = DisplaySettings()
        let docked = try DesktopWorkArea(display: "side", screen: screen, usable: screen, primary: false,
                                        settings: settings, fallbackEdge: .right)
        #expect(try ManagedWindowBoundary.correction(frame: window, in: docked.ordinary, minimum: minimum)
            == SurfaceRect(x: -250, y: 40, width: 150, height: 120))
        settings.placement = .floating
        let floating = try DesktopWorkArea(display: "side", screen: screen, usable: screen, primary: false,
                                          settings: settings, fallbackEdge: .right)
        #expect(try ManagedWindowBoundary.correction(frame: window, in: floating.ordinary, minimum: minimum) == nil)
    }
}
