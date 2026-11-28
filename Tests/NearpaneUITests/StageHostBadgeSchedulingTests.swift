import AppKit
import Dispatch
import os
import Testing
@testable import NearpaneUI

@MainActor struct StageHostBadgeSchedulingTests {
    @Test(.timeLimit(.minutes(1))) func lazyAppIconsAreRasterizedBeforeReachingTheInputActor() async throws {
        let state = OSAllocatedUnfairLock(initialState: (loads: 0, draws: 0, onMain: false))
        let owner = WindowAppBadges.Owner(pid: 614, birth: 3400)
        let icons = await WindowAppBadges.prepareIcons([owner, owner]) { _ in
            state.withLock { $0.loads += 1; $0.onMain = Thread.isMainThread }
            // An accidental MainActor implementation fails without deadlocking it.
            guard !Thread.isMainThread else { return nil }
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor in delivered.signal() }
            delivered.wait()
            let lazy = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                state.withLock { $0.draws += 1; $0.onMain = $0.onMain || Thread.isMainThread }
                guard let canvas = NSGraphicsContext.current?.cgContext else { return false }
                canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                canvas.fill(rect)
                return true
            }
            guard let pixels = WindowAppBadges.rasterize(lazy) else { return nil }
            return WindowAppBadges.Pixels(name: "Fixture", icon: pixels)
        }
        let prepared = try #require(icons[owner])
        let before = state.withLock { $0 }
        #expect(before.loads == 1 && before.draws > 0 && !before.onMain)
        #expect(prepared.icon.width == 64 && prepared.icon.height == 64)
        let displayed = NSImage(cgImage: prepared.icon, size: NSSize(width: 32, height: 32))
        for side in [14.0, 28.0] {
            var proposed = CGRect(x: 0, y: 0, width: side, height: side)
            _ = try #require(displayed.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        }
        #expect(state.withLock { $0.draws == before.draws && !$0.onMain })
    }

    @Test(.timeLimit(.minutes(1))) func cancelledIconPreparationCannotPublishItsLateBitmap() async throws {
        let owner = WindowAppBadges.Owner(pid: 614, birth: 3400)
        let (starts, started) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); started.finish() }
        let task = Task {
            await WindowAppBadges.prepareIcons([owner]) { _ in
                started.yield(())
                guard !Thread.isMainThread else { return nil }
                release.wait()
                guard let canvas = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = canvas.makeImage() else { return nil }
                return WindowAppBadges.Pixels(name: "Late", icon: image)
            }
        }
        var begin = starts.makeAsyncIterator()
        _ = try #require(await begin.next())
        task.cancel()
        release.signal()
        #expect(await task.value.isEmpty)
    }
}
