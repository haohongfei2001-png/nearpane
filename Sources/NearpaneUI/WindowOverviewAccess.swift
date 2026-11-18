import AppKit
import ApplicationServices
import SwiftUI

/// These observations belong to the running Nearpane process. A window reader or action
/// helper checks its own privileges when it actually performs an operation.
@MainActor @Observable final class WindowOverviewAccess {
    enum Permission: Hashable {
        case focus, thumbnails

        var requestLabel: String {
            self == .focus ? "允许 Nearpane 使用辅助功能…" : "允许 Nearpane 读取窗口画面…"
        }
        var settingsLabel: String {
            self == .focus ? "打开辅助功能设置…" : "打开屏幕录制设置…"
        }
    }

    enum Action { case request, settings }
    static let shared = WindowOverviewAccess(read: systemGrants, request: requestSystemAccess, open: openSettings)

    static func systemGrants() -> Set<Permission> {
        var grants = Set<Permission>()
        if AXIsProcessTrusted() { grants.insert(.focus) }
        if CGPreflightScreenCaptureAccess() { grants.insert(.thumbnails) }
        return grants
    }

    static func sidebarGuides(grants: Set<Permission>, showPictures: Bool, readerDenied: Bool, visible: Bool) -> Set<Permission> {
        guard visible else { return [] }
        var needed = Set<Permission>()
        if showPictures { needed.insert(.thumbnails) }
        // An absent or partial helper observation does not establish an access denial.
        if readerDenied { needed.insert(.focus) }
        return needed.subtracting(grants)
    }

    private let read: @MainActor () -> Set<Permission>
    private let request: @MainActor (Permission) -> Void
    private let open: @MainActor (Permission) -> Void
    private var requested = Set<Permission>()
    private(set) var grants: Set<Permission>

    init(read: @escaping @MainActor () -> Set<Permission>, request: @escaping @MainActor (Permission) -> Void, open: @escaping @MainActor (Permission) -> Void) {
        self.read = read
        self.request = request
        self.open = open
        grants = read()
    }

    func refresh() {
        let current = read()
        if current != grants { grants = current }
        if !requested.isDisjoint(with: current) { requested.subtract(current) }
    }

    func action(for permission: Permission) -> Action? {
        guard !grants.contains(permission) else { return nil }
        return requested.contains(permission) ? .settings : .request
    }

    func perform(_ action: Action, for permission: Permission) {
        // The button might have been rendered before the user approved or revoked access.
        refresh()
        guard action == self.action(for: permission) else { return }
        switch action {
        case .request:
            requested.insert(permission)
            request(permission)
        case .settings:
            open(permission)
        }
        refresh()
    }

    private static func requestSystemAccess(_ permission: Permission) {
        switch permission {
        case .focus: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .thumbnails: _ = CGRequestScreenCaptureAccess()
        }
    }

    private static func openSettings(_ permission: Permission) {
        let pane = permission == .focus ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct WindowPermissionButton: View {
    let permission: WindowOverviewAccess.Permission
    var body: some View {
        if let action = WindowOverviewAccess.shared.action(for: permission) {
            Button(action == .request ? permission.requestLabel : permission.settingsLabel) {
                WindowOverviewAccess.shared.perform(action, for: permission)
            }
        }
    }
}

extension View {
    @MainActor func refreshWindowPermissions() -> some View {
        onAppear { WindowOverviewAccess.shared.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                WindowOverviewAccess.shared.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                WindowOverviewAccess.shared.refresh()
            }
    }
}
