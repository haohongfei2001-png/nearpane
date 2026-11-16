import SwiftUI
import NearpaneCore

/// Material strength and surface tint are resolved together. Keeping a full native blur
/// below a fully transparent card would leave its contents on an opaque-looking plate.
struct SurfaceGlassLevels {
    let outerTint, innerTint, outerMaterial, innerMaterial, foldedTint: Double
    static func outerDefault(dark: Bool) -> Double { dark ? 60 : 48 }
    static func innerDefault(dark: Bool) -> Double { dark ? 90 : 80 }

    init(_ settings: PanelGlassSettings, dark: Bool, reduceTransparency: Bool) {
        func levels(_ selected: Double?, factory: Double) -> (Double, Double) {
            if reduceTransparency { return (1, 1) }
            let overall = 1 - (settings.overallTransparency ?? 0) / 100
            let local = (100 - (selected ?? factory)) / 100
            return (overall * local, overall * min(1, local / ((100 - factory) / 100)))
        }
        (outerTint, outerMaterial) = levels(settings.outerTransparency, factory: Self.outerDefault(dark: dark))
        (innerTint, innerMaterial) = levels(settings.innerTransparency, factory: Self.innerDefault(dark: dark))
        // The factory icon uses bare material. Add a wash only when its requested
        // outer surface is more opaque than that original appearance.
        let factory = Self.outerDefault(dark: dark)
        foldedTint = reduceTransparency ? 1 : (1 - (settings.overallTransparency ?? 0) / 100)
            * max(0, 1 - (settings.outerTransparency ?? factory) / factory)
    }
}

/// A common tint contract for the rim and cards. The outer frame is deliberately
/// less transparent; it is painted only outside the cards, never underneath them.
struct SurfaceGlassPalette {
    let outer: Color
    let inner: Color
    let folded: Color
    let rim: Color
    let innerRim: Color
    let outerOpacity: Double
    let innerOpacity: Double

    init(dark: Bool, increasedContrast: Bool, reduceTransparency: Bool, settings: PanelGlassSettings = .init()) {
        let levels = SurfaceGlassLevels(settings, dark: dark, reduceTransparency: reduceTransparency)
        outerOpacity = levels.outerTint
        innerOpacity = levels.innerTint
        let base = reduceTransparency ? Color(nsColor: .windowBackgroundColor)
            : Color(red: dark ? 0.15 : 0.89, green: dark ? 0.15 : 0.90, blue: dark ? 0.22 : 0.98)
        outer = base.opacity(outerOpacity)
        folded = base.opacity(levels.foldedTint)
        inner = reduceTransparency ? Color(nsColor: .windowBackgroundColor)
            : Color(red: dark ? 0.20 : 0.98, green: dark ? 0.20 : 0.98, blue: dark ? 0.28 : 1).opacity(innerOpacity)
        rim = increasedContrast ? Color.primary.opacity(0.65) : .white.opacity((dark ? 0.32 : 0.62) * levels.outerMaterial)
        innerRim = increasedContrast ? Color.primary.opacity(0.65) : .white.opacity((dark ? 0.24 : 0.48) * levels.innerMaterial)
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
