import SwiftUI
import NearpaneCore

/// The unified transparency control keeps one adaptive layer balance. Explicit
/// historical layer tokens remain readable for archived rendering evidence.
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
        if outerTransparency == nil && innerTransparency == nil {
            result.overallTransparency = overallTransparency ?? (dark ? 22 : 32)
            result.outerTransparency = dark ? 68 : 65
            result.innerTransparency = dark ? 7 : 8
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
        let shellColor = dark ? Color(red: 38/255, green: 38/255, blue: 38/255) : .white
        let cardColor = dark ? Color(red: 34/255, green: 34/255, blue: 34/255) : .white
        let solid = dark ? shellColor : Color(red: 241/255, green: 241/255, blue: 241/255)
        func wash(_ top: Color, _ bottom: Color, opacity: Double) -> LinearGradient {
            let colors = reduceTransparency ? [top, top] : [top.opacity(opacity), bottom.opacity(opacity)]
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        outer = wash(reduceTransparency ? solid : shellColor, shellColor, opacity: levels.outerTint)
        inner = wash(cardColor, cardColor, opacity: levels.innerTint)
        folded = reduceTransparency ? solid : shellColor.opacity(levels.foldedTint)

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
                      y: section.y,
                      width: max(0, section.width - 2 * inset),
                      height: section.height)
    }

    static func radius(settings: DisplaySettings, width: Double) -> Double {
        settings.measures[.cornerRadius]?.points(in: width) ?? 16
    }

    static func shellRadius(settings: DisplaySettings, size: CGSize) -> CGFloat {
        let inset = settings.glass.inset(width: size.width)
        return min(radius(settings: settings, width: size.width) + inset,
                   min(size.width, size.height) / 2)
    }

    static func cardPaths(layout: SurfaceLayout, width: Double, settings: DisplaySettings) -> Path {
        Path { path in
            for section in [layout.voice, layout.screenshots] + Array(layout.additionalTools.values) where section.height > 0 {
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
    var radius: Double = 16
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
            .padding(.horizontal, settings.glass.inset(width: width))
    }
}
