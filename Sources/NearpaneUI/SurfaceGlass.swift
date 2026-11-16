import SwiftUI
import NearpaneCore

/// A common tint contract for the rim and cards. The outer frame is deliberately
/// less transparent; it is painted only outside the cards, never underneath them.
struct SurfaceGlassPalette {
    let outer: Color
    let inner: Color
    let rim: Color
    let innerRim: Color
    let outerOpacity: Double
    let innerOpacity: Double

    init(dark: Bool, increasedContrast: Bool, reduceTransparency: Bool) {
        outerOpacity = reduceTransparency ? 1 : (dark ? 0.40 : 0.52)
        innerOpacity = reduceTransparency ? 1 : (dark ? 0.10 : 0.20)
        outer = reduceTransparency ? Color(nsColor: .windowBackgroundColor)
            : Color(red: dark ? 0.15 : 0.89, green: dark ? 0.15 : 0.90, blue: dark ? 0.22 : 0.98).opacity(outerOpacity)
        inner = reduceTransparency ? Color(nsColor: .windowBackgroundColor)
            : Color(red: dark ? 0.20 : 0.98, green: dark ? 0.20 : 0.98, blue: dark ? 0.28 : 1).opacity(innerOpacity)
        rim = increasedContrast ? Color.primary.opacity(0.65) : .white.opacity(dark ? 0.32 : 0.62)
        innerRim = increasedContrast ? Color.primary.opacity(0.65) : .white.opacity(dark ? 0.24 : 0.48)
    }
}

struct SurfaceCardGeometry {
    static func frame(in section: SurfaceRect, width: Double) -> CGRect {
        let inset = PanelSizeMetrics.cardInset(width: width)
        return CGRect(x: section.x + min(inset, section.width / 2),
                      y: section.y + min(inset, section.height / 2),
                      width: max(0, section.width - 2 * inset),
                      height: max(0, section.height - 2 * inset))
    }

    static func radius(settings: DisplaySettings, width: Double) -> Double {
        settings.measures[.cornerRadius]?.points(in: width) ?? 18
    }

    static func shellRadius(settings: DisplaySettings, size: CGSize) -> CGFloat {
        let inset = PanelSizeMetrics.cardInset(width: size.width)
        return min(radius(settings: settings, width: size.width) + inset,
                   min(size.width, size.height) / 2)
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
                                          reduceTransparency: opaque)
        GeometryReader { geometry in
            let shell = RoundedRectangle(
                cornerRadius: SurfaceCardGeometry.shellRadius(settings: settings, size: geometry.size),
                style: .continuous)
            palette.outer.mask {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    for section in [layout.voice, layout.screenshots, layout.desktop] where section.height > 0 {
                        let frame = SurfaceCardGeometry.frame(in: section, width: width)
                        let radius = min(SurfaceCardGeometry.radius(settings: settings, width: width),
                                         min(frame.width, frame.height) / 2)
                        path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: frame))
                    }
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    var body: some View {
        let palette = SurfaceGlassPalette(dark: scheme == .dark, increasedContrast: contrast == .increased,
                                          reduceTransparency: opaque)
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
        self.background { SurfaceGlass(radius: SurfaceCardGeometry.radius(settings: settings, width: width)) }
            .padding(PanelSizeMetrics.cardInset(width: width))
    }
}
