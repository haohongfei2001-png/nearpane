import Foundation
import Testing
@testable import NearpaneCore

@Suite(.serialized)
struct LayoutTests {
    @Test func testFrozenRatiosAcrossSizesAndModuleCounts() {
        for width in [90.0, 180, 320] {
            for height in [400.0, 864, 1920] {
                for count in [0, 1, 5, 100] {
                    let result = LayoutComposer.compose(width: width, height: height, pinnedCount: count, expanded: false)
                    #expect(abs((result.voice.height + result.screenshots.height) - (height * 3 / 8)) <= 0.0001)
                    #expect(abs((result.desktop.height) - (height * 5 / 8)) <= 0.0001)
                    #expect(result.desktop.y + result.desktop.height == height)
                }
            }
        }
    }

    @Test func testOverlayAndOverflowDoNotChangeCoreGeometry() {
        let base = LayoutComposer.compose(width: 180, height: 864, pinnedCount: 0, expanded: false)
        let expanded = LayoutComposer.compose(width: 180, height: 864, pinnedCount: 20, expanded: true)
        #expect(base.voice == expanded.voice)
        #expect(base.screenshots == expanded.screenshots)
        #expect(base.desktop == expanded.desktop)
        #expect(expanded.overflowCount == 15)
        #expect(expanded.expanded!.y > expanded.desktop.y)
        #expect(expanded.expanded!.height < expanded.desktop.height)
    }

    @Test func testInvalidAndTinySurfaceSizesStayFiniteAndNonnegative() {
        for (w, h) in [(0.0, 0.0), (-10, -10), (.nan, .infinity), (8, 8)] {
            let layout = LayoutComposer.compose(width: w, height: h, pinnedCount: 3, expanded: true)
            for rect in [layout.voice, layout.screenshots, layout.desktop, layout.expanded!] {
                #expect(rect.width.isFinite && rect.height.isFinite)
                #expect(rect.width >= 0)
                #expect(rect.height >= 0)
            }
        }
    }

    @Test func testRightAndLeftEdgesUseVisibleAreaAndEighthOfScreen() {
        let screen = ScreenGeometry(id: "main", frame: .init(width: 1440, height: 900),
                                    visibleFrame: .init(x: 0, y: 40, width: 1440, height: 830))
        #expect(SurfacePlacement.resolve(screens: [screen], preferredID: nil, edge: .right) == SurfaceRect(x: 1260, y: 40, width: 180, height: 830))
        #expect(SurfacePlacement.resolve(screens: [screen], preferredID: nil, edge: .left)?.x == 0)
    }

    @Test func testRotatedNegativeOriginAndMissingDisplayFallback() {
        let main = ScreenGeometry(id: "main", frame: .init(width: 1440, height: 900), visibleFrame: .init(width: 1440, height: 860))
        let rotated = ScreenGeometry(id: "portrait", frame: .init(x: -1080, y: -400, width: 1080, height: 1920),
                                     visibleFrame: .init(x: -1080, y: -370, width: 1080, height: 1890))
        #expect(SurfacePlacement.resolve(screens: [main, rotated], preferredID: "portrait", edge: .left) == SurfaceRect(x: -1080, y: -370, width: 135, height: 1890))
        #expect(SurfacePlacement.resolve(screens: [main], preferredID: "portrait", edge: .right)?.width == 180)
        #expect(SurfacePlacement.resolve(screens: [], preferredID: "portrait", edge: .right) == nil)
    }
}
