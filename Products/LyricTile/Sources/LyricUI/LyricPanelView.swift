import AppKit
import LyricCore
import LyricPlayback
import SwiftUI

public struct LyricPanelView: View {
    @ObservedObject private var model: LyricAppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pointerInside = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var isSeeking = false
    @FocusState private var controlsFocused: Bool

    public init(model: LyricAppModel) { self.model = model }
    private var dark: Bool { (forcedScheme ?? colorScheme) == .dark }
    private var primary: Color { Color(nsColor: LyricPalette.primary(dark: dark)) }
    private var secondary: Color { Color(nsColor: LyricPalette.secondary(dark: dark)) }
    private var forcedScheme: ColorScheme? {
        switch model.settings.appearance { case .automatic: nil; case .light: .light; case .dark: .dark }
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                surface
                if model.idle && model.ownershipMessage == nil { waiting }
                else { content(width: geometry.size.width, height: geometry.size.height) }
            }
            .clipShape(RoundedRectangle(cornerRadius: model.idle ? 18 : 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: model.idle ? 18 : 22, style: .continuous)
                .strokeBorder(contrast == .increased ? secondary.opacity(0.6) : dark ? Color.white.opacity(0.13) : Color.white.opacity(0.85), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: model.idle ? 18 : 22))
            .onHover(perform: pointerChanged)
            .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
                if enabled { revealControls() }
                else if !pointerInside { scheduleHide() }
            }
            .onChange(of: controlsFocused) { _, focused in
                if focused { revealControls() } else if !pointerInside { scheduleHide() }
            }
            .onChange(of: model.presentation) { _, page in
                if page != nil { revealControls() } else if !pointerInside { scheduleHide() }
            }
            .onChange(of: model.songMenuIsOpen) { _, open in
                if open { revealControls() } else if !pointerInside { scheduleHide() }
            }
            .onChange(of: model.seekPreviewMS) { _, position in
                if position == nil {
                    isSeeking = false
                    if !pointerInside { scheduleHide() }
                }
            }
            .onDisappear { hoverTask?.cancel() }
        }
        .environment(\.colorScheme, forcedScheme ?? colorScheme)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency || contrast == .increased {
            (dark ? Color(red: 0.157, green: 0.173, blue: 0.204) : Color(red: 0.965, green: 0.965, blue: 0.961))
        } else {
            LyricMaterial()
                .overlay(dark ? Color(red: 0.141, green: 0.161, blue: 0.196).opacity(0.90)
                         : Color(red: 0.98, green: 0.98, blue: 0.976).opacity(0.87))
        }
    }
    private var waiting: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").font(.system(size: 20, weight: .medium)).foregroundStyle(primary)
            VStack(alignment: .leading, spacing: 3) {
                Text("等一首歌").font(.system(size: 12, weight: .medium)).foregroundStyle(primary)
                Text("播放音乐后显示歌词").font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 62)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func content(width: CGFloat, height: CGFloat) -> some View {
        let font: CGFloat = model.settings.largeText ? 22 : width <= 184 ? 18 : 20
        ZStack(alignment: .topLeading) {
            if let image = model.artwork {
                Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: 70)
                    .blur(radius: 30).opacity(0.08).clipped().allowsHitTesting(false)
            }
            if model.controlsVisible {
                metadata.frame(height: 32).padding(.horizontal, 15).offset(y: 14)
                    .transition(.opacity)
            }

            if let ownership = model.ownershipMessage {
                emptyState(title: "歌词已经在旁", detail: ownership).offset(y: 88)
            } else if model.snapshot.requiresAuthorization {
                authorization.offset(y: 82)
            } else {
                lyricContent(fontSize: font)
            }

            if model.controlsVisible && model.snapshot.selection != nil {
                VStack(spacing: 6) {
                    transport
                    progress
                }
                .padding(.horizontal, 16)
                .frame(width: width)
                .offset(y: max(195, height - 80))
                .transition(.opacity)
            }
            HStack(spacing: 6) {
                Circle().fill(secondary.opacity(0.65)).frame(width: 4, height: 4)
                Text(model.sourceCaption).font(.system(size: 10))
            }
            .foregroundStyle(secondary).offset(x: 18, y: max(0, height - 30))
            .opacity(model.controlsVisible ? 0 : 1).allowsHitTesting(!model.controlsVisible)
            .accessibilityHidden(model.controlsVisible)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var metadata: some View {
        HStack(spacing: 9) {
            Group {
                if let artwork = model.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 7).fill(secondary.opacity(0.09))
                    .overlay(Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(secondary)) }
            }
            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                LyricSongMenu(model: model, dark: dark).frame(height: 16)
                Text(model.artist.isEmpty ? (model.snapshot.player?.displayName ?? "") : model.artist)
                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.openPlayer() } label: {
                Image(systemName: "arrow.up.forward").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(primary)
                .help("返回\(model.snapshot.player?.displayName ?? "播放器")")
                .accessibilityLabel("返回\(model.snapshot.player?.displayName ?? "播放器")")
                .focused($controlsFocused)
        }
    }

    @ViewBuilder private func lyricContent(fontSize: CGFloat) -> some View {
        if let cue = model.currentCue, [.syncedLine, .syncedToken, .plainText].contains(model.frame.phase) || model.browsedCueIndex != nil {
            if !model.settings.largeText, let previous = model.previousText {
                Text(previous).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                    .padding(.horizontal, 17).offset(y: 56).accessibilityHidden(true)
            }
            ZStack {
                LyricGlyphText(cue: cue, anchor: model.snapshot.anchor,
                               sourceAdvanceMS: model.sourceAdvanceMS,
                               userAdvanceMS: model.advanceMS,
                               tokenHighlight: model.frame.phase == .syncedToken && model.browsedCueIndex == nil,
                               animate: model.canAnimateTokens, fontSize: fontSize, dark: dark,
                               browse: { model.browse(by: $0) })
                    .id(cue.id).transition(.opacity)
            }
            .frame(height: model.settings.largeText ? 87 : 81).padding(.horizontal, 17).offset(y: 87)
            .animation(.timingCurve(0.22, 0.72, 0.18, 1, duration: reduceMotion ? 0.12 : 0.22), value: cue.id)
            if model.browsedCueIndex != nil {
                Button("回到当前句") { model.returnToCurrent() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .padding(.horizontal, 17).offset(y: 175)
            } else if !model.settings.largeText {
                let text = model.actionMessage ?? model.translationText ?? model.backgroundText ?? model.nextText
                if let text {
                    Text(text).font(.system(size: model.translationText == nil ? 12 : 11)).foregroundStyle(secondary)
                        .lineLimit(1).padding(.horizontal, 17).offset(y: 175)
                        .help(text).accessibilityHidden(model.translationText == nil && model.actionMessage == nil)
                }
            }
        } else {
            switch model.frame.phase {
            case .resolving:
                emptyState(title: "正在找歌词", detail: model.title).offset(y: 88)
            case .instrumental:
                emptyState(title: "此刻，\n只有音乐。", detail: nil).offset(y: 88)
            case .interlude:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 7) { ForEach(0..<3) { _ in Circle().fill(secondary).frame(width: 4, height: 4) } }
                    Text("间奏").font(.system(size: 17, weight: .medium)).foregroundStyle(primary)
                    Text("下一句，稍后继续").font(.system(size: 11)).foregroundStyle(secondary)
                }.padding(.horizontal, 17).offset(y: 88)
            case .notFound, .sourceUnavailable:
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.lyricFailure == nil ? "还没有找到歌词" : "暂时无法取得歌词")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(primary)
                    Text(model.lyricFailure ?? "试试其他版本，或导入歌词文件。")
                        .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(3)
                    Button("选择歌词") { model.show(.candidates) }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(primary)
                }.padding(.horizontal, 17).offset(y: 85)
            case .positionUnavailable:
                emptyState(title: model.snapshot.statusMessage ?? (model.snapshot.anchor?.quality == .stale ? "正在重新连接\n播放器" : "此播放器\n暂不提供进度"),
                           detail: model.document == nil ? nil : "可打开完整歌词阅读")
                    .offset(y: 84)
            case .noPlayback:
                emptyState(title: model.snapshot.statusMessage ?? "等一首歌",
                           detail: model.snapshot.statusMessage == nil ? "照常使用你喜欢的播放器" : nil).offset(y: 88)
            case .syncedLine, .syncedToken, .plainText:
                emptyState(title: "等待下一句", detail: nil).offset(y: 88)
            }
        }
    }

    private func emptyState(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .medium)).lineSpacing(4).foregroundStyle(primary)
            if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(3) }
        }.padding(.horizontal, 17).accessibilityElement(children: .combine)
    }
    private var authorization: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接\(model.snapshot.player?.displayName ?? "播放器")")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(primary)
            Text("允许读取当前歌曲和进度，并响应播放按钮。")
                .font(.system(size: 11)).foregroundStyle(secondary)
            HStack(spacing: 12) {
                Button("重试") { model.reconnect() }
                Button("系统设置") { model.openAutomationSettings() }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(primary)
        }.padding(.horizontal, 17)
    }
    private var transport: some View {
        HStack(spacing: 15) {
            transportButton("backward.end.fill", label: "上一首", enabled: model.snapshot.capabilities.canPrevious) { model.perform(.previous) }
            transportButton(model.snapshot.state == .playing ? "pause.fill" : "play.fill",
                            label: model.snapshot.state == .playing ? "暂停" : "播放",
                            enabled: model.snapshot.state == .playing ? model.snapshot.capabilities.canPause : model.snapshot.capabilities.canPlay,
                            primaryButton: true) { model.togglePlayback() }
            transportButton("forward.end.fill", label: "下一首", enabled: model.snapshot.capabilities.canNext) { model.perform(.next) }
        }
        .frame(maxWidth: .infinity)
        .help(model.actionMessage ?? "控制\(model.snapshot.player?.displayName ?? "当前播放器")")
    }
    private func transportButton(_ symbol: String, label: String, enabled: Bool,
                                 primaryButton: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 32, height: 32)
                .background(primaryButton ? (dark ? Color.white.opacity(0.08) : Color.white.opacity(0.6)) : .clear, in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(primary)
        .disabled(!enabled || model.isPerformingCommand || !model.ownsSession)
        .accessibilityLabel(label).help(label).focused($controlsFocused)
    }
    private var progress: some View {
        VStack(spacing: 2) {
            if model.snapshot.capabilities.canSeek, let duration = model.durationMS, model.playbackPositionMS != nil {
                Slider(value: Binding(get: { Double(model.seekPreviewMS ?? model.playbackPositionMS ?? 0) },
                                      set: { model.previewSeek(to: $0) }),
                       in: 0...Double(duration), onEditingChanged: { editing in
                    isSeeking = editing
                    if editing { model.beginSeek() } else { model.finishSeek(); if !pointerInside { scheduleHide() } }
                }).controlSize(.mini).tint(primary).disabled(!model.canSeek)
                    .accessibilityLabel("歌曲进度").focused($controlsFocused)
            } else {
                GeometryReader { geometry in
                    Capsule().fill(secondary.opacity(0.18)).overlay(alignment: .leading) {
                        if let position = model.playbackPositionMS, let duration = model.durationMS {
                            Capsule().fill(primary).frame(width: geometry.size.width * min(1, max(0, Double(position) / Double(duration))))
                        }
                    }
                }.frame(height: 3).padding(.vertical, 5).accessibilityLabel("当前播放器不支持拖动进度")
            }
            HStack {
                Text(Self.time(model.seekPreviewMS ?? model.playbackPositionMS))
                Spacer()
                Text(Self.time(model.durationMS))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(secondary)
                .accessibilityElement(children: .combine)
        }
    }
    public static func time(_ milliseconds: Int64?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "—:—" }
        let seconds = milliseconds / 1000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    private func pointerChanged(_ inside: Bool) {
        pointerInside = inside; hoverTask?.cancel()
        if inside {
            hoverTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                revealControls()
            }
        } else { scheduleHide() }
    }
    private func revealControls() {
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.16)) { model.setControlsVisible(true) }
    }
    private func scheduleHide() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            guard !voiceOverEnabled, !pointerInside, !isSeeking, model.presentation == nil, !controlsFocused,
                  !model.songMenuIsOpen, model.seekPreviewMS == nil else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.18)) { model.setControlsVisible(false) }
        }
    }
}

private struct LyricMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

