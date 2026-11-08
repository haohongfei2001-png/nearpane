import Foundation

/// Surface coordinates are top-left logical points. Screen placement alone uses AppKit coordinates.
public struct SurfaceRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum SurfaceEdge: String, Codable, CaseIterable, Sendable { case left, right }

public struct ScreenGeometry: Equatable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let visibleFrame: SurfaceRect

    public init(id: String, frame: SurfaceRect, visibleFrame: SurfaceRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

public enum SurfacePlacement {
    /// A missing preferred display falls back without rewriting the preference.
    public static func resolve(screens: [ScreenGeometry], preferredID: String?, edge: SurfaceEdge) -> SurfaceRect? {
        let usable = screens.filter {
            [$0.frame, $0.visibleFrame].allSatisfy { rect in
                rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.width > 0 &&
                rect.height.isFinite && rect.height > 0
            }
        }
        guard let screen = usable.first(where: { $0.id == preferredID }) ?? usable.first else { return nil }
        let safe = screen.visibleFrame
        let width = min(max(0, screen.frame.width / 8), max(0, safe.width))
        return SurfaceRect(x: edge == .left ? safe.x : safe.x + safe.width - width,
                           y: safe.y, width: width, height: max(0, safe.height))
    }
}

public struct SurfaceLayout: Equatable, Sendable {
    public let voice: SurfaceRect
    public let screenshots: SurfaceRect
    public let desktop: SurfaceRect
    public let moduleRail: SurfaceRect?
    public let expanded: SurfaceRect?
    public let railCapacity: Int
    public let overflowCount: Int
}

public enum LayoutComposer {
    /// Optional modules live in a scrollable control layer, never in the core vertical stack.
    public static func compose(width: Double, height: Double, pinnedCount: Int, expanded: Bool) -> SurfaceLayout {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let tools = h * 3 / 8
        let desktop = SurfaceRect(y: tools, width: w, height: h - tools)
        let railHeight = min(32, desktop.height)
        let capacity = max(1, Int(max(0, w - 16) / 32))
        return SurfaceLayout(
            voice: SurfaceRect(width: w, height: tools * 0.6),
            screenshots: SurfaceRect(y: tools * 0.6, width: w, height: tools * 0.4),
            desktop: desktop,
            moduleRail: pinnedCount > 0 ? SurfaceRect(y: h - railHeight, width: w, height: railHeight) : nil,
            expanded: expanded ? SurfaceRect(x: min(6, w / 2), y: tools + min(6, desktop.height / 2),
                                             width: max(0, w - 12), height: max(0, desktop.height * 0.68 - 12)) : nil,
            railCapacity: capacity,
            overflowCount: max(0, pinnedCount - capacity)
        )
    }
}
