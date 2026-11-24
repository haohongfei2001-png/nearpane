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
        let sequence: UInt64

        func image(reusing previous: CGImage? = nil) -> CGImage? {
            if let previous, repeats(previous) { return previous }
            guard sample.isValid, let buffer = sample.imageBuffer else { return nil }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
            return image
        }

        /// Compare only a resumed stream's first buffer with its already-decoded card.
        /// Padding is allocator-specific. Compare every visible BGRA byte, including alpha.
        func repeats(_ image: CGImage) -> Bool {
            guard sample.isValid, let buffer = sample.imageBuffer,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  image.width == CVPixelBufferGetWidth(buffer), image.height == CVPixelBufferGetHeight(buffer),
                  image.bitsPerComponent == 8, image.bitsPerPixel == 32,
                  image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
                  image.alphaInfo == .premultipliedFirst, image.colorSpace?.name == CGColorSpace.sRGB,
                  let data = image.dataProvider?.data, let prior = CFDataGetBytePtr(data) else { return false }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer), visibleBytes = image.width * 4
            guard visibleBytes <= rowBytes, visibleBytes <= image.bytesPerRow,
                  CFDataGetLength(data) >= (image.height - 1) * image.bytesPerRow + visibleBytes,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
            for y in 0..<image.height {
                if memcmp(base.advanced(by: y * rowBytes), prior.advanced(by: y * image.bytesPerRow), visibleBytes) != 0 { return false }
            }
            return true
        }
    }

    enum Update: Sendable {
        case frame(Frame)
        case idle(UInt64)
        case unavailable
    }
    struct OutputAudit: Sendable {
        let audit: PreviewPipelineAudit, key: DesktopWindowKey
        func note(_ reason: PreviewPipelineAudit.Reason, epoch: UInt64, uptime: TimeInterval?) {
            audit.record(key, .stream, reason, epoch: epoch, uptime: uptime)
        }
    }
    final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let events: AsyncStream<Update>.Continuation
        // Accessed only by this stream's serial sample queue.
        private var lastSignal = -Double.infinity
        private struct Delivery {
            var epoch: UInt64 = 0
            var issued: UInt64 = 0
            var published: UInt64?
        }
        private let delivery = OSAllocatedUnfairLock(initialState: Delivery())
        var epoch: UInt64 { delivery.withLock { $0.epoch } }
        func published(_ frame: Frame) {
            delivery.withLock {
                if $0.epoch == frame.epoch { $0.published = frame.sequence }
            }
        }
        private let diagnostic: OutputAudit?
        private func unavailable(_ reason: PreviewPipelineAudit.Reason, now: TimeInterval? = nil) {
            let epoch = delivery.withLock {
                $0 = Delivery(epoch: $0.epoch &+ 1)
                return $0.epoch
            }
            diagnostic?.note(reason, epoch: epoch, uptime: now)
            events.yield(.unavailable)
        }
        let width: Int, height: Int
        init(_ events: AsyncStream<Update>.Continuation, width: Int, height: Int, diagnostic: OutputAudit? = nil) {
            self.events = events; self.width = width; self.height = height; self.diagnostic = diagnostic
        }
        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            guard sample.isValid, let rows = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]], let value = rows.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: value) else { unavailable(.invalidMetadata); return }
            let dirty = rows.first?[.dirtyRects] as? NSArray
            receive(sample, status: status, now: ProcessInfo.processInfo.systemUptime, hasDamage: dirty.map { $0.count > 0 })
        }
        func receive(_ sample: CMSampleBuffer, status: SCFrameStatus, now: TimeInterval, hasDamage: Bool? = nil) {
            switch status {
            case .complete, .started:
                if status == .complete, hasDamage == false, delivery.withLock({ $0.published == $0.issued }) {
                    idle(now)
                    return
                }
                guard let pixel = sample.imageBuffer, CVPixelBufferGetWidth(pixel) == width,
                      CVPixelBufferGetHeight(pixel) == height else { unavailable(.invalidBuffer, now: now); return }
                let (epoch, sequence) = delivery.withLock {
                    $0.issued &+= 1
                    return ($0.epoch, $0.issued)
                }
                let frame = Frame(sample: sample, received: now, epoch: epoch, sequence: sequence)
                diagnostic?.note(status == .started ? .started : .complete, epoch: frame.epoch, uptime: now)
                lastSignal = now
                events.yield(.frame(frame))
            case .idle:
                idle(now)
            case .stopped:
                unavailable(.stopped, now: now)
                events.finish()
            case .blank: unavailable(.blank, now: now)
            case .suspended: unavailable(.suspended, now: now)
            @unknown default: unavailable(.unknownStatus, now: now)
            }
        }
        private func idle(_ now: TimeInterval) {
            // The channel holds only one update. A heartbeat must never displace the
            // final changed frame of a window that has just stopped drawing.
            let state = delivery.withLock { $0 }
            diagnostic?.note(.idle, epoch: state.epoch, uptime: now)
            guard now - lastSignal >= 3, state.issued == 0 || state.published == state.issued else { return }
            lastSignal = now
            events.yield(.idle(state.epoch))
        }
        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            unavailable(.streamError)
            events.finish()
        }
    }

    let updates: AsyncStream<Update>
    let logicalSize: CGSize
    private let output: Output
    private let stream: SCStream

    var epoch: UInt64 { output.epoch }
    func published(_ frame: Frame) { output.published(frame) }

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

    init?(window: SCWindow, target: DesktopWindowTarget, audit: PreviewPipelineAudit? = nil) {
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
        output = Output(continuation, width: config.width, height: config.height,
                        diagnostic: audit.map { OutputAudit(audit: $0, key: target.key) })
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
