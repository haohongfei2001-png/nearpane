import SwiftUI
import NearpaneCore

/// A saved partial customization keeps the optical baseline it was created with.
extension PanelGlassSettings {
    var usesRecommendedTransparency: Bool {
        overallTransparency == nil && outerTransparency == nil && innerTransparency == nil
    }

    var restoringRecommendedTransparency: Self {
        var result = Self()
        result.rimWidth = rimWidth
        return result
    }

    func resolvedTransparency(dark: Bool) -> Self {
        var result = self
        if usesRecommendedTransparency {
            result.overallTransparency = dark ? 8 : 12
            result.outerTransparency = dark ? 56 : 45
            result.innerTransparency = dark ? 92 : 83
        } else {
            result.overallTransparency = overallTransparency ?? 0
            result.outerTransparency = outerTransparency ?? (dark ? 60 : 48)
            result.innerTransparency = innerTransparency ?? (dark ? 90 : 80)
        }
        return result
    }
}

/// The two masks attenuate one native behind-window material. Text and controls
/// never inherit their opacity. The original transfer curve stays continuous for
/// existing saved percentages and for a user editing the recommended appearance.
struct SurfaceGlassLevels {
    let outerTint, innerTint, outerMaterial, innerMaterial, foldedTint: Double

    init(_ settings: PanelGlassSettings, dark: Bool, reduceTransparency: Bool) {
        let values = settings.resolvedTransparency(dark: dark)
        let overall = 1 - (values.overallTransparency ?? 0) / 100
        let outerKnee = dark ? 60.0 : 48.0
        let innerKnee = dark ? 90.0 : 80.0
        func levels(_ percent: Double, knee: Double) -> (Double, Double) {
            if reduceTransparency { return (1, 1) }
            let local = (100 - percent) / 100
            return (overall * local, overall * min(1, local / ((100 - knee) / 100)))
        }
        let outer = values.outerTransparency ?? outerKnee
        (outerTint, outerMaterial) = levels(outer, knee: outerKnee)
        (innerTint, innerMaterial) = levels(values.innerTransparency ?? innerKnee, knee: innerKnee)
        foldedTint = reduceTransparency ? 1 : overall * max(0, 1 - outer / outerKnee)
    }
}

/// The rim has one even width and density. Equal-alpha color stops give the shell
/// and its independently cut cards a soft daylight edge without painting a wallpaper.
struct SurfaceGlassPalette {
    let outer: LinearGradient
    let inner: LinearGradient
    let folded: Color
    let rim: LinearGradient
    let innerRim: LinearGradient
    let outerOpacity: Double
    let innerOpacity: Double

    init(dark: Bool, increasedContrast: Bool, reduceTransparency: Bool, settings: PanelGlassSettings = .init()) {
        let levels = SurfaceGlassLevels(settings, dark: dark, reduceTransparency: reduceTransparency)
        outerOpacity = levels.outerTint
        innerOpacity = levels.innerTint
        let solid = Color(nsColor: .windowBackgroundColor)
        func wash(_ top: Color, _ bottom: Color, opacity: Double) -> LinearGradient {
            let colors = reduceTransparency ? [solid, solid] : [top.opacity(opacity), bottom.opacity(opacity)]
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        let outerTop = dark ? Color(white: 0.24) : Color(white: 0.94)
        let outerBottom = dark ? Color(white: 0.18) : Color(white: 0.90)
        outer = wash(outerTop, outerBottom, opacity: levels.outerTint)
        inner = wash(dark ? Color(white: 0.48) : .white,
                     dark ? Color(white: 0.36) : Color(white: 0.99),
                     opacity: levels.innerTint)
        folded = reduceTransparency ? solid : outerTop.opacity(levels.foldedTint)

        func edge(strength: Double, highlight: Double, shade: Double) -> LinearGradient {
            let colors = increasedContrast ? Array(repeating: Color.primary.opacity(0.65), count: 2)
                : [Color.white.opacity(highlight * strength), Color.black.opacity(shade * strength)]
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        rim = edge(strength: levels.outerMaterial, highlight: dark ? 0.39 : 0.80, shade: dark ? 0.28 : 0.10)
        innerRim = edge(strength: levels.innerMaterial, highlight: dark ? 0.32 : 0.90, shade: dark ? 0.20 : 0.10)
    }
}

struct SurfaceCardGeometry {
    static func frame(in section: SurfaceRect, width: Double, settings: DisplaySettings = .init()) -> CGRect {
        let inset = settings.glass.inset(width: width)
        return CGRect(x: section.x + min(inset, section.width / 2),
                      y: section.y + min(inset, section.height / 2),
                      width: max(0, section.width - 2 * inset),
                      height: max(0, section.height - 2 * inset))
    }

    static func radius(settings: DisplaySettings, width: Double) -> Double {
        settings.measures[.cornerRadius]?.points(in: width) ?? 18
    }

    static func shellRadius(settings: DisplaySettings, size: CGSize) -> CGFloat {
        let inset = settings.glass.inset(width: size.width)
        return min(radius(settings: settings, width: size.width) + inset,
                   min(size.width, size.height) / 2)
    }

    static func cardPaths(layout: SurfaceLayout, width: Double, settings: DisplaySettings) -> Path {
        Path { path in
            for section in [layout.voice, layout.screenshots, layout.desktop] where section.height > 0 {
                let frame = frame(in: section, width: width, settings: settings)
                guard !frame.isEmpty else { continue }
                let radius = min(radius(settings: settings, width: width), min(frame.width, frame.height) / 2)
                path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: frame))
            }
        }
    }
}

/// The native behind-window material remains the single blur source. The cutouts
/// ensure the more opaque frame wash cannot compound with the transparent cards.
struct SurfaceShell: View {
    let layout: SurfaceLayout
    let width: Double
    let settings: DisplaySettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    var body: some View {
        let palette = SurfaceGlassPalette(dark: scheme == .dark, increasedContrast: contrast == .increased,
                                          reduceTransparency: opaque, settings: settings.glass)
        GeometryReader { geometry in
            let shell = RoundedRectangle(
                cornerRadius: SurfaceCardGeometry.shellRadius(settings: settings, size: geometry.size),
                style: .continuous)
            palette.outer.mask {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addPath(SurfaceCardGeometry.cardPaths(layout: layout, width: width, settings: settings))
                }.fill(style: FillStyle(eoFill: true))
            }
            .clipShape(shell)
            .overlay {
                shell.strokeBorder(palette.rim, lineWidth: contrast == .increased ? 1 : 1 / max(1, scale))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Decoration only: no synthetic wallpaper or sampled user-window pixels.
struct SurfaceGlass: View {
    var radius: Double = 18
    var settings = PanelGlassSettings()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    var body: some View {
        let palette = SurfaceGlassPalette(dark: scheme == .dark, increasedContrast: contrast == .increased,
                                          reduceTransparency: opaque, settings: settings)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(palette.inner)
            .overlay {
                shape.strokeBorder(palette.innerRim, lineWidth: contrast == .increased ? 1 : 1 / max(1, scale))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func surfaceCard(width: Double, settings: DisplaySettings) -> some View {
        self.background { SurfaceGlass(radius: SurfaceCardGeometry.radius(settings: settings, width: width), settings: settings.glass) }
            .padding(settings.glass.inset(width: width))
    }
}
