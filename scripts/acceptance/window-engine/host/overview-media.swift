import AVFoundation
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The public artifacts contain only low-resolution samples of the system-owned strip. No audio or cursor.
final class OverviewMedia: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "nearpane.acceptance.strip")
    private let context = CIContext()
    private var frames = [[String:Any]]()
    private var last = -Double.infinity
    private var stream: SCStream?
    private var reason = "noCompleteFrames"
    init(_ directory: URL) { self.directory = directory }

    @MainActor func start() async {
        guard CGPreflightScreenCaptureAccess() else { reason = "screenRecordingPreflightDenied"; return }
        do {
            let source = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:false)
            guard let d = source.displays.first(where:{ $0.displayID == CGMainDisplayID() }) else { return }
            let owners = source.applications.filter { item in
                let known = ["com.apple.dock":"/System/Library/CoreServices/Dock.app", "com.apple.WindowManager":"/System/Library/CoreServices/WindowManager.app"]
                guard let path = known[item.bundleIdentifier] else { return false }
                return NSRunningApplication(processIdentifier:item.processID)?.bundleURL?.path == path
            }
            guard owners.contains(where:{ $0.bundleIdentifier == "com.apple.dock" }) else { reason = "systemStripOwnerUnavailable"; return }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x:0, y:0, width:d.width, height:min(160,d.height))
            config.width = 144
            config.height = 16
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value:1,timescale:12)
            let s = SCStream(filter:SCContentFilter(display:d,including:owners,exceptingWindows:[]),configuration:config,delegate:self)
            try s.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
            try await s.startCapture()
            stream = s
        } catch { reason = "captureStartError/" + String((error as NSError).code) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let buffer = sample.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
              (info[.status] as? Int) == SCFrameStatus.complete.rawValue else { return }
        let time = sample.presentationTimeStamp.seconds
        guard time.isFinite, time > last, frames.count < 400,
              let image = context.createCGImage(CIImage(cvPixelBuffer:buffer),from:CGRect(x:0,y:0,width:144,height:16)) else { return }
        let name = String(format:"frame-%03d.png", frames.count), file = directory.appendingPathComponent(name)
        guard let out = CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil) else { return }
        CGImageDestinationAddImage(out,image,nil)
        guard CGImageDestinationFinalize(out) else { return }
        frames.append(["file":name,"pts":time,"receivedUptime":ProcessInfo.processInfo.systemUptime])
        last = time
    }

    @MainActor func finish() async -> [String:Any] {
        if let stream {
            do { try await stream.stopCapture() } catch { reason = "captureStopError/" + String((error as NSError).code) }
        }
        return queue.sync {
            ["status":frames.count >= 2 ? "CAPTURED" : "BLOCKED",
             "reason":frames.count >= 2 ? "timestampedSystemStripSamples" : reason,
             "width":144,"height":16,"scope":"Dock and WindowManager only, upper 160 points",
             "audio":false,"cursor":false,"frames":frames]
        }
    }
}
