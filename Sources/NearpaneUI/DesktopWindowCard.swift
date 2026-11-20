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

    func fittedSize(for window: WindowObservation, width: CGFloat, heightLimit: CGFloat) -> CGSize? {
        guard window.displayID == displayID, let source = Self.sizeInPoints(window, capturedSizes: capturedSizes),
              width > 0, heightLimit > 0 else { return nil }
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

/// Fit every card in a single top-aligned column. The same extra scale applies to
/// all pictures, including portrait and unusually small windows.
struct DesktopRosterFit {
    struct Row {
        let picture: CGSize?
        let height: CGFloat
        let inlineCaption: Bool
        let showsCaption: Bool
    }

    let rows: [Row]
    let spacing: CGFloat

    init(pictures: [CGSize?], availableHeight: CGFloat, spacing requestedGap: CGFloat, labelSize: CGFloat) {
        guard !pictures.isEmpty else { rows = []; spacing = 0; return }
        let count = CGFloat(pictures.count)
        let height = max(0, availableHeight)
        let line = max(14, ceil(max(10, labelSize) * 1.3))
        spacing = min(max(0, requestedGap), height / (10 * count))
        let budget = height - spacing * (count - 1)
        let inline = budget / count < 2 * (line + 3)
        let minimum = min(line, budget / count)

        func rowHeight(_ picture: CGSize?, scale: CGFloat) -> CGFloat {
            guard let picture else { return minimum }
            return inline ? max(minimum, picture.height * scale) : line + 3 + picture.height * scale
        }
        func total(_ scale: CGFloat) -> CGFloat {
            pictures.reduce(0) { $0 + rowHeight($1, scale: scale) }
        }
        var scale: CGFloat = 1
        if inline && minimum == budget / count, let tallest = pictures.compactMap({ $0?.height }).max(), tallest > 0 {
            scale = min(1, minimum / tallest)
        } else if total(1) > budget {
            // In dense mode caption and picture share vertical space. As pictures
            // shrink, shorter rows reach their caption height before taller ones.
            var lower: CGFloat = 0, upper: CGFloat = 1
            for _ in 0..<28 {
                let middle = (lower + upper) / 2
                if total(middle) <= budget { lower = middle } else { upper = middle }
            }
            scale = lower
        }
        rows = pictures.map { picture in
            let rowHeight = rowHeight(picture, scale: scale)
            return Row(picture: picture.map { CGSize(width: $0.width * scale, height: $0.height * scale) },
                       height: rowHeight, inlineCaption: inline, showsCaption: picture == nil || rowHeight >= line)
        }
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
    var row: DesktopRosterFit.Row?
    var currentImage: (@MainActor () -> CGImage?)?

    var body: some View {
        Group {
            if row?.inlineCaption == true {
                HStack(alignment: .top, spacing: 4) {
                    preview
                    if row?.showsCaption == true { caption }
                }
            } else {
                VStack(alignment: .center, spacing: 0) {
                    preview
                    caption.frame(height: 18)
                }
            }
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: row?.height, alignment: .topLeading)
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
