import AppKit
import Foundation
import QuartzCore
import SwiftUI

/// Film-only instrumentation installed in a copied product tree.
/// The on-screen product window, its geometry and its OS input route are unchanged.
@MainActor
enum FilmCaptureSupport {
    static var destination: URL? {
        guard let value = ProcessInfo.processInfo.environment["LYRICTILE_FILM_OUTPUT"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
    private struct PhotographySurface {
        let window: NSPanel
        let view: NSHostingView<AnyView>
    }
    private struct PhotographySession {
        let sourceWindow: NSWindow
        let model: LyricAppModel
        let still: PhotographySurface
        let motion: PhotographySurface
    }
    private static var photography: PhotographySession?

    static func bind(model: LyricAppModel, window: NSWindow) async {
        guard destination != nil, photography == nil else { return }
        func make(_ scale: CGFloat, x: CGFloat) -> PhotographySurface {
            let content = AnyView(LyricPanelView(model: model)
                .frame(width: 208, height: 192)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 208 * scale, height: 192 * scale, alignment: .topLeading)
                .environment(\.displayScale, scale)
                .allowsHitTesting(false))
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 208 * scale, height: 192 * scale)
            let panel = NSPanel(contentRect: NSRect(x: x, y: -4000, width: 208 * scale, height: 192 * scale),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.hidesOnDeactivate = false
            panel.appearance = NSAppearance(named: .aqua); panel.title = "Film-only offscreen photography surface"
            panel.contentView = view; panel.orderFrontRegardless()
            return PhotographySurface(window: panel, view: view)
        }
        photography = PhotographySession(sourceWindow: window, model: model,
            still: make(6, x: -4000), motion: make(4, x: -6000))
        try? await Task.sleep(for: .milliseconds(200))
    }

    static func prepareLayers(_ view: NSView, scale: CGFloat) {
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        func prepare(_ layer: CALayer) {
            layer.contentsScale = scale; layer.rasterizationScale = scale
            layer.shouldRasterize = false; layer.setNeedsDisplay()
            layer.sublayers?.forEach(prepare)
        }
        if let layer = view.layer { prepare(layer) }
        view.needsDisplay = true
        view.subviews.forEach { prepareLayers($0, scale: scale) }
    }
    static func bitmap(view: NSView, scale: Int = 4) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NSError(domain: "FilmCapture", code: 1)
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    static func save(view: NSView, to url: URL, scale: Int = 6) throws {
        let bitmap = try bitmap(view: view, scale: scale)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "FilmCapture", code: 2) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func sourceState(window: NSWindow) -> [String: Any] {
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        let model = photography?.sourceWindow === window ? photography?.model : nil
        return [
            "windowVisible": window.isVisible,
            "sourcePanelFrame": ["x":Double(frame.minX),"y":Double(frame.minY),"width":Double(frame.width),"height":Double(frame.height)],
            "sourceMouse": ["x":Double(mouse.x),"y":Double(mouse.y)],
            "pointerNormalized": ["x":Double((mouse.x-frame.minX)/max(1,frame.width)),"y":Double(1-(mouse.y-frame.minY)/max(1,frame.height))],
            "controlsVisible": model?.controlsVisible ?? false,
            "playbackState": model?.snapshot.state.rawValue ?? "unknown",
            "currentCueIndex": model?.currentCueIndex as Any? ?? NSNull(),
            "positionMS": model?.playbackPositionMS as Any? ?? NSNull(),
            "title": model?.title ?? ""
        ]
    }
    static func capture(window: NSWindow, to url: URL) throws {
        guard let native = window.contentView else { throw NSError(domain:"FilmCapture",code:3) }
        if let photography, photography.sourceWindow === window {
            let original = url.deletingLastPathComponent().appendingPathComponent("source-window-" + url.lastPathComponent)
            try save(view: native, to: original, scale: 1)
            prepareLayers(photography.still.view, scale: 6)
            try save(view: photography.still.view, to: url, scale: 1)
            var report = sourceState(window: window)
            report["kind"] = "production-view-re-render-from-actual-player-state"
            report["logicalWidth"] = 208; report["logicalHeight"] = 192; report["nativeRenderScale"] = 6
            report["sourceWindowImage"] = original.lastPathComponent
            report["sourceWindowGeometryChanged"] = false
            report["photographyInputEnabled"] = false
            report["source"] = "Same live LyricAppModel as the actual Music playback/OS pointer test; a separate offscreen production LyricPanelView at 208x192. No bitmap stretching."
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathExtension("json"))
        } else {
            try save(view: native, to: url, scale: 1)
        }
    }
    static func record(window: NSWindow, name: String, seconds: Double) async {
        guard let destination, let photography, photography.sourceWindow === window else { return }
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return }
        let view = photography.motion.view
        let start = ProcessInfo.processInfo.systemUptime
        var frames: [[String: Any]] = []
        let count = Int(seconds * 30)
        for index in 0..<count {
            let goal = start + Double(index) / 30
            let delay = goal - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let now = ProcessInfo.processInfo.systemUptime
            let name = String(format: "frame-%04d.png", index)
            do {
                prepareLayers(view, scale: 4)
                try save(view: view, to: folder.appendingPathComponent(name), scale: 1)
                var state = sourceState(window: window)
                state["file"] = name; state["elapsed"] = now-start
                frames.append(state)
            } catch { frames.append(["error": error.localizedDescription, "elapsed": now-start]) }
            // PNG work may miss a 30 Hz deadline. Always return to the main run
            // loop so actual mouse events, Music observations and command readback
            // are never starved by the filming observer.
            try? await Task.sleep(for: .milliseconds(2))
        }
        let report: [String: Any] = [
            "kind":"production-view-re-render-from-actual-player-state",
            "source":"Actual Music local original audio, imported original lyrics, same production LyricAppModel as the original panel and real OS pointer target",
            "targetFPS":30,"requestedDuration":seconds,"actualDuration":ProcessInfo.processInfo.systemUptime-start,
            "logicalWidth":208,"logicalHeight":192,"nativeRenderScale":4,"pixelWidth":832,"pixelHeight":768,
            "sourceWindowGeometryChanged":false,"photographyInputEnabled":false,"frames":frames,
            "limitations":"Separate offscreen native production view for consistent 208pt film framing. Original panel receives CGEvent; normalized pointer and visible/state values come from that original panel. This is not WindowServer footage or an uninstrumented performance benchmark. Elapsed timestamps are authoritative."
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to: folder.appendingPathComponent("capture.json"))
        }
    }
}
