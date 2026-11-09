import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// Invoked only for an explicitly authorized real visual review of the running, isolated package.
@main struct CaptureAcceptancePanel {
    enum Failure: String, Error {
        case arguments, hostIdentity, screenCapturePermission, windowUnavailable, encoding
    }

    @MainActor static func owns(_ running: NSRunningApplication, executable: URL) -> Bool {
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expectedID = "com.holdsnow.nearpane.host"
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = proc_pidpath(running.processIdentifier, &path, UInt32(path.count))
        guard size > 0, !running.isTerminated,
              URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)).resolvingSymlinksInPath().path == executable.path,
              running.executableURL?.resolvingSymlinksInPath().path == executable.path,
              running.bundleURL?.resolvingSymlinksInPath().path == bundle.path,
              let disk = Bundle(url: bundle), disk.bundleIdentifier == expectedID,
              disk.executableURL?.resolvingSymlinksInPath().path == executable.path else { return false }
        // A directly supervised .app can lack a LaunchServices identifier.
        return running.bundleIdentifier.map { $0 == expectedID } ?? true
    }

    @MainActor static func capture() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let secondaryOnly = args.count == 5 && args.last == "--secondary-only"
        guard args.count == 4 || secondaryOnly, let pid = Int32(args[0]), pid > 0, let number = UInt32(args[1]), number != 0 else { throw Failure.arguments }
        let executable = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        guard executable.path == args[2],
              let running = NSRunningApplication(processIdentifier: pid),
              owns(running, executable: executable) else { throw Failure.hostIdentity }
        guard CGPreflightScreenCaptureAccess() else { throw Failure.screenCapturePermission }
        // A supervised command-line client needs a WindowServer connection before constructing the filter.
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        guard !NSScreen.screens.isEmpty else { throw Failure.windowUnavailable }
        func withinSecondary() -> Bool {
            guard let screen = NSScreen.screens.last, NSScreen.screens.count == 2,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  id.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(id.uint32Value) == 0,
                  CGDisplayBounds(id.uint32Value).intersection(CGDisplayBounds(CGMainDisplayID())).isEmpty,
                  let item = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?.first,
                  (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number,
                  (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let values = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: values), !frame.isEmpty else { return false }
            return CGDisplayBounds(id.uint32Value).contains(frame)
        }
        guard !secondaryOnly || withinSecondary() else { throw Failure.windowUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }),
              !running.isTerminated else { throw Failure.windowUnavailable }
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
        guard CGImageDestinationFinalize(dest) else { throw Failure.encoding }
        guard owns(running, executable: executable), !secondaryOnly || withinSecondary() else { throw Failure.hostIdentity }
        try (output as Data).write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    }

    @MainActor static func main() async {
        do { try await capture() }
        catch {
            let reason = (error as? Failure)?.rawValue ?? "\((error as NSError).domain) \((error as NSError).code)"
            FileHandle.standardError.write(Data("Panel capture failed: \(reason)\n".utf8))
            exit(2)
        }
    }
}
