import AppKit
import ApplicationServices
import CReadOnlySpaces
import NearpaneCore

/// A direct, single user selection. No frame setters, keyboard shortcuts or Space actions.
package func focusCurrentWindow(id: ManagedWindowID, element: AXUIElement, owner: OrdinaryOwnerIdentity,
                        bundle: String, frame: SurfaceRect, display: String, deadline: TimeInterval, space: String? = nil,
                        scope: OrdinaryFocusScope? = nil, timing: WindowFocusTiming? = nil, windowlessHelper: Bool = true, permit: () throws -> Void) throws {
    let app = AXUIElementCreateApplication(id.pid)
    var writes = WindowFocusTiming.Writes(timing, .worker)
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
    if space != nil {
        try require(NPReadOnlySpacesOpen() == 1, "系统无法确认这个后台窗口所属的桌面。")
    }
    func isMember(_ number: UInt32) -> Bool {
        guard let space else { return false }
        return OrdinaryDesktopMembership.contains(number, display: display, record: space)
    }
    func validate(presented: Bool = false, allowMinimized: Bool = false) throws {
        let now = ProcessInfo.processInfo.systemUptime
        try require(deadline >= now && deadline - now <= 12, "桌面已变化，请重新选择。")
        try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
        if let scope {
            let trace = CurrentFocusScope.Trace()
            let evidence = CurrentFocusScope.inspect(scope, number: id.number, trace: trace, windowlessHelper: windowlessHelper) {
                CurrentFocusScope.original(id, element: element, frame: frame, display: display, trace: trace)
            }
            if evidence != .confirmed { timing?.scopeFindings(trace.findings, from: .worker) }
            try require(evidence == .confirmed, "已绑定的窗口、可见位置或当前桌面已变化。")
            return
        }
        let matches = try windows(id.pid).filter { number($0) == id.number }
        guard matches.count == 1 && CFEqual(matches[0], element), let fields = OrdinaryFocusAttributes(element),
              allowMinimized || fields.minimized == false else { throw Refusal("原窗口已关闭、重建或进入其他状态。") }
        let rect = fields.frame
        let ax = SurfaceRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        let screen = try displayID(ax)
        guard screen == display, space == nil || isMember(id.number),
              let row = WindowSurfaceRecord(number: id.number), row.pid == id.pid, row.layer == 0 else {
            throw Refusal("窗口已离开当前桌面，或其显示位置已改变。")
        }
        if space == nil || presented {
            try require((space != nil || ax == frame) && activeNumbers().contains(id.number) &&
                        row.isOnscreen && ax == row.frame,
                        "系统尚未确认这扇窗口在当前桌面置前。")
        }
    }
    func permitWrite() throws {
        guard scope != nil else { return try permit() }
        try CurrentFocusScope.authorizeStep(permit: permit) {
            try validate()
            try require(ProcessInfo.processInfo.systemUptime < deadline, "原选窗操作已超时。")
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
        while true {
            if condition() { return true }
            let remaining = end - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            // The command pipe is re-enabled only after this handler returns.
            CFRunLoopRunInMode(.defaultMode, min(0.018, remaining), false)
        }
    }
    func focused() -> Bool { frontPID() == id.pid && exact(kAXFocusedWindowAttribute) }
    if scope == nil, space != nil, attribute(element, kAXMinimizedAttribute) as? Bool == true {
        try validate(allowMinimized: true)
        try permitWrite()
        writes.before(.unminimize)
        try require(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success &&
                    waitFor(0.7) { attribute(element, kAXMinimizedAttribute) as? Bool == false },
                    "应用未能展开这扇最小化的窗口。")
        try validate()
    }
    if focused() {
        try validate(presented: true)
        try require(focused(), "焦点已离开所选窗口。")
        timing?.confirmed(.worker)
        return
    }
    guard let origin = frontPID() else { throw Refusal("系统未提供当前前台应用。") }
    if origin != id.pid {
        if !exact(kAXMainWindowAttribute) {
            try validate()
            try permitWrite()
            try require(frontPID() == origin, "前台已变化，请重新选择。")
            writes.before(.main)
            try require(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
                        "应用未允许选中这扇窗口。")
        }
        let mainIsTarget = waitFor(0.35) { exact(kAXMainWindowAttribute) }
        try validate()
        // Admission binds this window. A sibling on a different Space neither authorizes
        // the selected window nor prevents selecting it after its desktop is current.
        try require(mainIsTarget && exact(kAXMainWindowAttribute) &&
                    (isMember(id.number) || activeNumbers().contains(id.number)),
                    "无法确认置前会留在当前桌面。")
        let before = frontPID()
        try require(before == origin || before == id.pid, "前台已变化，请重新选择。")
        if before != id.pid {
            try validate()
            try permitWrite()
            try require(frontPID() == origin && exact(kAXMainWindowAttribute), "前台已变化，请重新选择。")
            writes.before(.frontmost)
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
        try permitWrite()
        try require(frontPID() == id.pid, "前台已变化，请重新选择。")
        writes.before(.raise)
        try require(AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success, "此窗口不支持置前。")
        if !waitFor(0.12, until: focused) {
            try validate()
            try require(frontPID() == id.pid, "前台已变化，请重新选择。")
            var writable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &writable) == .success && writable.boolValue {
                try validate()
                try permitWrite()
                try require(frontPID() == id.pid, "前台已变化，请重新选择。")
                writes.before(.focusedWindow)
                try require(AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element) == .success,
                            "应用拒绝将焦点交给所选窗口。")
            } else if !exact(kAXMainWindowAttribute) {
                try validate()
                try permitWrite()
                try require(frontPID() == id.pid, "前台已变化，请重新选择。")
                writes.before(.main)
                try require(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
                            "应用未允许选中这扇窗口。")
            }
        }
    }
    let confirmed = waitFor(0.65, until: focused)
    let presented = confirmed && scope == nil && space != nil && waitFor(0.8) { (try? validate(presented: true)) != nil }
    if !presented { try validate(presented: true) }
    try require(confirmed && focused(), "应用已在前台，但系统未确认这扇窗口获得焦点。")
    timing?.confirmed(.worker)
}
