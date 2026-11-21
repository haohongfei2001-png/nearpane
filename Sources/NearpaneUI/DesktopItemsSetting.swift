import AppKit
import ApplicationServices

enum DesktopItemDisplay: String, CaseIterable, Sendable {
    case onWallpaperClick, always

    var label: String {
        switch self {
        case .onWallpaperClick: "点击空白墙纸时显示"
        case .always: "始终显示"
        }
    }
}

/// The desktop owns the preference. Only an explicit Settings choice reaches this adapter.
/// A nil request reads the native control without pressing it.
actor DesktopItemsSetting {
    static let shared = DesktopItemsSetting()
    static let pane = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension?show-items-on-desktop")!
    static let checkboxID = "show-items-on-desktop"
    private static let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
    private static let extensionBundle = "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex"

    enum Outcome: Equatable, Sendable {
        case confirmed(DesktopItemDisplay), manual, unconfirmed, unavailable, busy
    }
    struct Readback<Element: Equatable>: Equatable {
        let item: Element
        let mode: DesktopItemDisplay
    }

    private var inProgress = false

    func choose(_ desired: DesktopItemDisplay?) async -> Outcome {
        guard !inProgress else { return .busy }
        inProgress = true
        defer { inProgress = false }
        let initiator = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard !Task.isCancelled, let pid = await Self.openPane() else { return .unavailable }
        guard AXIsProcessTrusted() else { return .manual }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = ContinuousClock.now + .seconds(6)
        var sawSettings = false
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if Self.isFrontmost(pid) {
                sawSettings = true
                if let first = Self.checkbox(in: app, pid: pid) {
                    return await Self.apply(desired, first: first, read: { Self.checkbox(in: app, pid: pid) },
                        press: { item in _ = AXUIElementPerformAction(item, kAXPressAction as CFString) },
                        wait: { try await Task.sleep(for: .milliseconds(120)) })
                }
            } else if sawSettings || NSWorkspace.shared.frontmostApplication?.processIdentifier != initiator {
                return .manual
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
        }
        return .manual
    }

    /// No delayed writes or retries after dispatch. AX may report a timeout for an applied press.
    static func apply<Element: Equatable>(_ desired: DesktopItemDisplay?, first: Readback<Element>,
        read: () -> Readback<Element>?, press: (Element) -> Void,
        wait: () async throws -> Void) async -> Outcome {
        guard !Task.isCancelled, read() == first else { return .manual }
        guard let desired, first.mode != desired else { return .confirmed(first.mode) }
        press(first.item)
        var consecutive = 0
        for _ in 0..<12 {
            do { try await wait() } catch { break }
            guard !Task.isCancelled, let observed = read(), observed.item == first.item else { break }
            consecutive = observed.mode == desired ? consecutive + 1 : 0
            if consecutive == 2 { return .confirmed(desired) }
        }
        return .unconfirmed
    }

    @MainActor private static func openPane() async -> pid_t? {
        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = false
        config.addsToRecentItems = false
        guard let app = try? await NSWorkspace.shared.open([pane], withApplicationAt: settings, configuration: config),
              app.bundleIdentifier == "com.apple.systempreferences",
              app.bundleURL?.standardizedFileURL.path == settings.path else { return nil }
        return app.processIdentifier
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    private static func attr(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
    }
    private static func owner(_ item: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(item, &pid) == .success ? pid : nil
    }
    private static func checkbox(in app: AXUIElement, pid: pid_t) -> Readback<AXUIElement>? {
        guard isFrontmost(pid), let raw = attr(app, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        guard owner(window) == pid, attr(window, kAXModalAttribute) as? Bool != true else { return nil }
        var queue = [window], seen = Set<AXUIElement>(), match: AXUIElement?
        let deadline = ContinuousClock.now + .seconds(1)
        while let item = queue.popLast() {
            guard seen.insert(item).inserted else { continue }
            guard seen.count <= 1600, ContinuousClock.now < deadline,
                  let role = attr(item, kAXRoleAttribute) as? String, role != kAXSheetRole else { return nil }
            if attr(item, kAXIdentifierAttribute) as? String == checkboxID, [kAXCheckBoxRole, "AXSwitch"].contains(role) {
                guard match == nil else { return nil }
                match = item
            }
            if ![kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, kAXImageRole, "AXWebArea"].contains(role) {
                queue.append(contentsOf: attr(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        guard let item = match, let ownerPID = owner(item) else { return nil }
        if ownerPID != pid {
            let paneApp = NSRunningApplication(processIdentifier: ownerPID)
            guard paneApp?.bundleIdentifier == "com.apple.Desktop-Settings.extension",
                  paneApp?.bundleURL?.standardizedFileURL.path == extensionBundle else { return nil }
        }
        guard attr(item, kAXEnabledAttribute) as? Bool == true,
              let value = attr(item, kAXValueAttribute) as? NSNumber, [0.0, 1.0].contains(value.doubleValue),
              let current = attr(app, kAXFocusedWindowAttribute), CFEqual(current, window), isFrontmost(pid) else { return nil }
        return Readback(item: item, mode: value.boolValue ? .always : .onWallpaperClick)
    }
}
