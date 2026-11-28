// Display composite restricted to the signed installed rail, the two exact owned source windows and the macOS wallpaper.
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import ImageIO

private enum Failure: Error { case identity, geometry, capture }
@main struct Scene {
    @MainActor static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data(("scene unavailable: " + String(describing:error) + "\n").utf8)); exit(2) }
    }
    @MainActor static func run() async throws {
        let a = Array(CommandLine.arguments.dropFirst())
        guard a.count == 5, let pid = Int32(a[1]), let n1 = UInt32(a[2]), let n2 = UInt32(a[3]), n1 != n2,
              let fixture = NSRunningApplication(processIdentifier:pid), fixture.bundleIdentifier == "net.example.spaces-document",
              fixture.bundleURL?.standardizedFileURL == URL(fileURLWithPath:a[4],isDirectory:true).standardizedFileURL,
              let host = NSRunningApplication.runningApplications(withBundleIdentifier:"com.holdsnow.nearpane.alpha").first(where: { $0.bundleURL?.path == "/Applications/Nearpane.app" })
        else { throw Failure.identity }
        let shared = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        let sources = shared.windows.filter { [n1,n2].contains($0.windowID) && $0.owningApplication?.processID == pid }
        let rail = shared.windows.filter { $0.owningApplication?.processID == host.processIdentifier && $0.windowLayer == Int(CGWindowLevelForKey(.floatingWindow)) && $0.frame.height > $0.frame.width * 1.4 }
        guard sources.count == 2, rail.count == 1, shared.displays.count == 1, let display = shared.displays.first else { throw Failure.geometry }
        let wall = shared.windows.filter { w in
            let owner = w.owningApplication?.bundleIdentifier ?? ""
            return w.windowLayer < Int(CGWindowLevelForKey(.desktopWindow)) && w.frame == display.frame && (owner.isEmpty || owner == "com.apple.WindowManager" || owner == "com.apple.wallpaper.agent")
        }
        guard !wall.isEmpty else { throw Failure.geometry }
        let filter = SCContentFilter(display: display, including: wall + sources + rail)
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width); config.height = Int(display.frame.height); config.showsCursor = false
        let bitmap = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        guard let writer = CGImageDestinationCreateWithURL(URL(fileURLWithPath:a[0]) as CFURL,UTType.png.identifier as CFString,1,nil) else { throw Failure.capture }
        CGImageDestinationAddImage(writer,bitmap,nil)
        guard CGImageDestinationFinalize(writer) else { throw Failure.capture }
    }
}
