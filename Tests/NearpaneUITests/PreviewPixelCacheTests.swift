import CoreGraphics
@testable import NearpaneUI
import Testing

@MainActor struct PreviewPixelCacheTests {
    @Test func bytesAndCountEvictTheLeastRecentlyDisplayedWindow() {
        let cache = PreviewPixelCache<Int, String>(maxCount: 3, maxBytes: 10)
        for key in 1...3 { cache.store("card", for: key, cost: 2) }
        cache.touch(1)
        cache.store("new", for: 4, cost: 5)
        #expect(cache.peek(2) == nil && cache.peek(1) != nil && cache.bytes == 9)
        cache.store("larger", for: 1, cost: 7)
        #expect(cache.count == 1 && cache.bytes == 7 && cache.peek(1) == "larger")
        cache.store("invalid", for: 1, cost: 11)
        #expect(cache.count == 0 && cache.bytes == 0)
    }

    @Test func totalsIncludePickerDecodedStrideAndDisplayRemoval() throws {
        let bitmap = try #require(CGContext(data: nil, width: 10, height: 20, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(bitmap.makeImage())
        #expect(PreviewPixelBudget.charge(pixels) == 2 * pixels.bytesPerRow * pixels.height)
        #expect(PreviewPixelBudget.galleryCount + 1 == 128)
        #expect(PreviewPixelBudget.galleryBytes + PreviewPixelBudget.pickerBytes == 256 * 1024 * 1024)
        let cache = PreviewPixelCache<Int, String>()
        cache.store("A", for: 1, cost: 256)
        cache.store("B", for: 2, cost: 256)
        cache.remove { _, display in display == "A" }
        #expect(cache.bytes == 256 && cache.peek(1) == nil && cache.peek(2) == "B")
        cache.removeAll()
        #expect(cache.bytes == 0 && cache.count == 0)
    }
}
