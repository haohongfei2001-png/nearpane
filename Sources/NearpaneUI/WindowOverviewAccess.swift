import AppKit
import ApplicationServices
import SwiftUI

private typealias ViewState<T> = State<T>

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
    static let shared = WindowOverviewAccess(read: systemGrants, request: requestSystemAccess, open: openSettings,
                                             readWorker: OrdinaryWindowDirectory.focusPermission)

    static func systemGrants() -> Set<Permission> {
        systemGrants(readFocus: AXIsProcessTrusted, screen: WindowPermissionProbe.screen)
    }

    static func systemGrants(readFocus: () -> Bool, screen: WindowPermissionProbe) -> Set<Permission> {
        // Card rendering can coalesce denials. A guide refresh must see a change made
        // in System Settings even if a card checked a moment before the user granted it.
        screen.invalidate()
        var grants = Set<Permission>()
        if readFocus() { grants.insert(.focus) }
        if screen.allowed() { grants.insert(.thumbnails) }
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
    private let readWorker: @MainActor (_ prompt: Bool) async -> Bool?
    private var requested = Set<Permission>()
    private(set) var grants: Set<Permission>
    private(set) var workerFocus: Bool?
    private(set) var checkedWorker = false
    @ObservationIgnored private var workerQuery: (id: UUID, task: Task<Bool?, Never>)?
    private var lastWorkerCheck: TimeInterval = -.infinity
    private(set) var observeUntil: TimeInterval = 0

    init(read: @escaping @MainActor () -> Set<Permission>, request: @escaping @MainActor (Permission) -> Void,
         open: @escaping @MainActor (Permission) -> Void, readWorker: @escaping @MainActor (Bool) async -> Bool? = { _ in nil }) {
        self.read = read
        self.request = request
        self.open = open
        self.readWorker = readWorker
        grants = read()
    }

    func recordWorkerFocus(_ granted: Bool?) {
        workerQuery = nil
        workerFocus = granted
        checkedWorker = true
        lastWorkerCheck = ProcessInfo.processInfo.systemUptime
        if granted == true { requested.remove(.focus) }
    }

    func checkGuide(force: Bool = false) async {
        refresh()
        let query: (id: UUID, task: Task<Bool?, Never>)
        if let pending = workerQuery {
            query = pending
        } else {
            guard force || ProcessInfo.processInfo.systemUptime - lastWorkerCheck >= 3 else { return }
            query = (UUID(), Task { [readWorker] in await readWorker(false) })
            workerQuery = query
        }
        let answer = await query.task.value
        if workerQuery?.id == query.id { recordWorkerFocus(answer) }
    }

    var focusAvailable: Bool? { grants.contains(.focus) ? true : workerFocus }

    func guideAction(for permission: Permission) -> Action? {
        if permission == .thumbnails { return action(for: permission) }
        guard focusAvailable == false else { return nil }
        return action(for: .focus)
    }

    func performGuide(_ action: Action, for permission: Permission) async {
        if permission == .focus { await checkGuide(force: true) }
        refresh()
        guard guideAction(for: permission) == action else { return }
        observeUntil = ProcessInfo.processInfo.systemUptime + 120
        // The visible installation is the stable TCC principal. Never ask the user
        // to approve a short-lived helper when a bundled app entry is actionable.
        perform(action, for: permission)
    }

    func checkAfterRequest() async {
        let previousFocus = grants.contains(.focus)
        refresh()
        if requested.contains(.focus) || previousFocus != grants.contains(.focus) {
            await checkGuide(force: previousFocus != grants.contains(.focus))
        }
        if requested.isEmpty { observeUntil = 0 }
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
        case .focus:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .thumbnails:
            _ = CGRequestScreenCaptureAccess()
            WindowPermissionProbe.screen.invalidate()
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

/// The Host reads pixels and can directly focus a publicly identified window.
/// Apps requiring the isolated window-number reader use the signed action helper.
struct WindowAccessGuide: View {
    let showPictures: Bool
    @ViewState private var expanded = false
    private let access = WindowOverviewAccess.shared

    var body: some View {
        // Keep a zero-height observer even when the first preflight granted screen capture.
        // The independent focus reply can arrive after the sidebar has already appeared.
        VStack(alignment: .leading, spacing: 0) {
            let missingPixels = showPictures && !access.grants.contains(.thumbnails)
            let missingFocus = access.checkedWorker && access.focusAvailable != true
            if missingPixels || missingFocus {
                Button {
                    expanded = true
                } label: {
                    Label(missingPixels && missingFocus ? "设置窗口权限" : missingPixels ? "启用窗口画面" : "检查窗口切换",
                          systemImage: "lock.open")
                        .lineLimit(1)
                }
                .controlSize(.small)
                .accessibilityIdentifier("window-access-guide")
                .popover(isPresented: $expanded) {
                    VStack(alignment: .trailing, spacing: 12) {
                        WindowAccessSteps(showPictures: showPictures)
                        Button("完成") { expanded = false }
                            .controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("window-access-done")
                    }
                    .frame(width: 276).padding(14)
                }
            }
        }
        .modifier(WindowGuideObserver(access: access))
    }
}

struct WindowAccessSteps: View {
    let showPictures: Bool
    private let access = WindowOverviewAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showPictures {
                step(.thumbnails, name: "窗口画面", systemName: "屏幕与系统音频录制", granted: access.grants.contains(.thumbnails))
            }
            step(.focus, name: "精确切换窗口", systemName: "辅助功能", granted: access.focusAvailable)
            if access.guideAction(for: .focus) != nil || (showPictures && access.guideAction(for: .thumbnails) != nil) {
                DisclosureGroup("系统开关已经打开？") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("如果这项开关已打开，但当前版本仍读不到许可，可以移除旧的 Nearpane 条目，再添加此处的应用。权限生效后这里会自动更新。若系统提示重新打开，请按提示操作。")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("在访达中显示当前 Nearpane") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .controlSize(.small)
                        Text(Bundle.main.bundlePath)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
                .controlSize(.small)
            }
        }
        .modifier(WindowGuideObserver(access: access))
    }

    private func step(_ permission: WindowOverviewAccess.Permission, name: String, systemName: String, granted: Bool?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(systemName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action = access.guideAction(for: permission) {
                Button(action == .request ? "授权…" : "打开系统设置…") {
                    Task { await access.performGuide(action, for: permission) }
                }
                .accessibilityIdentifier(permission == .thumbnails ? "window-access-allow-pictures" : "window-access-allow-focus")
            } else if granted == true {
                Label("已允许", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .accessibilityIdentifier(permission == .thumbnails ? "window-access-pictures-granted" : "window-access-focus-granted")
            } else if !access.checkedWorker {
                Text("正在检查…").foregroundStyle(.secondary)
            } else {
                Button("重新检查") { Task { await access.checkGuide(force: true) } }
                    .accessibilityIdentifier("window-access-recheck-focus")
                    .help("本次未能读取切换权限")
            }
        }
        .controlSize(.small)
    }
}

private struct WindowGuideObserver: ViewModifier {
    private struct Observation: Equatable {
        let settingsActive: Bool
        let deadline: TimeInterval
    }

    let access: WindowOverviewAccess
    @ViewState private var settingsActive = false

    func body(content: Content) -> some View {
        let observation = Observation(settingsActive: settingsActive, deadline: access.observeUntil)
        return content
            .onAppear {
                settingsActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                settingsActive = app.bundleIdentifier == "com.apple.systempreferences"
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)) { event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.systempreferences" else { return }
                settingsActive = false
                Task { await access.checkGuide(force: true) }
            }
            .task(id: observation) {
                await access.checkGuide()
                // Also observe changes made directly in System Settings while
                // the sidebar stays visible in the background.
                while !Task.isCancelled && (observation.settingsActive || ProcessInfo.processInfo.systemUptime < observation.deadline) {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await access.checkAfterRequest()
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
