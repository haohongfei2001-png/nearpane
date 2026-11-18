import NearpaneCore
import SwiftUI

/// The same number of desktop points maps to the same number of sidebar points for every
/// member of a display. A straddling or oversized window can widen the shared reference.
struct DesktopWindowThumbnailLayout {
    private let displayID: String?
    private let scale: CGFloat
    private let capturedSizes: [UInt32: CGSize]

    init(windows: [WindowObservation], display: DisplayObservation?, availableWidth: CGFloat,
         capturedSizes: [UInt32: CGSize] = [:]) {
        displayID = display?.id
        self.capturedSizes = capturedSizes
        guard let display, display.frame.geometry.isValid, availableWidth.isFinite, availableWidth > 0 else {
            scale = 0
            return
        }
        let widest = windows.lazy.filter { $0.displayID == display.id }
            .compactMap { Self.sizeInPoints($0, capturedSizes: capturedSizes) }.map(\.width).max() ?? 0
        scale = availableWidth / max(display.frame.width, widest)
    }

    func size(for window: WindowObservation) -> CGSize? {
        guard window.displayID == displayID, scale > 0, let size = Self.sizeInPoints(window, capturedSizes: capturedSizes) else { return nil }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func sizeInPoints(_ window: WindowObservation, capturedSizes: [UInt32: CGSize]) -> CGSize? {
        guard let m = window.metadata else { return nil }
        if let size = capturedSizes[m.number], size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            return size
        }
        guard m.globalFrame.geometry.isValid, m.hasCatalogGeometry != false,
              m.axFrame == nil || m.presentation == .confirmed,
              m.hasCatalogGeometry == true || (m.onActiveDesktop == true && m.isOnscreen == true) else { return nil }
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
    var unavailableReason: String?
    var borderWidth: CGFloat = 0.8
    var labelSize: CGFloat = 10
    var currentImage: (@MainActor () -> CGImage?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
            }
            HStack(spacing: 4) {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Text(label).font(.system(size: max(10, labelSize), weight: .semibold)).lineLimit(1)
            }
            if pictureSize == nil || image == nil {
                Text(pictureSize == nil ? "窗口尺寸待核对" : (unavailableReason ?? "正在读取窗口画面"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
