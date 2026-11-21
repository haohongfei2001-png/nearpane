// Capture the installed rail with a real Apple wallpaper on a non-key test window behind it.
// The filter explicitly includes only these two windows. Raw captures are reviewed before sharing.
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

private struct Refused: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private final class Backdrop: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main struct WallpaperReview {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard (1...2).contains(args.count), CGPreflightScreenCaptureAccess() else { throw Refused("observer access or arguments") }
        let output = URL(fileURLWithPath: args[0], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let installed = "/Applications/Nearpane.app"
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.holdsnow.nearpane.alpha")
            .filter { $0.bundleURL?.path == installed }
        guard hosts.count == 1, let host = hosts.first, let screen = NSScreen.main,
              let displayID = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw Refused("installed host and screen required")
        }
        func inventory() async throws -> SCShareableContent {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let content = try await inventory()
        let rails = content.windows.filter {
            $0.owningApplication?.processID == host.processIdentifier && $0.frame.height > 300 &&
                $0.frame.height > $0.frame.width * 1.4 && $0.windowLayer == Int(CGWindowLevelForKey(.floatingWindow))
        }
        guard rails.count == 1, let rail = rails.first,
              let display = content.displays.first(where: { $0.displayID == displayID }), display.frame.contains(rail.frame),
              let primary = NSScreen.screens.first else { throw Refused("visible installed rail must be unique") }
        let shot = rail.frame.insetBy(dx: -55, dy: -4).intersection(display.frame)
        let rect = NSRect(x: shot.minX, y: primary.frame.maxY - shot.maxY, width: shot.width, height: shot.height)
        let backdrop = Backdrop(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .init(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) - 1)
        backdrop.hidesOnDeactivate = false
        backdrop.ignoresMouseEvents = true
        backdrop.hasShadow = false
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        imageView.imageScaling = .scaleNone
        backdrop.contentView = imageView
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer { backdrop.orderOut(nil); backdrop.close() }
        var checks: [[String: Any]] = []
        func capture(_ name: String, label file: String, including included: [SCWindow]) async throws {
            let filter = SCContentFilter(display: display, including: included)
            let config = SCStreamConfiguration()
            config.sourceRect = shot.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(shot.width * CGFloat(filter.pointPixelScale))
            config.height = Int(shot.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let url = output.appendingPathComponent(name + ".png")
            guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Refused("encode") }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw Refused("encode") }
            checks.append(["file": name + ".png", "wallpaper": file, "pixels": [image.width, image.height],
                           "panelPoints": [rail.frame.width, rail.frame.height], "leftInCrop": rail.frame.minX - shot.minX,
                           "topInCrop": rail.frame.minY - shot.minY, "scale": filter.pointPixelScale])
        }
        // The WindowServer base and the system wallpaper surface are beneath the desktop level.
        // Finder's icon plane, app windows and the menu bar never enter this filter.
        let desktop = content.windows.filter { w in
            let owner = w.owningApplication?.bundleIdentifier ?? ""
            return w.windowLayer < Int(CGWindowLevelForKey(.desktopWindow)) && w.frame == display.frame &&
                   (owner.isEmpty || owner == "com.apple.WindowManager" || owner == "com.apple.wallpaper.agent")
        }
        if !desktop.isEmpty, let actual = NSWorkspace.shared.desktopImageURL(for: screen),
           actual.standardizedFileURL.path.hasPrefix("/System/Library/") {
            try await capture("system-desktop", label: actual.lastPathComponent, including: desktop + [rail])
        }
        let base = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        for (name, file) in [("blue", "Mac Blue.heic"), ("yellow", "Mac Yellow.heic"), ("complex", "Sonoma.heic")] {
            if args.last == "--desktop-only" { break }
            guard let picture = NSImage(contentsOf: base.appendingPathComponent(file)) else { throw Refused("missing system wallpaper") }
            // Crop a full-display aspect-fill wallpaper at its real display coordinates.
            let scale = max(screen.frame.width / picture.size.width, screen.frame.height / picture.size.height)
            let scaled = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            let origin = CGPoint(x: screen.frame.midX - scaled.width / 2, y: screen.frame.midY - scaled.height / 2)
            let patch = NSImage(size: rect.size)
            patch.lockFocus()
            picture.draw(in: NSRect(x: origin.x - rect.minX, y: origin.y - rect.minY, width: scaled.width, height: scaled.height))
            patch.unlockFocus()
            imageView.image = patch
            backdrop.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(450))
            let live = try await inventory()
            guard let panel = live.windows.first(where: { $0.windowID == rail.windowID && $0.owningApplication?.processID == host.processIdentifier && $0.frame == rail.frame }),
                  let back = live.windows.first(where: { $0.windowID == UInt32(backdrop.windowNumber) && $0.owningApplication?.processID == getpid() }),
                  front == NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw Refused("window or focus changed") }
            try await capture(name, label: file, including: [back, panel])
            try await capture(name + "-background", label: file, including: [back])
        }
        backdrop.orderOut(nil)
        let result: [String: Any] = ["samples": checks, "source": "WindowServer display capture of the installed sidebar with the system desktop plane or a nonactivating Apple wallpaper fixture",
                                     "focusPreserved": front == NSWorkspace.shared.frontmostApplication?.processIdentifier]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("capture.json"), options: .withoutOverwriting)
    }
}
