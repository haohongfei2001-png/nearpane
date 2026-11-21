import AppKit
import AVFoundation
import ScreenCaptureKit

/// Full-screen capture is only reachable through the comparison runner in the disposable
/// hosted login. No microphone, system audio, private profile or user session is enrolled.
enum CaptureUnavailable: Error { case permission, display, completion }

func fixtureDisplay() async throws -> SCDisplay {
    guard CGPreflightScreenCaptureAccess() else { throw CaptureUnavailable.permission }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard content.displays.count == 1, let display = content.displays.first else { throw CaptureUnavailable.display }
    return display
}

@MainActor func cornerPixels(width: Int, height: Int) async throws -> NSImage {
    let display = try await fixtureDisplay()
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: display.width-width, y: display.height-height, width: width, height: height)
    config.width = width; config.height = height; config.showsCursor = false
    let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    return NSImage(cgImage: pixels, size: CGSize(width: width, height: height))
}

private final class RecordingState: NSObject, SCRecordingOutputDelegate {
    let lock = NSLock()
    private var complete = false, failed = false
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) { lock.withLock { complete = true } }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: any Error) { lock.withLock { failed = true } }
    var result: Bool? { lock.withLock { failed ? false : (complete ? true : nil) } }
}

@MainActor func recordComparison(_ root: URL) async throws {
    let display = try await fixtureDisplay()
    let config = SCStreamConfiguration()
    config.width = display.width; config.height = display.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.capturesAudio = false; config.captureMicrophone = false; config.showsCursor = true
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
    let settings = SCRecordingOutputConfiguration()
    settings.outputURL = root.appendingPathComponent("trial.mp4")
    let witness = RecordingState()
    let file = SCRecordingOutput(configuration: settings, delegate: witness)
    try stream.addRecordingOutput(file)
    try await stream.startCapture()
    try Data().write(to: root.appendingPathComponent("film-ready"), options: .atomic)
    let deadline = ContinuousClock.now + .seconds(120)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("film-stop").path),
          witness.result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(80)) }
    try await stream.stopCapture()
    let finish = ContinuousClock.now + .seconds(6)
    while witness.result == nil, ContinuousClock.now < finish { try await Task.sleep(for: .milliseconds(50)) }
    guard witness.result == true else { throw CaptureUnavailable.completion }
}
