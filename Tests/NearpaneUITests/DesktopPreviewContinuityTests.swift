import AppKit
import CoreGraphics
import NearpaneCore
import os
import Testing
@testable import NearpaneUI

@MainActor struct DesktopPreviewContinuityTests {
    @Test(arguments: [false, true])
    func cappedInventoryKeepsTheReadOnlyCardOnlyOnItsVerifiedDesktop(changedHome: Bool) async throws {
        let fixture = StageHostGroupProjectionTests()
        var row = fixture.window(17)
        row.metadata?.overviewOrdinaryRole = true
        row.metadata?.minimized = false
        let window = row
        let phase = OSAllocatedUnfairLock(initialState: 0)
        let alternate = UUID()
        let (samples, sampled) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let feed = CurrentDesktopWindows(read: { request in
            let step = phase.withLock { $0 }
            var sample = await fixture.snapshot(step == 0 ? [window] : [], request: request, accessibility: .available)
            if step == 1 {
                let original = try #require(sample.native)
                sample.native = .init(population: original.population, accessibility: original.accessibility, spaces: original.spaces,
                    rows: original.rows, windowLimitReached: true, beganUptime: original.beganUptime, endedUptime: original.endedUptime,
                    stageManagerEnabled: false, catalogComplete: false)
                if changedHome {
                    let old = try #require(sample.scopes.first)
                    sample.scopes = [.init(id: old.id, displayID: old.displayID, records: [.init(id:"9", isCurrent:true, ordinaryUUID:alternate)])]
                }
            }
            return sample
        }, sessionAvailable: { true }, fingerprint: { 0 })
        feed.didSample = { sampled.yield(()) }
        feed.observe(true)
        defer { feed.observe(false); sampled.finish() }
        func wait(_ ready: () -> Bool) async throws {
            if ready() { return }
            for await _ in samples { if ready() { return } }
            try #require(ready())
        }
        try await wait { feed.snapshot?.windows == [window] }
        let displayed = try #require(feed.snapshot)
        _ = try #require(DesktopWindowTarget.preview(window, in: displayed))
        let key = try #require(DesktopWindowKey(window)), original = try #require(feed.lifetime(of: key))
        phase.withLock { $0 = 1 }
        feed.changed()
        try await wait { feed.snapshot?.native?.windowLimitReached == true }
        #expect(feed.lifetime(of: key) == nil)
        if changedHome {
            #expect(feed.departingPictures == nil && feed.pictureAppearance(of: key) == nil)
        } else {
            #expect(feed.departingPictures?.snapshot.windows == [window])
            let presentation = try #require(feed.pictureAppearance(of: key))
            #expect(presentation != original)
            feed.changed()
            try await wait { feed.pictureAppearance(of: key) != presentation }
            #expect(feed.pictureAppearance(of: key) != nil && feed.lifetime(of: key) == nil)
            phase.withLock { $0 = 2 }
            feed.changed()
            try await wait { feed.snapshot?.native?.windowLimitReached == false }
            #expect(feed.snapshot?.windows.isEmpty == true && feed.departingPictures == nil && feed.pictureAppearance(of: key) == nil)
        }
    }

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
        let mount = UUID()
        gallery.setCard(first.key, on: first.display, owner: mount, visible: true)
        gallery.setCard(first.key, on: first.display, owner: mount, visible: false)
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
        let changedHome = OSAllocatedUnfairLock(initialState: false)
        let (samples, sampled) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let feed = CurrentDesktopWindows(read: { request in
            await fixture.snapshot(changedHome.withLock { $0 } ? [] : [a], request: request)
        }, sessionAvailable: { true }, fingerprint: { 0 })
        feed.didSample = { sampled.yield(()) }
        feed.observe(true)
        defer { feed.observe(false); sampled.finish() }
        func wait(_ ready: () -> Bool) async throws {
            if ready() { return }
            for await _ in samples { if ready() { return } }
            try #require(ready())
        }
        try await wait { feed.snapshot != nil }
        let key = try #require(DesktopWindowKey(a))
        let issued = try #require(feed.lifetime(of: key))
        changedHome.withLock { $0 = true }
        feed.invalidate(preservingOriginalWindows: true, reason: "active-space")
        #expect(feed.snapshot == nil && feed.lifetime(of: key) == nil)
        #expect(feed.departingPictures?.snapshot.windows == [a] && feed.pictureAppearance(of: key) == issued)
        try await wait { feed.snapshot != nil }
        #expect(feed.snapshot?.windows == [] && feed.departingPictures == nil && feed.pictureAppearance(of: key) == nil)
        feed.invalidate(reason: "session-unavailable")
        #expect(feed.departingPictures == nil && feed.snapshot == nil)
    }
}
