import AppKit
import SwiftUI
import NearpaneCore
import Observation
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

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
        VStack(alignment: .leading, spacing: 14) {
            Text(InstalledBuild(bundle: .main).label).font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("组件信息") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Saytile"); Text(version("saytile")) }
                    GridRow { Text("Riftlet"); Text(version("riftlet")) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .textSelection(.enabled)
    }
}

public struct SettingsView: View {
    private let host: HostSession
    private let navigation: SettingsNavigation
    private let installedBuild = InstalledBuild(bundle: .main)
    private let domains: EmbeddedModules?
    private let moduleSwitches: ModuleSwitchCoordinator
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
        self.moduleSwitches = domains?.moduleSwitches ?? ModuleSwitchCoordinator()
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        GeometryReader { bounds in
            let sidebarWidth = bounds.size.width >= 850 ? 184.0 : 164.0
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarWidth)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.055)).frame(width: 1) }
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .accessibilityIdentifier("main-content-" + navigation.page.rawValue)
                }
                .frame(width: max(0, bounds.size.width - sidebarWidth), height: bounds.size.height)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear {
            if !availablePages.contains(navigation.page) { navigation.showModules() }
        }
        .refreshWindowPermissions()
        .productAccent(host.configuration.accent)
        .frame(minWidth: 740, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .nativeVerificationAccessibility()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(host.configuration.accent.color)
                Text("Nearpane").font(.system(size: 15, weight: .semibold))
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 20)
            VStack(spacing: 4) {
                ForEach(MainWindowSection.allCases) { section in
                    navigationButton(section.title, symbol: section.symbol, selected: navigation.section == section,
                                     identifier: "main-nav-" + section.rawValue) { navigation.select(section) }
                }
            }.padding(.horizontal, 10)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                .padding(.horizontal, 18).padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    switch navigation.section {
                    case .modules:
                        Text("已启用").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.bottom, 7)
                        ForEach(enabledModules) { manifest in
                            navigationButton(ModulePresentation.title(manifest), symbol: manifest.symbol,
                                             selected: navigation.moduleID == manifest.id,
                                             identifier: "main-module-nav-" + manifest.id, compact: true) {
                                navigation.showModule(manifest.id)
                            }
                        }
                        if enabledModules.isEmpty {
                            Text("从模块页选择需要的工具").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                        }
                    case .library:
                        navigationGroup(pages: [.voiceArchive, .screenshotArchive, .memoArchive, .wordArchive])
                    case .settings:
                        navigationGroup(pages: [.general, .dimensions, .displays, .permissions, .data, .app, .diagnostics])
                    }
                }.padding(.horizontal, 10)
            }.accessibilityLabel("Nearpane 页面导航")
            Text(installedBuild.label)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .textSelection(.enabled).padding(18)
                .accessibilityIdentifier("settings-installed-version")
        }
    }

    private var enabledModules: [ModuleManifest] {
        let enabled = host.registry.preferences.filter(\.enabled).compactMap { pref in
            host.registry.manifests.first { $0.id == pref.id }
        }
        return enabled
    }

    private var pageTitle: String {
        if let detail = lyricsDetailTitle { return detail }
        if let id = navigation.moduleID,
           let manifest = host.registry.manifests.first(where: { $0.id == id }) {
            return ModulePresentation.title(manifest)
        }
        return navigation.page.label
    }

    private var lyricsDetailTitle: String? {
        guard navigation.page == .lyrics else { return nil }
        switch navigation.lyricsPage {
        case "fullLyrics": return "完整歌词"
        case "source": return "歌词来源"
        case "adjustment": return "时间校准"
        case "candidates": return "选择歌词"
        default: return nil
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if lyricsDetailTitle != nil {
                    Button { navigation.showLyrics() } label: {
                        Label("歌词", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("main-back-to-lyrics")
                    Text("/").foregroundStyle(.quaternary)
                } else if navigation.moduleID != nil {
                    Button { navigation.showModules() } label: {
                        Label("模块", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("main-back-to-modules")
                    Text("/").foregroundStyle(.quaternary)
                } else if navigation.section != .modules {
                    Text(navigation.section.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("/").foregroundStyle(.quaternary)
                }
                Text(pageTitle).font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                headerAction
            }
            if navigation.moduleID == BuiltinCatalog.desktop {
                Picker("空间调度页面", selection: Binding(get: { navigation.page }, set: { navigation.page = $0 })) {
                    Text("调度").tag(SettingsPage.windowManagement)
                    Text("窗口显示").tag(SettingsPage.desktop)
                    Text("规则").tag(SettingsPage.windowRules)
                }.pickerStyle(.segmented).frame(maxWidth: 340)
                    .accessibilityIdentifier("module-spaces-pages")
            }
            if let id = navigation.moduleID {
                ModuleSwitchNotice(switches: moduleSwitches, id: id, host: host, modules: domains)
            }
            if host.configurationProtected || host.configurationSaveFailed {
                Label(host.configurationProtected ? "无法读取原配置，原文件已保留。" : "设置尚未保存，请检查资料目录。",
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
    }

    @ViewBuilder private var headerAction: some View {
        if let id = navigation.moduleID,
           let preference = host.registry.preferences.first(where: { $0.id == id }) {
            Toggle(preference.enabled ? "已启用" : "启用", isOn: Binding(get: {
                host.registry.preferences.first(where: { $0.id == id })?.enabled == true
            }, set: { value in
                moduleSwitches.setEnabled(id, value, host: host, modules: domains)
            }))
            .toggleStyle(.switch).controlSize(.small).fixedSize()
            .disabled(moduleSwitches.changing.contains(id))
            .accessibilityIdentifier("module-detail-enabled-" + id)
        } else if navigation.page == .voiceArchive {
            Button { navigation.showModule(BuiltinCatalog.voice) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("语音设置").accessibilityLabel("语音设置")
                .accessibilityIdentifier("archive-voice-settings")
        } else if navigation.page == .screenshotArchive {
            Button { navigation.showModule(BuiltinCatalog.screenshots) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("截图设置").accessibilityLabel("截图设置")
                .accessibilityIdentifier("archive-tray-settings")
        }
    }

    @ViewBuilder private func navigationGroup(pages: [SettingsPage]) -> some View {
        ForEach(pages.filter { availablePages.contains($0) }) { page in
            navigationButton(page.label, symbol: page.symbol, selected: navigation.page == page,
                             identifier: "settings-nav-" + page.rawValue, compact: true) { navigation.page = page }
        }
    }

    private func navigationButton(_ title: String, symbol: String, selected: Bool,
                                  identifier: String, compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: compact ? 13 : 15, weight: .medium)).frame(width: 20)
                    .foregroundStyle(selected ? host.configuration.accent.color : .secondary)
                Text(title).font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: compact ? 32 : 38)
            .background(selected ? host.configuration.accent.color.opacity(colorScheme == .dark ? 0.18 : 0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }

    private var availablePages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .voice, .tray, .voiceArchive, .screenshotArchive: return hasDomains
            case .memoArchive, .wordArchive: return domains != nil
            case .tasksArchive: return false
            case .lyrics:
                #if canImport(NearpaneLyricsModule)
                return domains?.lyrics != nil
                #else
                return false
                #endif
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
            if let domains { VoiceArchiveView(module: domains.voice, openSettings: { navigation.showModule(BuiltinCatalog.voice) }).padding(.horizontal, 28).padding(.bottom, 12) }
            #else
            EmptyView()
            #endif
        case .screenshotArchive:
            #if canImport(NearpaneTray)
            if let domains { ScreenshotArchiveView(module: domains.tray, openSettings: { navigation.showModule(BuiltinCatalog.screenshots) }).padding(.horizontal, 28).padding(.bottom, 12) }
            #else
            EmptyView()
            #endif
        case .general: MainWindowGeneralSettings(host: host, menuVisibilityChanged: menuVisibilityChanged)
        case .modules: ModuleManagementView(host: host, modules: domains, switches: moduleSwitches, open: { navigation.showModule($0) })
        case .module: genericModule
        case .lyrics:
            #if canImport(NearpaneLyricsModule)
            if let lyrics = domains?.lyrics {
                HostLyricsManagementView(lyrics: lyrics, page: navigation.lyricsPage)
                    .padding(.horizontal, 28).padding(.bottom, 24)
            }
            #else
            EmptyView()
            #endif
        case .memoArchive, .tasksArchive, .wordArchive:
            if let notebook = domains?.notebook {
                NotebookLibraryView(notebook: notebook, kind: navigation.page == .wordArchive ? .vocabulary : .notes, navigation: navigation)
                    .id(navigation.page)
            }
        case .permissions: permissions
        case .data: dataManagement
        case .voice:
            #if canImport(NearpaneVoice)
            if let domains {
                VStack(alignment: .leading, spacing: 0) {
                    VoiceInputSettings(module: domains.voice)
                    ModuleTextSizeSettings(host: host, screens: screens, scope: .voice, stillCurrent: inventory.contains)
                        .padding(.horizontal, 28).padding(.vertical, 16)
                }
            }
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
                }.formStyle(.grouped)
            }
            #else
            EmptyView()
            #endif
        case .displays: appearance
        case .dimensions:
            WorkspaceDisplaySettings(host: host, screens: screens, request: requestSecondary,
                                     dismiss: dismissSpaces, stillCurrent: inventory.contains)
                .padding(.horizontal, 28).padding(.bottom, 24)
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

    @ViewBuilder private var genericModule: some View {
        if let id = navigation.moduleID,
           let manifest = host.registry.manifests.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(manifest.summary).font(.callout).foregroundStyle(.secondary)
                    if let state = ModulePresentation.status(host.registry.states[id] ?? .available) {
                        HStack {
                            Text(state).font(.callout).foregroundStyle(.secondary)
                            if host.registry.states[id] == .degraded {
                                Button("重新启动") { moduleSwitches.setEnabled(id, true, host: host, modules: domains) }
                            }
                        }
                    }
                    if manifest.kind == .builtin && !BuiltinCatalog.sidebarTools.contains(id), id != BuiltinCatalog.clock,
                       let preference = host.registry.preferences.first(where: { $0.id == id }) {
                        Toggle("显示在侧栏", isOn: Binding(get: {
                            host.registry.preferences.first(where: { $0.id == id })?.pinned == true
                        }, set: { host.handle(.setPinned(id, $0)) }))
                        .toggleStyle(.switch).controlSize(.small).disabled(!preference.enabled)
                    }
                    if id == BuiltinCatalog.clock { ClockDetails(host: host) }
                    if let library = manifest.capabilities.library {
                        Button { openLibrary(library) } label: { Label("在仓库中查看内容", systemImage: "tray.full") }
                    }
                    Text("外观和尺寸沿用 Nearpane 的全局设置。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("外观与布局", action: navigation.showAppearance).font(.callout)
                }.padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func openLibrary(_ library: ModuleLibraryKind) {
        switch library {
        case .voice: navigation.showVoiceArchive()
        case .screenshots: navigation.showScreenshotArchive()
        case .notes: navigation.showNotebookLibrary()
        case .tasks: navigation.showNotebookLibrary("tasks")
        case .vocabulary: navigation.showNotebookLibrary("vocabulary")
        }
    }

    private var permissions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("按使用需要授权。更改系统权限后，Nearpane 会重新读取当前状态。")
                    .font(.callout).foregroundStyle(.secondary)
                WindowAccessSteps(showPictures: true)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 12) {
                    Text("模块权限").font(.system(size: 12, weight: .semibold))
                    if hasDomains {
                        permissionLink("麦克风与语音识别", detail: "语音", module: BuiltinCatalog.voice)
                        permissionLink("截图目录与浏览器附加", detail: "截图", module: BuiltinCatalog.screenshots)
                    }
                    #if canImport(NearpaneLyricsModule)
                    if domains?.lyrics != nil { permissionLink("播放器访问", detail: "歌词", module: BuiltinCatalog.lyrics) }
                    #endif
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    private func permissionLink(_ title: String, detail: String, module: String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Button(detail + "设置") { navigation.showModule(module) }.buttonStyle(.link)
        }
    }

    private var dataManagement: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("语音、截图与随手记保存在当前 Nearpane 资料中。停用模块不会清除这些内容。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开仓库", action: navigation.showLibrary)
                if let profileImport {
                    Divider().opacity(0.5)
                    profileImport
                }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
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
            Section("文字") {
                ModuleTextSizeSettings(host: host, screens: screens, scope: .spaces, stillCurrent: inventory.contains)
            }
        }.formStyle(.grouped)
    }

    private var appearance: some View {
        DisplayPlacementSettings(host: host, screens: screens,
            request: requestSecondary, dismiss: dismissSpaces,
            stillCurrent: inventory.contains, placementChanged: placementChanged)
            .padding(.horizontal, 28).padding(.bottom, 24)
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
