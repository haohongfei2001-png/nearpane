import AppKit
import WindowLab

/// Only opaque equality is tested on the foreground application's window. No title, value or image is read.
@MainActor final class FocusStudy {
    let directory: URL, pid: pid_t, focused: AXUIElement
    private let output: FileHandle
    private var observers: [NSObjectProtocol] = []
    private var violated = false
    static func focusedWindow(_ pid: pid_t) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var raw: CFTypeRef?
        guard AXIsProcessTrusted(), AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw Refusal("foreground AX focused window unavailable") }
        let w = raw as! AXUIElement
        var actual: pid_t = 0
        try require(AXUIElementGetPid(w, &actual) == .success && actual == pid, "foreground AX owner differs")
        return w
    }
    init(_ directory: URL) throws {
        self.directory = directory
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { throw Refusal("foreground unavailable") }
        self.pid = pid; focused = try Self.focusedWindow(pid)
        let file = directory.appendingPathComponent("focus-" + String(getpid()) + ".jsonl")
        try Data().write(to: file, options: .withoutOverwriting)
        output = try FileHandle(forWritingTo: file)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.violated = true
                    try? self.record(["event":name.rawValue, "key":NSApp.keyWindow?.windowNumber ?? -1, "main":NSApp.mainWindow?.windowNumber ?? -1])
                }
            })
        }
    }
    private func record(_ fields: [String: Any]) throws {
        var row = fields; row["uptime"] = ProcessInfo.processInfo.systemUptime
        try output.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
    }
    func sample(windows: [Int:(Member, NSWindow)], panel: NSWindow?) throws {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let ax = front == pid ? try? Self.focusedWindow(pid) : nil
        let same = ax.map { CFEqual(focused, $0) } ?? false
        let all = windows.values.map { $0.1 } + [panel].compactMap { $0 }
        let rows: [[String: Any]] = all.map { w in
            ["number": w.windowNumber, "key": w.isKeyWindow, "main": w.isMainWindow, "mini": w.isMiniaturized,
             "responder": w.firstResponder.map { String(ObjectIdentifier($0).hashValue) } ?? "none"]
        }
        try record(["event":"sample", "frontPID":front, "baselinePID":pid, "axWindowReadable":ax != nil,
                    "sameAXFocusedWindow":same, "active":NSApp.isActive, "windows":rows])
        try require(!violated && same && !NSApp.isActive && !all.contains { $0.isKeyWindow || $0.isMainWindow }, "focus boundary changed or unreadable")
    }
}
