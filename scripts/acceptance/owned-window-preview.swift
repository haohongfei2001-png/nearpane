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
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.12, green: 0.75, blue: 0.3, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    private struct Readback: Codable {
        var axStatus: Int32?, centerRGB: [Double]?
        var focusedThroughout: Bool?, cleaned: Bool?, axTrusted: Bool?, captureTrusted: Bool?
        var windowOrdered = false
        var cgOwnsVisibleWindow = false, axWindows = 0, axNumberMatches = 0, axFrameMatches = 0
        var width = 0, height = 0, correctColor = false
        var imageSHA256: String?, stopped: String?
    }

    private static func axFacts(pid: pid_t, number: UInt32, frame: CGRect) -> [Int32] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var array: CFArray?
        let status = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 4, &array)
        guard status == .success, let windows = array as? [AXUIElement] else { return [status.rawValue, 0, 0, 0] }
        var numbers = 0, frames = 0
        for window in windows {
            func value(_ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, key as CFString, &value) == .success ? value : nil
            }
            guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s), CGRect(origin: p, size: s) == frame { frames += 1 }
            if let n = value("AXWindowNumber") as? NSNumber, n.uint32Value == number { numbers += 1 }
        }
        return [status.rawValue, Int32(windows.count), Int32(numbers), Int32(frames)]
    }

    @MainActor static func main() async throws {
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
        var proof = Readback()
        defer { if let output = try? JSONEncoder().encode(proof) { print(String(decoding: output, as: UTF8.self)) } }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        guard app.activationPolicy() == .prohibited else { proof.stopped = "activation-policy"; return }
        guard let console = CGSessionCopyCurrentDictionary() as? [String: Any],
              console[kCGSessionOnConsoleKey as String] as? Bool == true,
              console[kCGSessionLoginDoneKey as String] as? Bool == true else { proof.stopped = "not-active-console"; return }
        guard console["CGSSessionScreenIsLocked"] as? Bool != true else { proof.stopped = "screen-locked"; return }
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front > 1, front != getpid() else { proof.stopped = "no-foreground-witness"; return }
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
        proof.cgOwnsVisibleWindow = true
        if proof.axTrusted == true {
            let ownPID = getpid()
            let facts = await Task.detached { () -> [Int32]? in
                let actor = Process(), pipe = Pipe()
                actor.executableURL = URL(fileURLWithPath: args[0]); actor.standardOutput = pipe
                actor.arguments = ["--read-parent", String(ownPID), String(number)] + [quartzFrame.minX, quartzFrame.minY, quartzFrame.width, quartzFrame.height].map { String(Double($0)) }
                do { try actor.run() } catch { return nil }
                let result = pipe.fileHandleForReading.readDataToEndOfFile()
                actor.waitUntilExit()
                return try? JSONDecoder().decode([Int32].self, from: result)
            }.value
            if let facts, facts.count == 4 {
                proof.axStatus = facts[0]; proof.axWindows = Int(facts[1]); proof.axNumberMatches = Int(facts[2]); proof.axFrameMatches = Int(facts[3])
            }
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
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let color = bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB), let data = image.dataProvider?.data else { proof.stopped = "unreadable-image"; return }
            proof.width = image.width; proof.height = image.height
            proof.centerRGB = [color.redComponent, color.greenComponent, color.blueComponent]
            proof.correctColor = color.greenComponent > 0.6 && color.redComponent < 0.3 && color.blueComponent < 0.5
            proof.imageSHA256 = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        } catch {
            let e = error as NSError
            proof.stopped = "capture-\(e.domain)-\(e.code)"
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
