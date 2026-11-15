import SwiftUI
import NearpaneCore

/// Decoration only: the native behind-window material remains the blur source.
/// No synthetic wallpaper or sampled user-window pixels are used here.
struct SurfaceGlass: View {
    var radius: Double = 18
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(opaque ? Color(nsColor: .windowBackgroundColor) : Color.white.opacity(scheme == .dark ? 0.06 : 0.22))
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.04 : 0.12), .indigo.opacity(0.065)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.55) : .white.opacity(scheme == .dark ? 0.24 : 0.65),
                                   lineWidth: contrast == .increased ? 1 : 1 / max(1, scale))
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.055), radius: 3, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func surfaceCard(width: Double, settings: DisplaySettings) -> some View {
        let radius = settings.measures[.cornerRadius]?.points(in: width) ?? 18
        return self
            .background { SurfaceGlass(radius: radius) }
            .padding(.horizontal, PanelSizeMetrics.cardInset(width: width))
            .padding(.vertical, 4)
    }
}
