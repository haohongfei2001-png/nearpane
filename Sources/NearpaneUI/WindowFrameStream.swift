import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import os

/// One queue for one immutable window filter. At most one pending frame crosses to the gallery.
@MainActor final class WindowFrameStream {
    static let limit = 8
    static let longestEdge: CGFloat = 420

    struct Frame: @unchecked Sendable {
        // ScreenCaptureKit owns the immutable sample. Retaining it keeps its pixel buffer alive.
        let sample: CMSampleBuffer
        let received: TimeInterval
        let epoch: UInt64

        func image() -> CGImage? {
            guard sample.isValid, let buffer = sample.imageBuffer else { return nil }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
            return image
        }
    }

    enum Update: Sendable {
        case frame(Frame)
        case idle(UInt64)
        case unavailable
    }
    final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let events: AsyncStream<Update>.Continuation
        // Accessed only by this stream's serial sample queue.
        private var lastSignal = -Double.infinity
        private let validity = OSAllocatedUnfairLock(initialState: UInt64(0))
        var epoch: UInt64 { validity.withLock { $0 } }
        private func unavailable() {
            validity.withLock { $0 &+= 1 }
            events.yield(.unavailable)
        }
        let width: Int, height: Int
        init(_ events: AsyncStream<Update>.Continuation, width: Int, height: Int) {
            self.events = events; self.width = width; self.height = height
        }
        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            guard sample.isValid, let rows = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]], let value = rows.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: value) else { unavailable(); return }
            receive(sample, status: status, now: ProcessInfo.processInfo.systemUptime)
        }
        func receive(_ sample: CMSampleBuffer, status: SCFrameStatus, now: TimeInterval) {
            switch status {
            case .complete, .started:
                guard let pixel = sample.imageBuffer, CVPixelBufferGetWidth(pixel) == width,
                      CVPixelBufferGetHeight(pixel) == height else { unavailable(); return }
                lastSignal = now
                events.yield(.frame(Frame(sample: sample, received: now, epoch: epoch)))
            case .idle:
                // The compositor reports unchanged content. Avoid waking the UI for repeated identical frames.
                if now - lastSignal >= 3 { lastSignal = now; events.yield(.idle(epoch)) }
            case .stopped:
                unavailable()
                events.finish()
            default:
                unavailable()
            }
        }
        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            unavailable()
            events.finish()
        }
    }

    let updates: AsyncStream<Update>
    let logicalSize: CGSize
    private let output: Output
    private let stream: SCStream

    var epoch: UInt64 { output.epoch }

    static func rate(on display: String) -> Int32 {
        let screen = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(display) == .orderedSame
        }
        let refresh = screen?.maximumFramesPerSecond ?? 0
        return Int32(refresh > 0 ? min(60, refresh) : 30)
    }

    static func sRGBConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Keep the captured BGRA bytes in the same color space VideoToolbox uses for untagged RGB.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    init?(window: SCWindow, target: DesktopWindowTarget) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = filter.contentRect.size
        guard window.windowID == target.key.number, window.windowLayer == 0,
              window.owningApplication?.processID == target.key.pid, target.acceptsContentSize(size),
              window.frame.width > 0, window.frame.height > 0 else { return nil }
        logicalSize = size
        let scale = min(1, Self.longestEdge / max(size.width, size.height))
        let config = Self.sRGBConfiguration()
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.rate(on: target.display))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.preservesAspectRatio = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let (events, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = events
        output = Output(continuation, width: config.width, height: config.height)
        stream = SCStream(filter: filter, configuration: config, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.holdsnow.nearpane.window-preview", qos: .userInitiated))
        } catch { return nil }
    }

    func start() async throws { try await stream.startCapture() }
    func finishOutput() { output.events.finish() }
    func stop() async {
        finishOutput()
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .screen)
    }
}
