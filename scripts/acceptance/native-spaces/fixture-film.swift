import AppKit
import AVFoundation
import ScreenCaptureKit

struct FilmError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MovieEvents: NSObject, SCRecordingOutputDelegate {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { failure = error }
    }
    func done() throws -> Bool {
        try lock.withLock { if let failure { throw failure }; return finished }
    }
}

@main struct FixtureFilm {
    static func main() async {
        do { try await capture() }
        catch { fputs("Fixture recording: \(error.localizedDescription)\n", stderr); exit(2) }
    }

    @MainActor static func capture() async throws {
        // Initialize this standalone observer's WindowServer connection on the main thread.
        _ = NSApplication.shared
        _ = NSScreen.screens
        let args = CommandLine.arguments
        guard args.count == 5, let pid = Int32(args[1]), let wid = UInt32(args[2]),
              let seconds = Int(args[3]), (2...45).contains(seconds), CGPreflightScreenCaptureAccess(),
              let owner = NSRunningApplication(processIdentifier: pid),
              ["org.nearpane.acceptance.LifecycleWindow","net.example.spaces-document"].contains(owner.bundleIdentifier),
              !FileManager.default.fileExists(atPath: args[4]) else { throw FilmError("Expected an owned fixture window and a fresh recording path") }
        let output = URL(fileURLWithPath: args[4])
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == wid && $0.owningApplication?.processID == pid }),
              !owner.isTerminated else { throw FilmError("Fixture identity changed") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = 640; config.height = 360
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = output; settings.outputFileType = .mp4; settings.videoCodecType = .h264
        let events = MovieEvents()
        let recording = SCRecordingOutput(configuration: settings, delegate: events)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        try Data("window-only".utf8).write(to: output.appendingPathExtension("ready"), options: .atomic)
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        for _ in 0..<60 {
            if try events.done() { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard try events.done(), video.count == 1, audio.isEmpty, duration >= 1,
              !owner.isTerminated else { throw FilmError("Missing duration, clean video track or fixture identity") }
        let receipt: [String:Any] = ["pid":pid, "window":wid, "seconds":duration, "videoTracks":video.count,
            "audioTracks":audio.count, "filter":"desktopIndependentWindow", "windowServerRecording":true]
        print(String(decoding: try JSONSerialization.data(withJSONObject:receipt),as:UTF8.self))
    }
}
