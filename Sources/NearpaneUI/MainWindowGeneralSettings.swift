import AppKit
import NearpaneCore
import ServiceManagement
import SwiftUI

struct MainWindowGeneralSettings: View {
    let host: HostSession
    let menuVisibilityChanged: (Bool) -> Void
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginChanging = false
    @State private var loginIssue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("启动与访问").font(.system(size: 12, weight: .semibold))
                    Toggle("登录时打开 Nearpane", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: updateLogin))
                        .toggleStyle(.switch).controlSize(.small).disabled(loginChanging || loginStatus == .notFound)
                        .accessibilityIdentifier("settings-login-item")
                    if loginStatus == .requiresApproval {
                        Button("在系统设置中允许开机启动…") { SMAppService.openSystemSettingsLoginItems() }
                            .font(.callout)
                    } else if loginStatus == .notFound {
                        Text("将 Nearpane 放入「应用程序」后，可设置开机启动。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let loginIssue { Text(loginIssue).font(.caption).foregroundStyle(.secondary) }
                    Divider().opacity(0.55)
                    Toggle("在菜单栏显示 Nearpane", isOn: Binding(get: { host.configuration.showsMenuBarIcon }, set: { visible in
                        if host.setShowsMenuBarIcon(visible) { menuVisibilityChanged(visible) }
                    })).toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("settings-menu-bar-icon")
                    Text("双击「应用程序」中的 Nearpane，也会打开这个窗口。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("日常使用").font(.system(size: 12, weight: .semibold))
                    Text("侧栏呈现内容，主窗口管理模块、仓库与设置。模块关闭后，原有资料仍保留在仓库中。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(host.configuration.surfaceHidden ? "显示桌面侧栏" : "隐藏桌面侧栏") {
                        host.setSurfaceHidden(!host.configuration.surfaceHidden)
                    }.accessibilityIdentifier("settings-surface-visible")
                }
                if !host.configuration.showsMenuBarIcon {
                    Divider().opacity(0.55)
                    Button("退出 Nearpane") { NSApp.terminate(nil) }
                        .accessibilityIdentifier("settings-quit-nearpane")
                }
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func updateLogin(_ enabled: Bool) {
        guard !loginChanging else { return }
        loginChanging = true
        loginIssue = nil
        Task { @MainActor in
            defer { loginChanging = false; loginStatus = SMAppService.mainApp.status }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { loginIssue = error.localizedDescription }
        }
    }
}
