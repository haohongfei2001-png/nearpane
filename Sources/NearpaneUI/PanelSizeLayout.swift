import NearpaneCore

/// Shared by the actual NSPanel and the Settings preview. The full reference height
/// still sets module proportions when the current role needs only part of the panel.
struct PanelSizeLayout {
    let frame: SurfaceRect
    let referenceHeight: Double
    let form: PanelSizeForm

    init?(settings: DisplaySettings, screen: ScreenGeometry, edge: SurfaceEdge,
          content: PanelContent, voice: Bool, tray: Bool, floating: Bool) {
        guard let full = settings.panel(on: screen, fallbackEdge: edge) else { return nil }
        referenceHeight = full.height
        let sizes = settings.contentHeights(full.height, content: content, voice: voice, tray: tray)
        let sections = [sizes.voice, sizes.tray, sizes.spaces].filter { $0 > 0 }
        let fittedHeight = sections.reduce(0, +) + Double(max(0, sections.count - 1)) * sizes.gap
        let alwaysUseFullHeight = settings.measures[.panelHeight] != nil || content == .hidden
        guard let rect = settings.panel(on: screen, fallbackEdge: edge,
                                        heightFraction: alwaysUseFullHeight ? 1 : max(PanelSizeMetrics.minimumSide, fittedHeight) / full.height,
                                        floating: floating) else { return nil }
        frame = rect
        form = settings.sizeForm(width: rect.width, height: rect.height, content: content, voice: voice, tray: tray,
                                 referenceHeight: full.height)
    }
}
