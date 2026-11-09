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
    public static func resolve(screens: [ScreenGeometry], preferredID: String?, edge: SurfaceEdge, settings: [String: DisplaySettings] = [:]) -> SurfaceRect? {
        let usable = screens.filter {
            [$0.frame, $0.visibleFrame].allSatisfy { rect in
                rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.width > 0 &&
                rect.height.isFinite && rect.height > 0
            }
        }
        guard let screen = usable.first(where: { $0.id == preferredID }) ?? usable.first else { return nil }
        return (settings[screen.id] ?? .init()).panel(on:screen,fallbackEdge:edge)
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
    public static func compose(width: Double, height: Double, pinnedCount: Int, expanded: Bool,
                               settings: DisplaySettings = .init(), content: PanelContent = .full,
                               voiceEnabled: Bool = true, trayEnabled: Bool = true, referenceHeight: Double? = nil) -> SurfaceLayout {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let sizes = settings.contentHeights(referenceHeight ?? h, content: content, voice: voiceEnabled, tray: trayEnabled)
        let voice = min(h, sizes.voice)
        let trayY = min(h, voice + (voice > 0 && sizes.tray > 0 ? sizes.gap : 0))
        let tray = min(h - trayY, sizes.tray)
        let tools = min(h, trayY + tray + (trayY + tray > 0 && sizes.spaces > 0 ? sizes.gap : 0))
        let desktop = SurfaceRect(y: tools, width: w, height: min(h - tools, sizes.spaces))
        let railHeight = min(settings.points(.railHeight,in:h), desktop.height)
        let unit = max(1, settings.points(.railButtonWidth,in:w) + 4)
        let capacity = max(1, Int(max(0, w - 16) / unit))
        return SurfaceLayout(
            voice: SurfaceRect(width:w, height:voice),
            screenshots: SurfaceRect(y:trayY,width:w,height:tray),
            desktop: desktop,
            moduleRail: pinnedCount > 0 ? SurfaceRect(y: tools + desktop.height - railHeight, width:w, height:railHeight) : nil,
            expanded: expanded ? SurfaceRect(x: min(6, w / 2), y: tools + min(6, desktop.height / 2),
                                             width:max(0,w - 12),height:max(0, settings.points(.moduleHeight,in:desktop.height) - 12)) : nil,
            railCapacity: capacity,
            overflowCount: max(0, pinnedCount - capacity)
        )
    }
}
