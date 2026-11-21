import AppKit
import Foundation

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted(),
      let app = NSRunningApplication(processIdentifier: pid),
      app.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app", app.bundleIdentifier == "com.holdsnow.nearpane.alpha" else { exit(2) }
let installed = AXUIElementCreateApplication(pid)
let windows = attr(installed, kAXWindowsAttribute) as? [AXUIElement] ?? []
let known = ["voice-capture-toggle", "tray-camera-entry", "tray-file-drop", "desktop-reserved-region"]
var counts = Dictionary(uniqueKeysWithValues: known.map { ($0, 0) })
var nativeCards = 0, splitMembers = 0
var seen = Set<AXUIElement>()
func read(_ el: AXUIElement, _ depth: Int) {
    guard depth < 40, seen.count < 4000, seen.insert(el).inserted else { return }
    if let id = attr(el, kAXIdentifierAttribute) as? String {
        if counts[id] != nil { counts[id, default: 0] += 1 }
        if id.hasPrefix("native-space-window:") || id.hasPrefix("current-desktop-window:") { nativeCards += 1 }
        if id.hasPrefix("split-view-member:") { splitMembers += 1 }
    }
    for child in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] { read(child, depth + 1) }
}
var toolBounds: [CGRect] = []
for window in windows {
    let voice = counts["voice-capture-toggle"] ?? 0, tray = counts["tray-camera-entry"] ?? 0
    read(window, 0)
    guard counts["voice-capture-toggle"] != voice && counts["tray-camera-entry"] != tray,
          let p = attr(window, kAXPositionAttribute), let z = attr(window, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(z) == AXValueGetTypeID() else { continue }
    var origin = CGPoint.zero, size = CGSize.zero
    if AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(z as! AXValue, .cgSize, &size) {
        toolBounds.append(CGRect(origin: origin, size: size))
    }
}
let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
let frames = rows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.compactMap { row -> [String:Int]? in
    guard let b = row[kCGWindowBounds as String] as? [String:NSNumber],
          let w = b["Width"], let h = b["Height"] else { return nil }
    return ["width": w.intValue, "height": h.intValue]
}
let visibleToolPanels = toolBounds.filter { expected in
    rows.filter { row in
        guard (row[kCGWindowOwnerPID as String] as? Int32) == pid,
              let b = row[kCGWindowBounds as String] as? [String:NSNumber],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return false }
        let box = CGRect(x:x.doubleValue, y:y.doubleValue, width:w.doubleValue, height:h.doubleValue)
        return abs(box.minX-expected.minX) <= 1 && abs(box.minY-expected.minY) <= 1 &&
            abs(box.width-expected.width) <= 1 && abs(box.height-expected.height) <= 1
    }.count == 1
}.map { ["width":Int($0.width.rounded()), "height":Int($0.height.rounded())] }
let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
let status: [String:Any] = ["stageManager": stage as? Bool ?? false, "observerAX": true, "toolAndRegionCounts": counts,
    "boundVisibleToolPanels": visibleToolPanels, "nativeCards": nativeCards, "splitMembers": splitMembers, "surfaceSizes":frames, "visibleScreenHeights":NSScreen.screens.map { Double($0.visibleFrame.height) }]
print(String(decoding: try JSONSerialization.data(withJSONObject: status, options: .sortedKeys), as: UTF8.self))
