import AppKit
import QuartzCore
import Foundation
@preconcurrency import ScreenCaptureKit
@testable import NearpaneUI

/// A disposable WindowServer session can exercise ordering and key delivery
/// without AX or screen-recording permission. The installed Host has a separate
/// end-to-end witness for input and displayed pixels.
private enum HostedError: Error { case noBitmap }

/// Records only one RGB value from the center of these synthetic windows.
/// All capture APIs are behind a nonprompting authorization check.
private final class HostedPixels: NSObject, SCStreamOutput, @unchecked Sendable {
    private struct Sample { let pts: Double, r: Int, g: Int, b: Int }
    private let queue = DispatchQueue(label: "net.example.nearpane.hosted-switch.pixels")
    private var frames = [Sample]()
    private var stream: SCStream?

    @MainActor static func start(on screen: NSScreen, source: NSWindow) async -> (HostedPixels?, String) {
        guard CGPreflightScreenCaptureAccess() else { return (nil, "screenReadPermissionUnavailable") }
        guard #available(macOS 14.4, *), let current = try? await SCShareableContent.currentProcess,
              let app = current.applications.first(where: { $0.processID == getpid() }),
              let id = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let display = current.displays.first(where: { $0.displayID == id.uint32Value }),
              let original = current.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }),
              original.owningApplication?.processID == getpid() else { return (nil, "ownedCaptureSourcesUnavailable") }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        filter.includeMenuBar = false
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: original.frame.midX - display.frame.minX - 4,
            y: original.frame.midY - display.frame.minY - 4, width: 8, height: 8)
        config.width = 16; config.height = 16; config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5; config.showsCursor = false; config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB; config.pixelFormat = kCVPixelFormatType_32BGRA
        let probe = HostedPixels()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            try await stream.startCapture()
            probe.stream = stream
            return (probe, "started")
        } catch { return (nil, "ownedStreamUnavailable") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard frames.count < 180, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let image = sampleBuffer.imageBuffer, CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(image) == 16, CVPixelBufferGetHeight(image) == 16,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let plane = CVPixelBufferGetBaseAddress(image) else { return }
        let p = plane.assumingMemoryBound(to: UInt8.self) + 8 * CVPixelBufferGetBytesPerRow(image) + 32
        guard p[3] == 255, sampleBuffer.presentationTimeStamp.seconds.isFinite else { return }
        frames.append(Sample(pts:sampleBuffer.presentationTimeStamp.seconds,r:Int(p[2]),g:Int(p[1]),b:Int(p[0])))
    }

    var hasOriginal: Bool { queue.sync { frames.last.map { $0.r >= 235 && $0.g < 12 && $0.b < 15 } == true } }

    @MainActor func finish() async -> [String: Any] {
        do { try await stream?.stopCapture() } catch { return ["status":"UNKNOWN","reason":"streamStopUnavailable"] }
        let samples = queue.sync { frames }
        guard let first = samples.first, let last = samples.last else { return ["status":"UNKNOWN","reason":"noCompleteFrames"] }
        let changed = samples.filter { $0.r > 12 && $0.b > 12 && $0.g < 12 }
        let valid = samples.allSatisfy { $0.g < 12 && $0.r + $0.b >= 235 }
        let monotone = zip(samples, samples.dropFirst()).allSatisfy {
            $0.pts < $1.pts && $0.r + 6 >= $1.r && $0.b <= $1.b + 6
        }
        let bins = Set(changed.map { $0.b / 16 }).count
        let span = (changed.map(\.b).max() ?? 0) - (changed.map(\.b).min() ?? 0)
        let endpoints = first.r >= 235 && first.b < 15 && last.r < 15 && last.b >= 235
        let status = valid && endpoints && bins >= 3 && span >= 70 ? (monotone ? "PASS" : "FAIL") : "UNKNOWN"
        return ["status":status, "scope":"foreground process filtered to its own 8-point crop",
                "distinctIntermediateBins":bins, "sampledRGB":samples.map { [$0.r,$0.g,$0.b] },
                "presentationMilliseconds":samples.map { ($0.pts-first.pts)*1000 }, "monotone":monotone,
                "sourceAndTarget":endpoints, "fixturePalette":valid]
    }
}

