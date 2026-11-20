import Foundation
import Testing
@testable import NearpaneCore

@Suite(.serialized)
struct LayoutTests {
    @Test func toolHeightsStayFixedAndWindowsTakeTheRemainder() {
        for width in [90.0, 180, 320] {
            for height in [400.0, 864, 1920] {
                for count in [0, 1, 5, 100] {
                    let result = LayoutComposer.compose(width: width, height: height, pinnedCount: count, expanded: false)
                    #expect(result.voice.height == 144 && result.screenshots.height == 76)
                    #expect(result.desktop.y == 252 && result.desktop.height == height - 264)
                    #expect(result.desktop.y + result.desktop.height == height - 12)
                }
            }
        }
    }

    @Test func reorderedToolsUseTheirActualHeightsAndReturnSpaceToWindows() {
        let order = [BuiltinCatalog.memo, BuiltinCatalog.voice, BuiltinCatalog.screenshots]
        for paused in [false, true] {
            for rows in 1...2 {
                let layout = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false,
                    voiceCompact: paused, trayRows: rows, toolOrder: order)
                #expect(layout.additionalTools[BuiltinCatalog.memo] == .init(y: 12, width: 240, height: 128))
                #expect(layout.voice.y == 150 && layout.voice.height == (paused ? 40 : 144))
                #expect(layout.screenshots.y == layout.voice.y + layout.voice.height + 10)
                #expect(layout.screenshots.height == (rows == 1 ? 76 : 144))
                #expect(layout.windowArea.y == layout.screenshots.y + layout.screenshots.height + 10)
                #expect(layout.windowArea.y + layout.windowArea.height == 888)
            }
        }
        for (display, expected) in [(640.0,160.0), (1280,240), (1440,240), (1920,307), (2560,360), (3440,430)] {
            #expect(DisplaySettings.recommendedPanelWidth(in: display) == expected)
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

    @Test func windowsFollowOnlyPresentedToolsAndKeepTheRestOfTheirSection() {
        for voice in [false, true] {
            for tray in [false, true] {
                for pinned in [0, 1, 8] {
                    let layout = LayoutComposer.compose(width: 240, height: 900, pinnedCount: pinned,
                        expanded: true, voiceEnabled: voice, trayEnabled: tray)
                    let toolsEnd = 12.0 + (voice ? 154 : 0) + (tray ? 86 : 0)
                    #expect(layout.desktop.y == toolsEnd)
                    #expect(layout.moduleRail?.y == (pinned > 0 ? toolsEnd : nil))
                    #expect(layout.windowArea.y == toolsEnd + (layout.moduleRail?.height ?? 0))
                    #expect(layout.windowArea.height + layout.windowArea.y == layout.desktop.height + layout.desktop.y)
                    #expect(layout.expanded!.y >= layout.windowArea.y)
                }
            }
        }
        let clockOnly = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 1, expanded: false, content: .spacesOnly)
        #expect(clockOnly.moduleRail?.y == 12 && clockOnly.windowArea.y == 12 + (clockOnly.moduleRail?.height ?? 0))
        let secondary = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false, content: .spacesOnly)
        #expect(secondary.moduleRail == nil && secondary.windowArea == .init(y: 12, width: 240, height: 876))
    }

    @Test func defaultEdgesUseVisibleAreaAndRecommendedWidth() {
        let screen = ScreenGeometry(id: "main", frame: .init(width: 1440, height: 900),
                                    visibleFrame: .init(x: 0, y: 40, width: 1440, height: 830))
        #expect(SurfacePlacement.resolve(screens: [screen], preferredID: nil, edge: .right) == SurfaceRect(x: 1200, y: 40, width: 240, height: 830))
        #expect(SurfacePlacement.resolve(screens: [screen], preferredID: nil, edge: .left)?.x == 0)
    }

    @Test func testRotatedNegativeOriginAndMissingDisplayFallback() {
        let main = ScreenGeometry(id: "main", frame: .init(width: 1440, height: 900), visibleFrame: .init(width: 1440, height: 860))
        let rotated = ScreenGeometry(id: "portrait", frame: .init(x: -1080, y: -400, width: 1080, height: 1920),
                                     visibleFrame: .init(x: -1080, y: -370, width: 1080, height: 1890))
        #expect(SurfacePlacement.resolve(screens: [main, rotated], preferredID: "portrait", edge: .left) == SurfaceRect(x: -1080, y: -370, width: 240, height: 1890))
        #expect(SurfacePlacement.resolve(screens: [main], preferredID: "portrait", edge: .right)?.width == 240)
        #expect(SurfacePlacement.resolve(screens: [], preferredID: "portrait", edge: .right) == nil)
    }
}
