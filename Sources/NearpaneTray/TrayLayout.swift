import Foundation
import NearpaneCore

/// Tray coordinates use logical points from the top left. A camera slot never enters QueueStore.
public enum TraySlot: Hashable { case asset(UUID), camera }
public struct TrayCell: Equatable { public let slot: TraySlot; public let frame: CGRect }
public struct TrayLayout {
    public let cellSize: CGSize
    public let columnGap, rowGap: CGFloat
    public let cells: [TrayCell]
    public let menu: CGRect?
    public let contentHeight: CGFloat
    public let imageViewport: CGFloat

    public init(ids: [UUID], size: CGSize, captureEntry: Bool, expanded: Bool, settings: DisplaySettings = .init()) {
        let w = max(0,size.width), h = max(0,size.height)
        columnGap = min(settings.points(.columnGap,in:w),min(w,h)/8)
        rowGap = min(settings.points(.rowGap,in:h),min(w,h)/8)
        let cw = min((w - columnGap)/2,settings.points(.cellWidth,in:w - columnGap))
        let ch = min(h,settings.points(.cellHeight,in:h-rowGap))
        cellSize = CGSize(width:cw,height:ch)
        let open = captureEntry && expanded
        let dx = cw + columnGap, dy = ch + rowGap
        let items = ids.map(TraySlot.asset) + (captureEntry && !open ? [.camera] : [])
        // A one-row tray is bottom-aligned: a single image moves UP when the camera expands.
        let top = !open && items.count <= 2 ? ch + rowGap : 0
        cells = items.enumerated().map { i, slot in
            .init(slot: slot, frame: CGRect(x: CGFloat(i % 2) * dx,
                                            y: top + CGFloat(i / 2) * dy, width: cw, height: ch))
        }
        let menuHeight = min(h-rowGap,settings.points(.trayMenuHeight,in:h-rowGap))
        imageViewport = open ? max(0,h-menuHeight-rowGap) : h
        menu = open ? CGRect(x:0,y:imageViewport+rowGap,width:w,height:menuHeight) : nil
        contentHeight = max(imageViewport, cells.last?.frame.maxY ?? 0)
    }

    public static func fitted(pixels: CGSize, cell: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = max(0, min(1, cell.width / pixels.width, cell.height / pixels.height))
        return .init(width: pixels.width * scale, height: pixels.height * scale)
    }
}
