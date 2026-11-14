import AppKit
import SwiftUI
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
#endif

public struct SettingsView: View {
    private let host: HostSession
    private let domains: EmbeddedModules?
    private let profileImport: AnyView?
    private let applicationServices: AnyView?
    private let inventory: SettingsScreenInventory
    private let previewExposure: SettingsPreviewExposure
    private var screens: [ScreenGeometry] { inventory.screens }
    private let dismissSpaces: (String) -> Void
    private let requestSecondary: (String) -> Void
    private let placementChanged: () -> Void
    public init(host: HostSession, inventory: SettingsScreenInventory, previewExposure: SettingsPreviewExposure, domains: EmbeddedModules? = nil, profileImport: AnyView? = nil, applicationServices: AnyView? = nil, requestSecondary: @escaping (String) -> Void = { _ in }, dismissSpaces: @escaping (String) -> Void = { _ in }, placementChanged: @escaping () -> Void) {
        self.previewExposure = previewExposure
        self.profileImport = profileImport
        self.applicationServices = applicationServices
        self.dismissSpaces = dismissSpaces
        self.requestSecondary = requestSecondary
        self.domains = domains; self.host = host; self.inventory = inventory; self.placementChanged = placementChanged
    }

    public var body: some View {
        TabView {
            modules.tabItem { Text("模块") }
            #if canImport(NearpaneVoice)
            if let domains, domains.candidate { VoiceInputSettings(module: domains.voice).tabItem { Text("语音") } }
            #endif
            #if canImport(NearpaneTray)
            if let tray = domains?.tray {
                Form {
                    Text(domains?.candidate == true ? "截图保存在此版本的独立托盘，退出后仍可继续使用。" : "使用已有的 Riftlet 资料库。连接期间由 Nearpane 独占；断开后原库仍由 Riftlet 使用。")
                    if tray.connected {
                        if tray.collectionEnabled {
                            Button("停止收录系统截图") { tray.stopCollecting() }
                        } else if domains?.candidate != true || tray.productAttachments {
                            Button("选择当前系统截图目录并收录…") {
                                let picker = NSOpenPanel()
                                picker.canChooseDirectories = true; picker.canChooseFiles = false
                                picker.canCreateDirectories = false; picker.allowsMultipleSelection = false
                                picker.begin { response in
                                    if response == .OK, let url = picker.url { Task { await tray.collect(from: url) } }
                                }
                            }
                        }
                        if tray.productAttachments && tray.hasSavedCollection && !tray.collectionEnabled {
                            Button("重新核对原截图目录") { Task { await tray.recheckCollection() } }
                            Button("忘记原截图目录") { tray.stopCollecting() }
                        }
                        Button("断开资料库") {
                            tray.disconnect()
                            if domains?.candidate == true { host.setCandidateTrayConnected(false) }
                        }
                        if !tray.localOnly {
                            Button((tray.mayAttach || tray.savedAttachmentConsent) ? "重新检查草稿附加权限" : "允许附加到当前浏览器草稿…") {
                                Task { await tray.authorizeAttachments() }
                            }
                            if tray.productAttachments && tray.savedAttachmentConsent {
                                Button("关闭草稿附加") { Task { await tray.disableAttachments() } }
                            }
                            if let notice = tray.attachmentAccessNotice { Text(notice).foregroundStyle(.secondary) }
                            if let feedback = tray.attachmentFeedback { Text(feedback).font(.callout) }
                            Text("保持 Chrome 中要使用的 ChatGPT 草稿在前台，再点击缩略图。不会发送消息；结果未知时不会自动重传。")
                        } else { Text("当前仅收录截图。附加到草稿须使用已绑定的专用测试会话。") }
                    } else {
                        Button(tray.connecting ? "正在连接…" : (domains?.candidate == true ? "重新连接此版本托盘" : "连接已有 Riftlet 资料库")) {
                            Task {
                                await tray.connect()
                                if domains?.candidate == true && tray.connected { host.setCandidateTrayConnected(true) }
                            }
                        }.disabled(!tray.active || tray.connecting)
                    }
                    if let issue = tray.issue { Text(issue).foregroundStyle(.secondary) }
                }.padding().tabItem { Text("Riftlet") }
            }
            #endif
            appearance.tabItem { Text("显示器") }
            WorkspaceDisplaySettings(host:host,screens:screens,request:requestSecondary,dismiss:dismissSpaces, stillCurrent: inventory.contains).tabItem { Text("尺寸与呈现") }
            WorkspacePolicySettings(host:host).tabItem { Text("窗口规则") }
            if let lab = domains?.workRect { CandidateWorkRectView(session: lab, host: host, previewExposure: previewExposure).tabItem { Text("窗口管理") } }
            desktopOptions.tabItem { Text("空间观察") }
            if let applicationServices { applicationServices.tabItem { Text("应用") } }
            if domains?.candidate != true { mockSettings.tabItem { Text("Mock & diagnostics") } }
        }
        .padding(16)
        .frame(width: 600, height: 540)
    }

