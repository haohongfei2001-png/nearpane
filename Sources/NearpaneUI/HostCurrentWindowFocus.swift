import AppKit
import ApplicationServices
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// Selection from a card for a window currently presented on this desktop. Only use
/// an AX window number returned by the selected application. Apps that do not expose
/// that attribute keep the isolated controller's existing identity resolution.
actor HostCurrentWindowFocus {
    private let target: DesktopWindowTarget
    private let owner = OrdinaryOwnerIdentity()
    private let bundle: String
    private let application: NSRunningApplication
    private let app: AXUIElement
    private var element: AXUIElement?

    init(target: DesktopWindowTarget, bundle: String, application: NSRunningApplication) {
        self.target = target
        self.bundle = bundle
        self.application = application
        app = AXUIElementCreateApplication(target.key.pid)
    }

    private func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &result) == .success ? result : nil
    }

    nonisolated static func exactIndex(numbers: [UInt32?], selected: UInt32) -> Int? {
        guard selected > 0, numbers.count <= 64 else { return nil }
        let matches = numbers.indices.filter { numbers[$0] == selected }
        return matches.count == 1 ? matches[0] : nil
    }

    private func verifiedElement() throws -> AXUIElement {
        let key = target.key
        try owner.verify(key.pid, launch: key.birth, bundle: bundle, find: { _ in application })
        var list: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &list) == .success,
              let windows = list as? [AXUIElement], windows.count <= 64 else {
            throw OrdinaryWindowFailure("Nearpane 无法核对所选应用的窗口。")
        }
        let end = ProcessInfo.processInfo.systemUptime + 0.5
        let numbers: [UInt32?] = try windows.map { window in
            guard ProcessInfo.processInfo.systemUptime < end else {
                throw OrdinaryWindowFailure("应用未及时返回完整的窗口编号。")
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, pid == key.pid,
                  AXUIElementSetMessagingTimeout(window, 0.12) == .success,
                  let n = value(window, "AXWindowNumber") as? NSNumber else { return nil }
            return UInt32(exactly: n.int64Value)
        }
        guard let index = Self.exactIndex(numbers: numbers, selected: key.number) else {
            throw OrdinaryWindowFailure("应用未提供可核对的唯一窗口编号。")
        }
        let w = windows[index]
        guard element.map({ CFEqual(w, $0) }) ?? true, let fields = OrdinaryFocusAttributes(w), fields.minimized == false else {
            throw OrdinaryWindowFailure("原窗口已关闭或状态已变化。")
        }
        guard target.matches(fields.frame),
              target.sharedSurface(visible: true, matchFrame: true, for: .windowSelection) else {
            throw OrdinaryWindowFailure("系统未确认所选窗口的实际位置。")
        }
        return w
    }

    /// Read-only. A denial or unsupported public attribute can still try the original
    /// worker. Once focus() starts it must never fall through to another action route.
    func bind() -> Bool {
        guard target.publiclyVisible, AXUIElementSetMessagingTimeout(app, 0.12) == .success else { return false }
        element = try? verifiedElement()
        return element != nil
    }

    private func same(_ source: AXUIElement, _ key: String, _ original: AXUIElement) -> Bool {
        guard let current = value(source, key), CFGetTypeID(current) == AXUIElementGetTypeID() else { return false }
        return CFEqual(current, original)
    }

    private func frontPID() -> pid_t? { try? FrontFocus.verifiedPID() }

    static func observe(until end: Double, interval: Double = 0.012,
                        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                        pause: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                        isolatedTo _: isolated (any Actor)? = #isolation,
                        condition: () -> Bool) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            if condition() { return true }
            let remaining = end - now()
            guard remaining > 0 else { return false }
            try await pause(min(interval, remaining))
        }
    }

    func focus(deadline: Double, current: @escaping @MainActor @Sendable () -> Bool, timing: WindowFocusTiming?) async throws {
        guard let original = element, let origin = frontPID() else { throw OrdinaryWindowFailure("系统未确认所选窗口或当前焦点。") }
        let pid = target.key.pid
        var writes = WindowFocusTiming.Writes(timing, .host)
        func validate() async throws {
            guard ProcessInfo.processInfo.systemUptime < deadline, WindowContentPreview.sessionAvailable(),
                  CFEqual(try verifiedElement(), original) else { throw OrdinaryWindowFailure("窗口已变化，请重新选择。") }
            // Check the current user intent immediately before each system action, after
            // checking exact AX identity. Never send mouse or keyboard input.
            guard await MainActor.run(body: {
                current() && target.isVisibleSurface(for: .windowSelection)
            }) else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        }
        func focused() -> Bool { frontPID() == pid && same(app, kAXFocusedWindowAttribute, original) }
        func wait(_ condition: () -> Bool) async throws {
            let until = min(deadline, ProcessInfo.processInfo.systemUptime + 0.75)
            guard try await Self.observe(until: until, interval: 0.025, condition: condition) else { throw OrdinaryWindowFailure("系统未确认所选窗口获得焦点。") }
        }
        if origin != pid {
            if !same(app, kAXMainWindowAttribute, original) {
                try await validate()
                guard frontPID() == origin else { throw OrdinaryWindowFailure("前台已变化，请重新选择。") }
                writes.before(.main)
                guard AXUIElementSetAttributeValue(original, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
                else { throw OrdinaryWindowFailure("应用未允许选中这扇窗口。") }
                try await wait { same(app, kAXMainWindowAttribute, original) }
            }
            if frontPID() != pid {
                try await validate()
                guard frontPID() == origin, same(app, kAXMainWindowAttribute, original) else { throw OrdinaryWindowFailure("前台已变化，请重新选择。") }
                writes.before(.frontmost)
                guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
                else { throw OrdinaryWindowFailure("应用未允许将所选窗口带到前台。") }
                try await wait { frontPID() == pid }
            }
        }
        if !focused() {
            try await validate()
            guard frontPID() == pid else { throw OrdinaryWindowFailure("前台已变化，请重新选择。") }
            writes.before(.raise)
            guard AXUIElementPerformAction(original, kAXRaiseAction as CFString) == .success
            else { throw OrdinaryWindowFailure("此窗口未能置前。") }
            // Some applications raise z-order without moving the keyboard. A focused-
            // window setter is allowed only for the same retained element and active app.
            let raisedFocus = try await Self.observe(until: min(deadline, ProcessInfo.processInfo.systemUptime + 0.1), condition: focused)
            if !raisedFocus {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &settable) == .success && settable.boolValue {
                    try await validate()
                    guard frontPID() == pid else { throw OrdinaryWindowFailure("前台已变化，请重新选择。") }
                    writes.before(.focusedWindow)
                    guard AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, original) == .success
                    else { throw OrdinaryWindowFailure("应用拒绝将键盘焦点交给所选窗口。") }
                } else if !same(app, kAXMainWindowAttribute, original) {
                    try await validate()
                    guard frontPID() == pid else { throw OrdinaryWindowFailure("前台已变化，请重新选择。") }
                    writes.before(.main)
                    guard AXUIElementSetAttributeValue(original, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
                    else { throw OrdinaryWindowFailure("应用未允许将所选窗口设为主窗口。") }
                }
                try await wait(focused)
            }
        }
        try await validate()
        guard focused() else { throw OrdinaryWindowFailure("焦点已离开所选窗口。") }
        timing?.confirmed(.host)
    }
}
