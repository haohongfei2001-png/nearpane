import CoreMedia
import CoreVideo
import Foundation
import NearpaneCore
import Observation
import os
@preconcurrency import ScreenCaptureKit
@testable import NearpaneUI
import SwiftUI
import Testing

@MainActor struct WindowFrameStreamTests {
    // Synthetic pixels exercise the native sample handoff without enumerating or capturing the user's windows.
    private func sample(_ blue: UInt8, green: UInt8 = 0, red: UInt8 = 0, colorSpace: CGColorSpace? = nil) throws -> CMSampleBuffer {
        var storage: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess)
        let pixel = try #require(storage)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixel))
        for y in 0..<4 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixel)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<4 {
                row[x * 4] = blue; row[x * 4 + 1] = green; row[x * 4 + 2] = red; row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        if let colorSpace { CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate) }
        var desc: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &desc) == noErr)
        var out: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: try #require(desc),
                sampleTiming: &timing, sampleBufferOut: &out) == noErr)
        return try #require(out)
    }

    @Test func requestedColorSpaceSurvivesVideoToolboxAndTheProductionCard() throws {
        let config = WindowFrameStream.sRGBConfiguration()
        #expect(config.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(config.colorSpaceName == CGColorSpace.sRGB)
        let requested = try #require(CGColorSpace(name: config.colorSpaceName))
        // Exercise both the explicit CV attachment and VideoToolbox's fallback for this BGRA contract.
        for tag in [requested, nil] {
            let green = try sample(66, green: 186, red: 53, colorSpace: tag)
            let image = try #require(WindowFrameStream.Frame(sample: green, received: 1, epoch: 0, sequence: 1).image())
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            let card = DesktopWindowCard(label: "Field Notes", icon: nil, image: image,
                pictureSize: CGSize(width: 32, height: 32), borderWidth: 0).frame(width: 32)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            let rendered = try #require(renderer.cgImage)
            let center = try #require(rendered.cropping(to: CGRect(x: 15, y: 15, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: requested, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            #expect(rgba == [53, 186, 66, 255])
        }
    }

    @Test func twoStableWindowFiltersDeliverDistinctLatestFramesAndBlankInvalidatesOnlyItsOwner() async throws {
        let (left, leftEvents) = AsyncStream<WindowFrameStream.Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (right, rightEvents) = AsyncStream<WindowFrameStream.Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let a = WindowFrameStream.Output(leftEvents, width: 4, height: 4)
        let b = WindowFrameStream.Output(rightEvents, width: 4, height: 4)
        var la = left.makeAsyncIterator(), rb = right.makeAsyncIterator()
        let first = try sample(32), other = try sample(224)
        a.receive(first, status: .started, now: 1)
        b.receive(other, status: .complete, now: 2)
        a.receive(other, status: .complete, now: 3)
        guard case let .frame(l)? = await la.next(), case let .frame(r)? = await rb.next() else {
            Issue.record("Both bounded per-window outputs must deliver"); return
        }
        #expect(l.received == 3 && r.received == 2 && l.image()?.width == 4 && r.image()?.width == 4)
        #expect(l.epoch == a.epoch && r.epoch == b.epoch)
        a.receive(first, status: .blank, now: 4)
        a.receive(first, status: .idle, now: 8)
        #expect(a.epoch != l.epoch && b.epoch == r.epoch)
        guard case let .idle(epoch)? = await la.next() else { Issue.record("Expected idle from the new epoch"); return }
        #expect(epoch != l.epoch)
        b.receive(other, status: .stopped, now: 9)
        #expect(b.epoch != r.epoch)
        guard case .unavailable? = await rb.next() else { Issue.record("Stopped stream must withdraw pixels"); return }
        #expect(await rb.next() == nil)
        leftEvents.finish()
    }

    @Test func changingOneWindowDoesNotRefreshUnrelatedCardOrLayoutObservers() {
        let cache = PreviewPixelCache<Int, String>()
        cache.store("left", for: 1, cost: 8)
        cache.store("right", for: 2, cost: 8)
        let left = OSAllocatedUnfairLock(initialState: false), right = OSAllocatedUnfairLock(initialState: false)
        let layout = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = cache.peek(1) }, onChange: { left.withLock { $0 = true } })
        withObservationTracking({ _ = cache.peek(2) }, onChange: { right.withLock { $0 = true } })
        withObservationTracking({ _ = cache.contains(1); _ = cache.bytes }, onChange: { layout.withLock { $0 = true } })
        cache.store("new left", for: 1, cost: 8)
        #expect(left.withLock { $0 } && !right.withLock { $0 } && !layout.withLock { $0 })
        #expect(cache.peek(2) == "right")
    }

    @Test func onlyTheObservedWindowOnItsOwnDisplayInvalidatesAMountedCard() throws {
        let fixture = DesktopGalleryTargetTests()
        let windows = [fixture.window(number: 22), fixture.window(number: 23)]
        let target = try #require(DesktopWindowTarget(windows[0], in: fixture.sample(windows)))
        let peer = try #require(DesktopWindowKey(windows[1]))
        let gallery = DesktopWindowGallery(permitsWindow: { _ in true }, lifetime: { _ in nil })
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = gallery.image(for: target, permitted: true) },
            onChange: { changed.withLock { $0 = true } })
        gallery.setCard(peer, on: target.display, owner: UUID(), visible: true)
        gallery.setCard(target.key, on: "second-display", owner: UUID(), visible: true)
        #expect(!changed.withLock { $0 })
        let oldCard = UUID(), newCard = UUID()
        gallery.setCard(target.key, on: target.display, owner: oldCard, visible: true)
        #expect(changed.withLock { $0 })

        let remounted = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = gallery.image(for: target, permitted: true) },
            onChange: { remounted.withLock { $0 = true } })
        let cancelled = UUID()
        gallery.setViewport(target.key, on: target.display, owner: oldCard, visible: false)
        #expect(gallery.priority(target) == 0)
        gallery.setCard(target.key, on: target.display, owner: cancelled, visible: true)
        #expect(gallery.priority(target) == 1)
        gallery.setViewport(target.key, on: target.display, owner: cancelled, visible: true)
        #expect(gallery.priority(target) == 2)
        gallery.setCard(target.key, on: target.display, owner: cancelled, visible: false)
        gallery.setViewport(target.key, on: target.display, owner: cancelled, visible: true)
        #expect(gallery.priority(target) == 0 && !remounted.withLock { $0 })
        gallery.setCard(target.key, on: target.display, owner: newCard, visible: true)
        gallery.setViewport(target.key, on: target.display, owner: newCard, visible: true)
        gallery.setCard(target.key, on: target.display, owner: newCard, visible: true)
        gallery.setViewport(target.key, on: target.display, owner: oldCard, visible: false)
        gallery.setCard(target.key, on: target.display, owner: oldCard, visible: false)
        gallery.setViewport(target.key, on: target.display, owner: oldCard, visible: false)
        #expect(gallery.priority(target) == 2 && !remounted.withLock { $0 })
        gallery.setCard(target.key, on: target.display, owner: newCard, visible: false)
        gallery.setViewport(target.key, on: target.display, owner: newCard, visible: true)
        #expect(gallery.priority(target) == 1 && remounted.withLock { $0 })
    }

    @Test func idleCannotDisplaceTheLastChangedFrameAndUnchangedDamageDoesNotRedecode() async throws {
        let (updates, events) = AsyncStream<WindowFrameStream.Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { events.finish() }
        let output = WindowFrameStream.Output(events, width: 4, height: 4)
        var next = updates.makeAsyncIterator()
        let first = try sample(38), changed = try sample(207)
        // Some compositors send an empty damage list on the first complete sample.
        output.receive(first, status: .complete, now: 1, hasDamage: false)
        output.receive(first, status: .idle, now: 6)
        guard case let .frame(baseline)? = await next.next() else { Issue.record("The first pixels were displaced"); return }
        let decoded = try #require(baseline.image())
        #expect(baseline.repeats(decoded))
        output.published(baseline)
        output.receive(first, status: .complete, now: 12, hasDamage: false)
        guard case .idle(baseline.epoch)? = await next.next() else { Issue.record("Unchanged pixels were issued again"); return }
        output.receive(changed, status: .complete, now: 14, hasDamage: true)
        output.receive(changed, status: .idle, now: 20)
        guard case let .frame(last)? = await next.next() else { Issue.record("A heartbeat displaced the final document edit"); return }
        #expect(last.sequence == baseline.sequence + 1 && last.received == 14)
        #expect(!last.repeats(decoded))
        output.published(last)
        output.receive(changed, status: .suspended, now: 21)
        output.receive(first, status: .complete, now: 22, hasDamage: false)
        guard case let .frame(resumed)? = await next.next() else { Issue.record("Resume needs a new baseline"); return }
        #expect(resumed.epoch != last.epoch)
        #expect(resumed.repeats(decoded))
    }

    @Test func budgetHandoffsServeNewCardsWithoutRepeatedlyPreemptingTheViewport() {
        #expect(DesktopWindowGallery.shouldYieldStream(serving: 0, waiting: 2, servingSince: 5, delivered: true, lastServedWaiting: 5, now: 5.1))
        #expect(!DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 0, servingSince: 5, delivered: true, lastServedWaiting: nil, now: 20))
        #expect(DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 2, servingSince: 5, delivered: true, lastServedWaiting: nil, now: 5.5))
        #expect(!DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 2, servingSince: 5, delivered: false, lastServedWaiting: nil, now: 6))
        #expect(DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 2, servingSince: 5, delivered: false, lastServedWaiting: nil, now: 8))
        #expect(!DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 2, servingSince: 5, delivered: true, lastServedWaiting: 4, now: 6))
        #expect(DesktopWindowGallery.shouldYieldStream(serving: 2, waiting: 2, servingSince: 5, delivered: true, lastServedWaiting: 4, now: 8))
    }

    @Test func fullscreenPicturesHaveNoOrdinaryInputAuthorityAndCannotCrossSpaces() throws {
        let fixture = DesktopGalleryTargetTests(), uuid = UUID()
        let rect = SurfaceRect(width: 900, height: 650)
        let window = WindowObservation(id: "normal-fullscreen-document", displayID: "display", bounds: rect,
            membership: .known(recordIDs: ["90"]), confidence: .unknown,
            metadata: .init(number: 213, pid: 71, launchMicroseconds: 99, element: nil, globalFrame: rect,
                frontToBack: 0, minimized: false, fullScreen: true, isOnscreen: true, onActiveDesktop: true,
                hasCatalogGeometry: true, overviewIsPresented: true, overviewOrdinaryRole: true,
                activeFullscreenSpaceID: "90"))
        var snapshot = fixture.sample([window])
        snapshot.scopes = [.init(id: "scope", displayID: "display", records: [.init(id: "90", isCurrent: true, fullscreenUUID: uuid)])]
        snapshot.native = .init(population: .workWindows, accessibility: .available, spaces: .observed, rows: [],
            windowLimitReached: false, beganUptime: 99, endedUptime: 100, catalogComplete: true)
        let preview = try #require(DesktopWindowTarget.preview(window, in: snapshot, now: fixture.time, uptime: 101))
        #expect(preview.present(in: snapshot, now: fixture.time, uptime: 101))
        #expect(DesktopWindowTarget(window, in: snapshot) == nil)
        #expect(DesktopWindowTarget.tilingCandidate(window, in: snapshot) == nil)
        snapshot.scopes = [.init(id: "scope", displayID: "display", records: [.init(id: "90", isCurrent: true, fullscreenUUID: UUID())])]
        #expect(!preview.present(in: snapshot, now: fixture.time, uptime: 101))
        snapshot.windows.removeAll()
        #expect(!preview.present(in: snapshot, now: fixture.time, uptime: 101))
    }
}
