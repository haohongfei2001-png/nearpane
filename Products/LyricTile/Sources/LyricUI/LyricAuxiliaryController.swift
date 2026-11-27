import AppKit
import Combine
import LyricCore
import LyricPlayback
import ServiceManagement
import SwiftUI

@MainActor
public final class LyricAuxiliaryController: NSObject, NSWindowDelegate {
    private let model: LyricAppModel
    private var windows: [LyricAuxiliaryPage: NSWindow] = [:]
    private var subscription: AnyCancellable?
    public var anchorFrame: (@MainActor () -> NSRect?)?

    public init(model: LyricAppModel) {
        self.model = model
        super.init()
        subscription = model.$presentation.compactMap { $0 }.sink { [weak self] page in self?.show(page) }
    }
    public func show(_ page: LyricAuxiliaryPage) {
        if let existing = windows[page] {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let size: NSSize
        switch page {
        case .fullLyrics: size = NSSize(width: 360, height: 520)
        case .settings: size = NSSize(width: 450, height: 620)
        case .welcome: size = NSSize(width: 400, height: 360)
        default: size = NSSize(width: 400, height: 450)
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if page == .fullLyrics || page == .candidates { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = page.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(360, size.width), height: 330)
        window.delegate = self
        let hosting = NSHostingView(rootView: LyricAuxiliaryView(model: model, page: page, close: { [weak self, weak window] in
            window?.close(); self?.model.presentation = nil
        }))
        // AppKit owns these window sizes. The default hosting sizing options
        // propagate SwiftUI's unconstrained minimum-size measurement back to
        // NSWindow. The wrapped welcome text can then enlarge a 360 pt window
        // to more than 2,000 pt before its actual 400 pt width is proposed.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        if !style.contains(.resizable) {
            window.contentMinSize = size
            window.contentMaxSize = size
        }
        window.setContentSize(size)
        if let anchor = anchorFrame?(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let available = screen.visibleFrame
            let x = max(available.minX + 12, min(anchor.minX - size.width - 12, available.maxX - size.width - 12))
            let y = max(available.minY + 12, min(anchor.maxY - size.height, available.maxY - size.height - 12))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else { window.center() }
        windows[page] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    public func closeAll() {
        let existing = Array(windows.values)
        windows.removeAll()
        for window in existing { window.close() }
        model.presentation = nil
    }
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let page = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: page)
        if model.presentation == page { model.presentation = nil }
    }
}

private struct LyricAuxiliaryView: View {
    @ObservedObject var model: LyricAppModel
    let page: LyricAuxiliaryPage
    let close: () -> Void
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginBusy = false
    @State private var sourceExpanded = false
    @State private var positionExpanded = false
    @State private var followsCurrentLine = true

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .welcome: welcome
            case .settings: settings
            case .candidates: candidates
            case .adjustment: adjustment
            case .source: source
            case .fullLyrics: fullLyrics
            }
            if let message = model.actionMessage {
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.actionMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(localized("关闭提示", "Dismiss message"))
                }
                .padding(12).background(Color.secondary.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // System Settings can approve or revoke the service while this window
            // stays open. Always show the system's current state when returning.
            refreshLoginStatus()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 44, height: 44)
                Text(localized("歌词，自然在旁。", "Lyrics, right beside you.")).font(.system(size: 23, weight: .medium))
            }
            .background(LyricAuxiliaryLayoutMarker(id: "welcome-heading"))
            HStack(alignment: .center, spacing: 16) {
                // A labelled static design preview, never a fabricated player or lyric session.
                VStack(spacing: 5) {
                    VStack(spacing: 7) {
                        Text(localized("风经过长街", "Wind along the street")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(localized("让这一刻慢下来", "A moment, held")).font(.system(size: 14, weight: .semibold))
                        Text(localized("灯在街角亮起", "The corner lights up")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 136, height: 80)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    }
                    Text(localized("界面示意", "Interface preview")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Text(localized("播放时自动出现，停止时自动收起。鼠标移入即可查看歌曲和控制播放。", "Appears while music plays. Hover for song details and playback controls."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(LyricAuxiliaryLayoutMarker(id: "welcome-preview"))
            VStack(alignment: .leading, spacing: 5) {
                Toggle(localized("在线查找歌词", "Find lyrics online"), isOn: $model.settings.onlineLyrics)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Text(localized("查找时会向歌词服务发送歌名、歌手、专辑和时长。关闭后仍可在菜单栏导入本地歌词。", "Sends title, artist, album and duration to the lyrics service. You can also import local lyrics."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(LyricAuxiliaryLayoutMarker(id: "welcome-privacy"))
            Text(localized("Apple Music 与 Spotify 首次连接时可能请求自动化权限，用于读取歌曲与控制播放。", "Apple Music and Spotify may ask for Automation access to read and control playback."))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .background(LyricAuxiliaryLayoutMarker(id: "welcome-permission"))
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(localized("开始使用", "Get started")) {
                    model.settings.completedWelcome = true
                    close()
                    model.requestShowPanel?()
                }.buttonStyle(.borderedProminent).tint(Color(red: 0.188, green: 0.196, blue: 0.227))
                    .keyboardShortcut(.defaultAction)
                Button(localized("打开设置", "Open Settings")) { model.show(.settings) }.buttonStyle(.plain)
            }
            .background(LyricAuxiliaryLayoutMarker(id: "welcome-actions"))
        }.padding(24)
    }

    private var settings: some View {
        Form {
            Section(localized("外观", "Appearance")) {
                Picker(localized("配色", "Theme"), selection: $model.settings.appearance) {
                    Text(localized("跟随系统", "System")).tag(LyricSettings.Appearance.automatic)
                    Text(localized("浅色", "Light")).tag(LyricSettings.Appearance.light)
                    Text(localized("深色", "Dark")).tag(LyricSettings.Appearance.dark)
                }
                Toggle(localized("大号歌词", "Larger lyrics"), isOn: $model.settings.largeText)
                Toggle(localized("在全屏时显示", "Show over full-screen apps"), isOn: $model.settings.showInFullScreen)
                Text(localized("播放时自动显示，不播放时自动收起。", "Appears during playback and hides when playback stops."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("播放与歌词", "Playback and lyrics")) {
                Picker(localized("跟随播放器", "Player"), selection: Binding(get: { model.settings.preferredPlayer ?? "" }, set: {
                    model.selectPlayer($0.isEmpty ? nil : PlayerID(rawValue: $0))
                })) {
                    Text(localized("自动", "Automatic")).tag("")
                    ForEach(PlayerID.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle(localized("显示歌词翻译（如有）", "Show translations when available"), isOn: $model.settings.showTranslation)
                Toggle(localized("在线查找歌词", "Find lyrics online"), isOn: $model.settings.onlineLyrics)
                Text(localized("在线查找会发送歌曲、歌手、专辑与时长；关闭后仍可使用本地歌词。", "Online lookup sends title, artist, album and duration. Local lyrics remain available when disabled."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(localized("来源与缓存", "Source and cache"), isExpanded: $sourceExpanded) {
                    HStack {
                        Button(localized("查看当前来源", "View current source")) { model.show(.source) }.disabled(model.document == nil)
                        Button(localized("清理自动缓存", "Clear online cache")) { model.clearCache() }
                    }
                }
            }
            Section(localized("通用", "General")) {
                Toggle(localized("登录时启动", "Open at login"), isOn: Binding(get: {
                    loginStatus == .enabled || loginStatus == .requiresApproval
                }, set: updateLogin))
                    .disabled(loginBusy || !canManageLoginItem)
                if canManageLoginItem && loginStatus == .requiresApproval {
                    Text(localized("等待系统允许，尚未启用。也可以关闭上方开关取消登录启动。", "Waiting for system approval. Turn the switch off to cancel."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(localized("在系统设置中允许登录启动", "Allow in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                DisclosureGroup(localized("桌面位置", "Desktop position"), isExpanded: $positionExpanded) {
                    Picker(localized("显示器", "Display"), selection: Binding(get: { model.settings.preferredDisplayUUID ?? "" }, set: {
                        model.settings.preferredDisplayUUID = $0.isEmpty ? nil : $0
                        model.requestReposition?()
                    })) {
                        Text(localized("当前显示器", "Current display")).tag("")
                        ForEach(LyricScreenIdentity.screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                    }
                    Toggle(localized("与其他 HOLDSNOW 工具自动排列", "Arrange with other HOLDSNOW tools"), isOn: $model.settings.coordinateTiles)
                        .help(localized("与支持自动排列的 HOLDSNOW 工具共享右侧空间", "Share the right edge with compatible HOLDSNOW tools"))
                    Button(localized("恢复右上角位置", "Reset to top right")) { model.requestReposition?() }
                }
                HStack {
                    Text("LyricTile").foregroundStyle(.secondary)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? localized("开发版本", "Development build"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button(localized("检查更新…", "Check for Updates…")) { model.requestUpdateCheck?() }
                }
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private var candidates: some View {
        VStack(alignment: .leading, spacing: 14) {
            songHeading
            Text(localized("选择与当前录音一致的版本；现场、重录与伴奏版本的时间可能不同。", "Choose the same recording. Live, re-recorded and instrumental versions may have different timing."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.isSearchingCandidates {
                HStack { ProgressView().controlSize(.small); Text(localized("正在查找版本…", "Finding versions…")).font(.system(size: 12)) }
            } else if model.candidates.isEmpty {
                ContentUnavailableView(localized("没有找到其他版本", "No other versions found"), systemImage: "text.magnifyingglass", description: Text(localized("可以重试，或为当前歌曲导入歌词文件。", "Try again or import a lyric file for this song.")))
            } else {
                List(model.candidates, id: \.providerRecordID) { candidate in
                    Button { model.choose(candidate) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.recording.title ?? localized("未命名歌曲", "Untitled track")).font(.system(size: 13, weight: .medium))
                            Text(candidate.recording.artists.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                Text(candidate.recording.album ?? candidate.providerID)
                                Spacer()
                                Text(LyricPanelView.time(candidate.recording.durationMS))
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                            if candidate.evidence.versionConflict || candidate.evidence.mainArtistConflict {
                                Text(localized("与当前录音信息不同，请核对版本", "Recording details differ. Check this version.")).font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.plain).disabled(model.isResolving)
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
            HStack {
                Button(localized("重新查找", "Search again")) { model.searchCandidates() }.disabled(model.isSearchingCandidates)
                Button(localized("导入歌词…", "Import lyrics…")) { model.importLyrics() }
            }
        }.padding(22)
    }
    private var adjustment: some View {
        VStack(alignment: .leading, spacing: 20) {
            songHeading
            Text(localized("只调整当前录音与当前歌词版本。歌词落后时选择提前，歌词过早时选择延后。", "Adjust this recording and lyric version only. Move late lyrics earlier, or early lyrics later."))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            VStack(spacing: 18) {
                Text(adjustmentDescription)
                    .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                HStack(spacing: 15) {
                    Button(localized("延后 0.1 秒", "Later by 0.1 s")) { model.changeAdvance(to: model.advanceMS - 100) }
                    Button(localized("提前 0.1 秒", "Earlier by 0.1 s")) { model.changeAdvance(to: model.advanceMS + 100) }
                }.disabled(model.document == nil || model.isSavingAdjustment)
                Button(localized("恢复原始时间", "Reset timing")) { model.changeAdvance(to: 0) }
                    .disabled(model.advanceMS == 0 || model.isSavingAdjustment)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
            Spacer()
            Text(localized("播放器的播放位置不会改变。", "The player’s playback position stays unchanged.")).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(25)
    }
    @ViewBuilder private var source: some View {
        if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    songHeading
                    LabeledContent(localized("来源", "Source"), value: document.source.providerID)
                    LabeledContent(localized("歌词格式", "Format"), value: document.originalFormat.rawValue)
                    LabeledContent(localized("时间信息", "Timing"), value: document.timingLevel == .token ? localized("逐字时间", "Word timing") : document.timingLevel == .line ? localized("逐行时间", "Line timing") : localized("纯文本", "Plain text"))
                    if let credit = document.source.contributorCredit, !credit.isEmpty { LabeledContent(localized("提供者", "Contributor"), value: credit) }
                    if let attribution = document.source.rights.attributionText, !attribution.isEmpty { Text(attribution).font(.system(size: 12)) }
                    if let url = document.source.sourceURL { Link(localized("打开来源页面", "Open source page"), destination: url) }
                    if let url = document.source.rights.apiEvidenceURL { Link(localized("接口使用条件", "API terms"), destination: url) }
                    if let url = document.source.rights.contentEvidenceURL { Link(localized("内容使用条件", "Content terms"), destination: url) }
                    Text(localized("本地绑定与时间调整只应用于当前录音和歌词版本。", "Local bindings and timing adjustments apply only to this recording and lyric version.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.textSelection(.enabled)
        } else { ContentUnavailableView(localized("还没有歌词来源", "No lyric source yet"), systemImage: "text.badge.questionmark") }
    }
    private var fullLyrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                songHeading
                Spacer()
                Button(localized("回到当前句", "Current line")) { followsCurrentLine = true; model.returnToCurrent() }
                    .font(.system(size: 11)).disabled(model.document?.timingLevel == .some(.none))
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.leadCues, id: \.id) { cue in
                            Text(cue.text).font(.system(size: 18, weight: model.currentCue?.id == cue.id ? .medium : .regular))
                                .foregroundStyle(model.currentCue?.id == cue.id ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled).id(cue.id)
                                .contextMenu {
                                    Button(localized("从这一句播放", "Play from this line")) { model.seek(to: cue) }
                                        .disabled(!model.canSeek || cue.sourceStartMS == nil)
                                }
                        }
                    }.padding(22)
                        .background(LyricLiveScrollObserver { followsCurrentLine = false })
                }
                .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in followsCurrentLine = false })
                .onChange(of: model.currentCue?.id) { _, id in
                    if followsCurrentLine, let id { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: followsCurrentLine) { _, follows in
                    if follows, let id = model.currentCue?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
    private var songHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.title).font(.system(size: 17, weight: .medium)).lineLimit(2)
            if !model.artist.isEmpty { Text(model.artist).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    private var adjustmentDescription: String {
        guard model.advanceMS != 0 else { return localized("未调整", "No adjustment") }
        let seconds = String(format: "%.1f", abs(Double(model.advanceMS)) / 1000)
        return model.advanceMS > 0
            ? localized("提前 \(seconds) 秒", "Earlier by \(seconds) s")
            : localized("延后 \(seconds) 秒", "Later by \(seconds) s")
    }
    private var canManageLoginItem: Bool {
        // The reusable lyrics UI must never register its Nearpane host as LyricTile.
        Bundle.main.bundleIdentifier == "com.holdsnow.lyrictile" && Bundle.main.bundleURL.pathExtension == "app"
    }
    private func refreshLoginStatus() {
        guard !loginBusy else { return }
        loginStatus = SMAppService.mainApp.status
    }
    private func updateLogin(_ enabled: Bool) {
        guard canManageLoginItem, !loginBusy else { return }
        loginStatus = SMAppService.mainApp.status
        let registered = loginStatus == .enabled || loginStatus == .requiresApproval
        guard enabled != registered else { return }
        loginBusy = true
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        SMAppService.mainApp.unregister { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
            } catch { model.actionMessage = localized("登录启动未能更新：\(error.localizedDescription)", "Could not update Open at Login: \(error.localizedDescription)") }
            loginStatus = SMAppService.mainApp.status
            loginBusy = false
        }
    }
}

private struct LyricLiveScrollObserver: NSViewRepresentable {
    let onScroll: @MainActor () -> Void
    func makeNSView(context: Context) -> LyricScrollProbe { LyricScrollProbe(onScroll: onScroll) }
    func updateNSView(_ view: LyricScrollProbe, context: Context) { view.onScroll = onScroll; view.attach() }
    static func dismantleNSView(_ view: LyricScrollProbe, coordinator: ()) { view.detach() }
}
@MainActor
private final class LyricScrollProbe: NSView {
    var onScroll: @MainActor () -> Void
    private weak var observedScrollView: NSScrollView?
    init(onScroll: @escaping @MainActor () -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func attach() {
        guard let scroll = enclosingScrollView, scroll !== observedScrollView else { return }
        detach(); observedScrollView = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    }
    func detach() { NotificationCenter.default.removeObserver(self); observedScrollView = nil }
    @objc private func didScroll(_ notification: Notification) { onScroll() }
}

@MainActor
public enum LyricScreenIdentity {
    public struct Display: Identifiable { public let id: String; public let name: String; public let screen: NSScreen }
    public static var screens: [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return Display(id: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName, screen: screen)
        }
    }
    public static func id(for screen: NSScreen) -> String? { screens.first { $0.screen === screen }?.id }
}


private func localized(_ chinese: String, _ english: String) -> String {
    LyricLocalization.text(chinese, english)
}
