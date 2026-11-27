import Foundation

public enum FullscreenToolKind: String, CaseIterable, Sendable {
    case workspace
    // Retained for source compatibility with earlier presentation receipts.
    case voice, capture
}
public enum FullscreenStripCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }
}

/// Stored per display. Expansion is a transient user gesture and is never restored on launch.
public struct FullscreenToolSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Legacy preferences remain decodable, but module visibility now follows the
    /// one Host registry. They no longer select a second fullscreen module set.
    public var voice = true
    public var capture = true
    public var corner: FullscreenStripCorner = .topRight
    public init() {}

    public func allows(_ kind: FullscreenToolKind) -> Bool {
        enabled
    }
}

/// Uses the exact shared sidebar composition, without Spaces or new domain instances.
public struct FullscreenWorkspaceLayout: Equatable, Sendable {
    public static let headerHeight = 32.0
    public let width: Double
    public let height: Double
    public let content: SurfaceLayout
    public let visibleModuleIDs: [String]
    public var viewportHeight: Double { height - Self.headerHeight }

    public init?(on screen: ScreenGeometry, settings: DisplaySettings, enabledModuleIDs: [String],
                 pinnedCount: Int = 0, expandedSample: Bool = false,
                 voiceCompact: Bool = false, trayRows: Int = 1, lyricsHeight: Double = 0) {
        guard screen.visibleFrame.geometry.isValid else { return nil }
        let width = WorkbenchVisualPolicy.width(in: screen.visibleFrame.width, settings: settings)
        let maximum = min(720, screen.visibleFrame.height - 16)
        guard width > 0, maximum > Self.headerHeight else { return nil }
        let order = enabledModuleIDs.filter { $0 != BuiltinCatalog.desktop }
        func compose(_ height: Double) -> SurfaceLayout {
            LayoutComposer.compose(width: width, height: height, pinnedCount: pinnedCount,
                expanded: expandedSample, settings: settings, content: .toolsOnly,
                voiceEnabled: order.contains(BuiltinCatalog.voice), trayEnabled: order.contains(BuiltinCatalog.screenshots),
                referenceHeight: screen.visibleFrame.height, voiceCompact: voiceCompact,
                trayRows: trayRows, lyricsHeight: lyricsHeight, toolOrder: order)
        }
        let initial = compose(maximum - Self.headerHeight)
        guard initial.voice.height > 0 || initial.screenshots.height > 0 ||
                initial.additionalTools.values.contains(where: { $0.height > 0 }) || initial.moduleRail != nil else { return nil }
        let height = min(maximum, initial.contentHeight + Self.headerHeight)
        let content = compose(height - Self.headerHeight)
        var seen = Set<String>()
        self.visibleModuleIDs = order.filter { seen.insert($0).inserted && content.frame(for: $0) != nil }
        self.width = width; self.height = height; self.content = content
    }
}

public extension DisplaySettings {
    /// Inputs and result are AppKit screen coordinates. Store only the user's display-local anchor.
    func fullscreenToolFrame(on screen: ScreenGeometry, expanded: Bool, count: Int,
                             confirmedControls: [SurfaceRect] = [], workspace: FullscreenWorkspaceLayout? = nil) -> SurfaceRect? {
        guard fullscreenTools.enabled, count > 0 else { return nil }
        let safe = screen.visibleFrame
        let width = expanded ? (workspace?.width ?? 136) : 104
        let height = expanded ? (workspace?.height ?? 34) : 28
        let corner = fullscreenTools.corner
        var proposed = SurfaceRect(x: corner.left ? safe.x + 8 : safe.x + safe.width - width - 8,
                                   y: corner.top ? safe.y + safe.height - height - 8 : safe.y + 8,
                                   width: width, height: height)
        if expanded, let anchor = toolAnchor?.anchor {
            proposed.x = screen.frame.x + anchor.x
            proposed.y = screen.frame.y + anchor.y
        }
        return FloatingToolSurface(anchor: proposed).placement(safe: safe, confirmedControls: confirmedControls)
    }

    mutating func saveFullscreenToolFrame(_ frame: SurfaceRect, on screen: ScreenGeometry) {
        guard frame.geometry.isValid, screen.frame.geometry.isValid,
              screen.visibleFrame.geometry.intersection(frame.geometry) == frame.geometry else { return }
        let local = SurfaceRect(x: frame.x - screen.frame.x, y: frame.y - screen.frame.y,
                                width: frame.width, height: frame.height)
        var surface = toolAnchor ?? FloatingToolSurface(anchor: local)
        surface.userMoved(to: local)
        toolAnchor = surface
    }
}
