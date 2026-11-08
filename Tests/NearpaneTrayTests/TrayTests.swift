import Foundation
import Testing
@testable import NearpaneTray

struct TrayLayoutTests {
    @Test func fixedViewportExpansionAndBackfillKeepOriginalIdentities() {
        let s = CGSize(width: 200, height: 100), ids = (0..<8).map { _ in UUID() }
        for count in 0...ids.count {
            let items = Array(ids.prefix(count))
            let closed = TrayLayout(ids: items, size: s, captureEntry: true, expanded: false)
            let opened = TrayLayout(ids: items, size: s, captureEntry: true, expanded: true)
            #expect(closed.cells.map(\.slot) == items.map(TraySlot.asset) + [.camera])
            #expect(opened.cells.map(\.slot) == items.map(TraySlot.asset))
            #expect(opened.menu?.width == s.width && opened.menu?.maxY == s.height)
            #expect(closed.cells.filter { $0.frame.maxY <= s.height }.count <= 4)
            #expect(opened.cells.filter { $0.frame.maxY <= opened.imageViewport }.count <= 2)
            if count == 1 { #expect(opened.cells[0].frame.minY < closed.cells[0].frame.minY) }
            if count > 3 { #expect(closed.contentHeight > s.height) }
        }
        let entryOff = TrayLayout(ids: ids, size: s, captureEntry: false, expanded: true)
        #expect(entryOff.menu == nil && !entryOff.cells.contains { $0.slot == .camera })
        #expect(TrayLayout.fitted(pixels: .init(width: 30, height: 3), cell: s) == .init(width: 30, height: 3))
        #expect(TrayLayout.fitted(pixels: .init(width: 30, height: 600), cell: s) == .init(width: 5, height: 100))
    }
}
