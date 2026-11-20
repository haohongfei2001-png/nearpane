import CoreMedia
import CoreVideo
import Foundation
import NearpaneCore
import Observation
import os
@preconcurrency import ScreenCaptureKit
@testable import NearpaneUI
import Testing

@MainActor struct WindowFrameStreamTests {
    // Synthetic pixels exercise the native sample handoff without enumerating or capturing the user's windows.
    private func sample(_ byte: UInt8) throws -> CMSampleBuffer {
        var storage: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess)
        let pixel = try #require(storage)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixel))
        for y in 0..<4 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixel)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<4 {
                row[x * 4] = byte; row[x * 4 + 1] = 0; row[x * 4 + 2] = 0; row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var desc: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &desc) == noErr)
        var out: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: try #require(desc),
                sampleTiming: &timing, sampleBufferOut: &out) == noErr)
        return try #require(out)
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
