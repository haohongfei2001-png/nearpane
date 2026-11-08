import Foundation

/// Tray coordinates use logical points from the top left. A camera slot never enters QueueStore.
public enum TraySlot: Hashable { case asset(UUID), camera }
public struct TrayCell: Equatable { public let slot: TraySlot; public let frame: CGRect }
public struct TrayLayout {
    public let cells: [TrayCell]
    public let menu: CGRect?
    public let contentHeight: CGFloat
    public let imageViewport: CGFloat

    public init(ids: [UUID], size: CGSize, captureEntry: Bool, expanded: Bool) {
        let w = max(0, size.width), h = max(0, size.height)
        let gap = min(4, min(w, h) / 8)
        let cw = (w - gap) / 2, ch = (h - gap) / 2
        let open = captureEntry && expanded
        let items = ids.map(TraySlot.asset) + (captureEntry && !open ? [.camera] : [])
        // A one-row tray is bottom-aligned: a single image moves UP when the camera expands.
        let top = !open && items.count <= 2 ? ch + gap : 0
        cells = items.enumerated().map { i, slot in
            .init(slot: slot, frame: CGRect(x: CGFloat(i % 2) * (cw + gap),
                                            y: top + CGFloat(i / 2) * (ch + gap), width: cw, height: ch))
        }
        imageViewport = open ? ch : h
        menu = open ? CGRect(x: 0, y: ch + gap, width: w, height: ch) : nil
        contentHeight = max(imageViewport, cells.last?.frame.maxY ?? 0)
    }

    public static func fitted(pixels: CGSize, cell: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = max(0, min(1, cell.width / pixels.width, cell.height / pixels.height))
        return .init(width: pixels.width * scale, height: pixels.height * scale)
    }
}
