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

    /// Presentation generation evidence. Layout continues to use the logical-point rectangles.
    public let rotationDegrees: Double
    public let backingScale: Double

    public init(id: String, frame: SurfaceRect, visibleFrame: SurfaceRect, rotationDegrees: Double = 0, backingScale: Double = 1) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
        self.rotationDegrees = rotationDegrees; self.backingScale = backingScale
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
    public let additionalTools: [String: SurfaceRect]
    public let desktop: SurfaceRect
    public let moduleRail: SurfaceRect?
    public let expanded: SurfaceRect?
    public let railCapacity: Int
    public let overflowCount: Int

    /// The configured desktop section includes the optional tool strip at its leading edge.
    public var windowArea: SurfaceRect {
        guard let moduleRail else { return desktop }
        return SurfaceRect(x: desktop.x, y: desktop.y + moduleRail.height, width: desktop.width,
                           height: desktop.height - moduleRail.height)
    }
}

public enum LayoutComposer {
    public static func compose(width: Double, height: Double, pinnedCount: Int, expanded: Bool,
                               settings: DisplaySettings = .init(), content: PanelContent = .full,
                               voiceEnabled: Bool = true, trayEnabled: Bool = true, referenceHeight: Double? = nil,
                               voiceCompact: Bool = false, trayRows: Int = 1,
                               toolOrder: [String] = [BuiltinCatalog.voice, BuiltinCatalog.screenshots]) -> SurfaceLayout {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let reference = referenceHeight ?? h
        let sizes = settings.contentHeights(reference, content: content, voice: voiceEnabled, tray: trayEnabled)
        let inset = min(settings.glass.inset(width: w), h / 2)
        let bottom = h - inset
        var y = inset
        var frames: [String: SurfaceRect] = [:]
        for id in toolOrder where frames[id] == nil {
            let preferred: Double
            switch id {
            case BuiltinCatalog.voice where sizes.voice > 0:
                preferred = voiceCompact ? 40 : sizes.voice
            case BuiltinCatalog.screenshots where sizes.tray > 0:
                preferred = settings.measures[.trayHeight] == nil && trayRows > 1 ? 144 : sizes.tray
            case BuiltinCatalog.memo, BuiltinCatalog.tasks:
                preferred = content == .full ? 128 : 0
            default: continue
            }
            guard preferred > 0 else { continue }
            let section = SurfaceRect(y: y, width: w, height: min(preferred, max(0, bottom - y)))
            frames[id] = section
            y = min(bottom, y + section.height + sizes.gap)
        }
        let available = content == .full || content == .spacesOnly ? max(0, bottom - y) : 0
        let desktop = SurfaceRect(y: y, width: w, height: min(available, settings.points(.spacesHeight, in: reference)))
        let railHeight = pinnedCount > 0 ? min(settings.points(.railHeight, in: h), desktop.height) : 0
        let windowHeight = desktop.height - railHeight
        let unit = max(1, settings.points(.railButtonWidth, in: w) + 4)
        let capacity = max(1, Int(max(0, w - 16) / unit))
        let empty = SurfaceRect(width: w, height: 0)
        return SurfaceLayout(voice: frames.removeValue(forKey: BuiltinCatalog.voice) ?? empty,
            screenshots: frames.removeValue(forKey: BuiltinCatalog.screenshots) ?? empty, additionalTools: frames,
            desktop: desktop, moduleRail: railHeight > 0 ? SurfaceRect(y: y, width: w, height: railHeight) : nil,
            expanded: expanded ? SurfaceRect(x: min(6, w / 2), y: y + railHeight + min(6, windowHeight / 2),
                width: max(0, w - 12), height: max(0, min(windowHeight, settings.points(.moduleHeight, in: windowHeight)) - 12)) : nil,
            railCapacity: capacity, overflowCount: max(0, pinnedCount - capacity))
    }
}
