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
    private var compact: Bool { model.panelContent == .compact }
    private let cornerRadius: CGFloat = 18
    private var forcedScheme: ColorScheme? {
        switch model.settings.appearance { case .automatic: nil; case .light: .light; case .dark: .dark }
    }

    public var body: some View {
        GeometryReader { geometry in
            if model.snapshot.selection != nil {
                ZStack {
                    surface
                    if compact {
                        compactPanel
                    } else {
                        lyrics(width: geometry.size.width)
                        if model.controlsVisible { lyricControls.transition(.opacity) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(contrast == .increased ? secondary.opacity(0.6)
                                      : dark ? Color.white.opacity(0.14) : Color.white.opacity(0.65), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover(perform: pointerChanged)
                .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
                    if enabled { revealControls() }
                    else if !pointerInside { scheduleHide() }
                }
                .onChange(of: controlsFocused) { _, focused in
                    updateInteraction()
                    if focused { revealControls() } else if !pointerInside { scheduleHide() }
                }
                .onChange(of: model.presentation) { _, _ in
                    // Auxiliary windows are independent; they must not pin the tile.
                    if !pointerInside { releasePointerFocus(); scheduleHide() }
                }
                .onChange(of: model.songMenuIsOpen) { _, open in
                    updateInteraction()
                    if open { revealControls() }
                    else if !pointerInside { releasePointerFocus(); scheduleHide() }
                }
                .onChange(of: model.seekPreviewMS) { _, position in
                    if position == nil {
                        isSeeking = false
                        updateInteraction()
                        if !pointerInside { releasePointerFocus(); scheduleHide() }
                    }
                }
                .onChange(of: model.isVisible) { _, visible in
                    if !visible {
                        hoverTask?.cancel(); pointerInside = false; controlsFocused = false; isSeeking = false
                        model.panelInteractionActive = false
                        model.setControlsVisible(false)
                    } else if voiceOverEnabled { revealControls() }
                }
                .onDisappear {
                    hoverTask?.cancel(); pointerInside = false; controlsFocused = false; isSeeking = false
                    model.panelInteractionActive = false
                }
            } else {
                // The window is withdrawn by the controller. Its unloaded state is
                // transparent too, including first launch and native view-load checks.
                Color.clear.accessibilityHidden(true)
            }
        }
        .environment(\.colorScheme, forcedScheme ?? colorScheme)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency || contrast == .increased {
            dark ? Color(red: 0.157, green: 0.173, blue: 0.204)
                 : Color(red: 0.965, green: 0.965, blue: 0.961)
        } else {
            LyricMaterial()
                .overlay(dark ? Color(red: 0.125, green: 0.137, blue: 0.161).opacity(0.78)
                         : Color(red: 0.99, green: 0.99, blue: 0.986).opacity(0.72))
        }
    }

    private func lyrics(width: CGFloat) -> some View {
        let supplement = model.translationText ?? model.backgroundText
            ?? (model.document?.timingLevel == .some(.none) ? "未同步歌词" : nil)
        let hasSupplement = supplement != nil
        let font: CGFloat = model.settings.largeText ? 22 : width <= 184 ? 18 : 20
        let rowHeight = LyricPanelLayout.lineHeight(for: font)
        let viewport = LyricPanelLayout.lyricViewportHeight(for: model.currentCue?.text,
            fontSize: font, availableWidth: width - 28)
        let gap: CGFloat = viewport > rowHeight ? 5 : (hasSupplement ? 9 : 11)
        return VStack(alignment: .leading, spacing: gap) {
            contextLine(at: -2)
            contextLine(at: -1)
            VStack(alignment: .leading, spacing: 3) {
                currentLine(fontSize: font).frame(height: viewport)
                if let supplement {
                    Text(supplement).font(.system(size: 11)).foregroundStyle(secondary)
                        .lineLimit(1).frame(height: 13).help(supplement)
                        .opacity(model.controlsVisible ? 0 : 1)
                        .accessibilityHidden(model.controlsVisible)
                }
            }
            contextLine(at: 1)
            contextLine(at: 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func contextLine(at distance: Int) -> some View {
        let near = abs(distance) == 1
        let text = model.contextText(at: distance)
        return Text(text ?? " ")
            .font(.system(size: near ? 14 : 12, weight: .regular))
            .foregroundStyle(contrast == .increased ? secondary : primary.opacity(near ? 0.78 : 0.64))
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: near ? 20 : 16)
            .opacity(model.controlsVisible || text == nil ? 0 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func currentLine(fontSize: CGFloat) -> some View {
        if let cue = model.currentCue {
            LyricGlyphText(cue: cue, anchor: model.snapshot.anchor,
                           sourceAdvanceMS: model.sourceAdvanceMS, userAdvanceMS: model.advanceMS,
                           tokenHighlight: model.frame.phase == .syncedToken && model.browsedCueIndex == nil,
                           animate: model.canAnimateTokens, fontSize: fontSize, dark: dark,
                           browse: { model.browse(by: $0) })
                .id(cue.id).transition(.opacity)
                .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: cue.id)
        } else {
            Text("间奏").font(.system(size: 16, weight: .medium)).foregroundStyle(secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Keep the artwork and title at the same position in both compact states.
    private var compactPanel: some View {
        VStack(spacing: 4) {
            trackSummary(interactive: model.controlsVisible, artworkSize: 36)
            if model.controlsVisible {
                transport
                progress
            } else {
                Text(compactCaption).font(.system(size: 11)).foregroundStyle(secondary)
                    .lineLimit(1)
                    .padding(.leading, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var compactCaption: String {
        switch model.frame.phase {
        case .resolving: "正在查找歌词"
        case .instrumental: "纯音乐"
        case .sourceUnavailable: "暂时无法取得歌词"
        case .positionUnavailable:
            model.document == nil ? (model.lyricFailure == nil ? "暂无歌词" : "暂时无法取得歌词") : "歌词暂未同步"
        case .notFound: "暂无歌词"
        case .noPlayback: ""
        case .interlude: "间奏"
        case .syncedLine, .syncedToken, .plainText: "暂无歌词"
        }
    }

    private var lyricControls: some View {
        VStack(spacing: 0) {
            trackSummary(interactive: true, artworkSize: 34)
            Spacer(minLength: 0)
            transport
            progress.padding(.top, 5)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func trackSummary(interactive: Bool, artworkSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            if interactive, model.snapshot.player != nil {
                Button { model.openPlayer() } label: { artwork(size: artworkSize) }
                    .buttonStyle(.plain)
                    .help("打开\(model.snapshot.player?.displayName ?? "播放器")")
                    .accessibilityLabel("打开\(model.snapshot.player?.displayName ?? "播放器")")
                    .focused($controlsFocused)
            } else { artwork(size: artworkSize) }
            VStack(alignment: .leading, spacing: 2) {
                if interactive { LyricSongMenu(model: model, dark: dark).frame(height: 16) }
                else {
                    Text(model.title).font(.system(size: 12, weight: .medium)).foregroundStyle(primary)
                        .lineLimit(1).help(model.title)
                }
                // A missing artist is absent. A player name is never presented as an artist.
                if !model.artist.isEmpty {
                    Text(model.artist).font(.system(size: 11)).foregroundStyle(secondary)
                        .lineLimit(1).help(model.artist)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if interactive, !compact, model.browsedCueIndex != nil {
                Button { model.returnToCurrent() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(secondary)
                .help("回到当前句").accessibilityLabel("回到当前句")
                .focused($controlsFocused)
            }
        }
        .frame(height: artworkSize)
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let artwork = model.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else {
                RoundedRectangle(cornerRadius: 7).fill(secondary.opacity(0.09))
                    .overlay(Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(secondary))
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: compact ? 14 : 18) {
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
            Image(systemName: symbol).font(.system(size: compact ? 14 : 16, weight: .medium))
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(primaryButton ? (dark ? Color.white.opacity(0.08) : Color.white.opacity(0.6)) : .clear, in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(primary)
        .disabled(!enabled || model.isPerformingCommand || !model.ownsSession)
        .accessibilityLabel(label).help(model.actionMessage ?? label).focused($controlsFocused)
    }

    private var progress: some View {
        HStack(spacing: 5) {
            Text(Self.time(model.seekPreviewMS ?? model.playbackPositionMS))
            Group {
                if model.snapshot.capabilities.canSeek, let duration = model.durationMS, model.playbackPositionMS != nil {
                    Slider(value: Binding(get: { Double(model.seekPreviewMS ?? model.playbackPositionMS ?? 0) },
                                          set: { model.previewSeek(to: $0) }),
                           in: 0...Double(duration), onEditingChanged: { editing in
                        isSeeking = editing
                        updateInteraction()
                        if editing { model.beginSeek() }
                        else {
                            model.finishSeek()
                            if !pointerInside { releasePointerFocus(); scheduleHide() }
                        }
                    })
                    .controlSize(.mini).tint(primary).disabled(!model.canSeek)
                    .accessibilityLabel("歌曲进度").focused($controlsFocused)
                } else {
                    GeometryReader { geometry in
                        Capsule().fill(secondary.opacity(0.18)).overlay(alignment: .leading) {
                            if let position = model.playbackPositionMS, let duration = model.durationMS {
                                Capsule().fill(primary).frame(width: geometry.size.width * min(1, max(0, Double(position) / Double(duration))))
                            }
                        }
                    }
                    .frame(height: 3)
                    .accessibilityLabel(model.playbackPositionMS == nil ? "当前播放器未提供进度" : "当前播放器不支持拖动进度")
                }
            }.frame(maxWidth: .infinity)
            Text(Self.time(model.durationMS))
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(secondary)
        .frame(height: 14)
    }
    public static func time(_ milliseconds: Int64?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "—:—" }
        let seconds = milliseconds / 1000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    private func pointerChanged(_ inside: Bool) {
        pointerInside = inside; hoverTask?.cancel()
        updateInteraction()
        if inside { revealControls() }
        else { releasePointerFocus(); scheduleHide() }
    }
    private func releasePointerFocus() {
        if !voiceOverEnabled, !isSeeking, !model.songMenuIsOpen { controlsFocused = false }
        updateInteraction()
    }
    private func updateInteraction() {
        model.panelInteractionActive = pointerInside || controlsFocused || isSeeking
            || model.songMenuIsOpen
    }
    private func revealControls() {
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) { model.setControlsVisible(true) }
    }
    private func scheduleHide() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            guard !voiceOverEnabled, !pointerInside, !isSeeking, !controlsFocused,
                  !model.songMenuIsOpen, model.seekPreviewMS == nil else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.16)) { model.setControlsVisible(false) }
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
