import AppKit
import SwiftUI
import NearpaneCore

/// Mask only this background sibling. The panel's interactive views live outside its compositing tree.
@MainActor final class PanelGlassMaterial: NSVisualEffectView {
    private struct Regions: Equatable {
        let size: CGSize
        let layout: SurfaceLayout?
        let settings: DisplaySettings
    }
    private var regions: Regions?
    private var darkAppearance: Bool?
    private var reducedTransparency: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(size: CGSize, layout: SurfaceLayout?, settings: DisplaySettings) {
        let next = Regions(size: size, layout: layout, settings: settings)
        if regions != next {
            regions = next
            darkAppearance = nil
        }
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    @objc private func updateAppearance() {
        guard let regions, regions.size.width > 0, regions.size.height > 0 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard dark != darkAppearance || reduced != reducedTransparency else { return }
        darkAppearance = dark
        reducedTransparency = reduced
        let levels = SurfaceGlassLevels(regions.settings.glass, dark: dark, reduceTransparency: reduced)
        if levels.outerMaterial == 1, levels.innerMaterial == 1 || regions.layout == nil {
            maskImage = nil
            return
        }
        let cards = regions.layout.map {
            SurfaceCardGeometry.cardPaths(layout: $0, width: regions.size.width, settings: regions.settings).cgPath
        }
        maskImage = Self.mask(size: regions.size, cards: cards, outer: levels.outerMaterial, inner: levels.innerMaterial)
    }

    static func mask(size: CGSize, cards: CGPath?, outer: Double, inner: Double) -> NSImage {
        // A constant mask stretches over any panel without allocating a per-display bitmap.
        let uniform = cards == nil || outer == inner
        let imageSize = uniform ? CGSize(width: 1, height: 1) : size
        return NSImage(size: imageSize, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setBlendMode(.copy)
            context.setFillColor(gray: 1, alpha: outer)
            context.fill(rect)
            if !uniform, let cards {
                context.setFillColor(gray: 1, alpha: inner)
                context.addPath(cards)
                context.fillPath()
            }
            return true
        }
    }
}
