import AppKit
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
    static func unobscuredPanel(_ pid: Int32, windowNumber: Int) throws -> CGRect {
        let (rect, windows, _) = try windowInfo(pid, windowNumber: windowNumber)
        try require(CGDisplayBounds(CGMainDisplayID()).contains(CGPoint(x: rect.midX, y: rect.midY)),
                    "The active panel is not on the primary display; no other display is modified.")
        for value in windows {
            guard let owner = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != pid,
                  ((value[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) >= 0,
                  ((value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let other = CGRect(dictionaryRepresentation: bounds as CFDictionary), other.intersects(rect) else { continue }
            throw ProbeError(message: "Another visible window covers the panel or its desktop backdrop: " + (value[kCGWindowOwnerName as String] as? String ?? "unknown"))
        }
        return rect
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
                                 playerPID: player?.processIdentifier, playerWasHidden: player?.isHidden ?? true)
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
            if !same() { try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: options); pause(0.35) }
            var playerRestored = true
            if let pid = value.playerPID, let player = NSRunningApplication(processIdentifier: pid), !value.playerWasHidden {
                if player.isHidden { _ = player.unhide(); pause(0.15) }
                playerRestored = !player.isHidden
            }
            let restored = same() && playerRestored
            return ["status": restored ? "RESTORED" : "BLOCKED", "restored": restored,
                    "originalURLReadbackMatched": same(), "playerVisibilityRestored": playerRestored,
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
            let original = try snapshot(state: state, runner: runner)
            var originalCapture = try capture(to: evidence.appendingPathComponent("ordinary-app-desktop.png"), deadline: deadline)
            _ = try windowInfo(pid, windowNumber: windowNumber)
            originalCapture["appPID"] = pid; originalCapture["windowNumber"] = windowNumber
            report["originalDesktopCapture"] = originalCapture
            if let playerPID = original.playerPID, let player = NSRunningApplication(processIdentifier: playerPID), !original.playerWasHidden {
                try require(player.hide(), "The temporary QQ window could not be hidden to expose the actual desktop backdrop.")
                pause(0.35)
            }
            report["panelBounds"] = rectangle(try unobscuredPanel(pid, windowNumber: windowNumber))
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
                let rect = try unobscuredPanel(pid, windowNumber: windowNumber)
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
        report["captures"] = captures; report["elapsedSeconds"] = clock - start
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
