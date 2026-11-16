import AppKit
import SwiftUI
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct PanelGlassSettingsTests {
    @Test func actualMaterialAndTintCanBeChangedIndependentlyWithoutFadingContents() throws {
        let material = PanelGlassMaterial(frame: NSRect(x: 0, y: 0, width: 160, height: 400))
        let label = NSTextField(labelWithString: "合成文字")
        material.addSubview(label)
        let layout = LayoutComposer.compose(width: 160, height: 400, pinnedCount: 0, expanded: false)
        var settings = DisplaySettings()
        settings.glass.outerTransparency = 100
        settings.glass.innerTransparency = 0
        settings.glass.overallTransparency = 50
        let levels = SurfaceGlassLevels(settings.glass, dark: false, reduceTransparency: false)
        #expect(levels.outerTint == 0 && levels.outerMaterial == 0)
        #expect(levels.innerTint == 0.5 && levels.innerMaterial == 0.5)
        material.configure(size: material.bounds.size, layout: layout, settings: settings)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let mask = try #require(material.maskImage)
            let image = NSBitmapImageRep(cgImage: try #require(mask.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            func alpha(atX x: Int, y: Int) throws -> CGFloat {
                let px = Int(Double(x) * Double(image.pixelsWide) / mask.size.width)
                let py = Int(Double(y) * Double(image.pixelsHigh) / mask.size.height)
                return try #require(image.colorAt(x: px, y: py)).alphaComponent
            }
            #expect(try alpha(atX: 2, y: 40) == 0)
            #expect(abs(try alpha(atX: 80, y: 40) - 0.5) < 0.015)
            // These points straddle the voice/tray boundary at y=90. Sampling the
            // reflected position instead would hit the middle of the desktop card.
            #expect(try alpha(atX: 80, y: 90) == 0)
            #expect(abs(try alpha(atX: 80, y: 310) - 0.5) < 0.015)
        }
        #expect(label.superview === material && !label.isHidden && label.alphaValue == 1 && material.alphaValue == 1)
        let reduced = SurfaceGlassLevels(settings.glass, dark: true, reduceTransparency: true)
        #expect(reduced.outerMaterial == 1 && reduced.innerMaterial == 1 && reduced.outerTint == 1 && reduced.innerTint == 1)
    }

    @Test func masterAtFullTransparencyClearsBothGlassLayersButRestoresTheirIndependentValues() {
        var settings = PanelGlassSettings()
        settings.outerTransparency = 55
        settings.innerTransparency = 82
        settings.overallTransparency = 100
        let clear = SurfaceGlassLevels(settings, dark: true, reduceTransparency: false)
        #expect(clear.outerMaterial == 0 && clear.innerMaterial == 0 && clear.outerTint == 0 && clear.innerTint == 0)
        #expect(clear.foldedTint == 0)
        settings.overallTransparency = 0
        let restored = SurfaceGlassLevels(settings, dark: false, reduceTransparency: false)
        #expect(restored.outerTint == 0.45 && restored.innerTint == 0.18)
        #expect(restored.outerMaterial < 1 && restored.innerMaterial < 1)
    }

    @Test func foldedAndSpaceOnlyPanelsUseTheSameMaskWithoutMovingOrFadingTheWindow() async throws {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        let frame = SurfaceRect(width: 800, height: 1200)
        let screen = ScreenGeometry(id: "secondary-mask", frame: frame, visibleFrame: frame)
        var config = DisplaySettings()
        config.glass.overallTransparency = 100
        let window = try #require(panel.window)
        let material = try #require(window.contentView as? NSVisualEffectView)
        for width in [20.0, 240] {
            config.measures[.panelWidth] = .init(width)
            host.setDisplaySettings(config, id: screen.id)
            panel.place(on: screen, primary: "main-fixture", content: .spacesOnly)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                let mask = try #require(material.maskImage)
                let image = NSBitmapImageRep(cgImage: try #require(mask.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                #expect(try #require(image.colorAt(x: 0, y: 0)).alphaComponent == 0)
            }
            #expect(window.frame.width == width && window.alphaValue == 1 && material.alphaValue == 1)
            #expect(material.subviews.filter { !$0.isHidden }.allSatisfy { $0.alphaValue == 1 })
            #expect(!window.isVisible)
        }
    }

    @Test func equalRimUsesPanelWidthForPercentAndNeverChangesReservedWidth() throws {
        let frame = SurfaceRect(width: 1440, height: 900)
        let original = try DesktopWorkArea(display: "fixture", screen: frame, usable: frame, primary: true,
                                           settings: .init(), fallbackEdge: .right)
        var settings = DisplaySettings()
        for measure in [Measure(12), Measure(6, .percent)] {
            settings.glass.rimWidth = measure
            let layout = LayoutComposer.compose(width: 200, height: 800, pinnedCount: 0, expanded: false, settings: settings)
            for section in [layout.voice, layout.screenshots, layout.desktop] {
                let inset = SurfaceCardGeometry.frame(in: section, width: 200, settings: settings)
                #expect(inset.minX - section.x == 12 && inset.minY - section.y == 12)
                #expect(section.x + section.width - inset.maxX == 12 && section.y + section.height - inset.maxY == 12)
            }
            #expect(try DesktopWorkArea(display: "fixture", screen: frame, usable: frame, primary: true,
                                     settings: settings, fallbackEdge: .right) == original)
        }
        settings.glass.innerTransparency = 63
        #expect(settings.restoringSizes(group: .voice).glass == settings.glass)
        let reset = settings.restoringSizes(group: .panel)
        #expect(reset.glass.rimWidth == nil && reset.glass.innerTransparency == 63)
    }

    @Test func livePreviewDoesNotCommitOrLeakToAnotherDisplayAndSavedSettingsRoundTrip() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        defer { host.stop() }
        var glass = PanelGlassSettings()
        glass.overallTransparency = 12.5
        glass.innerTransparency = 72
        glass.outerTransparency = 31
        glass.rimWidth = Measure(3.5, .percent)
        var committedEvents = 0
        host.presentationChanged = { committedEvents += 1 }
        host.previewGlass(glass, on: "right")
        #expect(host.panelPresentationSettings(on: "right").glass == glass)
        #expect(host.panelPresentationSettings(on: "left").glass == .init())
        #expect(store.value.displays["right"] == nil && committedEvents == 0)
        host.previewGlass(nil, on: "right")
        #expect(host.panelPresentationSettings(on: "right").glass == .init())
        let exposure = SettingsPreviewExposure()
        exposure.update(visible: true, miniaturized: false, appHidden: false, sessionUnavailable: false)
        exposure.previewGlass(glass, host: host, display: "right")
        exposure.update(visible: true, miniaturized: true, appHidden: false, sessionUnavailable: false)
        #expect(exposure.glassWithdrawal == 1 && host.panelPresentationSettings(on: "right").glass == .init())
        exposure.previewGlass(glass, host: host, display: "right")
        #expect(host.panelPresentationSettings(on: "right").glass == .init())
        var settings = DisplaySettings()
        settings.glass = glass
        host.setDisplaySettings(settings, id: "right")
        let saved = try JSONEncoder().encode(store.value)
        let restored = try JSONDecoder().decode(HostConfiguration.self, from: saved).validated()
        #expect(restored.displays["right"]?.glass == glass)
        #expect(try JSONDecoder().decode(DisplaySettings.self, from: Data("{}".utf8)).glass == .init())
        var invalid = restored
        invalid.displays["right"]?.glass.overallTransparency = 101
        #expect(throws: ConfigurationError.self) { try invalid.validated() }
    }
}
