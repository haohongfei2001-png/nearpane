import AppKit
import Foundation
import QuartzCore
import SwiftUI

/// Film-only instrumentation installed in a copied product tree.
/// WindowServer mode uses the sole original controller window at explicit film framing.
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
    private static var filmingBackdrop: NSPanel?
    private static var probeControl: NSPanel?
    private static var captureScreen: NSScreen?
    static var photographyFrame: NSRect?
    static var useStableCueTransition = false
    private static var activeTakeName: String?
    private static var motionGates: [String: [[String: Any]]] = [:]
    static var windowServerEnabled: Bool { ProcessInfo.processInfo.environment["LYRICTILE_FILM_WINDOWSERVER"] == "1" }
    static func inputWindowNumber(fallback: NSWindow) -> Int {
        windowServerEnabled ? (photography?.motion.window.windowNumber ?? fallback.windowNumber) : fallback.windowNumber
    }

    static func bind(model: LyricAppModel, window: NSWindow) async {
        guard destination != nil, photography == nil else { return }
        if windowServerEnabled {
            await bindSingleProductionView(model: model, window: window)
            return
        }
        func make(_ scale: CGFloat, x: CGFloat, visible: Bool = false) -> PhotographySurface {
            let content = AnyView(LyricPanelView(model: model)
                .frame(width: 208, height: 192)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 208 * scale, height: 192 * scale, alignment: .topLeading)
                .environment(\.displayScale, scale)
                .allowsHitTesting(visible))
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 208 * scale, height: 192 * scale)
            let panel = LyricNonactivatingPanel(contentRect: NSRect(x: x, y: visible ? 96 : -4000, width: 208 * scale, height: 192 * scale),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.hidesOnDeactivate = false
            panel.appearance = NSAppearance(named: .aqua); panel.title = "Film-only offscreen photography surface"
            panel.contentView = view
            if visible { panel.level = .floating; panel.ignoresMouseEvents = false }
            prepareLayers(view, scale: scale)
            panel.orderFrontRegardless()
            return PhotographySurface(window: panel, view: view)
        }
        photography = PhotographySession(sourceWindow: window, model: model,
            still: make(6, x: -4000),
            motion: make(4, x: -6000))
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func bindSingleProductionView(model: LyricAppModel, window: NSWindow) async {
        guard let panel = window as? NSPanel else { return }
        let screens = NSScreen.screens
        let desiredID = UInt32(ProcessInfo.processInfo.environment["NEARPANE_FILM_DISPLAY_ID"] ?? "")
        let screen = screens.first { candidate in
            guard let desiredID else { return false }
            return (candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == desiredID
        } ?? screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) ?? NSScreen.main!
        captureScreen = screen
        let bounds = screen.frame
        let frame = NSRect(x: bounds.minX+32, y: bounds.maxY-192-48, width: 208, height: 192)
        let plate = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        plate.isReleasedWhenClosed = false; plate.hasShadow = false; plate.isOpaque = true
        plate.backgroundColor = NSColor(srgbRed: 0.965, green: 0.969, blue: 0.965, alpha: 1)
        plate.ignoresMouseEvents = true; plate.hidesOnDeactivate = false; plate.level = .normal
        plate.title = "Neutral filming backdrop"; plate.orderFrontRegardless(); filmingBackdrop = plate
        // Remove and release the original hosting hierarchy before constructing
        // its sole replacement. There are no mirrored production views.
        panel.contentView = nil
        try? await Task.sleep(for: .milliseconds(200))
        let view = NSHostingView(rootView: AnyView(LyricPanelView(model: model).frame(width: 208, height: 192)))
        view.frame = NSRect(x: 0, y: 0, width: 208, height: 192)
        photographyFrame = frame
        panel.setFrame(frame, display: true, animate: false)
        panel.contentView = view; panel.orderFrontRegardless()
        let surface = PhotographySurface(window: panel, view: view)
        photography = PhotographySession(sourceWindow: panel, model: model, still: surface, motion: surface)
        try? await Task.sleep(for: .milliseconds(300))
        if let destination {
            let report: [String: Any] = [
                "kind": "single-production-view-in-original-controller-window",
                "productionViewCount": 1, "sourceWindowNumber": panel.windowNumber,
                "logicalSize": [208,192], "actualWindowBackingScale": Double(panel.backingScaleFactor),
                "actualViewBackingPixels": [Double(view.convertToBacking(view.bounds).width), Double(view.convertToBacking(view.bounds).height)],
                "screenBackingScale": Double(screen.backingScaleFactor),
                "displayID": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value as Any? ?? NSNull(),
                "reduceMotionSystemPreference": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "sourceWindowGeometryChangedForPhotography": true,
                "viewScaleEffect": false, "forcedDisplayScale": false,
                "offscreenProductionViews": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: destination.appendingPathComponent("single-view-photography.json"))
            }
        }
    }
    static func showAnimationControl(_ shown: Bool) {
        if !shown { probeControl?.orderOut(nil); probeControl?.close(); probeControl = nil; return }
        guard probeControl == nil, let frame = photographyFrame else { return }
        let panel = NSPanel(contentRect: NSRect(x: frame.maxX+32, y: frame.minY+40, width: 300, height: 90),
            styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hasShadow = false; panel.isOpaque = true
        panel.backgroundColor = .white; panel.ignoresMouseEvents = true; panel.level = .floating
        panel.contentView = NSHostingView(rootView: FilmAnimationControl())
        panel.orderFrontRegardless(); probeControl = panel
    }
    static func recordMotionGate(previous: Int?, current: Int?, selectionStable: Bool,
        reduceMotion: Bool, controls: Bool, browsing: Bool, seeking: Bool,
        performing: Bool, playing: Bool, flows: Bool) {
        guard let name = activeTakeName else { return }
        motionGates[name,default:[]].append([
            "hostUptime": ProcessInfo.processInfo.systemUptime,
            "previousIndex": previous as Any? ?? NSNull(), "currentIndex": current as Any? ?? NSNull(),
            "selectionStable": selectionStable, "reduceMotionEnvironment": reduceMotion,
            "controlsVisible": controls, "browsing": browsing, "seeking": seeking,
            "performingCommand": performing, "playing": playing, "flowsUpward": flows,
            "stableTransitionCandidate": useStableCueTransition])
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

    static func restoreWindowServerSurfaceIfSourceVisible() {
        guard let photography, photography.sourceWindow.isVisible else { return }
        if !photography.motion.window.isVisible { photography.motion.window.orderFrontRegardless() }
    }
    private static var screenStates: [String: [[String: Any]]] = [:]
    struct ScreenTake {
        let token: String
        let start: Double
        let name: String
        let folder: URL
        let requestedSeconds: Double
        let sampler: Task<Void, Never>
    }
    static func beginScreenTake(_ name: String, seconds: Double) async throws -> ScreenTake {
        guard let destination, let photography else { throw NSError(domain: "FilmScreen", code: 1) }
        let folder = destination.appendingPathComponent("windowserver", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let screen = captureScreen ?? NSScreen.screens.first!
        let displayIndex = Int(ProcessInfo.processInfo.environment["NEARPANE_FILM_SCREEN_INDEX"] ?? "") ?? ((NSScreen.screens.firstIndex(where: { $0 === screen }) ?? 0)+1)
        let request: [String: Any] = ["token": token, "name": name, "seconds": Int(seconds), "displayIndex": displayIndex]
        activeTakeName = name; motionGates[name] = []
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        let requestStart = ProcessInfo.processInfo.systemUptime
        var acknowledged = false
        while ProcessInfo.processInfo.systemUptime-requestStart < 8 {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("started.json")),
               let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], report["token"] as? String == token {
                acknowledged = true; break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard acknowledged else { throw NSError(domain: "FilmScreenRecorderHandshake", code: 2) }
        let start = ProcessInfo.processInfo.systemUptime
        let sampler = Task { @MainActor in
            var rows: [[String: Any]] = []
            while ProcessInfo.processInfo.systemUptime - start < seconds + 0.5 {
                let original = photography.sourceWindow
                let photo = photography.motion.window
                let frame = photo.frame
                let mouse = NSEvent.mouseLocation
                var row = sourceState(window: original)
                row["elapsed"] = ProcessInfo.processInfo.systemUptime - start
                row["photographyWindowVisible"] = photo.isVisible
                row["photographyPanelFrame"] = ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
                row["photographyPointerNormalized"] = ["x": Double((mouse.x-frame.minX)/frame.width), "y": Double(1-(mouse.y-frame.minY)/frame.height)]
                rows.append(row)
                try? await Task.sleep(for: .milliseconds(16))
            }
            screenStates[name] = rows
        }
        return ScreenTake(token: token, start: start, name: name, folder: folder, requestedSeconds: seconds, sampler: sampler)
    }
    static func finishScreenTake(_ take: ScreenTake) async -> Bool {
        var recorderResult: [String: Any] = ["exitCode": -2]
        while true {
            if let data = try? Data(contentsOf: take.folder.appendingPathComponent("done.json")),
               let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], report["token"] as? String == take.token {
                recorderResult = report; break
            }
            if ProcessInfo.processInfo.systemUptime-take.start >= take.requestedSeconds+18 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await take.sampler.value
        let rows = screenStates.removeValue(forKey: take.name) ?? []
        let screen = captureScreen ?? NSScreen.screens.first!
        let backingScale = screen.backingScaleFactor
        let frame = photography?.motion.window.frame ?? NSRect(x: 32, y: 96, width: 624, height: 576)
        let report: [String: Any] = [
            "kind": "actual-WindowServer-video-of-production-photography-view",
            "recording": take.name + "-fullscreen.mov",
            "processExitCode": recorderResult["exitCode"] as Any? ?? NSNull(),
            "recorderResult": recorderResult,
            "cursorIncluded": true,
            "requestedSeconds": take.requestedSeconds,
            "captureStartHostUptime": take.start,
            "cropTopLeftPixels": [Int((frame.minX-screen.frame.minX)*backingScale), Int((screen.frame.maxY-frame.maxY)*backingScale), Int(frame.width*backingScale), Int(frame.height*backingScale)],
            "screenBackingScale": Double(backingScale),
            "filmingBackdrop": "Separate neutral NSPanel RGB(0.965,0.969,0.965), below photography window, input disabled; production popover material unchanged",
            "logicalSize": [208,192], "nativeDisplayScale": Double(backingScale),
            "productionViewCount": 1, "scaleEffect": false, "forcedDisplayScale": false,
            "stableTransitionCandidate": useStableCueTransition,
            "motionGateTrace": motionGates[take.name] ?? [],
            "reduceMotionSystemPreference": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "sourceWindowGeometryChanged": true,
            "inputTarget": "The sole production LyricPanelView inside the original controller window, framed at 208x192 logical points on the native display; real CGEvent and fresh AX hit testing",
            "source": "Actual Music playing original local audio; original LRC imported through production repository. No synthetic playback clock and no bitmap animation.",
            "limitations": "Original controller window has film-only framing and its sole production view uses actual display backing resolution. No mirrored views or cacheDisplay motion. Fullscreen MOV is primary evidence; sampled state timestamps are not frame-perfect media timestamps. Stable-transition candidate removes only cueTransition guard in the temporary capture copy and is unreleased until independently accepted.",
            "states": rows]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: take.folder.appendingPathComponent(take.name + ".json"))
        }
        activeTakeName = nil
        return recorderResult["exitCode"] as? Int == 0
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
