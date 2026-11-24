import CoreGraphics
import Observation
import os
@testable import NearpaneUI
import Testing

@MainActor struct PreviewPixelCacheTests {
    @Test func aCardObservesOnlyItsOwnFirstFrameAndRemoval() {
        let cache = PreviewPixelCache<Int, String>(maxCount: 2, maxBytes: 16)
        cache.store("retained", for: 1, cost: 4)
        let retained = OSAllocatedUnfairLock(initialState: false)
        let waiting = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = cache.peek(1); cache.touch(1) }, onChange: { retained.withLock { $0 = true } })
        withObservationTracking({ _ = cache.peek(3) }, onChange: { waiting.withLock { $0 = true } })
        cache.store("visiting", for: 2, cost: 4)
        cache.touch(1)
        #expect(!retained.withLock { $0 } && !waiting.withLock { $0 })
        cache.store("first frame", for: 3, cost: 4) // evicts window 2
        #expect(!retained.withLock { $0 } && waiting.withLock { $0 })
        #expect(!cache.contains(2) && cache.peek(1) == "retained")
        cache.remove(3)
        #expect(!retained.withLock { $0 })
        cache.removeAll()
        #expect(retained.withLock { $0 } && !cache.contains(1))
    }

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
