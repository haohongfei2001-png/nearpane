import AppKit
import SwiftUI
import Testing
import NearpaneCore
@testable import NearpaneUI

/// A plain result holder cannot invalidate the SwiftUI tree while it is being rendered.
@MainActor private final class RendererAccessibilitySample {
    var reducesTransparency: Bool?
}

@MainActor private struct RendererEnvironmentReadback<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    let content: Content
    let sample: RendererAccessibilitySample

    init(content: Content, sample: RendererAccessibilitySample) {
        self.content = content; self.sample = sample
    }

    var body: some View {
        sample.reducesTransparency = reducesTransparency
        return content
    }
}

@MainActor struct DesktopRosterPresentationTests {
    @Test func glassChangesTheBackdropWhileWindowPixelsAndCaptionInkStayOpaque() throws {
        let source = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Leave the right half transparent, as an app can do in its own window.
        source.setFillColor(red: 0.8, green: 0.18, blue: 0.35, alpha: 1)
        source.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(source.makeImage())
        for scheme in [ColorScheme.light, .dark] {
            func render(_ transparency: Double?) throws -> (NSBitmapImageRep, Bool) {
                var glass = PanelGlassSettings()
                glass.overallTransparency = transparency
                glass.innerTransparency = 0
                let view = DesktopWindowCard(label: "窗口 Window", icon: nil, image: image, pictureSize: CGSize(width: 120, height: 60))
                    .frame(width: 144).background {
                        if transparency != nil { SurfaceGlass(radius: 9, settings: glass) }
                    }
                    .environment(\.colorScheme, scheme)
                // ImageRenderer has its own accessibility environment. Observe it
                // beside SurfaceGlass; the system preference is neither injected
                // into the read-only key nor used as a proxy for this renderer.
                let sample = RendererAccessibilitySample()
                let renderer = ImageRenderer(content: RendererEnvironmentReadback(content: view, sample: sample))
                renderer.scale = 2
                let result = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                if let transparency, let dir = ProcessInfo.processInfo.environment["NEARPANE_ROSTER_SAMPLE_DIR"] {
                    let name = "card-\(scheme == .dark ? "dark" : "light")-\(Int(transparency)).png"
                    try #require(result.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                return (result, try #require(sample.reducesTransparency))
            }
            let (solid, reduceTransparency) = try render(0)
            let (clear, clearReducesTransparency) = try render(100)
            let (foreground, foregroundReducesTransparency) = try render(nil)
            try #require(reduceTransparency == clearReducesTransparency && reduceTransparency == foregroundReducesTransparency)
            #expect(solid.pixelsWide == clear.pixelsWide && solid.pixelsHigh == clear.pixelsHigh)
            func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
                try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            }
            for x in [85, 205] {
                let pixel = try color(clear, x, 58)
                let reference = try color(solid, x, 58)
                #expect(pixel.alphaComponent == 1 && pixel == reference)
                if x == 85 {
                    #expect(pixel.redComponent > pixel.greenComponent + 0.3)
                } else {
                    #expect(scheme == .light ? pixel.redComponent > 0.85 : pixel.redComponent < 0.3)
                }
            }
            // Only the intrinsic glyph interiors are fully covered. Antialiased edges naturally blend.
            // Decode an opaque reference in the same bitmap color space as the caption.
            let rgb = scheme == .light ? [37.0, 39, 42] : [241.0, 242, 244]
            let swatch = Color(.sRGB, red: rgb[0]/255, green: rgb[1]/255, blue: rgb[2]/255).frame(width: 2, height: 2)
            let referenceImage = try #require(ImageRenderer(content: swatch).cgImage)
            let expected = try color(NSBitmapImageRep(cgImage: referenceImage), 0, 0)
            var ink = 0
            for y in 124..<(clear.pixelsHigh - 4) {
                for x in 0..<180 {
                    let pixel = try color(foreground, x, y)
                    if pixel.alphaComponent == 1 {
                        ink += 1
                        let reference = try color(solid, x, y)
                        let transparent = try color(clear, x, y)
                        #expect(pixel == reference && pixel == transparent)
                        #expect(pixel == expected)
                    }
                }
            }
            #expect(ink > 25)
            let outside = try color(clear, 278, 58)
            let glassPixel = try color(solid, 278, 58)
            if reduceTransparency {
                #expect(glassPixel.alphaComponent == 1 && outside.alphaComponent == 1)
            } else {
                #expect(glassPixel.alphaComponent == 1 && outside.alphaComponent == 0)
            }
        }
    }

