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
        let size: NSSize = page == .fullLyrics ? NSSize(width: 360, height: 520) : page == .settings ? NSSize(width: 450, height: 620) : NSSize(width: 400, height: 450)
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if page == .fullLyrics || page == .candidates { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = page.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(360, size.width), height: 330)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LyricAuxiliaryView(model: model, page: page, close: { [weak self, weak window] in
            window?.close(); self?.model.presentation = nil
        }))
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
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
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
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 64, height: 64)
            Text("歌词，自然在旁。").font(.system(size: 25, weight: .medium))
            Text("播放音乐时，歌词会自动出现在桌面右侧；停止播放后自动收起。鼠标移到歌词板上即可控制播放。")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
            Text("首次连接 Apple Music 或 Spotify 时，macOS 可能请求自动化权限，用于读取歌曲与控制播放。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            Toggle("在线查找歌词", isOn: $model.settings.onlineLyrics).toggleStyle(.checkbox).font(.system(size: 12))
            Text("在线查找会向歌词服务发送歌曲、歌手、专辑和时长，用于匹配歌词。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            Spacer(minLength: 0)
            HStack {
                Button("开始使用") {
                    model.settings.completedWelcome = true
                    close()
                    model.requestShowPanel?()
                }.buttonStyle(.borderedProminent).tint(Color(red: 0.188, green: 0.196, blue: 0.227))
                    .keyboardShortcut(.defaultAction)
                Button("先看看设置") { model.show(.settings) }.buttonStyle(.plain)
            }
        }.padding(30)
    }

    private var settings: some View {
        Form {
            Section("显示") {
                Picker("外观", selection: $model.settings.appearance) {
                    Text("跟随系统").tag(LyricSettings.Appearance.automatic)
                    Text("浅色").tag(LyricSettings.Appearance.light)
                    Text("深色").tag(LyricSettings.Appearance.dark)
                }
                Toggle("大号歌词", isOn: $model.settings.largeText)
                Picker("显示器", selection: Binding(get: { model.settings.preferredDisplayUUID ?? "" }, set: {
                    model.settings.preferredDisplayUUID = $0.isEmpty ? nil : $0
                    model.requestReposition?()
                })) {
                    Text("当前显示器").tag("")
                    ForEach(LyricScreenIdentity.screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                }
                Button("恢复右上角位置") { model.requestReposition?() }
                Toggle("与其他 HOLDSNOW 工具自动排列", isOn: $model.settings.coordinateTiles)
                    .help("与支持自动排列的 HOLDSNOW 工具共享右侧空间")
                Toggle("在全屏时显示", isOn: $model.settings.showInFullScreen)
                Text("播放时自动显示，停止后自动收起。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("播放与歌词") {
                Picker("跟随播放器", selection: Binding(get: { model.settings.preferredPlayer ?? "" }, set: {
                    model.selectPlayer($0.isEmpty ? nil : PlayerID(rawValue: $0))
                })) {
                    Text("自动").tag("")
                    ForEach(PlayerID.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("显示歌词翻译（如有）", isOn: $model.settings.showTranslation)
                Toggle("在线查找歌词", isOn: $model.settings.onlineLyrics)
                Text("在线查找会发送歌曲、歌手、专辑与时长；关闭后仍可使用本地歌词。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("来源与缓存", isExpanded: $sourceExpanded) {
                    HStack {
                        Button("查看当前来源") { model.show(.source) }.disabled(model.document == nil)
                        Button("清理自动缓存") { model.clearCache() }
                    }
                }
            }
            Section("通用") {
                Toggle("登录时启动", isOn: Binding(get: {
                    loginStatus == .enabled || loginStatus == .requiresApproval
                }, set: updateLogin))
                    .disabled(loginBusy || !canManageLoginItem)
                if canManageLoginItem && loginStatus == .requiresApproval {
                    Text("等待系统允许，尚未启用。也可以关闭上方开关取消登录启动。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("在系统设置中允许登录启动") { SMAppService.openSystemSettingsLoginItems() }
                }
                HStack {
                    Text("LyricTile").foregroundStyle(.secondary)
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本")
                        .foregroundStyle(.secondary)
                }
                Button("检查更新…") { model.requestUpdateCheck?() }
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private var candidates: some View {
        VStack(alignment: .leading, spacing: 14) {
            songHeading
            Text("选择与当前录音一致的版本；现场、重录与伴奏版本的时间可能不同。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.isSearchingCandidates {
                HStack { ProgressView().controlSize(.small); Text("正在查找版本…").font(.system(size: 12)) }
            } else if model.candidates.isEmpty {
                ContentUnavailableView("没有找到其他版本", systemImage: "text.magnifyingglass", description: Text("可以重试，或为当前歌曲导入歌词文件。"))
            } else {
                List(model.candidates, id: \.providerRecordID) { candidate in
                    Button { model.choose(candidate) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.recording.title ?? "未命名歌曲").font(.system(size: 13, weight: .medium))
                            Text(candidate.recording.artists.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                Text(candidate.recording.album ?? candidate.providerID)
                                Spacer()
                                Text(LyricPanelView.time(candidate.recording.durationMS))
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                            if candidate.evidence.versionConflict || candidate.evidence.mainArtistConflict {
                                Text("与当前录音信息不同，请核对版本").font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.plain).disabled(model.isResolving)
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
            HStack {
                Button("重新查找") { model.searchCandidates() }.disabled(model.isSearchingCandidates)
                Button("导入歌词…") { model.importLyrics() }
            }
        }.padding(22)
    }
    private var adjustment: some View {
        VStack(alignment: .leading, spacing: 20) {
            songHeading
            Text("只调整当前录音与当前歌词版本。歌词落后时选择提前，歌词过早时选择延后。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            VStack(spacing: 18) {
                Text(model.advanceMS == 0 ? "未调整" : "\(model.advanceMS > 0 ? "提前" : "延后") \(String(format: "%.1f", abs(Double(model.advanceMS)) / 1000)) 秒")
                    .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                HStack(spacing: 15) {
                    Button("延后 0.1 秒") { model.changeAdvance(to: model.advanceMS - 100) }
                    Button("提前 0.1 秒") { model.changeAdvance(to: model.advanceMS + 100) }
                }.disabled(model.document == nil || model.isSavingAdjustment)
                Button("恢复原始时间") { model.changeAdvance(to: 0) }
                    .disabled(model.advanceMS == 0 || model.isSavingAdjustment)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
            Spacer()
            Text("播放器的播放位置不会改变。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(25)
    }
    @ViewBuilder private var source: some View {
        if let document = model.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    songHeading
                    LabeledContent("来源", value: document.source.providerID)
                    LabeledContent("歌词格式", value: document.originalFormat.rawValue)
                    LabeledContent("时间信息", value: document.timingLevel == .token ? "逐字时间" : document.timingLevel == .line ? "逐行时间" : "纯文本")
                    if let credit = document.source.contributorCredit, !credit.isEmpty { LabeledContent("提供者", value: credit) }
                    if let attribution = document.source.rights.attributionText, !attribution.isEmpty { Text(attribution).font(.system(size: 12)) }
                    if let url = document.source.sourceURL { Link("打开来源页面", destination: url) }
                    if let url = document.source.rights.apiEvidenceURL { Link("接口使用条件", destination: url) }
                    if let url = document.source.rights.contentEvidenceURL { Link("内容使用条件", destination: url) }
                    Text("本地绑定与时间调整只应用于当前录音和歌词版本。").font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.textSelection(.enabled)
        } else { ContentUnavailableView("还没有歌词来源", systemImage: "text.badge.questionmark") }
    }
    private var fullLyrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                songHeading
                Spacer()
                Button("回到当前句") { followsCurrentLine = true; model.returnToCurrent() }
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
                                    Button("从这一句播放") { model.seek(to: cue) }
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
            } catch { model.actionMessage = "登录启动未能更新：\(error.localizedDescription)" }
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

