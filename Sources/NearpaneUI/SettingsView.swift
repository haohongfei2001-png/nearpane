import AppKit
import SwiftUI
import NearpaneCore
import Observation
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

enum SettingsPage: String, CaseIterable, Identifiable {
    case voiceArchive, screenshotArchive, general, dimensions, windowManagement, windowRules, displays, desktop, modules, app, voice, tray, diagnostics
    var id: Self { self }
    var label: String {
        switch self {
        case .voiceArchive: "语音档案"
        case .screenshotArchive: "截图档案"
        case .general: "通用"
        case .dimensions: "外观与尺寸"
        case .windowManagement: "窗口管理"
        case .windowRules: "窗口规则"
        case .displays: "显示器"
        case .desktop: "本屏窗口"
        case .voice: "Saytile 语音设置"
        case .tray: "Riftlet 截图设置"
        case .modules: "模块"
        case .app: "应用与更新"
        case .diagnostics: "开发诊断"
        }
    }
    var navigationLabel: String {
        switch self {
        case .voice: "Saytile 语音"
        case .tray: "Riftlet 截图"
        default: label
        }
    }

    var symbol: String {
        switch self {
        case .voiceArchive: "waveform"
        case .screenshotArchive: "photo.on.rectangle.angled"
        case .general: "gearshape"
        case .dimensions: "slider.horizontal.3"
        case .windowManagement: "macwindow.on.rectangle"
        case .windowRules: "list.bullet"
        case .displays: "display"
        case .desktop: "rectangle.3.group"
        case .voice: "mic"
        case .tray: "camera"
        case .modules: "square.grid.2x2"
        case .app: "arrow.triangle.2.circlepath"
        case .diagnostics: "wrench.and.screwdriver"
        }
    }
}

@Observable @MainActor public final class SettingsNavigation {
    #if canImport(NearpaneVoice)
    var page = SettingsPage.voiceArchive
    #else
    var page = SettingsPage.general
    #endif
    public init() {}
    public func showAppearance() { page = .dimensions }
    public func showVoiceArchive() { page = .voiceArchive }
    public func showScreenshotArchive() { page = .screenshotArchive }
    public func showGeneral() { page = .general }
    public func showApplicationServices() { page = .app }
    public func showDesktop() { page = .desktop }
    public func showWindowManagement() { page = .windowManagement }
}

struct InstalledBuild {
    let version, build: String

    init(bundle: Bundle) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }

    var label: String { "版本 " + version + "（" + build + "）" }
}

struct BundledDomainSource: Decodable {
    struct UpstreamBuild: Decodable {
        let version, channel: String
        let build: Int
    }
    let releaseTag: String?
    let upstreamBuild: UpstreamBuild?
    let commit: String

    var label: String {
        if let upstreamBuild {
            let channel = switch upstreamBuild.channel {
            case "internal": "内测"
            case "development": "开发"
            case "beta": "测试"
            case "release": "正式"
            default: upstreamBuild.channel
            }
            return "\(upstreamBuild.version)（\(upstreamBuild.build)，\(channel)） · \(commit.prefix(8))"
        }
        return (releaseTag ?? "源码") + " · " + commit.prefix(8)
    }
}

/// Display the releases actually present in this signed bundle, including when running offline.
public struct BundledDomainVersions: View {
    public init() {}

    private func version(_ name: String) -> String {
        guard let file = Bundle.main.url(forResource: "source", withExtension: "json", subdirectory: "Upstream/" + name),
              let bytes = try? Data(contentsOf: file),
              let source = try? JSONDecoder().decode(BundledDomainSource.self, from: bytes) else { return "版本信息不可用" }
        return source.label
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("Nearpane"); Text(InstalledBuild(bundle: .main).label) }
            GridRow { Text("Saytile"); Text(version("saytile")) }
            GridRow { Text("Riftlet"); Text(version("riftlet")) }
        }
        .textSelection(.enabled)
    }
}

