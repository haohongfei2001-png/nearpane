import Foundation
import Testing
@testable import WindowGeometryCore

struct GeometryTests {
    func display(_ id: String = "primary", cg: Rect = Rect(0, 0, 1440, 900),
                 scale: Double = 2, rotation: QuarterTurn = .zero) throws -> DisplayCoordinateTransform {
        try DisplayCoordinateTransform(displayID: id,
                                       appKitFrame: Rect(cg.x, 900 - cg.maxY, cg.width, cg.height),
                                       cgBounds: cg, backingScale: scale, rotation: rotation)
    }
    func assertPoint(_ actual: Point, _ expected: Point, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.x - expected.x) <= 1e-9, sourceLocation: sourceLocation)
        #expect(abs(actual.y - expected.y) <= 1e-9, sourceLocation: sourceLocation)
    }

    @Test func testPrimaryAndNegativeOriginsHaveIndependentGoldenCoordinates() throws {
        let primary = try display()
        assertPoint(try primary.appKitToCG(Point(100, 800)), Point(100, 100))
        #expect(try primary.appKitToCG(Rect(100, 600, 400, 200)) == Rect(100, 100, 400, 200))
        let left = try display("left", cg: Rect(-900, -300, 900, 1440), rotation: .clockwise90)
        assertPoint(try left.appKitToCG(Point(-800, 1100)), Point(-800, -200))
        #expect(try left.appKitToCG(left.appKitFrame) == left.cgBounds)
    }

    @Test func testPrimaryOriginNeedNotBeZeroInSuppliedCoordinateContract() throws {
        let transform = try DisplayCoordinateTransform(displayID: "offset",
            appKitFrame: Rect(40, -20, 1440, 900), cgBounds: Rect(8, 12, 1440, 900), backingScale: 1, rotation: .zero)
        assertPoint(try transform.appKitToCG(Point(40, 880)), Point(8, 12))
        assertPoint(try transform.cgToAppKit(Point(8, 912)), Point(40, -20))
    }

    @Test func testQuarterTurnGoldenPointsPreventDoubleRotationAndMirroring() throws {
        let expected: [QuarterTurn: Point] = [.zero: Point(40, 60), .clockwise90: Point(60, 160),
                                            .half: Point(160, 340), .clockwise270: Point(340, 40)]
        for rotation in QuarterTurn.allCases {
            let d = try display(cg: Rect(-100, 50, 100, 200), rotation: rotation)
            assertPoint(try d.cgToUnrotatedBacking(Point(-80, 80)), expected[rotation]!)
            assertPoint(try d.unrotatedBackingToCG(expected[rotation]!), Point(-80, 80))
            // Global logical frames are already oriented. Rotation never enters this conversion.
            #expect(try d.appKitToCG(Rect(-80, 760, 40, 60)) == Rect(-80, 80, 40, 60))
            assertPoint(try d.cgToOrientedBacking(Point(-80, 80)), Point(40, 60))
        }
    }

    @Test func testQuarterTurnGoldenRectanglesUseAllCorners() throws {
        let expected: [QuarterTurn: Rect] = [.zero: Rect(40, 60, 80, 120),
            .clockwise90: Rect(60, 80, 120, 80), .half: Rect(80, 220, 80, 120),
            .clockwise270: Rect(220, 40, 120, 80)]
        for rotation in QuarterTurn.allCases {
            let d = try display(cg: Rect(-100, 50, 100, 200), rotation: rotation)
            let source = Rect(-80, 80, 40, 60)
            #expect(try d.cgToUnrotatedBacking(source) == expected[rotation])
            #expect(try d.unrotatedBackingToCG(expected[rotation]!) == source)
        }
    }

    @Test func testBackingScaleDoesNotScaleGlobalOrigin() throws {
        for scale in [1.0, 1.25, 2.0] {
            let d = try display("right", cg: Rect(1440, -200, 900, 1440), scale: scale, rotation: .clockwise90)
            assertPoint(try d.cgToOrientedBacking(Point(1450, -180)), Point(10 * scale, 20 * scale))
            #expect(try d.cgToAppKit(Rect(1450, -180, 100, 200)) == Rect(1450, 880, 100, 200))
        }
    }

    @Test func testCrossDisplayRectIsClippedAndUsesEachScale() throws {
        let desktop = try DesktopGeometry(displays: [display(),
            display("right", cg: Rect(1440, 0, 900, 1440), scale: 1, rotation: .clockwise90)], primaryID: "primary")
        let rect = Rect(1400, 100, 100, 200)
        let slices = try desktop.slices(of: rect)
        #expect(slices.count == 2)
        #expect(slices[0].cgRect == Rect(1400, 100, 40, 200))
        #expect(slices[0].orientedBackingRect == Rect(2800, 200, 80, 400))
        #expect(slices[1].cgRect == Rect(1440, 100, 60, 200))
        #expect(slices[1].orientedBackingRect == Rect(0, 100, 60, 200))
        #expect(slices.map(\.fractionOfWindow) == [0.4, 0.6])
        #expect(try desktop.uncoveredArea(of: rect) == 0)
        #expect(try desktop.appKitToCG(desktop.cgToAppKit(rect)) == rect)
    }

    @Test func testThreeDisplaysNegativeOriginsAndGapsPreserveUncoveredArea() throws {
        let desktop = try DesktopGeometry(displays: [display(),
            display("left", cg: Rect(-1000, -300, 900, 1440), scale: 1),
            display("above", cg: Rect(0, -900, 1440, 900), scale: 1)], primaryID: "primary")
        let rect = Rect(-200, -50, 400, 100)
        let slices = try desktop.slices(of: rect)
        #expect(slices.count == 3)
        #expect(slices.reduce(0) { $0 + $1.cgRect.area } == 30_000)
        #expect(try desktop.uncoveredArea(of: rect) == 10_000)
        #expect(try desktop.slices(of: Rect(3000, 3000, 100, 100)).count == 0)
    }

    @Test func testMirrorsDuplicateIDsAndInconsistentTopologyFailClosed() throws {
        #expect(throws: (any Error).self) { try DesktopGeometry(displays: [display(), display("mirror")], primaryID: "primary") }
        #expect(throws: (any Error).self) { try DesktopGeometry(displays: [display(), display()], primaryID: "primary") }
        let bad = try DisplayCoordinateTransform(displayID: "bad", appKitFrame: Rect(1440, 0, 900, 1440),
                                                 cgBounds: Rect(1440, 0, 900, 1440), backingScale: 1, rotation: .clockwise90)
        #expect(throws: (any Error).self) { try DesktopGeometry(displays: [display(), bad], primaryID: "primary") }
        #expect(throws: (any Error).self) { try DesktopGeometry(displays: [], primaryID: "primary") }
        #expect(throws: (any Error).self) { try DesktopGeometry(displays: [display()], primaryID: "missing") }
    }

    @Test func testInvalidUnitsScaleAndNonfiniteGeometryAreRejected() throws {
        #expect(throws: (any Error).self) { try DisplayCoordinateTransform(displayID: "x", appKitFrame: Rect(0, 0, 100, 100),
            cgBounds: Rect(0, 0, 200, 200), backingScale: 2, rotation: .zero) }
        for scale in [0, -1, Double.nan, Double.infinity, Double.leastNonzeroMagnitude] {
            #expect(throws: (any Error).self) { try display(scale: scale) }
        }
        for rect in [Rect(0, 0, 0, 10), Rect(0, 0, -1, 10), Rect(.nan, 0, 10, 10),
                     Rect(0, 0, .infinity, 10), Rect(1e308, 0, 1e308, 10)] {
            #expect(!(rect.isValid))
            #expect(throws: (any Error).self) { try display(cg: rect) }
        }
        #expect(throws: (any Error).self) { try display().cgToAppKit(Point(.nan, 0)) }
        #expect(QuarterTurn(rawValue: 45) == nil)
    }

    @Test func testPreviewLetterboxAndCommonScaleGoldenCoordinates() throws {
        let preview = try PreviewTransform(source: Rect(-1000, -500, 2000, 1000), viewport: Rect(10, 20, 400, 400))
        #expect(preview.content == Rect(10, 120, 400, 200))
        #expect(preview.scale == 0.2)
        #expect(try preview.project(Rect(-900, -400, 400, 200)) == Rect(30, 140, 80, 40))
        #expect(try preview.project(Rect(0, -400, 200, 400)) == Rect(210, 140, 40, 80))
        assertPoint(try preview.unproject(Point(210, 220)), Point(0, 0))
        #expect(throws: (any Error).self) { try preview.unproject(Point(210, 100)) }
        #expect(throws: (any Error).self) { try preview.unproject(Point(410, 220)) }
        #expect(throws: (any Error).self) { try PreviewTransform(source: Rect(0, 0, 0, 10), viewport: Rect(0, 0, 10, 10)) }
    }

    @Test func testWorkAreaClipsWithoutChangingDesktopOrigin() throws {
        let d = try display()
        let appKitWorkArea = Rect(0, 30, 1440, 840)
        let cgWorkArea = try d.appKitToCG(appKitWorkArea)
        #expect(cgWorkArea == Rect(0, 30, 1440, 840))
        #expect(Rect(10, 10, 200, 200).intersection(cgWorkArea) == Rect(10, 30, 200, 180))
        assertPoint(try d.cgToAppKit(Point(10, 10)), Point(10, 890))
    }

    @Test func testHalfOpenHitTestGivesOneOwnerAtSeam() throws {
        let regions = [HitRegion(key: "left", bounds: Rect(-100, 0, 100, 100), frontToBackIndex: 1, identityEligible: true),
                       HitRegion(key: "right", bounds: Rect(0, 0, 100, 100), frontToBackIndex: 0, identityEligible: true)]
        #expect(try HitTesting.hit(Point(0, 50), regions: regions) == .candidate("right"))
        #expect(try HitTesting.hit(Point(-100, 0), regions: regions) == .candidate("left"))
        #expect(try HitTesting.hit(Point(100, 50), regions: regions) == .none)
        #expect(try HitTesting.hit(Point(50, 100), regions: regions) == .none)
    }

    @Test func testOverlapUsesZOrderAndExposedRegion() throws {
        let regions = [HitRegion(key: "back", bounds: Rect(0, 0, 100, 100), frontToBackIndex: 8, identityEligible: true),
                       HitRegion(key: "front", bounds: Rect(40, 40, 100, 100), frontToBackIndex: 2, identityEligible: true)]
        #expect(try HitTesting.hit(Point(60, 60), regions: regions) == .candidate("front"))
        #expect(try HitTesting.hit(Point(20, 20), regions: regions) == .candidate("back"))
        let preview = try PreviewTransform(source: Rect(0, 0, 200, 200), viewport: Rect(0, 0, 100, 100))
        #expect(try HitTesting.hit(preview.unproject(Point(30, 30)), regions: regions) == .candidate("front"))
    }

    @Test func testUnresolvedOccluderBlocksClickThroughAndTiesAreAmbiguous() throws {
        let back = HitRegion(key: "back", bounds: Rect(0, 0, 100, 100), frontToBackIndex: 1, identityEligible: true)
        let blocked = HitRegion(key: "unknown", bounds: Rect(20, 20, 100, 100), frontToBackIndex: 0, identityEligible: false)
        #expect(try HitTesting.hit(Point(50, 50), regions: [back, blocked]) == .blocked("unknown"))
        let tie = HitRegion(key: "tie", bounds: back.bounds, frontToBackIndex: 0, identityEligible: true)
        #expect(try HitTesting.hit(Point(50, 50), regions: [tie, blocked]) == .ambiguous(["tie", "unknown"]))
        #expect(throws: (any Error).self) { try HitTesting.hit(Point(0, 0), regions: [back, back]) }
        #expect(throws: (any Error).self) { try HitTesting.hit(Point(.nan, 0), regions: [back]) }
    }

    @Test func testVisibleFragmentsAreNonoverlappingAndConserveArea() throws {
        let source = Rect(0, 0, 100, 100), covers = [Rect(20, 20, 40, 40), Rect(40, 40, 40, 40)]
        let pieces = try HitTesting.visibleFragments(of: source, occluders: covers)
        #expect(pieces.reduce(0) { $0 + $1.area } == 7200)
        for (i, piece) in pieces.enumerated() {
            #expect(covers.allSatisfy { piece.intersection($0) == nil })
            #expect(pieces.prefix(i).allSatisfy { piece.intersection($0) == nil })
        }
        #expect(try HitTesting.visibleFragments(of: source, occluders: [source]) == [])
    }

    @Test func testDeterministicSyntheticRoundTripMetrics() throws {
        var seed: UInt64 = 0x4e45415250414e45
        func unit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / 9_007_199_254_740_992
        }
        var errors: [Double] = []
        var cases = 0
        for rotation in QuarterTurn.allCases {
            for scale in [1.0, 1.25, 2.0] {
                for origin in [Point(0, 0), Point(-1728, -900), Point(1512, 300)] {
                    let portrait = rotation == .clockwise90 || rotation == .clockwise270
                    let bounds = Rect(origin.x, origin.y, portrait ? 982 : 1512, portrait ? 1512 : 982)
                    let d = try display(cg: bounds, scale: scale, rotation: rotation)
                    let preview = try PreviewTransform(source: bounds, viewport: Rect(7, 11, 321, 199))
                    for _ in 0..<1000 {
                        let r = Rect(bounds.x + unit() * bounds.width * 0.6,
                                     bounds.y + unit() * bounds.height * 0.6,
                                     0.25 + unit() * bounds.width * 0.39,
                                     0.25 + unit() * bounds.height * 0.39)
                        errors.append(try d.appKitToCG(d.cgToAppKit(r)).componentError(from: r))
                        errors.append(try d.orientedBackingToCG(d.cgToOrientedBacking(r)).componentError(from: r))
                        errors.append(try d.unrotatedBackingToCG(d.cgToUnrotatedBacking(r)).componentError(from: r))
                        let point = Point(r.x, r.y), roundTrip = try preview.unproject(preview.project(point))
                        errors.append(max(abs(roundTrip.x - point.x), abs(roundTrip.y - point.y)))
                        cases += 1
                    }
                }
            }
        }
        let sorted = errors.sorted(), maximum = sorted.last!
        let metrics: [String: Any] = [
            "source": "deterministic-synthetic-only", "seedHex": "4e45415250414e45",
            "rectangleCases": cases, "errorSamples": errors.count,
            "rotationDegrees": [0, 90, 180, 270], "scales": [1.0, 1.25, 2.0],
            "maxLogicalPointError": maximum,
            "p50LogicalPointError": sorted[sorted.count / 2],
            "p95LogicalPointError": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "rmsLogicalPointError": sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)),
            "syntheticThresholdPoints": 1e-9,
            "liveCalibration": "NOT_TESTED", "activation": "NOT_TESTED",
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("GEOMETRY_METRICS " + String(decoding: data, as: UTF8.self))
        #expect(maximum <= 1e-9)
        #expect(cases == 36_000)
    }
}
