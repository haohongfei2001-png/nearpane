import AppKit
import Metal
import QuartzCore
import Testing
@testable import NearpaneUI

@MainActor struct WindowSwitchTransitionTests {
    typealias Surface = WindowSwitchScene.Surface
    let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
    let a = Surface(number: 17, pid: 101, frame: CGRect(x: -1000, y: 180, width: 520, height: 400))
    let b = Surface(number: 21, pid: 101, frame: CGRect(x: -750, y: 230, width: 350, height: 550))
    let c = Surface(number: 33, pid: 290, frame: CGRect(x: -550, y: 450, width: 200, height: 250))

    @Test func onlyTheActualOverlapLeavesTheOldWindow() throws {
        let patch = try #require(WindowSwitchScene.patch(source: a, target: b, on: screen, stack: [a, c, b]))
        #expect(patch.donor == a)
        #expect(patch.bounds == CGRect(x: -750, y: 230, width: 270, height: 350))
        #expect(WindowSwitchScene.patch(source: a, target: a, on: screen, stack: [a, b]) == nil)
        #expect(WindowSwitchScene.patch(source: a, target: b, on: screen, stack: [c, a, b]) == nil)
        #expect(WindowSwitchScene.patch(source: a, target: b, on: screen, stack: [a]) == nil)
        #expect(WindowSwitchScene.patch(source: a, target: b, on: screen.offsetBy(dx: 600, dy: 0), stack: [a, b]) == nil)
    }

    @Test func anUnobscuredSideBySideWindowDissolvesItsOwnInactiveAppearance() throws {
        let right = Surface(number: 19, pid: 102, frame: .init(x: -480, y: 180, width: 460, height: 400))
        let patch = try #require(WindowSwitchScene.patch(source: a, target: right, on: screen, stack: [a, right, c]))
        #expect(patch.donor == right && patch.bounds == right.frame)
        #expect(WindowSwitchScene.patch(source: a, target: right, on: screen, stack: [a, c, right]) == nil)
    }

    @Test func exactStackAndOwnerMustAgreeBeforeRevealingTheLiveSurface() throws {
        let otherApp = Surface(number: b.number, pid: 205, frame: b.frame)
        let patch = try #require(WindowSwitchScene.patch(source: a, target: otherApp, on: screen, stack: [a, otherApp]))
        func state(_ stack: [Surface], _ pid: pid_t?) -> WindowSwitchScene.Order {
            WindowSwitchScene.order(source: a, target: otherApp, patch: patch, display: screen, stack: stack, frontPID: pid)
        }
        #expect(state([a, otherApp], a.pid) == .original)
        #expect(state([a, otherApp], otherApp.pid) == .selecting)
        #expect(state([otherApp, a], a.pid) == .selecting)
        #expect(state([otherApp, a], otherApp.pid) == .selected)
        #expect(state([c, otherApp, a], c.pid) == .changed)
        #expect(state([otherApp], otherApp.pid) == .changed)
        #expect(state([otherApp, a], nil) == .changed)
        let reused = Surface(number: otherApp.number, pid: 999, frame: otherApp.frame)
        #expect(state([reused, a], reused.pid) == .changed)
        let moved = Surface(number: otherApp.number, pid: otherApp.pid, frame: otherApp.frame.offsetBy(dx: 4, dy: 0))
        #expect(state([moved, a], moved.pid) == .changed)
    }

    @Test func theCoverCannotActivateOrJoinAnotherSpace() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let panel = WindowSwitchCover(frame: .init(x: 40, y: 50, width: 20, height: 15), image: try #require(ctx.makeImage()))
        defer { panel.discard() }
        #expect(!panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.nonactivatingPanel) && !panel.isOpaque)
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces) && !panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(panel.level.rawValue > NSWindow.Level.normal.rawValue && panel.level.rawValue < NSWindow.Level.floating.rawValue)
    }

    // CARenderer samples the actual production layer animation on the GPU. The two
    // solid surfaces are fixtures. This does not measure the installed WindowServer.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) func isolatedCompositorBlendsWithoutBlackOrOldFrameReturn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = 64, frame = CGRect(x: 0, y: 0, width: size, height: size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        let root = CALayer(), cover = CALayer()
        root.frame = frame; root.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        cover.frame = CGRect(x: 8, y: 8, width: 48, height: 48)
        cover.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        root.addSublayer(cover)
        renderer.layer = root; renderer.bounds = frame
        let start = CACurrentMediaTime() + 0.05
        WindowSwitchCover.dissolve(cover, beginningAt: start)
        CATransaction.flush()
        var samples = [[Int]]()
        for i in 0...12 {
            renderer.beginFrame(atTime: start + Double(i) / 60, timeStamp: nil)
            renderer.addUpdate(frame); renderer.render(); renderer.endFrame()
            let fence = try #require(queue.makeCommandBuffer())
            fence.commit(); fence.waitUntilCompleted()
            func rgb(_ x: Int, _ y: Int) -> [Int] {
                var pixel = [UInt8](repeating: 0, count: 4)
                texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                return [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])]
            }
            samples.append(rgb(32, 32))
            #expect(rgb(2, 2) == [0, 0, 255])
        }
        #expect(samples.first == [255, 0, 0] && samples.last == [0, 0, 255])
        #expect(Set(samples).count >= 7)
        #expect(samples.allSatisfy { $0[0] + $0[2] >= 240 && $0[1] <= 2 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0[0] >= $1[0] && $0[2] <= $1[2] })
        if let path = ProcessInfo.processInfo.environment["NEARPANE_SWITCH_RGBA_RECEIPT"] {
            let data = try JSONSerialization.data(withJSONObject: ["scope": "isolated CARenderer, synthetic surfaces",
                "sampleStepHz": 60, "durationSeconds": WindowSwitchCover.duration, "centerSRGB": samples,
                "outsidePatchSRGB": [0, 0, 255]], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }
}
