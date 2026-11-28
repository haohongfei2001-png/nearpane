// Disposable CI only. Presses an observed, narrowly identified native control
// through existing Accessibility access; never requests or modifies AX access.
import AppKit
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"], !temporary.isEmpty,
      let output = argument("--output"), let mode = argument("--mode"), ["music", "qqMusic", "inspect"].contains(mode)
else { fputs("Only disposable GitHub Actions with RUNNER_TEMP is supported.\n", stderr); exit(2) }
let duration = min(180, max(1, Double(argument("--seconds") ?? "35") ?? 35))
let reportURL = URL(fileURLWithPath: output)
let trusted = AXIsProcessTrusted()
var report: [String: Any] = ["mode": mode, "accessibilityAlreadyTrusted": trusted,
    "accessibilityRequested": false, "TCCDatabaseModified": false,
    "inputMethod": "AXPress on a freshly inspected native accessibility element",
    "coordinateClicks": false, "accountUsed": false, "protocolsAccepted": false,
    "status": trusted ? "OBSERVING" : "BLOCKED", "actions": [], "windows": []]
func persist() {
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: reportURL, options: .atomic)
    }
}
if !trusted {
    report["reason"] = "Existing Accessibility access is unavailable; no permission request or input was made."
    persist(); exit(0)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func supportsPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    return AXUIElementCopyActionNames(element, &names) == .success
        && ((names as? [String]) ?? []).contains(kAXPressAction)
}
func normalized(_ value: String) -> String {
    value.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        .replacingOccurrences(of: "’", with: "'").lowercased()
}
struct Node {
    let element: AXUIElement
    let role: String
    let labels: [String]
    let enabled: Bool
}
func inspect(_ root: AXUIElement) -> [Node] {
    var nodes: [Node] = []
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard depth < 18, nodes.count < 400 else { return }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
            .map { string(element, $0) }.filter { !$0.isEmpty }
        let enabled = (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
        nodes.append(Node(element: element, role: string(element, kAXRoleAttribute), labels: labels, enabled: enabled))
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(100) {
            visit(child, depth + 1)
        }
    }
    visit(root, 0); return nodes
}
func eligibleAction(_ nodes: [Node], bundle: String) -> String? {
    let text = normalized(nodes.flatMap(\.labels).joined(separator: "\n"))
    if mode == "music", bundle.hasPrefix("com.apple."), text.contains("wants access to control \"music\""),
       (text.contains("\"hosted-compute-agent\"") || text.contains("\"lyrictile\"") || text.contains("\"nearpane film v2\"")),
       text.contains("allowing control will provide access to documents and data in") {
        return "Allow"
    }
    if mode == "music", bundle == "com.apple.Music",
       (text.contains("welcome to music") || text.contains("welcome to apple music")),
       text.contains("start listening"), !text.contains("agree"), !text.contains("terms and conditions") {
        return "Start Listening"
    }
    if mode == "music", bundle == "com.apple.Music",
       text.contains("hear about new music first"),
       text.contains("get notified about new music"), text.contains("not now") {
        return "Not Now"
    }
    if mode == "music", bundle == "com.holdsnow.lyrictile",
       let ready = argument("--welcome-ready"), FileManager.default.fileExists(atPath: ready),
       text.contains("lyrics, right beside you."), text.contains("get started") {
        return "Get started"
    }
    if mode == "qqMusic", bundle.hasPrefix("com.apple."), text.contains("allow \"qq音乐\" to access your"),
       text.contains("media library in apple music") {
        return "Don't Allow"
    }
    return nil
}
let deadline = Date().addingTimeInterval(duration)
var actionRecords: [[String: Any]] = []
var recordedWindows: [[String: Any]] = []
var seenWindows = Set<String>()
var pressedKinds = Set<String>()
persist()
while Date() < deadline {
    for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
        let bundle = app.bundleIdentifier ?? ""
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows.prefix(12) {
            let nodes = inspect(window)
            let labels = nodes.flatMap(\.labels)
            let text = String(labels.joined(separator: "\n").prefix(12_000))
            let windowKey = "\(app.processIdentifier)|\(text)"
            if seenWindows.insert(windowKey).inserted, recordedWindows.count < 40 {
                recordedWindows.append(["pid": app.processIdentifier, "bundleID": bundle,
                    "application": app.localizedName ?? "", "text": text,
                    "buttons": nodes.filter { $0.role == kAXButtonRole }.map {
                        ["labels": $0.labels, "enabled": $0.enabled] as [String: Any]
                    }])
                report["windows"] = recordedWindows; persist()
            }
            guard let label = eligibleAction(nodes, bundle: bundle),
                  !pressedKinds.contains(label), actionRecords.count < 4 else { continue }
            // Re-read immediately before pressing; a stale screenshot or a
            // guessed button position is never used as an input target.
            let fresh = inspect(window)
            guard eligibleAction(fresh, bundle: bundle) == label else { continue }
            // Music exposes its observed "Not Now" control as a link/text
            // control on this OS. Require its real AXPress action instead of
            // assuming every native actionable control has AXButton role.
            let buttons = fresh.filter { $0.enabled
                && $0.labels.contains(where: { normalized($0) == normalized(label) })
                && supportsPress($0.element) }
            guard buttons.count == 1 else { continue }
            let result = AXUIElementPerformAction(buttons[0].element, kAXPressAction as CFString)
            actionRecords.append(["pid": app.processIdentifier, "bundleID": bundle,
                "button": label, "AXResult": result.rawValue,
                "freshWindowText": String(fresh.flatMap(\.labels).joined(separator: "\n").prefix(12_000)),
                "timestamp": ISO8601DateFormatter().string(from: Date())])
            if result == .success { pressedKinds.insert(label) }
            report["actions"] = actionRecords; persist()
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}
report["status"] = actionRecords.isEmpty ? "NO_ALLOWED_CONTROL_OBSERVED" : "COMPLETED"
persist()
