import AppKit
import CoreGraphics
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct DesktopPreviewContinuityTests {
    @Test func aReturningCardUsesTheIdenticalBitmapUntilItsOwnContentChanges() throws {
        let fixture = DesktopGalleryTargetTests(), a = fixture.window(), b = fixture.window(number: 23, index: 1, id: "two")
        let opened = fixture.sample([a, b])
        let first = try #require(DesktopWindowTarget(a, in: opened)), sibling = try #require(DesktopWindowTarget(b, in: opened))
        let cache = PreviewPixelCache<DesktopWindowGallery.StillSlot, DesktopWindowGallery.Still>()
        let original = UUID(), returned = UUID()
        let gallery = DesktopWindowGallery(permitsWindow: { _ in true }, cache: cache, lifetime: { _ in original })
        func paint(_ color: NSColor) throws -> CGImage {
            let canvas = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.setFillColor(color.cgColor)
            canvas.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try #require(canvas.makeImage())
        }
        func publish(_ image: CGImage, to target: DesktopWindowTarget, appearance: UUID) throws {
            cache.store(.init(target: target, lifetime: appearance, capture: .init(image: image, logicalSize: CGSize(width: 320, height: 240)),
                              time: 10), for: .current(target.key), cost: try #require(PreviewPixelBudget.charge(image)))
        }
        func read(_ target: DesktopWindowTarget, _ appearance: UUID?, originalMatches: Bool = false, permitted: Bool = true) -> CGImage? {
            DesktopWindowGallery.lastCardPixels(target, in: cache, appearance: appearance, now: 900,
                allows: { _ in permitted }, originalMatches: { _, _ in originalMatches })
        }
        let green = try paint(.green), blue = try paint(.blue), red = try paint(.red)
        try publish(green, to: first, appearance: original)
        try publish(blue, to: sibling, appearance: original)
        gallery.setCard(first.key, on: first.display, visible: true)
        gallery.setCard(first.key, on: first.display, visible: false)
        gallery.clear(display: first.display, keepingCardFrames: true)
        #expect(gallery.activeStreamCount == 0 && gallery.cacheCount == 2)
        #expect(read(first, original) === green)
        let otherDesk = try #require(DesktopWindowTarget(a, in: fixture.sample([a], scope: "B")))
        #expect(read(otherDesk, original, originalMatches: true) == nil)
        #expect(read(first, nil, originalMatches: true) == nil)
        #expect(read(first, returned) == nil)
        #expect(read(first, returned, originalMatches: true) === green)
        #expect(read(first, returned, originalMatches: true, permitted: false) == nil)
        #expect(gallery.frameSequence(for: first) == 0 && gallery.captureRequests == 0)
        try publish(red, to: first, appearance: returned)
        #expect(read(first, returned) === red && read(sibling, original) === blue)
        gallery.clear()
        #expect(gallery.cacheBytes == 0 && read(first, returned) == nil)
    }

    @Test func aSpaceNotificationRetainsOnlyPresentationUntilTheNextConfirmedRoster() async throws {
        let fixture = StageHostGroupProjectionTests()
        let a = fixture.window(17)
        let feed = CurrentDesktopWindows(read: { request in
            await fixture.snapshot(request.revision == 1 ? [a] : [], request: request)
        }, sessionAvailable: { true }, fingerprint: { 0 })
        feed.observe(true)
        defer { feed.observe(false) }
        let deadline = ContinuousClock.now + .seconds(3)
        while feed.snapshot == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let key = try #require(DesktopWindowKey(a))
        let issued = try #require(feed.lifetime(of: key))
        feed.invalidate(preservingOriginalWindows: true, reason: "active-space")
        #expect(feed.snapshot == nil && feed.lifetime(of: key) == nil)
        #expect(feed.departingPictures?.snapshot.windows == [a] && feed.pictureAppearance(of: key) == issued)
        let end = ContinuousClock.now + .seconds(3)
        while feed.snapshot == nil && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.snapshot?.windows == [] && feed.departingPictures == nil && feed.pictureAppearance(of: key) == nil)
        feed.invalidate(reason: "session-unavailable")
        #expect(feed.departingPictures == nil && feed.snapshot == nil)
    }
}
