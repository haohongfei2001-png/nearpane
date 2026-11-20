import NearpaneCore
import SwiftUI

/// Each independent window fits the same available box using its own verified proportions.
struct DesktopWindowThumbnailLayout {
    let display: DisplayObservation?
    var capturedSizes: [UInt32: CGSize] = [:]

    func fittedSize(for window: WindowObservation, width: CGFloat, heightLimit: CGFloat) -> CGSize? {
        guard let display, display.frame.geometry.isValid, window.displayID == display.id,
              width.isFinite, heightLimit.isFinite, width > 0, heightLimit > 0,
              let source = Self.sizeInPoints(window, capturedSizes: capturedSizes) else { return nil }
        let scale = min(width / source.width, heightLimit / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private static func sizeInPoints(_ window: WindowObservation, capturedSizes: [UInt32: CGSize]) -> CGSize? {
        guard let m = window.metadata else { return nil }
        if let frame = m.catalogLogicalFrame, frame.geometry.isValid {
            return CGSize(width: frame.width, height: frame.height)
        }
        if let size = capturedSizes[m.number], size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            return size
        }
        let exactAX = m.axStandardWindowNumber == m.number && m.presentation == .confirmed
        guard m.globalFrame.geometry.isValid, m.hasCatalogGeometry != false,
              m.axFrame == nil || exactAX,
              m.hasCatalogGeometry == true || exactAX else { return nil }
        return CGSize(width: m.globalFrame.width, height: m.globalFrame.height)
    }
}

struct DesktopWindowCard: View {
    @Environment(\.colorScheme) private var scheme
    static func windowBacking(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.16 : 0.96)
    }
    let label: String
    let icon: NSImage?
    let image: CGImage?
    let pictureSize: CGSize?
    var borderWidth: CGFloat = 0.8
    var labelSize: CGFloat = 10
    var currentImage: (@MainActor () -> CGImage?)?

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            preview
            caption.frame(height: 18)
        }
        .foregroundStyle(Color(nsColor: SidebarTextColor.primary))
        .frame(maxWidth: .infinity, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }

    @ViewBuilder private var preview: some View {
        if let size = pictureSize {
            Canvas { context, canvas in
                let pixels: CGImage?
                if let currentImage { pixels = currentImage() } else { pixels = image }
                let bounds = CGRect(origin: .zero, size: canvas)
                if let pixels {
                    context.fill(Path(bounds), with: .color(Self.windowBacking(for: scheme)))
                    let fit = min(canvas.width / CGFloat(pixels.width), canvas.height / CGFloat(pixels.height))
                    let w = CGFloat(pixels.width) * fit, h = CGFloat(pixels.height) * fit
                    context.draw(Image(decorative: pixels, scale: 1),
                                 in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
                } else {
                    context.fill(Path(bounds), with: .color(.primary.opacity(0.045)))
                }
                let line = min(max(0, borderWidth), min(canvas.width, canvas.height) / 4)
                if line > 0 {
                    context.stroke(Path(bounds.insetBy(dx: line / 2, dy: line / 2)), with: .color(.primary.opacity(0.32)),
                                   lineWidth: line)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var caption: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(label).font(.system(size: max(10, labelSize), weight: .semibold)).lineLimit(1)
        }
    }
}