    @Test func nativeRosterStartsAfterToolsAndTheFifthWindowContinuesDown() async throws {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore(), includeSampleModules: false)
        await host.start()
        // This roster fixture supplies no notebook domain. Keep its original,
        // explicitly varied voice/tray/clock combinations independent of presets.
        host.handle(.setEnabled(BuiltinCatalog.memo, false))
        let controller = EdgeWindowController(host: host)
        defer { controller.close(); host.stop() }
        let frame = SurfaceRect(width: 1800, height: 1440)
        let screen = ScreenGeometry(id: "fixture-display", frame: frame, visibleFrame: frame)
        var settings = DisplaySettings()
        settings.measures[.panelWidth] = Measure(220)
        settings.measures[.panelHeight] = Measure(frame.height)
        settings.glass.overallTransparency = 100
        host.setDisplaySettings(settings, id: screen.id)
        let clock = BuiltinCatalog.clock
        let window = try #require(controller.window)
        let surface = try #require(window.contentView)
        for (voice, tray, pinClock, primary, count) in [(true,true,true,true,6), (true,true,false,true,6),
                (true,false,false,true,1), (false,false,true,true,1), (false,false,true,false,1), (false,false,false,true,1),
                (true,true,true,true,18)] {
            host.handle(.setEnabled(BuiltinCatalog.voice, voice))
            host.handle(.setEnabled(BuiltinCatalog.screenshots, tray))
            host.handle(.setEnabled(clock, pinClock))
            host.handle(.setPinned(clock, pinClock))
            let now = Date(), up = ProcessInfo.processInfo.systemUptime
            let windows = (1...count).map { n in
                let r = SurfaceRect(x: Double(10 * n), y: 20, width: 1640, height: n.isMultiple(of: 2) ? 560 : 720)
                return WindowObservation(id: "fixture-\(n)", displayID: screen.id, bounds: r, membership: .unknown,
                    confidence: .unknown, metadata: .init(number: UInt32(n), pid: 100000, launchMicroseconds: 100,
                    element: nil, globalFrame: r, frontToBack: n - 1, minimized: false, fullScreen: false, isOnscreen: true,
                    onActiveDesktop: true, hasCatalogGeometry: true))
            }
            let sample = DesktopSnapshot.observed(.init(session: UUID(), revision: 1, parentPID: 1, fixtureWindows: windows.compactMap { $0.metadata?.number },
                anchors: [], experimentalSpaces: false), from: now, to: now, build: "fixture", topology: "one",
                consistent: true, separateSpaces: true, displays: [.init(id: screen.id, frame: frame, rotationDegrees: 0,
                    backingScale: 1, usable: frame)], scopes: [], windows: windows, evidence: .init(population: .markedFixture,
                    accessibility: .denied, spaces: .unavailable, rows: [], windowLimitReached: false, beganUptime: up, endedUptime: up))
            host.bus.resetDesktopSession()
            try #require(host.bus.acceptDesktop(sample))
            let content: PanelContent = voice || tray || (pinClock && primary) ? .full : .spacesOnly
            controller.place(on: screen, primary: primary ? screen.id : "other-display", content: content)
            // The live roster intentionally renders only for a presented panel. Exercise
            // that existing lifecycle with synthetic observations and no domain services.
            controller.presentIfNeeded()
            try #require(window.isVisible && !window.isKeyWindow)
            surface.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(70))
            surface.displayIfNeeded()
            let hosting = try #require(surface.subviews.first { $0 is NSHostingView<EdgeSurfaceView> })
            let pixels = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: pixels)
            if let dir = ProcessInfo.processInfo.environment["NEARPANE_ROSTER_SAMPLE_DIR"] {
                try #require(pixels.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath:dir).appendingPathComponent("roster-\(voice)-\(tray)-\(pinClock)-\(primary)-\(count).png"))
            }
            let layout = LayoutComposer.compose(width: 220, height: frame.height, pinnedCount: 0,
                expanded: false, settings: settings, content: content, voiceEnabled: voice, trayEnabled: tray,
                toolOrder: host.registry.preferences.filter(\.enabled).map(\.id))
            // The wide picture band and its caption repeat at the same x. A second column
            // or a centered list changes both the count and the first band's y coordinate.
            let scale = CGFloat(pixels.pixelsWide) / hosting.bounds.width
            let rim = settings.glass.inset(width: 220)
            let contentWidth = layout.windowArea.width - 2 * rim
            let inset = settings.points(.spacePadding, in: contentWidth) + 4
            let firstY = layout.windowArea.y + inset
            let imageWidth = contentWidth - 2 * inset
            let stroke = settings.points(.borderWidth, in: imageWidth)
            let heights = windows.map { min(imageWidth * 0.5, imageWidth * $0.bounds.height / $0.bounds.width) - 2 * stroke }
            let rowGap = settings.points(.spaceRowGap, in: frame.height)
            var cursor = firstY
            let fullyVisible = heights.prefix { height in
                defer { cursor += height + 2 * stroke + 18 + rowGap }
                return cursor + height + 2 * stroke <= layout.windowArea.y + layout.windowArea.height
            }.count
            func pictureBands(at fraction: Double) throws -> [Range<Int>] {
                let x = Int(Double(pixels.pixelsWide) * fraction)
                func tone(_ y: Int) throws -> [Int] {
                    let c = try #require(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
                }
                let bandTone = try tone(Int((firstY + min(20, heights[0] / 2)) * scale))
                var runs: [Range<Int>] = [], start: Int?
                for y in Int(layout.windowArea.y * scale)..<pixels.pixelsHigh {
                    let matches = try tone(y) == bandTone
                    if matches && start == nil { start = y }
                    if !matches, let first = start {
                        if heights.contains(where: { abs(CGFloat(y - first) / scale - $0) <= 2 }) { runs.append(first..<y) }
                        start = nil
                    }
                }
                return runs
            }
            let left = try pictureBands(at: 0.23)
            let right = try pictureBands(at: 0.76)
            try #require(left.count == fullyVisible && right.count == fullyVisible, "left \(left), right \(right), expected first at \(firstY) pt and \(fullyVisible) complete cards")
            #expect(abs(CGFloat(left[0].lowerBound) / scale - firstY) <= 2)
            for (index, band) in left.enumerated() {
                #expect(abs(CGFloat(band.count) / scale - heights[index]) <= 2)
                #expect(abs(CGFloat(right[index].lowerBound - band.lowerBound) / scale) <= 1)
            }
            for (a, b) in zip(left, left.dropFirst()) {
                #expect(CGFloat(b.lowerBound - a.upperBound) / scale > 18)
                #expect(CGFloat(b.lowerBound - a.upperBound) / scale < 42)
            }
            if count > 6 {
                let last = try #require(left.last)
                #expect(CGFloat(last.upperBound) / scale < layout.windowArea.y + layout.windowArea.height)
                #expect(left.count < count && left.count >= 5)
                func containsScroller(_ view: NSView) -> Bool {
                    view is NSScrollView || view.subviews.contains { containsScroller($0) }
                }
                // The tools above the roster may have their own independent scroll view.
                // Supply the same presentation prerequisites to this isolated roster fixture.
                let display = SurfaceDisplay()
                display.id = screen.id
                display.interactionVisible = true
                let desktopView = NSHostingView(rootView: DesktopSurface(host: host, displayID: screen.id, enabled: true, display: display)
                    .frame(width: 220, height: 500))
                desktopView.layoutSubtreeIfNeeded()
                #expect(containsScroller(desktopView))
            }
            controller.hide()
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }
}
