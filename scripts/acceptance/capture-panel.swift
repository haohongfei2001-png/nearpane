import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// Invoked only for an explicitly authorized real visual review of the running, isolated package.
@main struct CaptureAcceptancePanel {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, let pid = Int32(args[0]), let number = UInt32(args[1]),
              let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == "com.holdsnow.nearpane.host",
              running.executableURL?.resolvingSymlinksInPath().path == args[2] else { throw CocoaError(.fileReadNoPermission) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }),
              !running.isTerminated else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
        config.height = max(1, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), !running.isTerminated else { throw CocoaError(.fileWriteUnknown) }
        try (output as Data).write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    }
}
