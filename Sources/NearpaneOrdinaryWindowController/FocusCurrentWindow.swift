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
    // NSRunningApplication properties update on the main run loop. This command is
    // itself a CFFileDescriptor callback, so sleeping here can freeze the previous PID.
    let system = AXUIElementCreateSystemWide()
    try require(AXUIElementSetMessagingTimeout(system, 0.18) == .success, "无法核对当前焦点。")
    func frontPID() -> pid_t? {
        if let value = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(value as! AXUIElement, &pid) == .success && pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    func waitFor(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + seconds)
        while !condition(), ProcessInfo.processInfo.systemUptime < end {
            // The command pipe is re-enabled only after this handler returns.
            CFRunLoopRunInMode(.defaultMode, 0.018, false)
        }
        return condition()
    }
    func focused() -> Bool { frontPID() == id.pid && exact(kAXFocusedWindowAttribute) }
    try validate()
    if focused() { return }
    guard let origin = frontPID() else { throw Refusal("系统未提供当前前台应用。") }
    if origin != id.pid {
        if !exact(kAXMainWindowAttribute) {
            try require(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
                        "应用未允许选中这扇窗口。")
        }
        let mainIsTarget = waitFor(0.35) { exact(kAXMainWindowAttribute) }
        try validate()
        let siblings = try windows(id.pid)
        let active = activeNumbers()
        let allHere = siblings.allSatisfy { number($0).map(active.contains) == true }
        try require(mainIsTarget && exact(kAXMainWindowAttribute) && (allHere || exact(kAXFocusedWindowAttribute)),
                    "无法确认置前会留在当前桌面。")
        let before = frontPID()
        try require(before == origin || before == id.pid, "前台已变化，请重新选择。")
        if before != id.pid {
            try require(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success,
                        "系统未允许所选应用成为前台。")
        }
        try require(waitFor(0.9) { frontPID() == id.pid }, "macOS 未将所选应用带到前台。")
    }
    // Activation can restore the app's previous key window. Select the requested
    // window after activation and never substitute a sibling.
    try validate()
    try require(frontPID() == id.pid, "前台已变化，请重新选择。")
    if !focused() {
        try require(AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success, "此窗口不支持置前。")
        if !waitFor(0.12, until: focused) {
            try validate()
            try require(frontPID() == id.pid, "前台已变化，请重新选择。")
            var writable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &writable) == .success && writable.boolValue {
                try require(AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element) == .success,
                            "应用拒绝将焦点交给所选窗口。")
            } else if !exact(kAXMainWindowAttribute) {
                try require(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
                            "应用未允许选中这扇窗口。")
            }
        }
    }
    let confirmed = waitFor(0.65, until: focused)
    try validate()
    try require(confirmed && focused(), "应用已在前台，但系统未确认这扇窗口获得焦点。")
}
