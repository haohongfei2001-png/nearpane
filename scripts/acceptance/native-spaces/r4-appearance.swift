// Drive only the unique installed Host's labeled controls. Restore the tool and dimension settings.
import AppKit
import ApplicationServices
private struct Refusal: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}
@MainActor private final class SettingsReview {
    let host: NSRunningApplication
    let app: AXUIElement
    let folder: URL
    let camera: URL
    init(_ folder: URL, _ camera: URL) throws {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.holdsnow.nearpane.alpha")
            .filter { $0.bundleURL?.path == "/Applications/Nearpane.app" }
        guard hosts.count == 1, let installed = hosts.first, AXIsProcessTrusted() else {
            throw Refusal("one installed host and observer AX required")
        }
        host = installed; app = AXUIElementCreateApplication(installed.processIdentifier)
        self.folder = folder; self.camera = camera
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    func attr(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, key as CFString, &result) == .success ? result : nil
    }
    func array(_ item: AXUIElement, _ key: String) -> [AXUIElement] { attr(item,key) as? [AXUIElement] ?? [] }
    func lookup(_ id: String) -> AXUIElement? {
        var items = array(app,kAXWindowsAttribute), n = 0
        while let item = items.popLast(), n < 2000 {
            n += 1
            if attr(item,kAXIdentifierAttribute) as? String == id { return item }
            items += array(item,kAXChildrenAttribute)
        }
        return nil
    }
    func control(_ id: String) async throws -> AXUIElement {
        for _ in 0..<30 {
            if let node = lookup(id) { return node }
            try await Task.sleep(for: .milliseconds(90))
        }
        throw Refusal("control unavailable: " + id)
    }
    func press(_ node: AXUIElement) throws {
        guard attr(node,kAXEnabledAttribute) as? Bool != false, AXUIElementPerformAction(node,kAXPressAction as CFString) == .success else { throw Refusal("control did not accept press") }
    }
    func click(_ id: String) async throws { try press(await control(id)); try await Task.sleep(for: .milliseconds(130)) }
    func openSettings() async throws {
        if standardVisible() && lookup("settings-nav-modules") != nil { return }
        guard let raw = attr(app,"AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let item = array(raw as! AXUIElement,kAXChildrenAttribute).first else { throw Refusal("status item unavailable") }
        _ = AXUIElementSetMessagingTimeout(item, 0.35)
        _ = AXUIElementPerformAction(item,kAXPressAction as CFString)
        for _ in 0..<20 {
            if let menu = array(item,kAXChildrenAttribute).first(where: { attr($0,kAXRoleAttribute) as? String == "AXMenu" }),
               let open = array(menu,kAXChildrenAttribute).first(where: { attr($0,kAXTitleAttribute) as? String == "打开 Nearpane" }) {
                try press(open); _ = try await control("settings-nav-modules"); return
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        _ = AXUIElementPerformAction(item,kAXCancelAction as CFString)
        throw Refusal("installed status menu not available")
    }
    func capture(_ name: String, mode: String = "--desktop-only") throws {
        let process = Process(); process.executableURL = camera; process.arguments = [folder.appendingPathComponent(name).path, mode]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Refusal("screen capture failed") }
    }
    func factorySize() throws -> Bool {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nearpane Alpha Profiles")
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("profile-index.json"))) as? [String: Any]
        guard let active = index?["active"] as? String, UUID(uuidString: active) != nil else { throw Refusal("active profile unavailable") }
        let u = root.appendingPathComponent("generations/" + active + "/Nearpane/host-configuration.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any]
        guard let displays = saved?["displays"] as? [String: [String: Any]] else { throw Refusal("display preferences unavailable") }
        return displays.values.allSatisfy { display in
            let keys = (display["measures"] as? [Any] ?? []).compactMap { $0 as? String }
            return !keys.contains("panelWidth") && !keys.contains("panelHeight")
        }
    }
    func standardVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String:Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == host.processIdentifier &&
                               ($0[kCGWindowLayer as String] as? Int) == 0 }
    }
    func selectedPage() -> String? {
        let pages = ["voiceArchive","screenshotArchive","general","dimensions","windowManagement","windowRules","displays","desktop",
                     "modules","app","voice","tray","diagnostics"]
        return pages.map { "settings-nav-" + $0 }.first { id in
            lookup(id).map { attr($0,kAXSelectedAttribute) as? Bool == true || attr($0,kAXValueAttribute) as? Int == 1 } == true
        }
    }
    func optics(_ values: [Double]) async throws {
        let wasVisible = standardVisible(), front = NSWorkspace.shared.frontmostApplication
        try await openSettings()
        let previous = selectedPage()
        var issue: Error?
        do {
            try await click("settings-nav-dimensions")
            let defaults = try await control("glass-defaults")
            guard attr(defaults,kAXEnabledAttribute) as? Bool == false else { throw Refusal("custom glass settings already in use") }
            for (id,v) in zip(["overall","outer","inner"], values) {
                let slider = try await control("glass-" + id)
                guard AXUIElementSetAttributeValue(slider,kAXValueAttribute as CFString, NSNumber(value:v)) == .success else { throw Refusal("glass slider failed") }
                try await Task.sleep(for: .milliseconds(130))
                guard let read = attr(try await control("glass-" + id),kAXValueAttribute) as? Double, abs(read-v) < 0.1 else { throw Refusal("glass slider readback failed") }
            }
            try capture("preview", mode: "--calibrate")
        } catch { issue = error }
        // Leaving this pane cancels its unsaved live preview.
        try await click("settings-nav-modules")
        if let previous { try? await click(previous) }
        if !wasVisible, let settings = array(app,kAXWindowsAttribute).first(where: { attr($0,kAXSubroleAttribute) as? String == "AXStandardWindow" }),
           let close = attr(settings,kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() { try? press(close as! AXUIElement) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.processIdentifier,
           let front, front != host, !front.isTerminated { _ = front.activate(options: []) }
        if let issue { throw issue }
    }
    func named(_ label: String, containing: Bool = false, role: String? = nil) -> AXUIElement? {
        var items = array(app,kAXWindowsAttribute), n = 0
        while let item = items.popLast(), n < 2400 {
            n += 1
            if role == nil || (attr(item, kAXRoleAttribute) as? String) == role {
                for key in [kAXDescriptionAttribute,kAXTitleAttribute,kAXValueAttribute] {
                    if let text = attr(item,key) as? String, containing ? text.contains(label) : text == label { return item }
                }
            }
            items += array(item,kAXChildrenAttribute)
        }
        return nil
    }

    func pressButton(_ label: String) throws {
        guard let node = named(label, role: kAXButtonRole) else { throw Refusal("button unavailable: " + label) }
        guard attr(node, kAXEnabledAttribute) as? Bool != false else { throw Refusal("button disabled: " + label) }
        if let pos = attr(node, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
           let dim = attr(node, kAXSizeAttribute), CFGetTypeID(dim) == AXValueGetTypeID() {
            var origin = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
               AXValueGetValue(dim as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 {
                let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                var hit: AXUIElement?
                _ = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
                for _ in 0..<5 {
                    guard let item = hit else { break }
                    if CFEqual(item, node), let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                       let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                        down.setIntegerValueField(.mouseEventClickState, value: 1)
                        up.setIntegerValueField(.mouseEventClickState, value: 1)
                        down.post(tap: .cghidEventTap)
                        up.post(tap: .cghidEventTap)
                        return
                    }
                    guard let parent = attr(item, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    hit = (parent as! AXUIElement)
                }
            }
        }
        let status = AXUIElementPerformAction(node, kAXPressAction as CFString)
        guard status == .success else { throw Refusal("AXPress " + label + " returned " + String(status.rawValue)) }
    }

    func calculationEditor() -> AXUIElement? {
        guard let container = named("计算草稿") else { return nil }
        var nodes = [container], editors = [AXUIElement]()
        while let item = nodes.popLast() {
            if attr(item,kAXRoleAttribute) as? String == kAXTextAreaRole { editors.append(item) }
            else { nodes.append(contentsOf: array(item,kAXChildrenAttribute)) }
        }
        return editors.count == 1 ? editors.first : nil
    }

    func checkCalculation() async throws -> [String:Bool] {
        try pressButton("打开计算草稿")
        for _ in 0..<15 where named("返回备忘录", role: kAXButtonRole) == nil {
            try await Task.sleep(for: .milliseconds(90))
        }
        guard named("返回备忘录", role: kAXButtonRole) != nil else { throw Refusal("draft toggle not observed") }
        defer { try? pressButton("返回备忘录") }
        guard let draft = calculationEditor(), attr(draft,kAXValueAttribute) as? String == "" else {
            throw Refusal("empty calculation draft required")
        }
        let expression = "(7-2)*3/2"
        var passed = [String:Bool]()
        defer {
            if let original = calculationEditor(), attr(original,kAXValueAttribute) as? String == expression {
                _ = AXUIElementSetAttributeValue(original,kAXValueAttribute as CFString,"" as CFString)
            }
        }
        guard AXUIElementSetAttributeValue(draft,kAXValueAttribute as CFString,expression as CFString) == .success else { throw Refusal("draft refused text") }
        try await Task.sleep(for: .milliseconds(200))
        try pressButton("计算最后一行")
        try await Task.sleep(for: .milliseconds(200))
        passed["displayedExpectedResult"] = named("7.5") != nil
        try pressButton("取消计算结果")
        try await Task.sleep(for: .milliseconds(130))
        passed["dismissalPreservedExpression"] = named("取消计算结果", role: kAXButtonRole) == nil && calculationEditor().flatMap { attr($0,kAXValueAttribute) as? String } == expression
        return passed
    }

    func run(fileTrial: URL? = nil, tools: Bool = false) async throws {
        let front = NSWorkspace.shared.frontmostApplication
        let defaults = try factorySize()
        let wasVisible = standardVisible()
        try await openSettings()
        let previousPage = selectedPage()
        let memoID = "module-enabled-com.holdsnow.nearpane.memo"
        var memoChanged = false, widthChanged = false, memoMoved = false, samples = [String]()
        var failure: Error?
        var extra = [String:Any]()
        do {
            if tools {
                try await click("settings-nav-voice")
                let options = ["首次开始收音时询问","请在系统设置的「隐私与安全性 → 麦克风」中允许","系统已限制访问","已允许"]
                extra["microphonePermissionFromInstalledVoiceSettings"] = options.first(where: { named($0, containing:true) != nil }) ?? "未读到"
                extra["recognitionLocal"] = named("Apple 本机", containing:true) != nil
            }
            try await click("settings-nav-modules")
            let memo = try await control(memoID)
            guard attr(memo,kAXValueAttribute) as? Int == 0 else { throw Refusal("memo already enabled") }
            try press(memo); memoChanged = true
            try await Task.sleep(for: .milliseconds(500))
            guard attr(try await control(memoID),kAXValueAttribute) as? Int == 1 else { throw Refusal("memo did not enable") }
            try capture("three-tools"); samples.append("three-tools")
            if let fileTrial {
                try await click("module-up-com.holdsnow.nearpane.memo"); memoMoved = true
                try await Task.sleep(for: .milliseconds(450))
                let child = Process(); child.executableURL = fileTrial
                child.arguments = [folder.appendingPathComponent("drag").path]
                try child.run(); child.waitUntilExit()
                guard child.terminationStatus == 0 else { throw Refusal("native file drag did not complete") }
            }
            if tools { extra["calculation"] = try await checkCalculation() }
            if defaults && fileTrial == nil && !tools {
                try await click("settings-nav-dimensions")
                let original = try await control("panel-width-value")
                guard let value = attr(original,kAXValueAttribute) as? String, let initial = Double(value.replacingOccurrences(of: ",", with: ".")),
                      initial > 12, initial < 26 else { throw Refusal("expected untouched percentage width") }
                for (name, percent) in [("narrow",12.5),("wide",25.0)] {
                    let slider = try await control("panel-width-slider")
                    let set = AXUIElementSetAttributeValue(slider,kAXValueAttribute as CFString, NSNumber(value:percent))
                    guard set == .success else { throw Refusal("width slider refused input") }
                    try await Task.sleep(for: .milliseconds(160))
                    try await click("panel-size-apply"); widthChanged = true
                    try await Task.sleep(for: .milliseconds(350))
                    try capture(name); samples.append(name)
                }
            }
        } catch { failure = error }
        var restored = true
        if widthChanged {
            do { try await click("settings-nav-dimensions"); try await click("panel-size-defaults"); try await click("panel-size-apply"); restored = try factorySize() }
            catch { restored = false }
        }
        if memoMoved {
            do { try await click("settings-nav-modules"); try await click("module-down-com.holdsnow.nearpane.memo") }
            catch { restored = false }
        }
        if memoChanged {
            do { try await click("settings-nav-modules"); let node = try await control(memoID)
                if attr(node,kAXValueAttribute) as? Int == 1 { try press(node) }
                try await Task.sleep(for: .milliseconds(180))
                restored = restored && (lookup(memoID).flatMap { attr($0,kAXValueAttribute) as? Int } == 0)
            } catch { restored = false }
        }
        if let previousPage { try? await click(previousPage) }
        if !wasVisible, let settings = array(app,kAXWindowsAttribute).first(where: { attr($0,kAXSubroleAttribute) as? String == "AXStandardWindow" }),
           let close = attr(settings,kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() { try? press(close as! AXUIElement) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.processIdentifier,
           let front, front != host, !front.isTerminated { _ = front.activate(options: []) }
        let report: [String:Any] = ["captured":samples, "configurationRestored":restored, "widthInitiallyFactory":defaults, "previousSettingsVisibilityPreserved":wasVisible == standardVisible(), "additional":extra, "issue":failure?.localizedDescription ?? ""]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"))
        if let failure { throw failure }
        guard restored else { throw Refusal("configuration restoration unconfirmed") }
    }
}
@main struct Entry {
    @MainActor static func main() async {
        do {
        let args = Array(CommandLine.arguments.dropFirst())
        guard [2,3,5].contains(args.count) else { throw Refusal("output directory and compiled wallpaper observer required") }
        let review = try SettingsReview(URL(fileURLWithPath:args[0]),URL(fileURLWithPath:args[1]))
        if args.count == 3 && args[2] == "--tools" { try await review.run(tools:true) }
        else if args.count == 3 { try await review.run(fileTrial: URL(fileURLWithPath: args[2])) }
        else if args.count == 2 { try await review.run() } else { try await review.optics(args.suffix(3).compactMap(Double.init)) }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(2) }
    }
}