@MainActor private struct HostedWindowSwitch {
    private func stack(_ candidates: [NSWindow]) -> [Int] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let numbers = Set(candidates.map(\.windowNumber))
        return windows.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == getpid(),
                  let n = row[kCGWindowNumber as String] as? Int, numbers.contains(n) else { return nil }
            return n
        }
    }

    private func observe(_ check: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if check() { return true }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return check()
    }

    private func fixture(_ frame: CGRect, _ color: NSColor) -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.backgroundColor = color
        let editor = NSTextView(frame: CGRect(x: 8, y: 8, width: 80, height: 26))
        editor.isRichText = false
        window.contentView?.addSubview(editor)
        return (window, editor)
    }

    func measure(output: URL) async throws {
        var receipt: [String: Any] = [
            "scope": "isolated hosted AppKit process, production WindowSwitchCover and real WindowServer",
            "status": "BLOCKED", "presentedPixels": "NOT_RUN", "installedHost": "NOT_RUN",
            "eventSource": "NSApplication.sendEvent to actual key window", "physicalInputs": 0
        ]
        func save(_ reason: String) throws {
            receipt["reason"] = reason
            let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try bytes.write(to: output, options: .withoutOverwriting)
        }
        let app = NSApplication.shared
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true, let screen = NSScreen.main else {
            try save("noUnlockedHostedConsole"); return
        }
        let registered = NSRunningApplication.current.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL &&
            NSRunningApplication.current.bundleIdentifier == "net.example.nearpane.hosted-window-switch"
        receipt["registeredFixture"] = registered
        guard registered && app.activationPolicy() == .regular else { try save("ordinaryRegisteredFixtureUnavailable"); return }
        app.activate()
        let frame = CGRect(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.midY - 60, width: 200, height: 120)
        let (source, oldEditor) = fixture(frame, .red)
        let (target, editor) = fixture(frame, .blue)
        defer { source.close(); target.close() }
        target.orderFront(nil)
        source.makeKeyAndOrderFront(nil)
        let original = try await observe {
            app.isActive && app.keyWindow === source && stack([source, target]) == [source.windowNumber, target.windowNumber]
        }
        receipt["sourceKeyAndFront"] = original
        receipt["baseline"] = ["applicationActive":app.isActive, "sourceKey":app.keyWindow === source,
            "sourceAndTargetOrder":stack([source, target]) == [source.windowNumber, target.windowNumber],
            "launchServicesFront":NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()]
        guard original else { try save("fixtureCouldNotOwnHostedForeground"); return }
        let (pixels, captureReason) = await HostedPixels.start(on: screen, source: source)
        receipt["presentedPixels"] = ["status":"BLOCKED", "reason":captureReason]
        if let pixels { receipt["sampledOriginalBeforeOrdering"] = try await observe { pixels.hasOriginal } }
        guard let bitmap = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HostedError.noBitmap }
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = bitmap.makeImage() else { throw HostedError.noBitmap }
        let panel = WindowSwitchCover(frame: frame, image: image)
        defer { panel.discard() }
        let fixtures = [source, target, panel]
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        let covered = try await observe { stack(fixtures) == [panel.windowNumber, source.windowNumber, target.windowNumber] }
        let keptSource = app.keyWindow === source
        receipt["coverAboveSourceAndTarget"] = covered
        receipt["sourceKeptKeyWithCoverVisible"] = keptSource
        target.makeKeyAndOrderFront(nil)
        let different = try await observe {
            app.keyWindow === target && stack(fixtures) == [panel.windowNumber, target.windowNumber, source.windowNumber]
        }
        receipt["targetKeyUnderCover"] = different
        var delivered = false
        if different, target.makeFirstResponder(editor), let key = app.keyWindow,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: key.windowNumber, context: nil,
                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
            panel.reveal()
            CATransaction.flush()
            let start = ContinuousClock.now
            app.sendEvent(event)
            let elapsed = ContinuousClock.now - start
            delivered = editor.string == "k" && oldEditor.string.isEmpty && app.keyWindow === target && panel.isVisible
            receipt["eventDispatchMilliseconds"] = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        receipt["markerExclusivelyInTargetWhilePanelVisible"] = delivered
        try await Task.sleep(for: .seconds(WindowSwitchCover.duration))
        panel.orderOut(nil)
        let uncovered = try await observe {
            app.keyWindow === target && stack(fixtures) == [target.windowNumber, source.windowNumber]
        }
        receipt["targetRemainedKeyAndFrontAfterRemoval"] = uncovered
        if let pixels {
            try await Task.sleep(for: .milliseconds(120))
            receipt["presentedPixels"] = await pixels.finish()
        }
        let ok = covered && keptSource && different && delivered && uncovered
        receipt["status"] = ok ? "PASS" : "FAIL"
        try save(ok ? "observed" : "orderingOrEditorMismatch")
    }
}


@MainActor private final class HostedDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await HostedWindowSwitch().measure(output: output) }
            catch {
                let failure = ["status":"UNKNOWN", "reason":"fixtureReceiptOrBitmapUnavailable"]
                if let data = try? JSONSerialization.data(withJSONObject: failure) {
                    try? data.write(to: output, options: .withoutOverwriting)
                }
            }
            NSApp.terminate(nil)
        }
    }
}

@main private struct HostedApp {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--verify-link"] {
            guard Bundle.main.bundleIdentifier == "net.example.nearpane.hosted-window-switch" else { exit(2) }
            print(WindowSwitchCover.duration)
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard args.count == 2, args[0] == "--run-hosted", env["GITHUB_ACTIONS"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS" else { exit(2) }
        let app = NSApplication.shared
        let delegate = HostedDelegate(output: URL(fileURLWithPath: args[1]))
        app.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { exit(3) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
