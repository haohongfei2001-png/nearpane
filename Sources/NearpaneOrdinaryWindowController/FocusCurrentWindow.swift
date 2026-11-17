import AppKit
import ApplicationServices
import NearpaneCore

/// A direct, single user selection. No frame setters, keyboard shortcuts or Space actions.
func focusCurrentWindow(id: ManagedWindowID, element: AXUIElement, owner: OrdinaryOwnerIdentity,
                        bundle: String, frame: SurfaceRect, display: String, deadline: TimeInterval) throws {
    let app = AXUIElementCreateApplication(id.pid)
    try require(AXUIElementSetMessagingTimeout(app, 0.18) == .success, "无法及时核对应用。")
    func activeNumbers() -> Set<UInt32> {
        // The worker services its command pipe on the main CFRunLoop.
        MainActor.assumeIsolated {
            Set((NSWindow.windowNumbers(options: .allApplications) ?? []).compactMap { UInt32(exactly: $0.int64Value) })
        }
    }
    func exact(_ key: String) -> Bool {
        guard let value = attribute(app, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(value, element)
    }
    func validate() throws {
        let now = ProcessInfo.processInfo.systemUptime
        try require(deadline >= now && deadline - now <= 12, "桌面已变化，请重新选择。")
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        let matches = try windows(id.pid).filter { number($0) == id.number }
        try require(matches.count == 1 && CFEqual(matches[0], element) &&
                    attribute(element, kAXRoleAttribute) as? String == kAXWindowRole &&
                    attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
                    attribute(element, kAXModalAttribute) as? Bool == false &&
                    attribute(element, kAXMinimizedAttribute) as? Bool == false &&
                    attribute(element, "AXFullScreen") as? Bool == false, "原窗口已关闭、重建或进入其他状态。")
        let ax = try axRect(element)
        let screen = try displayID(ax)
        guard ax == frame, screen == display, activeNumbers().contains(id.number),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.number) as? [[String:Any]],
              rows.count == 1, let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id.number,
              row[kCGWindowOwnerPID as String] as? Int32 == id.pid,
              row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bounds),
              frame == SurfaceRect(x:r.minX,y:r.minY,width:r.width,height:r.height) else {
            throw Refusal("窗口已离开当前桌面，或其显示位置已改变。")
        }
    }
    func focused() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid && exact(kAXFocusedWindowAttribute)
    }
    try validate()
    if focused() { return }
    try require(AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success, "此窗口不支持置前。")
    if !focused() {
        try validate()
        if !exact(kAXMainWindowAttribute) {
            try require(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
                        "应用未允许选中这扇窗口。")
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != id.pid {
            // Activation may otherwise switch to another Space. Require all candidate siblings
            // to be in the active set and the exact selected element to be the app's main window.
            let siblings = try windows(id.pid)
            let active = activeNumbers()
            guard siblings.allSatisfy({ number($0).map(active.contains) == true }),
                  exact(kAXMainWindowAttribute) else { throw Refusal("无法确认置前会留在当前桌面。") }
            try validate()
            // The helper itself has no foreground UI. Use the accessible application's
            // public frontmost attribute only after the selected main window is verified.
            try require(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success,
                        "系统未允许所选应用成为前台。")
        }
    }
    let end = min(deadline, ProcessInfo.processInfo.systemUptime + 0.65)
    while !focused() && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.025) }
    try validate()
    try require(focused(), "系统未确认选中的窗口获得焦点。")
}
