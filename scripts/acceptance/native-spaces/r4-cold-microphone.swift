// Operate only the production voice control of the exact installed process supplied by the profile owner.
import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio

private struct Refusal: LocalizedError {
    var errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
    return value
}

private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size), result: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
    return result
}

private func transport(_ selector: AudioObjectPropertySelector) throws -> String {
    guard let device = scalar(AudioObjectID(kAudioObjectSystemObject), selector), device != kAudioObjectUnknown,
          let type = scalar(device, kAudioDevicePropertyTransportType),
          [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
           kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt,
           kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
           kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort].contains(type) else {
        throw Refusal("The selected physical input or playback route could not be confirmed")
    }
    return withUnsafeBytes(of: type.bigEndian) { String(decoding: $0, as: UTF8.self) }
}

@MainActor private final class Trial {
    let host: NSRunningApplication
    let product: AXUIElement
    let result: URL
    var events = [[String: Any]]()
    let start = ProcessInfo.processInfo.systemUptime
    var receipt: [String: Any] = [:]
    var started = false

    init(pid: pid_t, result: URL) throws {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              app.bundleURL?.path == "/Applications/Nearpane.app",
              app.executableURL?.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" else {
            throw Refusal("Installed process or observer Accessibility permission is unavailable")
        }
        host = app
        product = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(product, 0.35)
        self.result = result
    }

    func event(_ name: String) {
        events.append(["kind": name, "offsetSeconds": ProcessInfo.processInfo.systemUptime - start])
    }

    private let voiceID = "voice-capture-toggle"
    private let openID = "nearpane-open-panel"
    private var controls = [String: Set<AXUIElement>]()
    private var diagnostics: [String: Any] = [:]
    private var openedFolded = false
    private var mayCompareButtonLabels = false
    // Report only fixed strings present in the product or AppKit. Unknown titles,
    // values, document names and tab identifiers never enter inventory receipts.
    private let staticIDs: Set<String> = [
        "desktop-reserved-region", "voice-capture-toggle", "nearpane-open-panel", "nearpane-close-panel",
        "nearpane-alpha-help", "nearpane-module-close", "window-access-done", "window-access-guide",
        "window-access-allow-focus", "window-access-allow-pictures", "window-roster-unconfirmed",
        "tray-content", "tray-camera-entry", "tray-file-drop", "voice-archive-search",
        "settings-installed-version", "settings-quit-nearpane", "settings-menu-bar-icon", "np.profile.quit",
        "np.fullscreen.move", "np.fullscreen.close", "np.fullscreen.open.voice", "np.fullscreen.open.capture",
        "np.fullscreen.capture", "np.fullscreen.voice", "np.update.status", "np.services.quit"
    ]
    private let staticLabels: Set<String> = [
        "Nearpane", "Nearpane 设置", "Nearpane Settings", "设置", "语音模块暂不可用", "麦克风不可用",
        "打开麦克风权限设置", "展开 Nearpane", "收起 Nearpane", "开始或恢复收音", "暂停收音",
        "打开语音工具", "打开截图工具", "收起浮层", "允许", "不允许", "Allow", "Don’t Allow", "OK",
        "好", "确定", "取消", "Cancel", "退出 Nearpane"
    ]
    private var lastScan = -Double.infinity

    // A nonactivating borderless panel can be absent from AXWindows even when on screen.
    // Hit-test only the installed app's own on-screen frames; never request another app's text.
    func scan() {
        var nodes = attribute(product, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let listed = nodes.count
        nodes.append(product)
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownedRows = rows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == host.processIdentifier }
        let frames = ownedRows.compactMap { row -> CGRect? in
            guard row[kCGWindowOwnerPID as String] as? pid_t == host.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: bounds), f.width >= 20, f.height >= 20 else { return nil }
            return f
        }
        var hitWindows = Set<AXUIElement>()
        for frame in frames {
            for y in [0.20, 0.50, 0.68] {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(product, Float(frame.midX), Float(frame.minY + y * frame.height), &hit) == .success,
                      var element = hit else { continue }
                for _ in 0..<24 {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(element, &pid) == .success, pid == host.processIdentifier else { break }
                    if attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
                        hitWindows.insert(element)
                        break
                    }
                    guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    element = parent as! AXUIElement
                }
            }
        }
        nodes.append(contentsOf: hitWindows)
        lastScan = ProcessInfo.processInfo.systemUptime
        var found = [String: Set<AXUIElement>](), visited = Set<AXUIElement>(), regions = 0
        var ids = [String: Int](), roles = [String: Int](), labels = Set<String>()
        let systemRoles = [kAXApplicationRole, kAXWindowRole, kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole,
                           kAXStaticTextRole, kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, kAXImageRole,
                           kAXGroupRole, kAXTabGroupRole, kAXSplitGroupRole, kAXScrollAreaRole, kAXToolbarRole,
                           kAXTableRole, kAXRowRole, kAXColumnRole, kAXCheckBoxRole, kAXRadioButtonRole,
                           kAXPopUpButtonRole, kAXSheetRole, kAXSystemDialogSubrole, "AXUnknown"]
        let diagnosticRoles = Set(systemRoles)
        while let node = nodes.popLast(), visited.count < 4000 {
            guard visited.insert(node).inserted else { continue }
            let role = attribute(node, kAXRoleAttribute) as? String
            let id = attribute(node, kAXIdentifierAttribute) as? String ?? ""
            if let role { roles[diagnosticRoles.contains(role) ? role : "other", default: 0] += 1 }
            if staticIDs.contains(id) {
                ids[id, default: 0] += 1
            } else if id.hasPrefix("settings-nav-") { ids["settings-nav-*", default: 0] += 1 }
            else if id.hasPrefix("np.fullscreen.") { ids["np.fullscreen.*", default: 0] += 1 }
            else if !id.isEmpty { ids["other", default: 0] += 1 }
            if mayCompareButtonLabels, role == kAXButtonRole || role == kAXWindowRole {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    if let label = attribute(node, key) as? String, staticLabels.contains(label) { labels.insert(label) }
                }
            }
            if id == "desktop-reserved-region" { regions += 1; continue }
            if id.hasPrefix("native-space-window:") || id.hasPrefix("current-desktop-window:") { continue }
            if [voiceID, openID, "window-access-done", "window-access-guide"].contains(id) {
                found[id, default: []].insert(node)
            } else if mayCompareButtonLabels, id.isEmpty, role == kAXButtonRole {
                // SwiftUI sometimes bridges the label but omits the view identifier.
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(node, $0) as? String }
                if labels.contains("开始或恢复收音") || labels.contains("暂停收音") { found[voiceID, default: []].insert(node) }
                if labels.contains("展开 Nearpane") { found[openID, default: []].insert(node) }
            }
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, kAXImageRole, kAXMenuBarRole, kAXMenuRole, "AXWebArea"].contains(role) { continue }
            nodes.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        controls = found
        let windows: [[String: Int]] = ownedRows.compactMap { row in
            guard let b = row[kCGWindowBounds as String] as? NSDictionary, let f = CGRect(dictionaryRepresentation: b) else { return nil }
            return ["layer": row[kCGWindowLayer as String] as? Int ?? -1, "x": Int(f.minX), "y": Int(f.minY),
                    "width": Int(f.width), "height": Int(f.height)]
        }
        diagnostics = ["ownedWindowGeometry": windows, "staticIDs": ids, "roles": roles, "staticLabels": labels.sorted(),
                       "axListedWindows": listed, "ownedOnScreenWindows": frames.count, "hitTestedAXWindows": hitWindows.count,
                       "visitedElements": visited.count, "desktopRegions": regions, "knownControls": found.mapValues(\.count)]
        if let button = unique(voiceID) {
            let info = details(button)
            diagnostics["voice"] = ["label": info.label, "state": info.value, "enabled": info.enabled,
                                    "pressAction": canPress(button)]
        }
    }

    // Independent WindowServer metadata identifies an ordinary desktop. On the
    // shared-Spaces configuration there is only one scope for all displays.
    private func primarySpace() -> [String: Any]? {
        guard NPReadOnlySpacesOpen() == 1, let scopes = NPReadInventory() as? [[String: Any]],
              let primary = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { return nil }
        let mainID = CFUUIDCreateString(nil, primary) as String
        let matches = scopes.count == 1 ? scopes : scopes.filter { ($0["Display Identifier"] as? String)?.uppercased() == mainID.uppercased() }
        guard matches.count == 1, let scope = matches.first, let current = scope["Current Space"] as? [String: Any],
              let id = current["id64"] as? NSNumber, let records = scope["Spaces"] as? [[String: Any]] else { return nil }
        let found = records.filter { $0["id64"] as? NSNumber == id }
        guard found.count == 1, let type = found[0]["type"] as? Int,
              let uuid = (found[0]["uuid"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return ["id": id, "uuid": uuid.uuidString, "type": type]
    }

    func inventory() -> [String: Any] {
        scan()
        diagnostics["primarySpace"] = primarySpace() as Any? ?? NSNull()
        return diagnostics
    }

    private func canPress(_ node: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(node, &names) == .success && (names as? [String])?.contains(kAXPressAction) == true
    }

    private func unique(_ id: String) -> AXUIElement? {
        var available = (controls[id] ?? []).filter { canPress($0) }
        if available.count > 1 {
            let main = CGDisplayBounds(CGMainDisplayID())
            available = available.filter { node in
                guard let point = attribute(node, kAXPositionAttribute), CFGetTypeID(point) == AXValueGetTypeID() else { return false }
                var origin = CGPoint.zero
                return AXValueGetValue(point as! AXValue, .cgPoint, &origin) && main.contains(origin)
            }
        }
        return available.count == 1 ? available.first : nil
    }

    private func details(_ button: AXUIElement) -> (node: AXUIElement, label: String, value: String, enabled: Bool) {
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(button, $0) as? String }
        let label = labels.first(where: { ["开始或恢复收音", "暂停收音"].contains($0) }) ?? "unknown"
        let values = [kAXValueAttribute, kAXValueDescriptionAttribute].compactMap { attribute(button, $0) as? String }
        let state = values.first(where: { ["暂停", "待命", "正在识别"].contains($0) }) ?? "unavailable"
        return (button, label, state, attribute(button, kAXEnabledAttribute) as? Bool == true)
    }

    func control() throws -> (node: AXUIElement, label: String, value: String, enabled: Bool) {
        guard !host.isTerminated else { throw Refusal("The isolated Host exited") }
        if ProcessInfo.processInfo.systemUptime - lastScan < 0.24, let button = unique(voiceID) {
            let current = details(button)
            if current.label != "unknown" { return current }
        }
        scan()
        guard let button = unique(voiceID) else { throw Refusal("No unique production sidebar voice button") }
        return details(button)
    }

    func revealPausedControl() async throws {
        try await wait(10) {
            self.scan()
            if let button = self.unique(self.voiceID) {
                let state = self.details(button)
                // The compact start button itself is conclusive when AppKit omits AXValue.
                return state.label == "开始或恢复收音" && state.enabled && ["暂停", "unavailable"].contains(state.value)
            }
            if !self.openedFolded, let button = self.unique(self.openID),
               attribute(button, kAXEnabledAttribute) as? Bool == true {
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
                self.openedFolded = true
                self.receipt["expandedFoldedSidebar"] = true
            }
            return false
        }
    }

    func press(_ label: String) throws {
        let button = try control()
        guard button.label == label, button.enabled,
              AXUIElementPerformAction(button.node, kAXPressAction as CFString) == .success else {
            throw Refusal("Voice button did not accept " + label)
        }
    }

    func wait(_ seconds: Double, _ condition: () throws -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            guard !host.isTerminated else { throw Refusal("The isolated Host exited") }
            if (try? condition()) == true { return }
            try await Task.sleep(for: .milliseconds(40))
        } while ProcessInfo.processInfo.systemUptime < until
        throw Refusal("Timed out waiting for the installed voice control")
    }

    func verifyIsolatedOwner() throws {
        let env = ProcessInfo.processInfo.environment
        guard let homePath = env["NEARPANE_TEST_HOME"], let generationPath = env["NEARPANE_TEST_GENERATION"] else {
            throw Refusal("Missing isolated profile owner")
        }
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let generation = URL(fileURLWithPath: generationPath, isDirectory: true)
        let container = home.deletingLastPathComponent()
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let root = home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles", isDirectory: true)
        guard container.deletingLastPathComponent().path == caches.path,
              container.lastPathComponent.hasPrefix("nearpane-native-acceptance."),
              home.resolvingSymlinksInPath().path == homePath,
              generation.resolvingSymlinksInPath().path == generationPath,
              generation.deletingLastPathComponent().path == root.appendingPathComponent("generations").path,
              UUID(uuidString: generation.lastPathComponent) != nil else { throw Refusal("Unexpected test data location") }
        let probe = Process(), pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-a", "-p", String(host.processIdentifier), "-t", root.appendingPathComponent("writer.lock").path]
        probe.standardOutput = pipe
        try probe.run()
        let read = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0, String(decoding: read, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == String(host.processIdentifier) else {
            throw Refusal("Installed Host does not own this isolated profile")
        }
        mayCompareButtonLabels = true
    }

    func run(_ stimulus: URL) async throws {
        try verifyIsolatedOwner()
        guard let initialSpace = primarySpace() else { throw Refusal("WindowServer did not identify the current Space") }
        receipt["spaceBeforeStart"] = initialSpace
        guard initialSpace["type"] as? Int == 0 else {
            throw Refusal("The production sidebar requires an ordinary desktop; the current Space is fullscreen")
        }
        receipt["physicalInputTransport"] = try transport(kAudioHardwarePropertyDefaultInputDevice)
        receipt["physicalOutputTransport"] = try transport(kAudioHardwarePropertyDefaultOutputDevice)
        let player = try AVAudioPlayer(contentsOf: stimulus)
        player.volume = 0.65
        guard player.duration > 0, player.duration <= 8, player.prepareToPlay() else { throw Refusal("Cannot prepare the local short phrase") }
        receipt["stimulusSeconds"] = player.duration
        receipt["playbackVolume"] = player.volume
        defer { player.stop() }
        try await revealPausedControl()
        guard let check = primarySpace(), NSDictionary(dictionary: initialSpace).isEqual(to: check) else {
            throw Refusal("The current Space changed before pressing the production sidebar")
        }
        try press("开始或恢复收音")
        started = true
        event("startPressed")
        try await wait(12) {
            let button = try control()
            return button.label == "暂停收音" && ["待命", "正在识别"].contains(button.value)
        }
        event("captureReady")
        guard player.play() else { throw Refusal("Short phrase playback failed") }
        event("stimulusStarted")
        let timeout = ProcessInfo.processInfo.systemUptime + player.duration + 1
        while player.isPlaying {
            guard ProcessInfo.processInfo.systemUptime < timeout else { throw Refusal("Short phrase playback did not finish") }
            try await Task.sleep(for: .milliseconds(40))
        }
        event("stimulusFinished")
        // The file may end immediately after a consonant. Allow the hardware callback
        // and resampler to enqueue their tail, then let normal Pause drain the worker.
        try await Task.sleep(for: .milliseconds(650))
        try press("暂停收音")
        event("pausePressed")
        try await wait(9) {
            let button = try self.control()
            return button.label == "开始或恢复收音" && ["暂停", "unavailable"].contains(button.value) && button.enabled
        }
        started = false
        event("pauseObserved")
        guard let after = primarySpace(), NSDictionary(dictionary: initialSpace).isEqual(to: after) else {
            throw Refusal("The controlled Space changed during the utterance")
        }
        receipt["spaceAfterPause"] = after
    }

    func save(issue: String?) throws {
        if let issue {
            receipt["issue"] = issue
            receipt["lastSidebarInventory"] = inventory()
        }
        receipt["events"] = events
        receipt["pid"] = host.processIdentifier
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: result, options: .atomic)
    }
}

@main struct Entry {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 2, args[0] == "--inventory", let pid = pid_t(args[1]) {
                let trial = try Trial(pid: pid, result: URL(fileURLWithPath: "/dev/null"))
                try? trial.verifyIsolatedOwner() // Beyond fixed identifiers, label fallback is restricted to a verified empty test profile.
                let data = try JSONSerialization.data(withJSONObject: trial.inventory(), options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            guard args.count == 3, let pid = pid_t(args[0]) else { throw Refusal("Expected installed PID, fixture WAV and receipt path") }
            let trial = try Trial(pid: pid, result: URL(fileURLWithPath: args[2]))
            do {
                try await trial.run(URL(fileURLWithPath: args[1]))
                try trial.save(issue: nil)
            } catch {
                if trial.started, (try? trial.control().label) == "暂停收音" {
                    try? trial.press("暂停收音")
                }
                try trial.save(issue: error.localizedDescription)
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(2)
        }
    }
}
