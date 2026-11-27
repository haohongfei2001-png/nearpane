import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

/// Public-API desktop evidence for a disposable GitHub macOS runner only.
/// It neither requests permissions nor creates or changes display modes.
@main @MainActor
struct CloudDesktopProbe {
    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct RestoreState: Codable {
        let displayID: UInt32
        let originalURL: String
        let optionsArchive: Data
        let playerPID: Int32?
        let playerWasHidden: Bool
        let playerBundlePath: String?
        var playerWindow: PlayerWindowState? = nil
    }
    struct PlayerWindowState: Codable {
        let number: Int
        let title: String
        let bounds: [Double]
        let wasMinimized: Bool
        var rect: CGRect { CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }
    }
    static let files = FileManager.default
    static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw ProbeError(message: message) }
    }
    static func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { throw ProbeError(message: "Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func pause(_ seconds: TimeInterval) {
        let until = clock + max(0, seconds)
        while clock < until { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.05, until - clock))) }
    }
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    static func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
    static func mode(_ value: CGDisplayMode) -> [String: Any] {
        ["width": value.width, "height": value.height, "pixelWidth": value.pixelWidth,
         "pixelHeight": value.pixelHeight, "refreshRate": value.refreshRate]
    }
    static func inventory() -> [String: Any] {
        let screens: [[String: Any]] = NSScreen.screens.compactMap { screen in
            guard let id = displayID(screen) else { return nil }
            let modes = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []).map(mode)
            let current: Any
            if let displayMode = CGDisplayCopyDisplayMode(id) { current = mode(displayMode) }
            else { current = NSNull() }
            return ["displayID": id, "name": screen.localizedName, "framePoints": rectangle(screen.frame),
                    "displayBounds": rectangle(CGDisplayBounds(id)), "backingScaleFactor": Double(screen.backingScaleFactor),
                    "isMainDisplay": CGDisplayIsMain(id) != 0,
                    "currentMode": current, "availableModes": modes]
        }
        return ["status": screens.isEmpty ? "BLOCKED" : "RECORDED", "screens": screens,
                "displayModesChanged": false, "virtualDisplaysCreated": false,
                "scaleQualification": "Only the recorded active backing scale is exercised; listed modes are inventory, not tested modes."]
    }
    static func mainScreen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: { displayID($0) == CGMainDisplayID() }) else {
            throw ProbeError(message: "No actual primary WindowServer display is available.")
        }
        return screen
    }
    static func rawOptions(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) })
    }
    static func decodedOptions(_ data: Data) throws -> [String: Any] {
        guard let result = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSColor.self, NSValue.self],
            from: data) as? [String: Any] else { throw ProbeError(message: "Cannot safely decode original desktop options.") }
        return result
    }
    static func windowInfo(_ pid: Int32, windowNumber: Int? = nil) throws -> (CGRect, [[String: Any]], Int) {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for value in windows {
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (value[kCGWindowNumber as String] as? NSNumber)?.intValue, number > 0,
                  windowNumber == nil || number == windowNumber,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= 100, rect.height >= 80 else { continue }
            return (rect, windows, number)
        }
        throw ProbeError(message: "The requested ordinary LyricTile PID/window number has no visible native panel.")
    }
    static func unobscuredPanel(_ pid: Int32, windowNumber: Int, checks: inout [[String: Any]]) throws -> CGRect {
        let (rect, windows, _) = try windowInfo(pid, windowNumber: windowNumber)
        try require(CGDisplayBounds(CGMainDisplayID()).contains(CGPoint(x: rect.midX, y: rect.midY)),
                    "The active panel is not on the primary display; no other display is modified.")
        var check: [String: Any] = ["appPID": pid, "windowNumber": windowNumber, "panelBounds": rectangle(rect),
                                  "observedUptime": clock, "systemWideAXHit": true, "inputPosted": false]
        var covering: [[String: Any]] = []
        defer { check["coveringWindows"] = covering; checks.append(check) }
        for value in windows {
            guard let owner = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != pid,
                  ((value[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) >= 0,
                  ((value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let other = CGRect(dictionaryRepresentation: bounds as CFDictionary), other.intersects(rect) else { continue }
            covering.append(["ownerPID": owner, "owner": value[kCGWindowOwnerName as String] as? String ?? "unknown",
                "windowNumber": value[kCGWindowNumber as String] ?? NSNull(), "layer": value[kCGWindowLayer as String] ?? NSNull(),
                "alpha": value[kCGWindowAlpha as String] ?? NSNull(), "bounds": rectangle(other)])
        }
        // CG rectangles include transparent system surfaces, including Dock's
        // full-display window. Record them; a genuine system-wide AX hit decides.
        let target = try nativeAXWindow(pid, rect: rect)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit)
        check["AXHitResult"] = status.rawValue
        check["point"] = ["x": Double(rect.midX), "y": Double(rect.midY)]
        guard status == .success, let hit else { throw ProbeError(message: "The actual panel has no successful system-wide AX hit.") }
        var hitPID: pid_t = 0
        let pidReadback = AXUIElementGetPid(hit, &hitPID)
        let belongs = pidReadback == .success && hitPID == pid && within(hit, ancestor: target)
        check["hitPID"] = hitPID; check["hitWithinActualTargetWindow"] = belongs
        try require(belongs, "The actual system-wide AX hit belongs to another window; no wallpaper capture was accepted.")
        return rect
    }
    static func playerWindows(_ pid: Int32) -> [(number: Int, rect: CGRect)] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.width >= 100, rect.height >= 80 else { return nil }
            return (number, rect)
        }
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func axBounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = unsafeBitCast(position, to: AXValue.self), s = unsafeBitCast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
              AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func within(_ element: AXUIElement, ancestor: AXUIElement) -> Bool {
        if CFEqual(element, ancestor) { return true }
        if let window = elementAttribute(element, kAXWindowAttribute), CFEqual(window, ancestor) { return true }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let value = current else { return false }
            if CFEqual(value, ancestor) { return true }
            current = elementAttribute(value, kAXParentAttribute)
        }
        return false
    }
    static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
    static func nativeAXWindow(_ pid: Int32, rect: CGRect, title: String? = nil) throws -> AXUIElement {
        try require(AXIsProcessTrusted(), "Existing Accessibility access is unavailable; no permission request was made.")
        // This timeout affects only this helper process, including each window read.
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
        let app = AXUIElementCreateApplication(pid)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        try require(windows.count <= 8, "The target process has too many windows for bounded, unambiguous matching.")
        let matches = windows.filter { window in
            guard let bounds = axBounds(window), sameBounds(bounds, rect) else { return false }
            return title == nil || (attribute(window, kAXTitleAttribute) as? String ?? "") == title
        }
        try require(matches.count == 1, "The actual native window has no unique Accessibility geometry/title match.")
        return matches[0]
    }
    static func exposeDesktop(_ original: inout RestoreState, state: URL, deadline: TimeInterval, report: inout [String: Any]) throws {
        var result: [String: Any] = ["method": "unchanged", "permissionsRequested": false]
        defer { report["playerWindowExposure"] = result }
        guard let pid = original.playerPID else { return }
        guard let player = NSRunningApplication(processIdentifier: pid), !player.isTerminated,
              player.bundleIdentifier == "com.tencent.QQMusicMac",
              player.bundleURL?.resolvingSymlinksInPath().path == original.playerBundlePath else {
            throw ProbeError(message: "The snapshotted temporary QQ process is no longer available.")
        }
        result["playerPID"] = pid; result["hiddenBefore"] = player.isHidden
        if !player.isHidden { result["hideReturned"] = player.hide() }
        let hideUntil = min(deadline, clock + 0.7)
        while clock < hideUntil && (!player.isHidden || !playerWindows(pid).isEmpty) { pause(0.05) }
        result["hiddenAfter"] = player.isHidden
        result["visibleWindowNumbersAfterHide"] = playerWindows(pid).map { $0.number }
        // hide()'s return value is diagnostic only; actual state and CG visibility decide.
        if player.isHidden && playerWindows(pid).isEmpty { result["method"] = "hide-readback"; return }
        let visible = playerWindows(pid)
        try require(clock + 6 < deadline && !original.playerWasHidden && !player.isHidden && visible.count == 1,
                    "No single visible QQ main window is available for bounded minimization.")
        let target = visible[0]
        let window = try nativeAXWindow(pid, rect: target.rect)
        guard let minimized = attribute(window, kAXMinimizedAttribute) as? Bool else {
            throw ProbeError(message: "The actual QQ window has no readable minimized state.")
        }
        try require(!minimized, "QQ reports its visible window already minimized; no ambiguous mutation was made.")
        var settable = DarwinBoolean(false)
        try require(AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success && settable.boolValue,
                    "The actual QQ window does not allow ordinary Accessibility minimization.")
        original.playerWindow = PlayerWindowState(number: target.number, title: attribute(window, kAXTitleAttribute) as? String ?? "",
            bounds: [Double(target.rect.minX), Double(target.rect.minY), Double(target.rect.width), Double(target.rect.height)], wasMinimized: minimized)
        // Persist before changing the window so a bounded external restore can recover it.
        try JSONEncoder().encode(original).write(to: state.appendingPathComponent("restore-state.json"), options: .atomic)
        result["windowNumber"] = target.number; result["bounds"] = rectangle(target.rect); result["wasMinimized"] = minimized
        let changed = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        result["minimizeAXResult"] = changed.rawValue
        let until = min(deadline, clock + 1)
        func disappeared() -> Bool {
            attribute(window, kAXMinimizedAttribute) as? Bool == true && !playerWindows(pid).contains { $0.number == target.number }
        }
        while clock < until && !disappeared() { pause(0.05) }
        result["minimizedReadback"] = attribute(window, kAXMinimizedAttribute) as Any? ?? NSNull()
        result["windowAbsentFromOnScreenList"] = !playerWindows(pid).contains { $0.number == target.number }
        try require(changed == .success && disappeared(), "QQ minimization did not confirm both AX state and actual CG window disappearance.")
        result["method"] = "accessibility-minimize"
    }
    static func prepare(config: URL, state: URL, evidence: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: config)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["desktopPatterns"] as? [String: Any], let width = settings["width"] as? Int,
              let height = settings["height"] as? Int, let patterns = settings["patterns"] as? [[String: Any]] else {
            throw ProbeError(message: "Original desktop pattern fixture configuration is missing.")
        }
        try require((64...4096).contains(width) && (64...4096).contains(height), "Pattern dimensions exceed the CI bound.")
        try require(patterns.compactMap { $0["name"] as? String }.sorted() == ["busy", "dark", "light"], "Expected exactly three named original patterns.")
        var generated: [[String: Any]] = []
        for value in patterns {
            guard let name = value["name"] as? String, let kind = value["kind"] as? String,
                  let colors = value["colors"] as? [[Int]], !colors.isEmpty,
                  colors.allSatisfy({ $0.count == 3 && $0.allSatisfy { (0...255).contains($0) } }),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ProbeError(message: "Invalid original pattern colors or bitmap context.")
            }
            try require(kind == "solid" || kind == "checkerboard", "Unsupported original pattern type.")
            let cell = kind == "solid" ? max(width, height) : max(8, min(256, value["cellSize"] as? Int ?? 32))
            for y in stride(from: 0, to: height, by: cell) {
                for x in stride(from: 0, to: width, by: cell) {
                    let color = colors[(x / cell + y / cell) % colors.count]
                    context.setFillColor(red: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255, blue: CGFloat(color[2]) / 255, alpha: 1)
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cell), height: CGFloat(cell)))
                }
            }
            guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw ProbeError(message: "Original pattern PNG generation failed.")
            }
            let url = state.appendingPathComponent("original-wallpaper-" + name + ".png")
            try png.write(to: url, options: .atomic)
            generated.append(["name": name, "file": url.lastPathComponent, "sha256": sha256(png), "kind": kind])
        }
        let report: [String: Any] = ["status": "PREPARED", "fixtureSHA256": sha256(data), "patterns": generated,
                                    "origin": "Original solid/checkerboard colors generated from Tests/Fixtures/CloudAcceptance.json."]
        try write(inventory(), to: evidence.appendingPathComponent("display-inventory.json"))
        try write(report, to: state.appendingPathComponent("prepared.json"))
        return report
    }
    static func snapshot(state: URL, runner: URL) throws -> RestoreState {
        let screen = try mainScreen()
        guard let original = NSWorkspace.shared.desktopImageURL(for: screen), original.isFileURL,
              files.isReadableFile(atPath: original.path), let options = NSWorkspace.shared.desktopImageOptions(for: screen) else {
            throw ProbeError(message: "Original desktop URL/options are not recoverable; desktop left unchanged.")
        }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: rawOptions(options), requiringSecureCoding: true)
        _ = try decodedOptions(archived)
        let player = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.QQMusicMac").first {
            $0.bundleURL?.resolvingSymlinksInPath().path.hasPrefix(runner.path + "/") == true
        }
        let value = RestoreState(displayID: CGMainDisplayID(), originalURL: original.absoluteString, optionsArchive: archived,
                                 playerPID: player?.processIdentifier, playerWasHidden: player?.isHidden ?? true,
                                 playerBundlePath: player?.bundleURL?.resolvingSymlinksInPath().path)
        try JSONEncoder().encode(value).write(to: state.appendingPathComponent("restore-state.json"), options: .atomic)
        return value
    }
    static func restore(state: URL) -> [String: Any] {
        let file = state.appendingPathComponent("restore-state.json")
        guard files.fileExists(atPath: file.path) else { return ["status": "NOT_NEEDED", "restored": true, "reason": "No mutation snapshot was created."] }
        do {
            let value = try JSONDecoder().decode(RestoreState.self, from: Data(contentsOf: file))
            guard let screen = NSScreen.screens.first(where: { displayID($0) == value.displayID }),
                  let original = URL(string: value.originalURL) else { throw ProbeError(message: "Original display or URL is unavailable for restoration.") }
            let raw = try decodedOptions(value.optionsArchive)
            let options = Dictionary(uniqueKeysWithValues: raw.map { (NSWorkspace.DesktopImageOptionKey(rawValue: $0.key), $0.value) })
            func same() -> Bool {
                NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == original.standardizedFileURL
                    && NSDictionary(dictionary: rawOptions(NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])).isEqual(NSDictionary(dictionary: raw))
            }
            var failures: [String] = []
            do { if !same() { try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options); pause(0.35) } }
            catch { failures.append(error.localizedDescription) }
            var playerRestored = true
            var windowRestored = value.playerWindow == nil
            if let pid = value.playerPID {
                do {
                    guard let player = NSRunningApplication(processIdentifier: pid), !player.isTerminated,
                          player.bundleIdentifier == "com.tencent.QQMusicMac",
                          player.bundleURL?.resolvingSymlinksInPath().path == value.playerBundlePath else {
                        throw ProbeError(message: "The saved QQ process identity is unavailable for restoration.")
                    }
                    if player.isHidden != value.playerWasHidden {
                        if value.playerWasHidden { _ = player.hide() } else { _ = player.unhide() }
                        pause(0.15)
                    }
                    playerRestored = player.isHidden == value.playerWasHidden
                    if let saved = value.playerWindow {
                        try require(saved.bounds.count == 4, "Invalid saved QQ window bounds.")
                        let window = try nativeAXWindow(pid, rect: saved.rect, title: saved.title)
                        if attribute(window, kAXMinimizedAttribute) as? Bool != saved.wasMinimized {
                            try require(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                saved.wasMinimized ? kCFBooleanTrue : kCFBooleanFalse) == .success, "QQ minimized state could not be restored.")
                        }
                        let until = clock + 0.7
                        while clock < until && (attribute(window, kAXMinimizedAttribute) as? Bool != saved.wasMinimized
                            || (!saved.wasMinimized && !value.playerWasHidden && !playerWindows(pid).contains { $0.number == saved.number })) { pause(0.05) }
                        windowRestored = attribute(window, kAXMinimizedAttribute) as? Bool == saved.wasMinimized
                            && (saved.wasMinimized || value.playerWasHidden || playerWindows(pid).contains { $0.number == saved.number })
                    }
                } catch { playerRestored = false; failures.append(error.localizedDescription) }
            }
            let restored = same() && playerRestored && windowRestored
            return ["status": restored ? "RESTORED" : "BLOCKED", "restored": restored,
                    "originalURLReadbackMatched": same(), "playerVisibilityRestored": playerRestored,
                    "playerWindowMinimizedStateRestored": windowRestored, "failures": failures,
                    "permissionsRequested": false, "displayModesChanged": false]
        } catch { return ["status": "BLOCKED", "restored": false, "reason": error.localizedDescription] }
    }
    static func capture(to url: URL, deadline: TimeInterval) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", "1", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let until = min(deadline, clock + 3)
        while process.isRunning && clock < until { pause(0.05) }
        if process.isRunning { process.terminate(); pause(0.2); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let timedOut = process.isRunning
        if timedOut { pause(0.1) }
        guard !process.isRunning, process.terminationStatus == 0,
              let bytes = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: bytes) else {
            throw ProbeError(message: "WindowServer screenshot failed or exceeded its bound; no permission request was made.")
        }
        return ["file": url.lastPathComponent, "sha256": sha256(bytes), "pixelWidth": bitmap.pixelsWide,
                "pixelHeight": bitmap.pixelsHigh, "captureKind": "WindowServer primary-display screenshot"]
    }
    static func run(state: URL, evidence: URL, runner: URL, pid: Int32) -> [String: Any] {
        let start = clock, deadline = start + 15
        var visibilityChecks: [[String: Any]] = []
        var captures: [[String: Any]] = [], report: [String: Any] = [
            "status": "BLOCKED", "scope": "same ordinary QQ-backed LyricTile process on actual desktop wallpapers",
            "appPID": pid, "applicationAppearance": "light", "visualReview": "PENDING",
            "physicalMouseTest": false, "permissionsRequested": false, "displayModesChanged": false, "virtualDisplaysCreated": false]
        do {
            let (_, _, windowNumber) = try windowInfo(pid)
            report["windowNumber"] = windowNumber
            let screen = try mainScreen()
            report["backingScaleFactor"] = Double(screen.backingScaleFactor)
            report["activeDisplayID"] = CGMainDisplayID()
            var original = try snapshot(state: state, runner: runner)
            var originalCapture = try capture(to: evidence.appendingPathComponent("ordinary-app-desktop.png"), deadline: deadline)
            _ = try windowInfo(pid, windowNumber: windowNumber)
            originalCapture["appPID"] = pid; originalCapture["windowNumber"] = windowNumber
            report["originalDesktopCapture"] = originalCapture
            try exposeDesktop(&original, state: state, deadline: deadline, report: &report)
            report["panelBounds"] = rectangle(try unobscuredPanel(pid, windowNumber: windowNumber, checks: &visibilityChecks))
            guard let prepared = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("prepared.json"))) as? [String: Any],
                  let patterns = prepared["patterns"] as? [[String: Any]] else { throw ProbeError(message: "Prepared original wall patterns are unavailable.") }
            report["fixtureSHA256"] = prepared["fixtureSHA256"]
            for pattern in patterns {
                try require(clock + 1 < deadline, "Desktop capture phase reached its bounded time budget.")
                guard let name = pattern["name"] as? String, ["light", "dark", "busy"].contains(name) else { throw ProbeError(message: "Invalid pattern identity.") }
                let input = state.appendingPathComponent("original-wallpaper-" + name + ".png")
                let options: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: false]
                try NSWorkspace.shared.setDesktopImageURL(input, for: screen, options: options)
                pause(0.8)
                let readback = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == input.standardizedFileURL
                try require(readback, "The public desktop API did not read back the requested wallpaper.")
                let rect = try unobscuredPanel(pid, windowNumber: windowNumber, checks: &visibilityChecks)
                var result = try capture(to: evidence.appendingPathComponent("desktop-wallpaper-" + name + ".png"), deadline: deadline)
                _ = try windowInfo(pid, windowNumber: windowNumber)
                result.merge(["name": name, "wallpaperURLReadbackMatched": readback, "inputSHA256": pattern["sha256"] ?? NSNull(),
                              "appPID": pid, "windowNumber": windowNumber, "panelBounds": rectangle(rect), "observedUptime": clock]) { _, new in new }
                captures.append(result)
            }
            report["status"] = "CAPTURED"
        } catch { report["reason"] = error.localizedDescription }
        let restoration = restore(state: state)
        report["restoration"] = restoration
        if restoration["restored"] as? Bool != true { report["status"] = "BLOCKED" }
        report["captures"] = captures; report["panelVisibilityChecks"] = visibilityChecks; report["elapsedSeconds"] = clock - start
        report["qualification"] = "Actual composed screenshots; contrast review is pending. No unexercised display scale, dark-app wallpaper matrix, mouse or commercial-catalog claim."
        return report
    }
    static func main() {
        do {
            let env = ProcessInfo.processInfo.environment
            try require(env["GITHUB_ACTIONS"] == "true", "Only run on the disposable GitHub Actions desktop.")
            guard let temp = env["RUNNER_TEMP"], let workspace = env["GITHUB_WORKSPACE"] else { throw ProbeError(message: "Missing disposable runner paths.") }
            let runner = URL(fileURLWithPath: temp).resolvingSymlinksInPath()
            let state = URL(fileURLWithPath: try argument("--state")).resolvingSymlinksInPath()
            let evidence = URL(fileURLWithPath: try argument("--evidence")).resolvingSymlinksInPath()
            let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath()
            try require(state.path.hasPrefix(runner.path + "/") && evidence.path.hasPrefix(root.path + "/Products/LyricTile/dist/evidence/"),
                        "State/evidence must remain inside the disposable runner and product CI evidence directories.")
            try files.createDirectory(at: state, withIntermediateDirectories: true)
            try files.createDirectory(at: evidence, withIntermediateDirectories: true)
            let command = CommandLine.arguments.dropFirst().first ?? ""
            let result: [String: Any]
            switch command {
            case "prepare": result = try prepare(config: URL(fileURLWithPath: argument("--config")), state: state, evidence: evidence)
            case "run":
                guard let pid = Int32(try argument("--app-pid")), pid > 0 else { throw ProbeError(message: "Invalid ordinary app PID.") }
                result = run(state: state, evidence: evidence, runner: runner, pid: pid)
                try write(result, to: evidence.appendingPathComponent("desktop-wallpaper-report.json"))
            case "restore":
                result = restore(state: state)
                try write(result, to: evidence.appendingPathComponent("desktop-wallpaper-restore.json"))
            default: throw ProbeError(message: "Expected prepare, run or restore.")
            }
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8) ?? "{}")
        } catch {
            let result: [String: Any] = ["status": "BLOCKED", "reason": error.localizedDescription, "permissionsRequested": false]
            print(String(data: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }
}
