import Foundation

public extension SurfaceRect {
    /// Largest whole-point rectangle inside the exact reservation. Rounding outward
    /// would let an ordinary AppKit window cover a fraction of the sidebar or Dock.
    var integralInterior: Self {
        let left = ceil(x), top = ceil(y)
        return .init(x: left, y: top, width: floor(x + width) - left, height: floor(y + height) - top)
    }
}

/// Global Quartz logical points, after display rotation and conversion of the usable inset.
public struct DesktopWorkArea: Equatable, Sendable {
    public enum ReservationError: LocalizedError, Equatable {
        case narrowerThanPanel

        public var errorDescription: String? {
            "独立预留宽度小于面板及其侧边留距。请增加持久预留宽度，或恢复随面板调整。"
        }
    }
    public let display: String, screen: SurfaceRect, ordinary: SurfaceRect
    public init(
        display: String, screen: SurfaceRect, usable: SurfaceRect, primary: Bool,
        settings: DisplaySettings, fallbackEdge: SurfaceEdge
    ) throws {
        guard screen.geometry.isValid, usable.geometry.isValid,
            screen.geometry.intersection(usable.geometry) == usable.geometry
        else { throw WorkspaceFailure.display }
        let docked = primary || settings.placement == .docked
        let width: Double
        if !docked {
            width = 0
        } else {
            // Match the panel's horizontal geometry in display-local points. Subtracting
            // global frame origins would introduce rounding differences on other displays.
            guard (settings.measures[.panelWidth] ?? DisplayMetric.panelWidth.factory).validPanelExtent,
                  (settings.measures[.sideInset] ?? DisplayMetric.sideInset.factory).valid else {
                throw WorkspaceFailure.invalidLayout
            }
            let panelWidth = settings.committedPanelWidth(in: usable.width)
            let sideInset = min(settings.points(.sideInset, in: usable.width), usable.width - panelWidth)
            let occupied = panelWidth + sideInset
            if let reserved = settings.measures[.reservedWidth] {
                guard reserved.valid else { throw WorkspaceFailure.invalidLayout }
                width = reserved.points(in: usable.width)
                guard width >= occupied else { throw ReservationError.narrowerThanPanel }
            } else {
                width = occupied
            }
        }
        guard width >= 0, width < usable.width else { throw WorkspaceFailure.minimumSize }
        self.display = display
        self.screen = screen
        ordinary = SurfaceRect(
            x: usable.x + ((settings.edge ?? fallbackEdge) == .left ? width : 0),
            y: usable.y, width: usable.width - width, height: usable.height)
    }
    public func frame(nativeFullscreen: Bool) -> SurfaceRect { nativeFullscreen ? screen : ordinary }
}
