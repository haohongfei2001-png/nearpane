import AppKit
import SwiftUI
import Testing
@testable import NearpaneUI
import NearpaneCore

@MainActor struct SurfaceGlassTests {
    @Test func fourSidedInsetsKeepTheSavedOuterFrameAndModuleRatios() {
        for width in [100.0, 180, 240, 480] {
            let layout = LayoutComposer.compose(width: width, height: 960, pinnedCount: 0, expanded: false)
            for section in [layout.voice, layout.screenshots, layout.desktop] {
                let frame = SurfaceCardGeometry.frame(in: section, width: width)
                let inset = PanelSizeMetrics.cardInset(width: width)
                #expect(abs(frame.minX - section.x - inset) < 0.00001)
                #expect(abs(frame.minY - section.y - inset) < 0.00001)
                #expect(abs(section.x + section.width - frame.maxX - inset) < 0.00001)
                #expect(abs(section.y + section.height - frame.maxY - inset) < 0.00001)
            }
            #expect(layout.voice.height + layout.screenshots.height == 960 * 3 / 8)
            #expect(layout.desktop.y + layout.desktop.height == 960)
        }
        let tiny = SurfaceCardGeometry.frame(in: .init(width: 2, height: 2), width: 2)
        #expect(tiny.width == 0 && tiny.height == 0)
    }

    @Test func widerFrameCannotHideTheLastVoiceLineInsideItsLargerUniformInset() {
        var settings = DisplaySettings()
        settings.measures[.voiceHeight] = .init(75)
        #expect(settings.sizeForm(width: 240, height: 960, content: .voiceOnly, voice: true, tray: false) == .compact)
        settings.measures[.voiceHeight] = .init(79)
        #expect(settings.sizeForm(width: 240, height: 960, content: .voiceOnly, voice: true, tray: false) == .full)
        #expect(settings.measures[.voiceHeight] == .init(79))
    }

    @Test func outerGlassIsLessTransparentAndAccessibilityCanRemoveTransparency() {
        for dark in [false, true] {
            for contrast in [false, true] {
                let transparent = SurfaceGlassPalette(dark: dark, increasedContrast: contrast, reduceTransparency: false)
                #expect(transparent.outerOpacity > transparent.innerOpacity)
                let opaque = SurfaceGlassPalette(dark: dark, increasedContrast: contrast, reduceTransparency: true)
                #expect(opaque.outerOpacity == 1 && opaque.innerOpacity == 1)
            }
        }
    }

