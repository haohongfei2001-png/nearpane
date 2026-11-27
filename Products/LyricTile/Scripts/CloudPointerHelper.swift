// Disposable macOS CI only. Derives every input point from current native
// window/Accessibility geometry; never requests permissions or uses AXPress.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct PointerRequest: Decodable {
    let requestID: String
    let sequence: Int
    let action: String
    let pid: Int32
    let windowNumber: UInt32
}
struct PointerFailure: Error { let reason: String }
func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw PointerFailure(reason: reason) }
}
func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}
let files = FileManager.default
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"], !temporary.isEmpty,
      files.fileExists(atPath: temporary), let directoryPath = argument("--directory") else {
    fputs("Only disposable GitHub Actions with RUNNER_TEMP is supported.\n", stderr); exit(2)
}
let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
let reportURL = directory.appendingPathComponent("native-pointer.json")
let requestURL = directory.appendingPathComponent("pointer-request.json")
let stopURL = directory.appendingPathComponent("pointer-stop")
let requestedSeconds = Double(argument("--seconds") ?? "120") ?? 120
let duration = requestedSeconds.isFinite ? min(180, max(1, requestedSeconds)) : 120
let trusted = AXIsProcessTrusted()
let postAllowed = CGPreflightPostEventAccess()
var report: [String: Any] = [
    "available": trusted && postAllowed, "accessibilityAlreadyTrusted": trusted,
    "postEventAccessAlreadyGranted": postAllowed, "accessibilityRequested": false,
    "postEventAccessRequested": false, "TCCDatabaseModified": false,
    "inputMethod": "CGEvent mouse movement and left-button events at freshly observed native geometry",
    "scope": "disposable CI ordinary LyricTile window only", "accountUsed": false,
    "status": trusted && postAllowed ? "OBSERVING" : "BLOCKED", "actions": []
]
func persist() {
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: reportURL, options: .atomic)
    }
}
persist()
if !trusted || !postAllowed {
    report["reason"] = "Existing Accessibility or event-posting access is unavailable; no permission request or input was made."
    persist(); exit(0)
}
func rectangle(_ value: CGRect) -> [String: Double] {
    ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
}
func point(_ value: CGPoint) -> [String: Double] { ["x": Double(value.x), "y": Double(value.y)] }
func valid(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
        && rect.width > 0 && rect.height > 0 && rect.width <= 16_384 && rect.height <= 16_384
}
struct NativeWindow {
    let number: UInt32
    let pid: Int32
    let bounds: CGRect
}
func onScreenWindows() -> [NativeWindow] {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    // Quartz returns these windows in front-to-back order.
    return rows.compactMap { row in
        guard let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
              let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), valid(bounds) else { return nil }
        return NativeWindow(number: number, pid: pid, bounds: bounds)
    }
}
func targetWindow(_ request: PointerRequest) throws -> NativeWindow {
    try require(request.pid > 0 && request.pid != getpid(), "Invalid target process.")
    guard let app = NSRunningApplication(processIdentifier: request.pid), !app.isTerminated,
          app.bundleIdentifier == "com.holdsnow.lyrictile" else {
        throw PointerFailure(reason: "Target PID is not the currently running ordinary LyricTile app.")
    }
    let matches = onScreenWindows().filter { $0.pid == request.pid && $0.number == request.windowNumber }
    try require(matches.count == 1, "The requested native window is not uniquely visible for this PID.")
    return matches[0]
}
func requireTopmost(_ position: CGPoint, window: NativeWindow) throws {
    try require(window.bounds.contains(position), "The input point is outside the actual target window.")
    guard let front = onScreenWindows().first(where: { $0.bounds.contains(position) }),
          front.pid == window.pid, front.number == window.number else {
        throw PointerFailure(reason: "Another visible window covers the intended input point.")
    }
}
func displayBounds(containing position: CGPoint) throws -> CGRect {
    var count: UInt32 = 0
    try require(CGGetActiveDisplayList(0, nil, &count) == .success && count > 0 && count <= 32,
                "No bounded active display list is available.")
    let capacity = count
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
    let result = displays.withUnsafeMutableBufferPointer { CGGetActiveDisplayList(capacity, $0.baseAddress, &count) }
    try require(result == .success, "Cannot inspect current display bounds.")
    guard let bounds = displays.prefix(Int(count)).map(CGDisplayBounds).first(where: { $0.contains(position) }) else {
        throw PointerFailure(reason: "The target point is outside the actual active displays.")
    }
    return bounds
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func axBounds(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          let rawSize = attribute(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
    let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
          AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
    let rect = CGRect(origin: position, size: size)
    return valid(rect) ? rect : nil
}
func isPauseButton(_ element: AXUIElement) -> Bool {
    guard string(element, kAXRoleAttribute) == kAXButtonRole,
          (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { return false }
    return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains { name in
        let label = string(element, name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return label == "pause" || label == "暂停"
    }
}
func pauseButton(in window: NativeWindow) throws -> (AXUIElement, CGRect) {
    let root = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(root, 0.12)
    let deadline = ProcessInfo.processInfo.systemUptime + 2.0
    var visited = 0
    var buttons: [(AXUIElement, CGRect)] = []
    func visit(_ element: AXUIElement, depth: Int) {
        guard depth <= 18, visited < 400, ProcessInfo.processInfo.systemUptime < deadline else { return }
        visited += 1
        if isPauseButton(element), let bounds = axBounds(element), window.bounds.contains(bounds) {
            buttons.append((element, bounds))
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(80) {
            visit(child, depth: depth + 1)
        }
    }
    // Inspect the app's actual windows before any menu hierarchy. Only a button
    // whose current frame is inside the requested CG window is eligible.
    let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if windows.isEmpty { visit(root, depth: 0) }
    else { for current in windows.prefix(12) { visit(current, depth: 0) } }
    try require(ProcessInfo.processInfo.systemUptime < deadline && visited < 400,
                "The fresh Accessibility inspection exceeded its bounded budget.")
    try require(buttons.count == 1, "No unique enabled Pause/暂停 button is exposed inside the target panel.")
    // Re-read its role, state and frame immediately before deriving the point.
    guard isPauseButton(buttons[0].0), let freshBounds = axBounds(buttons[0].0),
          window.bounds.contains(freshBounds) else { throw PointerFailure(reason: "The Pause button changed during inspection.") }
    return (buttons[0].0, freshBounds)
}
func post(_ type: CGEventType, at position: CGPoint) throws {
    try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "Existing input permission changed; no further input was posted.")
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: .left) else {
        throw PointerFailure(reason: "Core Graphics could not create the pointer event.")
    }
    event.flags = []
    if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
    event.post(tap: .cghidEventTap)
}
func perform(_ request: PointerRequest) -> [String: Any] {
    var row: [String: Any] = ["requestID": request.requestID, "sequence": request.sequence, "action": request.action,
        "pid": request.pid, "windowNumber": request.windowNumber, "posted": false, "outcome": "blocked",
        "timestamp": ISO8601DateFormatter().string(from: Date())]
    var postedEvents: [String] = []
    do {
        let window = try targetWindow(request)
        row["windowBounds"] = rectangle(window.bounds)
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        let display = try displayBounds(containing: center)
        row["displayBounds"] = rectangle(display)
        switch request.action {
        case "enter":
            try requireTopmost(center, window: window)
            row["point"] = point(center)
            try post(.mouseMoved, at: center); postedEvents.append("mouseMoved")
        case "pause":
            let (_, bounds) = try pauseButton(in: window)
            row["buttonBounds"] = rectangle(bounds)
            let position = CGPoint(x: bounds.midX, y: bounds.midY)
            row["point"] = point(position)
            _ = try displayBounds(containing: position)
            let fresh = try targetWindow(request)
            try require(fresh.bounds == window.bounds, "The native panel moved during button inspection.")
            try requireTopmost(position, window: fresh)
            try post(.mouseMoved, at: position); postedEvents.append("mouseMoved")
            // A normal down/up pair reaches native hit testing; no AX action or
            // injected model state is used. The app verifier checks the outcome.
            try post(.leftMouseDown, at: position); postedEvents.append("leftMouseDown")
            try post(.leftMouseUp, at: position); postedEvents.append("leftMouseUp")
        case "leave":
            let candidates = [CGPoint(x: window.bounds.maxX + 12, y: center.y),
                CGPoint(x: window.bounds.minX - 12, y: center.y),
                CGPoint(x: center.x, y: window.bounds.maxY + 12),
                CGPoint(x: center.x, y: window.bounds.minY - 12)]
            guard let outside = candidates.first(where: { display.insetBy(dx: 1, dy: 1).contains($0) && !window.bounds.contains($0) }) else {
                throw PointerFailure(reason: "No nearby point outside the panel lies within its actual display.")
            }
            row["point"] = point(outside)
            try post(.mouseMoved, at: outside); postedEvents.append("mouseMoved")
        default: throw PointerFailure(reason: "Unsupported pointer action.")
        }
        row["posted"] = true
        row["outcome"] = "posted"
    } catch let error as PointerFailure { row["reason"] = error.reason }
    catch { row["reason"] = "Native pointer inspection failed." }
    row["eventsPosted"] = postedEvents
    row["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    return row
}
let deadline = ProcessInfo.processInfo.systemUptime + duration
var lastSequence = 0
var lastData: Data?
var actions: [[String: Any]] = []
while ProcessInfo.processInfo.systemUptime < deadline && !files.fileExists(atPath: stopURL.path) && actions.count < 12 {
    if let size = try? requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
       let data = try? Data(contentsOf: requestURL), data.count <= 16_384, data != lastData {
        lastData = data
        if let request = try? JSONDecoder().decode(PointerRequest.self, from: data),
           UUID(uuidString: request.requestID) != nil, request.sequence > lastSequence,
           request.sequence <= 1_000_000, ["enter", "pause", "leave"].contains(request.action), request.windowNumber > 0 {
            lastSequence = request.sequence
            actions.append(perform(request))
            report["actions"] = actions; persist()
        } else {
            report["lastRejectedRequest"] = "Malformed, duplicate, out-of-order or unsupported request; no input was posted."
            persist()
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
report["status"] = "COMPLETED"
report["stoppedByCaller"] = files.fileExists(atPath: stopURL.path)
persist()
