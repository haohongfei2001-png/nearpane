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
        let workspace = try #require(FullscreenWorkspaceLayout(on: newScreen, settings: persisted,
            enabledModuleIDs: [BuiltinCatalog.voice]))
        let expected = SurfaceRect(x: 1900, y: 860, width: workspace.width, height: workspace.height)
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 1, workspace: workspace) == expected)
        let avoided = try #require(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 1,
                                                                 confirmedControls: [expected], workspace: workspace))
        #expect(avoided.x == expected.x && abs(avoided.y - expected.y) == expected.height)
        #expect(persisted.toolAnchor == old)
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: false, count: 1) == .init(x: 1608, y: 518, width: 104, height: 28))
        #expect(persisted.fullscreenTools.allows(.voice))
        #expect(persisted.fullscreenTools.allows(.capture) && persisted.fullscreenTools.allows(.workspace))
        #expect(!persisted.fullscreenTools.capture) // Stored legacy preference is preserved, not a second module toggle.
        #expect(persisted.fullscreenToolFrame(on: newScreen, expanded: true, count: 0) == nil)
    }

    @Test func workspaceUsesTheEnabledOrderAndSharedWidthWithoutSpacesOrDuplicateModules() throws {
        var settings = DisplaySettings()
        settings.measures[.panelWidth] = Measure(300)
        let order = [BuiltinCatalog.lyrics, BuiltinCatalog.desktop, BuiltinCatalog.memo,
                     BuiltinCatalog.voice, BuiltinCatalog.clock, BuiltinCatalog.screenshots, BuiltinCatalog.lyrics]
        let layout = try #require(FullscreenWorkspaceLayout(on: screen(0, 0), settings: settings,
            enabledModuleIDs: order, lyricsHeight: 192))
        let expected = [BuiltinCatalog.lyrics, BuiltinCatalog.memo, BuiltinCatalog.voice,
                        BuiltinCatalog.clock, BuiltinCatalog.screenshots]
        #expect(layout.visibleModuleIDs == expected)
        #expect(layout.width == 300 && layout.content.windowArea.height == 0)
        let frames = try expected.map { try #require(layout.content.frame(for: $0)) }
        for index in frames.indices.dropFirst() {
            #expect(frames[index].y >= frames[index - 1].y + frames[index - 1].height)
        }
        #expect(frames.allSatisfy { $0.width == layout.width })
    }

    @Test func inactiveLyricsAndSpacesAloneDoNotCreateAnEmptyFullscreenEntry() throws {
        let idle = FullscreenWorkspaceLayout(on: screen(0, 0), settings: .init(),
            enabledModuleIDs: [BuiltinCatalog.desktop, BuiltinCatalog.lyrics], lyricsHeight: 0)
        #expect(idle == nil)
        let clock = try #require(FullscreenWorkspaceLayout(on: screen(0, 0), settings: .init(),
            enabledModuleIDs: [BuiltinCatalog.desktop, BuiltinCatalog.lyrics, BuiltinCatalog.clock], lyricsHeight: 0))
        #expect(clock.visibleModuleIDs == [BuiltinCatalog.clock])
        #expect(clock.content.additionalTools[BuiltinCatalog.lyrics] == nil)
        let paused = try #require(FullscreenWorkspaceLayout(on: screen(0, 0), settings: .init(),
            enabledModuleIDs: [BuiltinCatalog.lyrics], lyricsHeight: 192))
        #expect(paused.visibleModuleIDs == [BuiltinCatalog.lyrics])
        #expect(paused.content.additionalTools[BuiltinCatalog.lyrics]?.height == 192)
    }

    @Test func shortScreensKeepEveryToolReachableThroughTheSharedScrollViewport() throws {
        let rect = SurfaceRect(width: 900, height: 300)
        let screen = ScreenGeometry(id: "small", frame: rect, visibleFrame: rect)
        var settings = DisplaySettings()
        settings.fullscreenTools.enabled = true
        let order = [BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.lyrics,
                     BuiltinCatalog.memo, BuiltinCatalog.clock]
        let layout = try #require(FullscreenWorkspaceLayout(on: screen, settings: settings,
            enabledModuleIDs: order, lyricsHeight: 192))
        #expect(layout.visibleModuleIDs == order)
        #expect(layout.content.contentHeight > layout.viewportHeight)
        #expect(layout.height <= screen.visibleFrame.height - 16)
        let frame = try #require(settings.fullscreenToolFrame(on: screen, expanded: true, count: 1, workspace: layout))
        #expect(screen.visibleFrame.geometry.intersection(frame.geometry) == frame.geometry)
        #expect(settings.fullscreenToolFrame(on: screen, expanded: true, count: 1,
            confirmedControls: [screen.visibleFrame], workspace: layout) == nil)
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
