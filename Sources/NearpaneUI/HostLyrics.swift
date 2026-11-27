#if canImport(NearpaneLyricsModule)
import AppKit
import Combine
import Foundation
import LyricPlayback
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
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var hostHidden = true
    @ObservationIgnored private var policy = LyricPanelVisibilityPolicy()

    init(directory: URL) {
        module = NearpaneLyricsModule(storageURL: directory)
        module.model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        module.$isPresented.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
    }

    func start() throws { requested = true; status = "正在连接播放器"; reconcile() }
    func stop() {
        requested = false
        status = "已停用"
        height = 0
        updateVisibility()
        reconcile()
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

    func setMounted(_ mounted: Bool) {
        self.mounted = mounted
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
        let visible = requested && module.isPresented && model.ownsSession &&
            policy.shouldPresent(model.snapshot, wasVisible: height > 0 && mounted && !hostHidden, isInteracting: interacting)
        let next = visible ? Double(model.panelContent == .lyrics ? LyricPanelLayout.lyricsHeight : LyricPanelLayout.compactHeight) : 0
        if height != next { height = next }
        let nextStatus: String
        if !requested { nextStatus = "已停用" }
        else if !module.isPresented { nextStatus = model.ownershipMessage ?? "等待歌词会话" }
        else if model.snapshot.requiresAuthorization { nextStatus = "需要允许播放器自动化权限" }
        else { nextStatus = model.snapshot.statusMessage ?? (visible ? "正在跟随播放器" : "播放音乐时自动显示") }
        if status != nextStatus { status = nextStatus }
        updateVisibility()
        if requested && !module.isPresented && worker == nil {
            // Another client explicitly took the shared session. Do not ping-pong.
            openingFailed?()
        }
    }
    private func updateVisibility() {
        let visible = requested && height > 0 && mounted && !hostHidden && module.isPresented
        if module.model.isVisible != visible { module.model.isVisible = visible }
    }
}

struct HostLyricsCard: View {
    let lyrics: HostLyrics
    var body: some View {
        lyrics.module.view
            .accessibilityIdentifier("nearpane-lyrics-card")
            .onAppear { lyrics.setMounted(true) }
            .onDisappear { lyrics.setMounted(false) }
    }
}

/// Host settings only: no independent startup, update, position or panel settings.
struct HostLyricsSettings: View {
    let lyrics: HostLyrics
    @ObservedObject var model: LyricAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lyrics.status).font(.caption).foregroundStyle(.secondary)
            Picker("跟随播放器", selection: $model.settings.preferredPlayer) {
                Text("自动").tag(String?.none)
                ForEach(PlayerID.allCases, id: \.self) { player in
                    Text(player.displayName).tag(Optional(player.rawValue))
                }
            }
            Toggle("在线查找歌词", isOn: $model.settings.onlineLyrics)
            Text("在线查找会向 LRCLIB 发送歌曲名、歌手、专辑和时长。关闭后仍可导入本地歌词。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("大号歌词", isOn: $model.settings.largeText)
            Toggle("显示歌词翻译（如有）", isOn: $model.settings.showTranslation)
            if model.snapshot.requiresAuthorization {
                Button("允许访问播放器…") { model.openAutomationSettings() }
            }
            if model.ownsSession {
                Button("重新连接") { model.reconnect() }
                Button("为当前歌曲导入歌词…") { model.importLyrics() }
                    .disabled(model.snapshot.selection == nil)
            }
        }
        .accessibilityIdentifier("nearpane-lyrics-settings")
    }
}
#endif
