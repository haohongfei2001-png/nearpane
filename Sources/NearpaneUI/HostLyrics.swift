#if canImport(NearpaneLyricsModule)
import AppKit
import Combine
import Foundation
import LyricPlayback
import LyricCore
import LyricUI
import NearpaneCore
import NearpaneLyricsModule
import Observation
import SwiftUI

/// One resident lyric session per Host, not a separate app or NSPanel.
@Observable @MainActor
final class HostLyrics: HostModule {
    let module: NearpaneLyricsModule
    private(set) var height: Double = 0
    private(set) var status = "等待播放音乐"
    private(set) var requested = false
    var openingFailed: (() -> Void)?
    @ObservationIgnored var requestManagementPage: ((String) -> Void)?
    private let verificationOnly: Bool
    @ObservationIgnored var heightDidChange: (() -> Void)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var mountedSurfaces = Set<UUID>()
    private var mounted: Bool { !mountedSurfaces.isEmpty }
    @ObservationIgnored private var hostHidden = true
    @ObservationIgnored private var policy = LyricPanelVisibilityPolicy()

    init(directory: URL, verificationOnly: Bool = false) {
        #if DEBUG
        self.verificationOnly = verificationOnly
        #else
        self.verificationOnly = false
        #endif
        module = NearpaneLyricsModule(storageURL: directory)
        module.openManagementPage = { [weak self] page in self?.requestManagementPage?(page.rawValue) }
        module.model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        module.$isPresented.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
    }

    func start() throws {
        requested = true; status = "正在连接播放器"
        if verificationOnly { refresh() } else { reconcile() }
    }
    func stop() {
        requested = false
        status = "已停用"
        let changed = height != 0
        height = 0
        updateVisibility()
        if changed { heightDidChange?() }
        if !verificationOnly { reconcile() }
    }
    func suspend() { stop() }
    func resume() throws { try start() }
    func perform(_ action: ModuleAction) throws {}
    func snapshot() throws -> ModuleProjection { .init(message: status) }
    func finishStopping() async { stop(); await worker?.value }

    private func reconcile() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { worker = nil }
            while true {
                if requested {
                    let acquired = await module.activate(takingOverStandalone: true)
                    if !requested { continue }
                    if !acquired {
                        status = module.model.ownershipMessage ?? "无法启动歌词模块"
                        openingFailed?()
                        return
                    }
                    refresh()
                    return
                }
                _ = await module.deactivate()
                policy = LyricPanelVisibilityPolicy()
                refresh()
                if !requested { return }
            }
        }
    }

    func setMounted(_ mounted: Bool, surface: UUID) {
        if mounted { mountedSurfaces.insert(surface) } else { mountedSurfaces.remove(surface) }
        updateVisibility()
        scheduleRefresh()
    }
    func setHostHidden(_ hidden: Bool) {
        hostHidden = hidden
        if hidden {
            module.model.panelInteractionActive = false
            module.model.setControlsVisible(false)
        }
        updateVisibility()
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingRefresh = false
            refresh()
        }
    }
    private func refresh() {
        let model = module.model
        let interacting = !hostHidden && mounted &&
            (model.panelInteractionActive || model.songMenuIsOpen || model.seekPreviewMS != nil)
        let visible = requested && module.isPresented && (model.ownsSession || verificationOnly) &&
            policy.shouldPresent(model.snapshot, wasVisible: height > 0 && mounted && !hostHidden, isInteracting: interacting)
        let next = visible ? Double(model.panelContent == .lyrics ? LyricPanelLayout.lyricsHeight : LyricPanelLayout.compactHeight) : 0
        let changed = height != next
        if changed { height = next }
        let nextStatus: String
        if !requested { nextStatus = "已停用" }
        else if !module.isPresented { nextStatus = model.ownershipMessage ?? "等待歌词会话" }
        else if model.snapshot.requiresAuthorization { nextStatus = "需要允许播放器自动化权限" }
        else if model.snapshot.state == .paused && visible { nextStatus = "已暂停 · 可在侧栏继续播放" }
        else { nextStatus = model.snapshot.statusMessage ?? (visible ? "正在跟随播放器" : "播放音乐时自动显示") }
        if status != nextStatus { status = nextStatus }
        updateVisibility()
        if changed { heightDidChange?() }
        if requested && !module.isPresented && worker == nil && !verificationOnly {
            // Another client explicitly took the shared session. Do not ping-pong.
            openingFailed?()
        }
    }
    #if DEBUG
    func installVerificationSnapshot(_ snapshot: PlaybackSnapshot, document: LyricDomain.Document? = nil) -> Bool {
        guard verificationOnly else { return false }
        module.installVerificationSnapshot(snapshot, document: document)
        refresh()
        return true
    }

    func clearVerificationControls() -> Bool {
        guard verificationOnly, !module.model.ownsSession else { return false }
        module.model.setControlsVisible(false)
        return true
    }
    #endif

    private func updateVisibility() {
        let visible = requested && height > 0 && mounted && !hostHidden && module.isPresented
        if module.model.isVisible != visible { module.model.isVisible = visible }
    }
}

