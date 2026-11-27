import NearpaneCore

/// Shared by the actual NSPanel and the Settings preview. The full reference height
/// still sets module proportions when the current role needs only part of the panel.
struct PanelSizeLayout {
    let frame: SurfaceRect
    let referenceHeight: Double
    let form: PanelSizeForm

    init?(settings: DisplaySettings, screen: ScreenGeometry, edge: SurfaceEdge,
          content: PanelContent, voice: Bool, tray: Bool, floating: Bool,
          toolOrder: [String] = [BuiltinCatalog.voice, BuiltinCatalog.screenshots], voiceCompact: Bool = false, trayRows: Int = 1, lyricsHeight: Double = 0,
          pinnedCount: Int = 0, expanded: Bool = false) {
        guard let full = settings.panel(on: screen, fallbackEdge: edge) else { return nil }
        referenceHeight = full.height
        let sizes = settings.contentHeights(full.height, content: content, voice: voice, tray: tray)
        let sections = [sizes.voice, sizes.tray, sizes.spaces].filter { $0 > 0 }
        let inset = settings.glass.inset(width: full.width)
        var fittedHeight = 2 * inset + sections.reduce(0, +) + Double(max(0, sections.count - 1)) * sizes.gap
        if content == .toolsOnly {
            let layout = LayoutComposer.compose(width: full.width, height: full.height, pinnedCount: pinnedCount,
                expanded: expanded, settings: settings, content: content, voiceEnabled: voice, trayEnabled: tray,
                referenceHeight: full.height, voiceCompact: voiceCompact, trayRows: trayRows, lyricsHeight: lyricsHeight, toolOrder: toolOrder)
            fittedHeight = min(full.height, layout.contentHeight)
        }
        let alwaysUseFullHeight = content != .toolsOnly &&
            (settings.measures[.panelHeight] != nil || content == .hidden || content == .full || content == .spacesOnly)
        guard let rect = settings.panel(on: screen, fallbackEdge: edge,
                                        heightFraction: alwaysUseFullHeight ? 1 : max(PanelSizeMetrics.minimumSide, fittedHeight) / full.height,
                                        floating: floating) else { return nil }
        frame = rect
        form = settings.sizeForm(width: rect.width, height: rect.height, content: content, voice: voice, tray: tray,
                                 referenceHeight: full.height, voiceCompact: voiceCompact,
                                 trayRows: trayRows, lyricsHeight: lyricsHeight, toolOrder: toolOrder, pinnedCount: pinnedCount)
    }
}
