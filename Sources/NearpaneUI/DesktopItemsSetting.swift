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
    private static let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
    private static let extensionBundle = "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex"
    private static let desktopLabels = paneLabels("On Desktop", chinese: ["桌面上", "在桌面上"])
    private static let stageLabels = paneLabels("In Stage Manager", chinese: ["在台前调度中"])

    private static func paneLabels(_ key: String, chinese: [String]) -> Set<String> {
        let bundle = Bundle(path: extensionBundle)
        return Set(([key, bundle?.localizedString(forKey: key, value: key, table: nil) ?? key] + chinese).map(normalize))
    }
    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":："))).lowercased()
    }

    enum Outcome: Equatable, Sendable {
        case confirmed(DesktopItemDisplay), manual(ReadIssue), unconfirmed, unavailable, busy
    }
    enum ReadIssue: String, Error {
        case accessibility, focus, window, modal, scanLimit, missingControl, ambiguousControl
        case owner, disabled, invalidValue, changed, cancelled
    }
    struct Readback<Element: Equatable>: Equatable {
        let item: Element
        let mode: DesktopItemDisplay
        var canPress = true
    }

    private var inProgress = false

    func choose(_ desired: DesktopItemDisplay?) async -> Outcome {
        guard !inProgress else { return .busy }
        inProgress = true
        defer { inProgress = false }
        let initiator = Self.foregroundPID()
        guard !Task.isCancelled, let pid = await Self.openPane() else { return .unavailable }
        guard AXIsProcessTrusted() else { return .manual(.accessibility) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = ContinuousClock.now + .seconds(6)
        var sawSettings = false, issue = ReadIssue.focus
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if Self.isFrontmost(pid) {
                sawSettings = true
                do {
                    let first = try Self.checkbox(in: app, pid: pid)
                    return await Self.apply(desired, first: first, read: { try? Self.checkbox(in: app, pid: pid) },
                        press: { item in _ = AXUIElementPerformAction(item, kAXPressAction as CFString) },
                        wait: { try await Task.sleep(for: .milliseconds(120)) })
                } catch { issue = error }
            } else if sawSettings || Self.foregroundPID().map({ $0 != initiator }) == true {
                return .manual(.focus)
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
        }
        return .manual(Task.isCancelled ? .cancelled : issue)
    }

    /// No delayed writes or retries after dispatch. AX may report a timeout for an applied press.
    static func apply<Element: Equatable>(_ desired: DesktopItemDisplay?, first: Readback<Element>,
        read: () -> Readback<Element>?, press: (Element) -> Void,
        wait: () async throws -> Void) async -> Outcome {
        guard !Task.isCancelled, read() == first else { return .manual(.changed) }
        guard let desired, first.mode != desired else { return .confirmed(first.mode) }
        guard first.canPress else { return .manual(.disabled) }
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
        foregroundPID() == pid
    }
    private static func foregroundPID() -> pid_t? {
        guard let raw = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return owner(raw as! AXUIElement)
    }
    private static func attr(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
    }
    private static func owner(_ item: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(item, &pid) == .success ? pid : nil
    }
    static func identifiesDesktopItems(id: String, names: Set<String>) -> Bool {
        let text = Set(names.map(normalize))
        guard text.isDisjoint(with: stageLabels) else { return false }
        // On macOS 26 "desktop-items" identifies the *Stage Manager* column.
        return id == "show-items-on-desktop" || (id == "show-items" && !text.isDisjoint(with: desktopLabels))
    }
    static func boolean(_ raw: CFTypeRef?) -> Bool? {
        if let n = raw as? NSNumber, [0.0, 1.0].contains(n.doubleValue) { return n.boolValue }
        switch raw as? String {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
    private static func checkbox(in app: AXUIElement, pid: pid_t) throws(ReadIssue) -> Readback<AXUIElement> {
        guard isFrontmost(pid), let raw = attr(app, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw .window }
        let window = raw as! AXUIElement
        guard owner(window) == pid, boolean(attr(window, kAXModalAttribute)) != true else { throw .modal }
        var queue = [window], seen = Set<AXUIElement>(), match: AXUIElement?
        let deadline = ContinuousClock.now + .seconds(2)
        while let item = queue.popLast() {
            guard seen.insert(item).inserted else { continue }
            guard seen.count <= 1600, ContinuousClock.now < deadline else { throw .scanLimit }
            let role = attr(item, kAXRoleAttribute) as? String ?? ""
            guard role != kAXSheetRole else { throw .modal }
            if [kAXCheckBoxRole, "AXSwitch"].contains(role), let id = attr(item, kAXIdentifierAttribute) as? String,
               ["show-items", "show-items-on-desktop"].contains(id),
               identifiesDesktopItems(id: id, names: Set([kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attr(item, $0) as? String })) {
                guard match == nil else { throw .ambiguousControl }
                match = item
            }
            if ![kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, kAXImageRole, "AXWebArea"].contains(role) {
                queue.append(contentsOf: attr(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        guard let item = match, let ownerPID = owner(item) else { throw .missingControl }
        if ownerPID != pid {
            let paneApp = NSRunningApplication(processIdentifier: ownerPID)
            guard paneApp?.bundleIdentifier == "com.apple.Desktop-Settings.extension",
                  paneApp?.bundleURL?.standardizedFileURL.path == extensionBundle else { throw .owner }
        }
        guard let value = boolean(attr(item, kAXValueAttribute)) else { throw .invalidValue }
        var actions: CFArray?
        let pressable = AXUIElementCopyActionNames(item, &actions) == .success && (actions as? [String])?.contains(kAXPressAction) == true
        var enabled: CFTypeRef?
        let readable = AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
        let canPress = pressable && (readable == .attributeUnsupported || (readable == .success && boolean(enabled) == true))
        guard let current = attr(app, kAXFocusedWindowAttribute), CFEqual(current, window), isFrontmost(pid) else { throw .focus }
        return Readback(item: item, mode: value ? .always : .onWallpaperClick, canPress: canPress)
    }
}