struct HostLyricsCard: View {
    let lyrics: HostLyrics
    @State private var surfaceID = UUID()
    var body: some View {
        lyrics.module.view
            .accessibilityIdentifier("nearpane-lyrics-card")
            .onAppear { lyrics.setMounted(true, surface: surfaceID) }
            .onDisappear { lyrics.setMounted(false, surface: surfaceID) }
    }
}

/// Host settings only: no independent startup, update, position or panel settings.
struct HostLyricsSettings: View {
    let lyrics: HostLyrics
    @ObservedObject var model: LyricAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lyrics.status).font(.caption).foregroundStyle(.secondary)
            Picker("跟随播放器", selection: Binding(get: { model.settings.preferredPlayer }, set: {
                model.selectPlayer($0.flatMap(PlayerID.init(rawValue:)))
            })) {
                Text("自动").tag(String?.none)
                ForEach(PlayerID.allCases, id: \.self) { player in
                    Text(player.displayName).tag(Optional(player.rawValue))
                }
            }
            Toggle("在线查找歌词", isOn: $model.settings.onlineLyrics)
            Text("在线查找会向 LRCLIB 发送歌曲名、歌手、专辑和时长。关闭后仍可导入本地歌词。")
                .font(.caption).foregroundStyle(.secondary)
            Text("歌曲暂停时保留歌词和播放控制；播放器退出后自动收起。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("大号歌词", isOn: $model.settings.largeText)
            Toggle("显示歌词翻译（如有）", isOn: $model.settings.showTranslation)
            if model.snapshot.requiresAuthorization {
                Button("允许访问播放器…") { model.openAutomationSettings() }
            }
            HStack {
                Button("完整歌词") { model.show(.fullLyrics) }.disabled(model.document == nil)
                Button("歌词来源") { model.show(.source) }.disabled(model.document == nil)
                Button("时间校准") { model.show(.adjustment) }.disabled(model.document == nil)
            }
            if model.ownsSession {
                Button("选择其他歌词版本") { model.show(.candidates) }.disabled(model.snapshot.selection == nil)
                Button("重新连接") { model.reconnect() }
                Button("为当前歌曲导入歌词…") { model.importLyrics() }
                    .disabled(model.snapshot.selection == nil)
            }
            DisclosureGroup("歌词缓存") {
                Text("自动缓存仅用于加快歌词匹配，不属于内容仓库。清理后仍保留已绑定的本地歌词。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清理自动缓存") { model.clearCache() }
            }
            if let message = model.actionMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("nearpane-lyrics-settings")
    }
}

/// All lyric management content stays inside the Host's existing main window.
struct HostLyricsManagementView: View {
    let lyrics: HostLyrics
    let page: String
    var body: some View {
        let destination = LyricAuxiliaryPage(rawValue: page) ?? .settings
        if destination == .settings || destination == .welcome {
            ScrollView {
                HostLyricsSettings(lyrics: lyrics, model: lyrics.module.model)
                    .padding(.vertical, 4).frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Match the current Host interface, without changing the standalone
            // module's language defaults or the process-wide macOS preferences.
            lyrics.module.managementView(for: destination, language: .chinese).id(destination)
        }
    }
}

#endif
