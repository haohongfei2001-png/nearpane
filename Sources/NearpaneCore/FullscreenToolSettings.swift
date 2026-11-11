import Foundation

public enum FullscreenToolKind: String, CaseIterable, Sendable { case voice, capture }
public enum FullscreenStripCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }
}

/// Stored per display. Expansion is a transient user gesture and is never restored on launch.
public struct FullscreenToolSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var voice = true
    public var capture = true
    public var corner: FullscreenStripCorner = .topRight
    public init() {}

    public func allows(_ kind: FullscreenToolKind) -> Bool {
        enabled && (kind == .voice ? voice : capture)
    }
}

public extension DisplaySettings {
    /// Inputs and result are AppKit screen coordinates. Store only the user's display-local anchor.
    func fullscreenToolFrame(on screen: ScreenGeometry, expanded: Bool, count: Int,
                             confirmedControls: [SurfaceRect] = []) -> SurfaceRect? {
        guard fullscreenTools.enabled, count > 0 else { return nil }
        let safe = screen.visibleFrame
        let width = expanded ? 136.0 : 8 + 24 * Double(min(count, 2))
        let height = expanded ? 34.0 : 26.0
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
