import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import ScreenCaptureKit

// Independent readback for one newly created window. No input events or picker are used.
private final class WitnessWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main private struct OwnedWindowPreview {
    private final class Swatch: NSView {
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let (left, right) = bounds.divided(atDistance: bounds.width / 2, from: .minXEdge)
            NSColor(srgbRed: 0.12, green: 0.75, blue: 0.30, alpha: 1).setFill(); left.fill()
            NSColor(srgbRed: 0.80, green: 0.12, blue: 0.60, alpha: 1).setFill(); right.fill()
        }
    }

    private struct AXFacts: Codable {
        var status: Int32 = -1, count = 0, frames = 0, publicNumber = 0, resolverNumber = 0, confirmed = 0
        var publicAttributeStatus: Int32?, actualFrame: [Double]?
    }
    private struct Readback: Codable {
        var applicationRegistered = false, ax: AXFacts?, cgNumber: UInt32?, cgFrame: [Double]?, rgba: [[UInt8]]?
        var focusedThroughout: Bool?, cleaned: Bool?, axTrusted: Bool?, captureTrusted: Bool?
        var windowOrdered = false, cgOwnsVisibleWindow = false
        var width = 0, height = 0, correctColor = false, swatchOrderMatches = false
        var imageSHA256: String?, stopped: String?
    }

    private static func components(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

    private static func axFacts(pid: pid_t, number: UInt32, frame: CGRect) -> AXFacts {
        var facts = AXFacts()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var array: CFArray?
        let status = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 4, &array)
        facts.status = status.rawValue
        guard status == .success, let windows = array as? [AXUIElement] else { return facts }
        facts.count = windows.count
        for window in windows {
            func value(_ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, key as CFString, &value) == .success ? value : nil
            }
            var owner: pid_t = 0, attribute: CFTypeRef?
            guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { continue }
            facts.publicAttributeStatus = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &attribute).rawValue
            let direct = (attribute as? NSNumber)?.uint32Value == number
            let resolved = NPReadAXWindowNumber(window) == number
            if direct { facts.publicNumber += 1 }
            if resolved { facts.resolverNumber += 1 }
            guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) {
                let actual = CGRect(origin: p, size: s)
                if direct || resolved { facts.actualFrame = components(actual) }
                if actual == frame {
                    facts.frames += 1
                    if direct || resolved, value(kAXRoleAttribute) as? String == kAXWindowRole,
                       value(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole { facts.confirmed += 1 }
                }
            }
        }
        return facts
    }

    @MainActor private final class Delegate: NSObject, NSApplicationDelegate {
        let originalFront: pid_t
        init(front: pid_t) { originalFront = front }
        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do { try await OwnedWindowPreview.run(front: originalFront); exit(0) }
                catch { FileHandle.standardError.write(Data("Window probe interrupted.\n".utf8)); exit(3) }
            }
        }
    }
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        if args.count == 8, args[1] == "--read-parent", let pid = Int32(args[2]), pid == getppid(),
           let number = UInt32(args[3]), let x = Double(args[4]), let y = Double(args[5]),
           let w = Double(args[6]), let h = Double(args[7]), AXIsProcessTrusted() {
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0,
                  let own = Bundle.main.executableURL?.resolvingSymlinksInPath(),
                  URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath() == own else { exit(2) }
            // A spawned process reads only its creator's AX window collection.
            let facts = axFacts(pid: pid, number: number, frame: CGRect(x: x, y: y, width: w, height: h))
            print(String(decoding: try JSONEncoder().encode(facts), as: UTF8.self))
            return
        }
        guard args.count == 1 else { exit(2) }
        let app = NSApplication.shared
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "org.nearpane.acceptance.OwnedWindowPreview",
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front > 1, front != getpid() else { exit(2) }
        _ = app.setActivationPolicy(.accessory)
        let delegate = Delegate(front: front)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func run(front: pid_t) async throws {
        var proof = Readback()
        defer { if let output = try? JSONEncoder().encode(proof) { print(String(decoding: output, as: UTF8.self)) } }
        let app = NSApplication.shared
        proof.applicationRegistered = app.isRunning && app.activationPolicy() == .accessory
            && NSRunningApplication.current.bundleIdentifier == Bundle.main.bundleIdentifier
        guard proof.applicationRegistered else { proof.stopped = "unregistered-fixture"; return }
        guard let console = CGSessionCopyCurrentDictionary() as? [String: Any],
              console[kCGSessionOnConsoleKey as String] as? Bool == true,
              console[kCGSessionLoginDoneKey as String] as? Bool == true else { proof.stopped = "not-active-console"; return }
        guard console["CGSSessionScreenIsLocked"] as? Bool != true else { proof.stopped = "screen-locked"; return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { proof.stopped = "launch-focus"; return }
        guard let screen = NSScreen.screens.last else { proof.stopped = "no-screen"; return }
        proof.axTrusted = AXIsProcessTrusted()
        proof.captureTrusted = CGPreflightScreenCaptureAccess()
        guard proof.axTrusted == true || proof.captureTrusted == true else { proof.stopped = "no-existing-permission"; return }
        let frame = CGRect(x: screen.visibleFrame.minX + 8, y: screen.visibleFrame.minY + 8, width: 120, height: 72)
        let window = WitnessWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = Swatch(frame: CGRect(origin: .zero, size: frame.size))
        var changed = false
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let owner = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, owner.processIdentifier != front { changed = true }
        }
        func focusOkay() -> Bool { !changed && !app.isActive && !window.isKeyWindow && !window.isMainWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == front }
        defer {
            window.orderOut(nil); window.close()
            proof.focusedThroughout = focusOkay(); proof.cleaned = !window.isVisible
            center.removeObserver(observer)
        }
        guard focusOkay(), screen.visibleFrame.contains(window.frame) else { proof.stopped = "before-order"; return }
        window.orderBack(nil)
        window.display()
        proof.windowOrdered = true
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(4))
            window.orderOut(nil)
            window.close()
            FileHandle.standardError.write(Data("Own-window witness timed out and closed its window.\n".utf8))
            exit(3)
        }
        defer { timeout.cancel() }
        try await Task.sleep(for: .milliseconds(210))
        guard focusOkay(), let number = UInt32(exactly: window.windowNumber), number > 0,
              let cg = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?.only,
              (cg[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid(),
              (cg[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number,
              (cg[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (cg[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = cg[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds) else { proof.stopped = "window-or-focus"; return }
        proof.cgOwnsVisibleWindow = true; proof.cgNumber = number; proof.cgFrame = components(quartzFrame)
        if proof.axTrusted == true {
            let ownPID = getpid()
            let binary = Bundle.main.executableURL
            proof.ax = await Task.detached { () -> AXFacts? in
                let actor = Process(), pipe = Pipe()
                actor.executableURL = binary; actor.standardOutput = pipe
                actor.arguments = ["--read-parent", String(ownPID), String(number)] + [quartzFrame.minX, quartzFrame.minY, quartzFrame.width, quartzFrame.height].map { String(Double($0)) }
                do { try actor.run() } catch { return nil }
                let result = pipe.fileHandleForReading.readDataToEndOfFile()
                actor.waitUntilExit()
                return try? JSONDecoder().decode(AXFacts.self, from: result)
            }.value
        }
        guard proof.captureTrusted == true, focusOkay() else { proof.stopped = "capture-permission-or-focus"; return }
        do {
            let shareable = try await SCShareableContent.currentProcess
            guard focusOkay(), let chosen = shareable.windows.filter({ $0.windowID == number && $0.owningApplication?.processID == getpid() }).only,
                  chosen.isOnScreen, chosen.frame == quartzFrame else { proof.stopped = "own-filter-unavailable"; return }
            let filter = SCContentFilter(desktopIndependentWindow: chosen)
            guard filter.style == .window, filter.includedWindows.count == 1, filter.includedWindows.first?.windowID == number else { proof.stopped = "filter-scope"; return }
            let config = SCStreamConfiguration()
            config.width = Int(quartzFrame.width); config.height = Int(quartzFrame.height)
            config.showsCursor = false; config.capturesAudio = false; config.includeChildWindows = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard focusOkay(), image.width == config.width, image.height == config.height else { proof.stopped = "capture-size-or-focus"; return }
            let rowBytes = image.width * 4
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let raster = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let buffer = raster.data else { proof.stopped = "pixel-conversion"; return }
            raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.assumingMemoryBound(to: UInt8.self)
            func pixel(_ x: Int) -> [UInt8] {
                let offset = raster.bytesPerRow * (image.height / 2) + 4 * x
                return (0..<4).map { bytes[offset + $0] }
            }
            let left = pixel(image.width / 4), right = pixel(image.width * 3 / 4)
            proof.width = image.width; proof.height = image.height; proof.rgba = [left, right]
            proof.correctColor = zip(left + right, [31,191,77,255,204,31,153,255]).allSatisfy { abs(Int($0) - $1) <= 8 }
            proof.swatchOrderMatches = Int(left[1]) - Int(left[0]) > 50 && Int(right[0]) - Int(right[1]) > 50 && left[3] > 245 && right[3] > 245
            proof.imageSHA256 = SHA256.hash(data: Data(bytes: buffer, count: raster.bytesPerRow * image.height)).map { String(format: "%02x", $0) }.joined()
        } catch {
            let e = error as NSError
            proof.stopped = "capture-\(e.domain)-\(e.code)"
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