    @Test func hiddenPanelMaterialTracksPresentedWidthAndCustomCardRadius() async throws {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        let frame = SurfaceRect(width: 1600, height: 960)
        let screen = ScreenGeometry(id: "geometry-fixture", frame: frame, visibleFrame: frame)
        var settings = DisplaySettings()
        let surface = try #require(panel.window?.contentView)
        #expect(surface.subviews.first is PanelGlassMaterial)
        let layer = try #require(surface.layer)
        for (width, corner) in [(120.0, nil as Measure?), (240, nil), (240, Measure(8, .percent))] {
            settings.measures[.panelWidth] = Measure(width)
            settings.measures[.cornerRadius] = corner
            host.setDisplaySettings(settings, id: screen.id)
            panel.place(on: screen, primary: screen.id, content: .full)
            let presented = Double(try #require(panel.window?.frame.width))
            #expect(presented == width)
            let expected = (corner?.points(in: presented) ?? 18) + PanelSizeMetrics.cardInset(width: presented)
            #expect(abs(Double(layer.cornerRadius) - expected) < 0.00001)
            #expect(layer.cornerCurve == .continuous && panel.window?.isVisible == false)
        }
    }

    @Test func renderedCornerRimsFollowTheInsetAroundAllFourCorners() throws {
        let width = 240.0, height = 640.0, scale = 4
        var settings = DisplaySettings()
        for corner in [nil as Measure?, Measure(44), Measure(10, .percent)] {
            settings.measures[.cornerRadius] = corner
            let layout = LayoutComposer.compose(width: width, height: height, pinnedCount: 0,
                                                expanded: false, settings: settings)
            let renderer = ImageRenderer(content: SurfaceShell(layout: layout, width: width, settings: settings)
                .frame(width: width, height: height).environment(\.colorScheme, .light))
            renderer.scale = CGFloat(scale)
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            for left in [false, true] {
                for top in [false, true] {
                    // Follow the diagonal from outside the rounded shell, across its rim,
                    // and into the untouched card cutout. Measure thickness in points.
                    let alpha = (0..<(55 * scale)).map { step in
                        rep.colorAt(x: left ? step : rep.pixelsWide - 1 - step,
                                    y: top ? step : rep.pixelsHigh - 1 - step)!.alphaComponent
                    }
                    let start = try #require(alpha.firstIndex(where: { $0 > 0.25 }))
                    let end = try #require(alpha[start...].firstIndex(where: { $0 < 0.25 }))
                    let thickness = Double(end - start) * 2.squareRoot() / Double(scale)
                    #expect(start > 0)
                    #expect(abs(thickness - PanelSizeMetrics.cardInset(width: width)) <= 1.5)
                }
            }
        }
    }

    @Test func recommendedTintLetsTheInnerCardTransmitMoreOfTheBackdrop() throws {
        // Exercise the actual SwiftUI fills independently of WindowServer's adaptive blur.
        let width = 144.0, height = 112.0
        let area = SurfaceRect(width: width, height: height)
        let card = SurfaceCardGeometry.frame(in: area, width: width)
        let layout = LayoutComposer.compose(width: width, height: height, pinnedCount: 0, expanded: false,
                                            content: .spacesOnly)
        let backgrounds: [(String, Color)] = [
            ("graphite", Color(red: 0.14, green: 0.17, blue: 0.22)),
            ("lavender", Color(red: 0.51, green: 0.55, blue: 0.86)),
            ("sage", Color(red: 0.52, green: 0.66, blue: 0.58)),
            ("paper", Color(red: 0.95, green: 0.94, blue: 0.91))
        ]
        for scheme in [ColorScheme.light, .dark] {
            var shellSamples = [CGFloat](), cardSamples = [CGFloat]()
            for (name, background) in backgrounds {
                let view = ZStack {
                    background
                    SurfaceShell(layout: layout, width: width, settings: .init())
                    SurfaceGlass().frame(width: card.width, height: card.height)
                }.frame(width: width, height: height).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                func red(_ x: Int) throws -> CGFloat {
                    try #require(rep.colorAt(x: x, y: 56)?.usingColorSpace(.sRGB)).redComponent
                }
                shellSamples.append(try red(3))
                cardSamples.append(try red(72))
                if let directory = ProcessInfo.processInfo.environment["NEARPANE_GLASS_SAMPLE_DIR"] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(
                        (scheme == .dark ? "dark-" : "light-") + name + ".png")
                    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            #expect(shellSamples == shellSamples.sorted() && cardSamples == cardSamples.sorted())
            let shellRange = try #require(shellSamples.last) - (try #require(shellSamples.first))
            let cardRange = try #require(cardSamples.last) - (try #require(cardSamples.first))
            #expect(shellRange > 0.25 && cardRange > shellRange + 0.15)
        }
    }

    @Test func renderedShellHasEvenEdgesAndDoesNotTintUnderCards() throws {
        // Real SwiftUI render with no window, no desktop capture and no fake blur.
        // Test the actual alpha, not a second interpretation of the palette constants.
        let width = 240.0, height = 480.0
        let layout = LayoutComposer.compose(width: width, height: height, pinnedCount: 0, expanded: false)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: SurfaceShell(layout: layout, width: width, settings: .init())
                .frame(width: width, height: height).environment(\.colorScheme, scheme))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            let alpha = { (x: Int, y: Int) in rep.colorAt(x: x, y: y)!.alphaComponent }
            // Both coordinate origins are covered by symmetric top/bottom sampling.
            let edges = [alpha(3, 50), alpha(236, 50), alpha(120, 3), alpha(120, 476)]
            #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.01 })
            #expect(edges[0] > 0.35)
            for section in [layout.voice, layout.screenshots, layout.desktop] {
                let y = Int(section.y + section.height / 2)
                #expect(alpha(120, y) == 0)
            }
            let card = ImageRenderer(content: SurfaceGlass(radius: 18).frame(width: 100, height: 100)
                .environment(\.colorScheme, scheme))
            let cardRep = NSBitmapImageRep(cgImage: try #require(card.cgImage))
            let innerAlpha = try #require(cardRep.colorAt(x: 50, y: 50)).alphaComponent
            #expect(innerAlpha > 0 && innerAlpha < edges[0])
        }
    }
}
