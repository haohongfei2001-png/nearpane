import AppKit
import Foundation
import SwiftUI

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

    /// Measures the production hosting view and its rendered content regions.
    /// A nonempty, mounted window is not enough: CI36 accidentally accepted a
    /// 2,157 pt welcome window with its actions far outside a normal display.
    public static func auxiliaryLayout(window: NSWindow, page: LyricAuxiliaryPage) -> [String: Any] {
        guard let view = window.contentView else { return ["layoutPassed": false] }
        view.layoutSubtreeIfNeeded()
        let expected: NSSize
        switch page {
        case .welcome: expected = NSSize(width: 400, height: 360)
        case .settings: expected = NSSize(width: 450, height: 620)
        default: return ["layoutPassed": false, "layoutError": "Unsupported smoke page"]
        }
        let bounds = view.bounds
        let sizeMatches = abs(bounds.width - expected.width) <= 0.5 && abs(bounds.height - expected.height) <= 0.5
        let required = page == .welcome ? ["welcome-heading", "welcome-preview", "welcome-privacy",
                                           "welcome-permission", "welcome-actions"] : []
        let markers = layoutMarkers(in: view).filter { required.contains($0.layoutID) }
        let frames = markers.map { view.convert($0.bounds, from: $0) }
        let regions: [[String: Any]] = zip(markers, frames).map { marker, frame in
            ["id": marker.layoutID, "x": frame.minX, "y": frame.minY,
             "width": frame.width, "height": frame.height]
        }
        let allPresent = Set(markers.map(\.layoutID)) == Set(required) && markers.count == required.count
        let inside = frames.allSatisfy {
            $0.width > 0 && $0.height > 0 && bounds.insetBy(dx: -0.5, dy: -0.5).contains($0)
        }
        let noOverlap = frames.indices.allSatisfy { i in
            frames.indices.filter { $0 > i }.allSatisfy { j in
                let overlap = frames[i].intersection(frames[j])
                return overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5
            }
        }
        return ["expectedWidth": expected.width, "expectedHeight": expected.height,
                "sizeMatchesDesign": sizeMatches, "contentRegions": regions,
                "contentRegionsPresent": allPresent, "contentWithinBounds": inside,
                "contentRegionsDoNotOverlap": noOverlap,
                "layoutPassed": sizeMatches && allPresent && inside && noOverlap]
    }

    private static func layoutMarkers(in view: NSView) -> [LyricAuxiliaryLayoutMarkerView] {
        (view as? LyricAuxiliaryLayoutMarkerView).map { [$0] }
            ?? view.subviews.flatMap { layoutMarkers(in: $0) }
    }
}

/// Transparent layout instrumentation. It has no intrinsic size, does not
/// participate in hit testing, and adds no user-facing controls or test data.
struct LyricAuxiliaryLayoutMarker: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> LyricAuxiliaryLayoutMarkerView {
        LyricAuxiliaryLayoutMarkerView(layoutID: id)
    }
    func updateNSView(_ view: LyricAuxiliaryLayoutMarkerView, context: Context) {}
}

final class LyricAuxiliaryLayoutMarkerView: NSView {
    let layoutID: String
    init(layoutID: String) {
        self.layoutID = layoutID
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
