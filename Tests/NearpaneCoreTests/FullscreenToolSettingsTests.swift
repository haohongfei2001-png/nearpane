import Foundation
import Testing
@testable import NearpaneCore

struct FullscreenToolSettingsTests {
    private func screen(_ x: Double, _ y: Double, id: String = "rotated") -> ScreenGeometry {
        ScreenGeometry(id: id, frame: .init(x: x, y: y, width: 800, height: 1280),
                       visibleFrame: .init(x: x, y: y + 10, width: 800, height: 1230))
    }

    @Test func legacyPerDisplaySettingsKeepFullscreenOptIn() throws {
        let restored = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"placement":"floating"}"#.utf8))
        #expect(!restored.fullscreenTools.enabled)
        #expect(restored.placement == .floating)
        #expect(restored.toolAnchor == nil)
        #expect(restored.fullscreenToolFrame(on: screen(-800, -40), expanded: false, count: 2) == nil)
    }

    @Test func savedLocalAnchorFollowsTheDisplayAndAvoidanceDoesNotOverwriteIt() throws {
        let original = screen(-800, -40)
        var settings = DisplaySettings()
        settings.fullscreenTools.enabled = true
        settings.fullscreenTools.capture = false
        settings.fullscreenTools.corner = .bottomLeft
        let chosen = SurfaceRect(x: -500, y: 320, width: 136, height: 34)
        settings.saveFullscreenToolFrame(chosen, on: original)
        let old = try #require(settings.toolAnchor)
        #expect(old.anchor.x == 300 && old.anchor.y == 360)

        let newScreen = screen(1600, 500)
        let persisted = try JSONDecoder().decode(DisplaySettings.self, from: JSONEncoder().encode(settings))
        let expected = SurfaceRect(x: 1900, y: 860, width: 136, height: 34)
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 1) == expected)
        let avoided = try #require(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 1,
                                                                 confirmedControls: [expected]))
        #expect(avoided.x == expected.x && abs(avoided.y - expected.y) == expected.height)
        #expect(persisted.toolAnchor == old)
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: false, count: 1) == .init(x: 1608, y: 518, width: 32, height: 26))
        #expect(persisted.fullscreenTools.allows(.voice))
        #expect(!persisted.fullscreenTools.allows(.capture))
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 0) == nil)
    }

    @Test func movingToolsPersistsOnlyTheirScreenAndLeavesWorkRectAndPanelSizeIntact() throws {
        let first = screen(0, 0, id: "one")
        let second = screen(-800, 0)
        var config = HostConfiguration()
        config.displays[first.id] = DisplaySettings()
        var settings = DisplaySettings()
        settings.fullscreenTools.enabled = true
        let work = try DesktopWorkArea(display: second.id, screen: second.frame, usable: second.visibleFrame,
                                       primary: true, settings: settings, fallbackEdge: .right)
        let panel = settings.panel(on: second, fallbackEdge: .right)
        settings.saveFullscreenToolFrame(.init(x: -384, y: 458, width: 136, height: 34), on: second)
        settings.saveFullscreenToolFrame(.init(x: 40, y: 10, width: 136, height: 34), on: second)
        config.displays[second.id] = settings
        let restored = try JSONDecoder().decode(HostConfiguration.self, from: JSONEncoder().encode(config)).validated()
        #expect(restored.displays[first.id]?.toolAnchor == nil)
        #expect(restored.displays[second.id]?.toolAnchor?.anchor.x == 416)
        #expect(try DesktopWorkArea(display: second.id, screen: second.frame, usable: second.visibleFrame,
                                    primary: true, settings: settings, fallbackEdge: .right) == work)
        #expect(settings.panel(on: second, fallbackEdge: .right) == panel)
    }
}
