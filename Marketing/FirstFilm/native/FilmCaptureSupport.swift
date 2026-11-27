import AppKit
import Foundation

/// Film-only instrumentation, added to an isolated build by prepare_capture.py.
/// Production UI and player logic are unchanged. Frames contain the existing native view.
@MainActor
enum FilmCaptureSupport {
    static var destination: URL? {
        guard let value = ProcessInfo.processInfo.environment["LYRICTILE_FILM_OUTPUT"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
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
    static func record(window: NSWindow, name: String, seconds: Double) async {
        guard let destination, let view = window.contentView else { return }
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return }
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
                try save(view: view, to: folder.appendingPathComponent(name), scale: 4)
                frames.append(["file": name, "elapsed": now-start, "windowVisible": window.isVisible])
            } catch { frames.append(["error": error.localizedDescription, "elapsed": now-start]) }
        }
        let report: [String: Any] = ["kind":"real-native-app-view-sequence", "source":"real Music local original audio and imported original lyrics", "targetFPS":30, "requestedDuration":seconds, "actualDuration":ProcessInfo.processInfo.systemUptime-start,"logicalWidth":view.bounds.width,"logicalHeight":view.bounds.height,"renderScale":4,"frames":frames,"limitations":"Native view render at 4x; not a full WindowServer desktop screen recording. Frame elapsed timestamps are authoritative."]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to: folder.appendingPathComponent("capture.json"))
        }
    }
}