public struct SettingsView: View {
    private let host: HostSession
    private let navigation: SettingsNavigation
    private let installedBuild = InstalledBuild(bundle: .main)
    private let domains: EmbeddedModules?
    private let profileImport: AnyView?
    private let applicationServices: AnyView?
    private let inventory: SettingsScreenInventory
    private let previewExposure: SettingsPreviewExposure
    private var screens: [ScreenGeometry] { inventory.screens }
    private let dismissSpaces: (String) -> Void
    private let requestSecondary: (String) -> Void
    private let menuVisibilityChanged: (Bool) -> Void
    private let placementChanged: () -> Void
    public init(host: HostSession, inventory: SettingsScreenInventory, previewExposure: SettingsPreviewExposure, navigation: SettingsNavigation = SettingsNavigation(), domains: EmbeddedModules? = nil, profileImport: AnyView? = nil, applicationServices: AnyView? = nil, requestSecondary: @escaping (String) -> Void = { _ in }, dismissSpaces: @escaping (String) -> Void = { _ in }, menuVisibilityChanged: @escaping (Bool) -> Void = { _ in }, placementChanged: @escaping () -> Void) {
        self.menuVisibilityChanged = menuVisibilityChanged
        self.navigation = navigation
        self.previewExposure = previewExposure
        self.profileImport = profileImport
        self.applicationServices = applicationServices
        self.dismissSpaces = dismissSpaces
        self.requestSecondary = requestSecondary
        self.domains = domains; self.host = host; self.inventory = inventory; self.placementChanged = placementChanged
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        GeometryReader { bounds in
            let sidebarWidth = bounds.size.width >= 720 ? 168.0 : 152.0
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 2) {
                            navigationGroup("档案", pages: [.voiceArchive, .screenshotArchive])
                            navigationGroup("Nearpane 设置", pages: [.general, .dimensions, .windowManagement, .windowRules, .displays, .desktop, .modules, .app])
                            navigationGroup("模块设置", pages: [.voice, .tray, .diagnostics])
                        }.padding(8)
                    }.accessibilityLabel("Nearpane 导航")
                    Divider()
                    Text(installedBuild.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .accessibilityIdentifier("settings-installed-version")
                }
                .frame(width: sidebarWidth)
                .background {
                    Rectangle().fill(.regularMaterial)
                        .overlay(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.045))
                }
                Divider().frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(navigation.page.label).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if navigation.page == .voiceArchive && availablePages.contains(.voice) {
                            Button { navigation.page = .voice } label: { Label("语音设置", systemImage: "gearshape") }
                                .controlSize(.small)
                                .accessibilityIdentifier("archive-voice-settings")
                        } else if navigation.page == .screenshotArchive {
                            Button { navigation.page = .tray } label: { Label("截图设置", systemImage: "gearshape") }
                                .controlSize(.small)
                                .accessibilityIdentifier("archive-tray-settings")
                        }
                    }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(16)
                .frame(width: max(0, bounds.size.width - sidebarWidth - 1), height: bounds.size.height, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .onAppear {
            if !availablePages.contains(navigation.page) { navigation.showGeneral() }
        }
        .refreshWindowPermissions()
        .productAccent(host.configuration.accent)
        .frame(minWidth: 640, minHeight: 476)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func navigationGroup(_ label: String, pages: [SettingsPage]) -> some View {
        let entries = pages.filter { availablePages.contains($0) }
        if !entries.isEmpty {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
            ForEach(entries) { page in
                let selected = navigation.page == page
                Button { navigation.page = page } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol).frame(width: 18)
                            .foregroundStyle(selected ? host.configuration.accent.color : .secondary)
                        Text(page.navigationLabel)
                            .lineLimit(1).fontWeight(selected ? .medium : .regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).frame(height: 28)
                    .background(selected ? host.configuration.accent.color.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings-nav-" + page.rawValue)
            }
        }
    }

    private var availablePages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .voice: return hasDomains && domains?.candidate == true
            case .tray, .voiceArchive, .screenshotArchive: return hasDomains
            case .diagnostics: return domains?.candidate != true
            case .app: return applicationServices != nil
            default: return true
            }
        }
    }

    private var hasDomains: Bool {
        #if canImport(NearpaneVoice)
        domains != nil
        #else
        false
        #endif
    }

    @ViewBuilder private var content: some View {
        switch navigation.page {
        case .voiceArchive:
            #if canImport(NearpaneVoice)
            if let domains { VoiceArchiveView(module: domains.voice, openSettings: { navigation.page = .voice }) }
            #else
            EmptyView()
            #endif
        case .screenshotArchive:
            #if canImport(NearpaneTray)
            if let domains { ScreenshotArchiveView(module: domains.tray, openSettings: { navigation.page = .tray }) }
            #else
            EmptyView()
            #endif
        case .general: general
        case .modules: modules
        case .voice:
            #if canImport(NearpaneVoice)
            if let domains { VoiceInputSettings(module: domains.voice) }
            #else
            EmptyView()
            #endif
        case .tray:
            #if canImport(NearpaneTray)
            if let tray = domains?.tray {
                Form {
                    Text(domains?.candidate == true ? "收录的截图保存在 Nearpane 的截图档案。" : "使用已有的 Riftlet 资料库。连接期间由 Nearpane 独占；断开后原库仍由 Riftlet 使用。")
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
                            if tray.mayAttach {
                                LabeledContent("草稿附加", value: "已启用")
                            }
                            if tray.productAttachments {
                                Menu(tray.mayAttach ? "检查浏览器权限" : "允许附加到浏览器草稿…") {
                                    Button("Google Chrome") { Task { await tray.authorizeAttachments(in: .chrome) } }
                                    Button("Microsoft Edge") { Task { await tray.authorizeAttachments(in: .edge) } }
                                }
                            } else if !tray.mayAttach {
                                Button(tray.savedAttachmentConsent ? "重新核对草稿附加" : "允许附加到当前浏览器草稿…") {
                                    Task { await tray.authorizeAttachments() }
                                }
                            }
                            if tray.productAttachments && tray.savedAttachmentConsent {
                                Button("关闭草稿附加") { Task { await tray.disableAttachments() } }
                            }
                            if let notice = tray.attachmentAccessNotice { Text(notice).foregroundStyle(.secondary) }
                            if let feedback = tray.attachmentFeedback { Text(feedback).font(.callout) }
                            Text("在 Chrome 或 Microsoft Edge 中打开目标 ChatGPT 草稿后点击缩略图。Nearpane 只附加截图，结果待核对时会保留原操作。")
                        } else { Text("当前仅收录截图。附加到草稿须使用已绑定的专用测试会话。") }
                    } else {
                        Button(tray.connecting ? "正在连接…" : (domains?.candidate == true ? "重新连接截图托盘" : "连接已有 Riftlet 资料库")) {
                            Task {
                                await tray.connect()
                                if domains?.candidate == true && tray.connected { host.setCandidateTrayConnected(true) }
                            }
                        }.disabled(!tray.active || tray.connecting)
                    }
                    if let issue = tray.issue { Text(issue).foregroundStyle(.secondary) }
                }.padding()
            }
            #else
            EmptyView()
            #endif
        case .displays: appearance
        case .dimensions:
            WorkspaceDisplaySettings(host: host, screens: screens, request: requestSecondary,
                                     dismiss: dismissSpaces, stillCurrent: inventory.contains,
                                     previewExposure: previewExposure)
        case .windowRules: WorkspacePolicySettings(host: host, showWindowManagement: navigation.showWindowManagement)
        case .windowManagement:
            if let manager = domains?.workRect {
                CandidateWorkRectView(session: manager, host: host, previewExposure: previewExposure)
                    .environment(domains?.windowPreviews)
            } else {
                Text("此版本未包含窗口管理。请打开已安装的 Nearpane。")
                    .accessibilityIdentifier("settings-window-manager-unavailable")
            }
        case .desktop: desktopOptions
        case .app: applicationServices
        case .diagnostics: mockSettings
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccentSettings(host: host)
            Divider()
            if domains?.workRect != nil {
                Button("打开窗口管理…") { navigation.showWindowManagement() }
                    .accessibilityIdentifier("settings-general-window-management")
            }
            Toggle("在菜单栏显示 Nearpane", isOn: Binding(get: {
                host.configuration.showsMenuBarIcon
            }, set: { visible in
                if host.setShowsMenuBarIcon(visible) { menuVisibilityChanged(visible) }
            }))
            .accessibilityIdentifier("settings-menu-bar-icon")
            Text("隐藏图标后，双击 Finder 中的 Nearpane 即可打开此窗口。")
                .font(.callout).foregroundStyle(.secondary)
            if host.configurationSaveFailed {
                Text("设置未能保存，请检查资料目录后再试。").foregroundStyle(.secondary)
            }
            if !host.configuration.showsMenuBarIcon {
                Button("退出 Nearpane") { NSApp.terminate(nil) }
                    .accessibilityIdentifier("settings-quit-nearpane")
            }
        }.padding(.top, 8)
    }

    private var desktopOptions: some View {
        Form {
            DesktopItemsSettingsSection()
            Picker("窗口总览快捷键", selection: Binding(get: { host.configuration.overviewShortcut }, set: { choice in
                if host.setOverviewShortcut(choice) { DesktopOverviewShortcut.shared.configure(choice) }
            })) {
                Text("Nearpane　⌃⌥⌘↑").tag(OverviewShortcutChoice.nearpane)
                Text("使用 ⌃↑").tag(OverviewShortcutChoice.controlUp)
                Text("仅从菜单打开").tag(OverviewShortcutChoice.off)
            }
            if !DesktopOverviewShortcut.shared.status.isEmpty {
                Text(DesktopOverviewShortcut.shared.status).font(.caption)
            }
            if host.configuration.overviewShortcut != .off {
                Button("重新注册快捷键") { DesktopOverviewShortcut.shared.configure(host.configuration.overviewShortcut) }
            }
            let enabled = host.registry.preferences.first(where: { $0.id == BuiltinCatalog.desktop })?.enabled == true
            Toggle("显示本屏窗口", isOn: Binding(get: { enabled }, set: {
                if !$0 { domains?.stopWindowContentPreview() }
                host.handle(.setEnabled(BuiltinCatalog.desktop, $0))
            }))
            Toggle("显示当前桌面的窗口缩略图", isOn: Binding(get: { host.configuration.showsWindowThumbnails }, set: { show in
                host.setWindowThumbnails(show)
                if !show { domains?.windowPreviews.gallery.clear() }
            })).disabled(!enabled)
            Text("本屏窗口按比例显示，组合卡保留组内窗口的相对位置。点击成员可将该窗口置前。")
                .font(.caption).foregroundStyle(.secondary)
            if enabled { WindowAccessSteps(showPictures: host.configuration.showsWindowThumbnails) }
            Toggle("识别窗口所属桌面（实验性）", isOn: Binding(get: { host.configuration.experimentalSpaceObservation },
                  set: { host.setExperimentalSpaceObservation($0) })).disabled(!enabled)
            if #available(macOS 15.2, *), let previews = domains?.windowPreviews {
                HStack {
                    Button("选择窗口并拍摄预览…") { previews.choose(host: host) }
                        .disabled(!enabled || previews.choosing || previews.visibleDisplays.isEmpty || host.configuration.surfaceHidden)
                    if previews.active {
                        Button("清除预览") { previews.clear() }
                    }
                }
                if !previews.notice.isEmpty {
                    Text(previews.notice).font(.caption).foregroundStyle(.secondary)
                } else if !enabled {
                    Text("启用「显示本屏窗口」后可选择窗口。").font(.caption).foregroundStyle(.secondary)
                } else if previews.visibleDisplays.isEmpty || host.configuration.surfaceHidden {
                    Text("先显示并展开含空间预览的侧栏，再选择窗口。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("由系统选择器指定一扇窗口。快照仅在内存中保留一分钟。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("未取得画面权限时，侧栏显示应用与窗口轮廓。")
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
                if let notebook = domains?.notebook {
                    WordbookSection(notebook: notebook).id(ObjectIdentifier(notebook))
                }
                ForEach(host.registry.preferences, id: \.id) { pref in
                    if let manifest = host.registry.manifests.first(where: { $0.id == pref.id }) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle(manifest.name, isOn: Binding(get: { pref.enabled }, set: { host.handle(.setEnabled(pref.id, $0)) }))
                                    .accessibilityIdentifier("module-enabled-" + pref.id)
                                Spacer()
                                if manifest.kind == .builtin && !BuiltinCatalog.sidebarTools.contains(pref.id) {
                                    Toggle("固定", isOn: Binding(get: { pref.pinned }, set: { host.handle(.setPinned(pref.id, $0)) }))
                                        .fixedSize()
                                }
                                if manifest.kind == .builtin || BuiltinCatalog.sidebarTools.contains(pref.id) {
                                        Button { host.handle(.move(pref.id, -1)) } label: { Image(systemName: "arrow.up") }
                                            .accessibilityLabel("Move \(manifest.name) up").accessibilityIdentifier("module-up-" + pref.id)
                                        Button { host.handle(.move(pref.id, 1)) } label: { Image(systemName: "arrow.down") }
                                            .accessibilityLabel("Move \(manifest.name) down").accessibilityIdentifier("module-down-" + pref.id)
                                }
                            }
                            #if canImport(NearpaneLyricsModule)
                            if pref.id == BuiltinCatalog.lyrics, pref.enabled, let lyrics = domains?.lyrics {
                                HostLyricsSettings(lyrics: lyrics, model: lyrics.module.model)
                            }
                            #endif
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
                Text(domains?.candidate == true ? "固定时钟后，点击主驻留屏的时间可选择额外时区。" : "使用箭头调整工具顺序。窗口和桌面显示在工具下方。")
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