    private var desktopOptions: some View {
        Form {
            Picker("工作空间模式", selection:.constant(host.workspaceMode.mode)) {
                Text("Native Spaces").tag(WorkspaceMode.native)
                Text("Nearpane Virtual Workspaces · 等待实机恢复验证").tag(WorkspaceMode.virtual).disabled(true)
            }
            Text("Native 只读预览。系统空间切换、跨空间移窗和 Virtual 停放均关闭。").font(.caption)
            let enabled = host.registry.preferences.first(where: { $0.id == BuiltinCatalog.desktop })?.enabled == true
            Toggle("只读桌面预览", isOn: Binding(get: { enabled }, set: { host.handle(.setEnabled(BuiltinCatalog.desktop, $0)) }))
            Toggle("实验性 Space 归属读取", isOn: Binding(get: { host.configuration.experimentalSpaceObservation },
                  set: { host.setExperimentalSpaceObservation($0) })).disabled(!enabled)
            Text("默认只观察当前可见窗口的几何。实验读取仅用于已核验的系统构建。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(16)
    }

    private var modules: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if domains?.candidate == true { AlphaHelp() }
                if let profileImport { profileImport; Divider() }
                Text("按侧栏的播放按钮开始收音，按相同位置暂停。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(host.registry.preferences, id: \.id) { pref in
                    if let manifest = host.registry.manifests.first(where: { $0.id == pref.id }) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle(manifest.name, isOn: Binding(get: { pref.enabled }, set: { host.handle(.setEnabled(pref.id, $0)) }))
                                Spacer()
                                if manifest.kind == .builtin {
                                    Toggle("固定", isOn: Binding(get: { pref.pinned }, set: { host.handle(.setPinned(pref.id, $0)) }))
                                        .fixedSize()
                                    if host.registry.manifests.filter({ $0.kind == .builtin }).count > 1 {
                                        Button { host.handle(.move(pref.id, -1)) } label: { Image(systemName: "arrow.up") }
                                            .accessibilityLabel("Move \(manifest.name) up")
                                        Button { host.handle(.move(pref.id, 1)) } label: { Image(systemName: "arrow.down") }
                                            .accessibilityLabel("Move \(manifest.name) down")
                                    }
                                }
                            }
                            HStack {
                                Text(moduleStatus(host.registry.states[pref.id] ?? .available)).font(.caption).foregroundStyle(.secondary)
                                if host.registry.states[pref.id] == .degraded {
                                    Button("重新启动模块") { host.handle(.setEnabled(pref.id, true)) }
                                }
                            }
                        }
                        Divider()
                    }
                }
                Text(domains?.candidate == true ? "固定时钟后，点击主驻留屏的时间可选择额外时区。" : "语音、托盘和空间的顺序固定。箭头仅调整可选模块。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private func moduleStatus(_ state: ModuleState) -> String {
        switch state {
        case .available: "可启用"
        case .enabling: "正在启动"
        case .permissionRequired: "需要授权"
        case .resident: "已启用"
        case .expanded: "已展开"
        case .suspended: "已暂停"
        case .degraded: "暂不可用"
        case .disabled: "已关闭"
        }
    }

    private var appearance: some View {
        Form {
            Picker("默认停靠边缘", selection: Binding(get: { host.configuration.edge }, set: {
                host.setPlacement(edge: $0, displayID: host.configuration.preferredDisplayID); placementChanged()
            })) {
                ForEach(SurfaceEdge.allCases, id: \.self) { Text($0 == .left ? "左侧" : "右侧").tag($0) }
            }
            Picker("主驻留显示器", selection: Binding(get: { host.configuration.preferredDisplayID ?? "" }, set: {
                host.setPlacement(edge: host.configuration.edge, displayID: $0.isEmpty ? nil : $0); placementChanged()
            })) {
                Text("跟随菜单栏所在屏幕").tag("")
                ForEach(Array(screens.enumerated()), id: \.element.id) { index, screen in
                    Text("显示器 \(index + 1) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))").tag(screen.id)
                }
                if let missing = host.configuration.preferredDisplayID, !screens.contains(where: { $0.id == missing }) {
                    Text("首选显示器暂未连接（已保留选择）").tag(missing)
                }
            }
            Text("主驻留屏默认预留可用宽度的 1/8。拔除首选屏时暂用可用屏，重新连接后恢复选择。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(16)
    }

    private var mockSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Fixture", selection: Binding(get: { host.configuration.fixture }, set: { fixture in
                    Task { await host.selectFixture(fixture) }
                })) { ForEach(DesktopFixture.allCases) { Text($0.label).tag($0) } }
                // Presentation-only preview; selecting it does not feed fixtures to the ordinary Host bus.
                let snapshot = host.configuration.fixture.makeSnapshot()
                Group {
                    Text("\(snapshot.displays.count) synthetic displays (diagnostics only)")
                    Text("Internal scope record counts: \(snapshot.scopes.map { String($0.records.count) }.joined(separator: " + "))")
                    Text("User-facing Space semantics: UNKNOWN. Counts above are internal records, not independent desktops.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Simulated permissions (no macOS prompts)").font(.headline)
                let key = PermissionKey(moduleID: BuiltinCatalog.calendar, permission: .calendarRead)
                HStack {
                    Text("Calendar sample: \(host.permissions.decision(for: key).rawValue)")
                    Button("Grant mock") { host.permissions.setDecision(.granted, for: key) }
                    Button("Revoke mock") { host.permissions.setDecision(.denied, for: key) }
                }
                Text("Enabling a module does not request permissions. Refreshing the Calendar sample checks this simulated grant.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if host.configurationProtected {
                    Text("Configuration could not be read. The original file is protected; this session's changes will not be saved.")
                        .foregroundStyle(.orange)
                } else if host.configurationSaveFailed {
                    Text("Configuration could not be saved. Changes are in memory only.").foregroundStyle(.orange)
                } else { Text("Configuration persistence ready.").font(.caption) }
                Text("Diagnostics: \(host.diagnostics.records.count) bounded local records. No content or desktop identifiers.")
                    .font(.caption)
                ForEach(Array(host.diagnostics.records.suffix(6).enumerated()), id: \.offset) { _, record in
                    Text(record.code.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Space membership is unknown. Switching Spaces and activating windows are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}
