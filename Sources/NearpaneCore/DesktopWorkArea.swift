import Foundation

/// Global Quartz logical points, after display rotation and conversion of the usable inset.
public struct DesktopWorkArea: Equatable, Sendable {
    public let display: String, screen: SurfaceRect, ordinary: SurfaceRect
    public init(display: String, screen: SurfaceRect, usable: SurfaceRect, primary: Bool,
                settings: DisplaySettings, fallbackEdge: SurfaceEdge) throws {
        guard screen.geometry.isValid, usable.geometry.isValid,
              screen.geometry.intersection(usable.geometry) == usable.geometry else { throw WorkspaceFailure.display }
        let reserved = settings.measures[.reservedWidth] ?? (primary ? settings.measures[.panelWidth] ?? DisplayMetric.reservedWidth.factory : Measure(0))
        guard reserved.valid else { throw WorkspaceFailure.invalidLayout }
        let width = reserved.points(in: usable.width)
        guard width >= 0, width < usable.width else { throw WorkspaceFailure.minimumSize }
        self.display = display; self.screen = screen
        ordinary = SurfaceRect(x: usable.x + ((settings.edge ?? fallbackEdge) == .left ? width : 0),
                               y: usable.y, width: usable.width - width, height: usable.height)
    }
    public func frame(nativeFullscreen: Bool) -> SurfaceRect { nativeFullscreen ? screen : ordinary }
}
