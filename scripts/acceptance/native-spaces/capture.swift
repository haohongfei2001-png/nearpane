import AppKit
import ScreenCaptureKit

struct Refused: Error { let stage: String; init(_ stage: String) { self.stage = stage } }
@main struct TitleEvidence {
    @MainActor static func main() async {
        do { try await capture() }
        catch {
            let ns = error as NSError
            let value: [String:Any] = ["ready":false, "reason":(error as? Refused)?.stage ?? "system capture failed",
                                       "errorDomain":ns.domain, "errorCode":ns.code]
            if let result = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) {
                print(String(decoding:result,as:UTF8.self))
            }
        }
    }
    @MainActor static func capture() async throws {
        let args = CommandLine.arguments
        let card = args.count == 12 && ["roster-card", "roster-shared-card"].contains(args[2])
        let roster = args.count >= 6 && ["roster-content", "roster-panel"].contains(args[2])
        let rail = roster && args[2] == "roster-panel"
        guard CGPreflightScreenCaptureAccess(), card || ((roster || args.count == 4) && !FileManager.default.fileExists(atPath: args.last!))
        else { throw Refused("permission, arguments or preexisting file") }
        func observe() throws -> [String: Any] {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: args[1])
            if roster { p.arguments = Array(args.dropFirst(2).dropLast()) }
            else { p.arguments = card ? Array(args.dropFirst(2)) : ["crop", args[2]] }
            p.standardOutput = out
            try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard p.terminationStatus == 0, let r = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let r = card ? r["pixelCrop"] as? [String:Any] : r, r["ready"] as? Bool == true else { throw Refused("could not bind crop to visible installed window") }
            return r
        }
        let a = try observe()
        guard let pid = a["pid"] as? pid_t, let number = a["number"] as? UInt32,
              let rect = a["crop"] as? [NSNumber], rect.count == 4,
              roster ? (rect[2].intValue > 0 && rect[3].intValue > 0) :
                  (rect[2].intValue == (card ? 4 : 60) && rect[3].intValue == (card ? 4 : 17)),
              let wanted = a["display"] as? String, let uuid = UUID(uuidString:wanted) else { throw Refused("unrecognized window coordinates") }
        let sharable = try await SCShareableContent.excludingDesktopWindows(!rail,onScreenWindowsOnly:true)
        let displays = sharable.displays.filter { screen in
            guard let id = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue() else { return false }
            return UUID(uuidString: CFUUIDCreateString(nil, id) as String) == uuid
        }
        let windows = sharable.windows.filter { $0.windowID == number && $0.owningApplication?.processID == pid }
        let crop = CGRect(x:rect[0].doubleValue, y:rect[1].doubleValue, width:rect[2].doubleValue, height: rect[3].doubleValue)
        guard displays.count == 1, let display = displays.first, windows.count == 1, let panel = windows.first,
              panel.frame.contains(crop), display.frame.contains(crop), try NSDictionary(dictionary:a).isEqual(to:observe()) else { throw Refused("source changed or crop not contained by selected window and display") }
        let wallpaper = rail ? sharable.windows.filter { window in
            let owner = window.owningApplication?.bundleIdentifier ?? ""
            return window.windowLayer < Int(CGWindowLevelForKey(.desktopWindow)) && window.frame == display.frame &&
                (owner.isEmpty || owner == "com.apple.WindowManager" || owner == "com.apple.wallpaper.agent")
        } : []
        let filter = SCContentFilter(display:display, including:[panel] + wallpaper)
        filter.includeMenuBar = false
        let config = SCStreamConfiguration()
        config.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(crop.width) * 2; config.height = Int(crop.height) * 2; config.showsCursor = false; config.capturesAudio = false
        config.captureMicrophone = false
        // The SDK defaults to clear. Its backgroundColor property is assign, so a transient NSColor.cgColor would dangle.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard image.width == config.width, image.height == config.height, try NSDictionary(dictionary:a).isEqual(to:observe())
        else { throw Refused("source changed or output dimensions differed") }
        let rep = NSBitmapImageRep(cgImage:image)
        if card {
            var green = 0, purple = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                    if c.greenComponent > max(c.redComponent, c.blueComponent) + 0.15 { green += 1 }
                    if min(c.redComponent, c.blueComponent) > c.greenComponent + 0.15 { purple += 1 }
                }
            }
            let result: [String:Any] = ["ready": true, "fixture": a["fixtureNumber"]!, "sampleCount": image.width * image.height,
                                        "green": green, "purple": purple]
            print(String(decoding: try JSONSerialization.data(withJSONObject:result, options:.sortedKeys), as:UTF8.self))
            return
        }
        guard let bytes = rep.representation(using:.png,properties:[:]) else { throw Refused("encoding failed") }
        try bytes.write(to: URL(fileURLWithPath:args.last!),options:.withoutOverwriting)
        var receipt = a
        if rail { receipt["wallpaperIncluded"] = !wallpaper.isEmpty }
        print(String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys),as:UTF8.self))
    }
}
