import AppKit
import ApplicationServices
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// Native focus route from upstream platform/apple/routes/focus.rs and controller::ax_focus.
/// The caller must observe the whole group becoming current before accepting the click.
@MainActor struct AppleStageFocus {
    private let key: DesktopWindowKey
    private let image: OrdinaryProcessImage
    private let window: AXUIElement
    private let application: AXUIElement
    private let display, record: String
    private let uuid: UUID

    init?(_ key: DesktopWindowKey, display: String, record: String, uuid: UUID) {
        guard AXIsProcessTrusted(), let image = try? OrdinaryProcessImage.read(key.pid), image.launch == key.birth,
              let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated, !app.isHidden,
              app.activationPolicy == .regular, let bundle = app.bundleIdentifier,
              !bundle.hasPrefix("com.holdsnow.nearpane."), key.pid != getpid(),
              OrdinaryDesktopMembership.contains(key.number, display: display, record: record, uuid: uuid) else { return nil }
        application = AXUIElementCreateApplication(key.pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        guard let windows = Self.value(application, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 128 else { return nil }
        let matches = windows.filter { NearpaneOrdinaryWindowRuntime.number($0) == key.number }
        guard matches.count == 1, let match = matches.first,
              Self.value(match, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              Self.value(match, kAXMinimizedAttribute) as? Bool == false,
              Self.value(match, "AXFullScreen") as? Bool != true else { return nil }
        AXUIElementSetMessagingTimeout(match, 0.08)
        self.key = key; self.image = image; self.window = match; self.display = display; self.record = record; self.uuid = uuid
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private static func outsideOverview() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard apps.count == 1, let dock = apps.first,
              dock.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/Dock.app" else { return false }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let children = value(root, kAXChildrenAttribute) as? [AXUIElement], children.count <= 64 else { return false }
        var list = false
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.05)
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &raw)
            guard result == .success || result == .attributeUnsupported || result == .noValue else { return false }
            if raw as? String == "mc" { return false }
            if value(child, kAXRoleAttribute) as? String == kAXListRole { list = true }
        }
        return list
    }

    private func live() -> Bool {
        StageManagerPreference.read() == true && (try? OrdinaryProcessImage.read(key.pid)) == image &&
            NearpaneOrdinaryWindowRuntime.number(window) == key.number &&
            OrdinaryDesktopMembership.contains(key.number, display: display, record: record, uuid: uuid)
    }
    func perform(current: () -> Bool) throws {
        guard current(), live(), Self.outsideOverview(), current() else { throw StageSwitchError.interrupted }
        // Some ordinary apps decline raise. The native route still needs main and frontmost,
        // then independent AX focus and complete WindowManager group readback.
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard current(), live(), AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
              current(), live(), AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        else { throw StageSwitchError.interrupted }
    }
    func confirmed() -> Bool {
        guard live(), NSWorkspace.shared.frontmostApplication?.processIdentifier == key.pid,
              let raw = Self.value(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID(),
              CFEqual(raw, window), NearpaneOrdinaryWindowRuntime.number(raw as! AXUIElement) == key.number else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        guard let focused = Self.value(system, kAXFocusedApplicationAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var pid: pid_t = 0
        return AXUIElementGetPid(focused as! AXUIElement, &pid) == .success && pid == key.pid
    }
}

/// Follow the exact focus that was present when R4 accepted the click. A different
/// document of either application can take focus without changing the HID counters.
@MainActor final class AppleFocusHandoff {
    private let applications: CrossSpaceFocusWatch
    private enum Focused { case window(AXUIElement), desktop }
    private let original: Focused
    private let source: SelectionForeground
    private let target: DesktopWindowKey
    private var acceptedTarget = false
    private var revoked = false

    init?(target: DesktopWindowKey) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular, !app.isTerminated,
              app.processIdentifier != getpid(), let source = SelectionForeground.read(app.processIdentifier),
              let original = Self.focused(source.pid),
              SelectionForeground.read(NSWorkspace.shared.frontmostApplication?.processIdentifier) == source else { return nil }
        self.source = source
        self.original = original
        self.target = target
        applications = CrossSpaceFocusWatch(source: source, target: .init(pid: target.pid, birth: target.birth))
    }

    private static func focused(_ pid: pid_t) -> Focused? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw)
        if status == .noValue, let finder = NSRunningApplication(processIdentifier: pid),
           finder.bundleIdentifier == "com.apple.finder",
           finder.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/Finder.app" {
            return .desktop
        }
        guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        var actual: pid_t = 0
        guard AXUIElementGetPid(window, &actual) == .success && actual == pid, NearpaneOrdinaryWindowRuntime.number(window) != nil else { return nil }
        return .window(window)
    }

    func current() -> Bool {
        guard !revoked, applications.current(),
              let owner = SelectionForeground.read(NSWorkspace.shared.frontmostApplication?.processIdentifier),
              let focused = Self.focused(owner.pid) else { revoked = true; return false }
        if case let .window(element) = focused, owner.pid == target.pid, owner.birth == target.birth,
           NearpaneOrdinaryWindowRuntime.number(element) == target.number {
            acceptedTarget = true
        } else if acceptedTarget || owner != source {
            revoked = true
        } else {
            switch (original, focused) {
            case (.desktop, .desktop): break
            case let (.window(a), .window(b)): revoked = !CFEqual(a,b)
            default: revoked = true
            }
        }
        return !revoked
    }
    func stop() { applications.stop() }
}
