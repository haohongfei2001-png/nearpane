import Foundation
import Testing
@testable import NearpaneCore

@Suite(.serialized)
struct LayoutTests {
    @Test func testReferenceSectionsAdaptWithoutChangingOuterWidthAcrossModuleCounts() {
        for width in [90.0, 180, 320] {
            for height in [400.0, 864, 1920] {
                for count in [0, 1, 5, 100] {
                    let result = LayoutComposer.compose(width: width, height: height, pinnedCount: count, expanded: false)
                    #expect(abs(result.voice.height - min(height * 0.225, width * 173 / 325)) < 0.0001)
                    #expect(abs(result.screenshots.height - min(height * 0.225, width * 195 / 325)) < 0.0001)
                    #expect(result.desktop.y == result.voice.height + result.screenshots.height)
                    #expect(abs(result.desktop.y + result.desktop.height - height) < 0.0001)
                }
            }
        }
    }

    @Test func referenceSectionsRespectManualHeightsAndPartialPresentation() {
        let sizes = DisplaySettings()
        let reference = LayoutComposer.compose(width: 325, height: 913, pinnedCount: 0, expanded: false)
        #expect(reference.voice == SurfaceRect(width: 325, height: 173))
        #expect(reference.screenshots == SurfaceRect(y: 173, width: 325, height: 195))
        #expect(reference.desktop == SurfaceRect(y: 368, width: 325, height: 545))

        let one = sizes.contentHeights(913, width: 325, content: .voiceOnly, voice: true, tray: true)
        #expect(one.voice == 173 && one.tray == 0 && one.spaces == 0)
        var manual = sizes
        manual.measures = [.voiceHeight: .init(201), .trayHeight: .init(24, .percent)]
        let adjusted = manual.contentHeights(900, width: 150, content: .full, voice: true, tray: true)
        #expect(adjusted.voice == 201 && adjusted.tray == 216 && adjusted.spaces == 483)
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
