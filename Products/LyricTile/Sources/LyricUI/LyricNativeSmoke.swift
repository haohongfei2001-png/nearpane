import AppKit
import Foundation

/// Captures only the application's own existing NSView. Does not manufacture a player or song.
@MainActor
public enum LyricNativeSmoke {
    public enum CaptureFailure: Error { case missingView, emptyBounds, bitmapUnavailable, encodingFailed }

    public static func capture(window: NSWindow, to destination: URL) throws {
        guard let view = window.contentView else { throw CaptureFailure.missingView }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0 else { throw CaptureFailure.emptyBounds }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CaptureFailure.bitmapUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureFailure.encodingFailed }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
    }
}
