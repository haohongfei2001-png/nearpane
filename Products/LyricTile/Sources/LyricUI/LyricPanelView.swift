import AppKit
import LyricCore
import LyricPlayback
import SwiftUI

public struct LyricPanelView: View {
    @ObservedObject private var model: LyricAppModel
    private let inheritsHostAppearance: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pointerInside = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var isSeeking = false
    @State private var previousMotionPosition: MotionPosition?
    @FocusState private var controlsFocused: Bool

    public init(model: LyricAppModel, inheritsHostAppearance: Bool = false) {
        self.model = model; self.inheritsHostAppearance = inheritsHostAppearance
    }
    private var dark: Bool { (forcedScheme ?? colorScheme) == .dark }
    private var primary: Color { Color(nsColor: LyricPalette.primary(dark: dark)) }
    private var secondary: Color { Color(nsColor: LyricPalette.secondary(dark: dark)) }
    private var compact: Bool { model.panelContent == .compact }
    private let cornerRadius: CGFloat = 18
    private struct MotionPosition: Equatable {
        let selection: LyricDomain.Selection?
        let index: Int?
    }
    private var motionPosition: MotionPosition {
        .init(selection: model.snapshot.selection, index: model.currentCueIndex)
    }
    // A small upward hand-off only for adjacent, automatic playing cues.
    // Seeking, manual browsing, a new song, hover and Reduce Motion stay still.
    private var flowsUpward: Bool {
        guard !reduceMotion, !model.controlsVisible, model.browsedCueIndex == nil,
              model.seekPreviewMS == nil, !model.isPerformingCommand,
              model.snapshot.state == .playing, let previousMotionPosition,
              previousMotionPosition.selection == motionPosition.selection,
              let before = previousMotionPosition.index, let now = motionPosition.index
        else { return false }
        return now == before + 1
    }
    private var cueTransition: AnyTransition {
        guard flowsUpward else { return .identity }
        return .asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                           removal: .offset(y: -8).combined(with: .opacity))
    }
    private var forcedScheme: ColorScheme? {
        if inheritsHostAppearance { return nil }
        switch model.settings.appearance {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
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
                                      : dark ? Color.white.opacity(0.20) : Color.white.opacity(0.76), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover(perform: pointerChanged)
                .onChange(of: motionPosition, initial: true) { _, position in
                    previousMotionPosition = position
                }
                .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
                    if enabled { revealControls() }
                    else if !pointerInside { scheduleHide() }
                }
                .onChange(of: controlsFocused) { _, focused in
                    updateInteraction()
                    if focused { revealControls() } else if !pointerInside { scheduleHide() }
                }
                .onChange(of: model.presentation) { _, _ in
                    // Management navigation must not keep hover controls pinned.
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
                .overlay(dark ? Color(red: 0.125, green: 0.137, blue: 0.161).opacity(0.66)
                         : Color(red: 0.99, green: 0.99, blue: 0.986).opacity(0.56))
                .overlay {
                    LinearGradient(colors: [.white.opacity(dark ? 0.035 : 0.14), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
    }

    private func lyrics(width: CGFloat) -> some View {
        let supplement = model.translationText ?? model.backgroundText
            ?? (model.document?.timingLevel == .some(.none) ? LyricLocalization.text("未同步歌词", "Unsynced lyrics") : nil)
        let hasSupplement = supplement != nil
        let font: CGFloat = model.settings.largeText ? 22 : width <= 184 ? 18 : 20
        let layout = LyricPanelLayout.readingLayout(for: model.currentCue?.text,
            fontSize: font, availableWidth: width - 28, hasSupplement: hasSupplement,
            controlsVisible: model.controlsVisible)
        return VStack(alignment: .center, spacing: layout.spacing) {
            if layout.contextRadius == 2 { contextLine(at: -2) }
            contextLine(at: -1)
            VStack(alignment: .center, spacing: 3) {
                ZStack {
                    currentLine(fontSize: font)
                }
                .frame(maxWidth: .infinity)
                .frame(height: layout.viewportHeight)
                .clipped()
                if let supplement {
                    Text(supplement).font(.system(size: 11)).foregroundStyle(secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 13).help(supplement)
                        .opacity(model.controlsVisible ? 0 : 1)
                        .accessibilityHidden(model.controlsVisible)
                }
            }
            contextLine(at: 1)
            if layout.contextRadius == 2 { contextLine(at: 2) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(flowsUpward ? .easeOut(duration: 0.18) : nil, value: motionPosition)
    }

    private func contextLine(at distance: Int) -> some View {
        let near = abs(distance) == 1
        let text = model.contextText(at: distance)
        return ZStack {
            Text(text ?? " ")
                .font(.system(size: near ? 14 : 12, weight: .regular))
                .foregroundStyle(contrast == .increased ? secondary : primary.opacity(near ? 0.76 : 0.60))
                .multilineTextAlignment(.center)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .id(text)
                .transition(cueTransition)
        }
        .frame(height: near ? 20 : 16)
        .clipped()
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
                .id(cue.id).transition(cueTransition)
        } else {
            let placeholder = model.snapshot.state == .paused ? LyricLocalization.text("已暂停", "Paused")
                : model.frame.phase == .interlude ? LyricLocalization.text("间奏", "Interlude")
                : LyricLocalization.text("歌词暂不可用", "Lyrics unavailable")
            Text(placeholder)
                .font(.system(size: 16, weight: .medium)).foregroundStyle(secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        if model.snapshot.state == .paused { return LyricLocalization.text("已暂停", "Paused") }
        return switch model.frame.phase {
        case .resolving: LyricLocalization.text("正在查找歌词", "Finding lyrics…")
        case .instrumental: LyricLocalization.text("纯音乐", "Instrumental")
        case .sourceUnavailable: LyricLocalization.text("暂时无法取得歌词", "Lyrics unavailable")
        case .positionUnavailable:
            model.document == nil ? (model.lyricFailure == nil ? LyricLocalization.text("暂无歌词", "No lyrics") : LyricLocalization.text("暂时无法取得歌词", "Lyrics unavailable")) : LyricLocalization.text("歌词暂未同步", "Lyrics are not synced")
        case .notFound: LyricLocalization.text("暂无歌词", "No lyrics")
        case .noPlayback: ""
        case .interlude: LyricLocalization.text("间奏", "Interlude")
        case .syncedLine, .syncedToken, .plainText: LyricLocalization.text("暂无歌词", "No lyrics")
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
                    .help(LyricLocalization.text("打开\(model.snapshot.player?.displayName ?? "播放器")", "Open \(model.snapshot.player?.displayName ?? "player")"))
                    .accessibilityLabel(LyricLocalization.text("打开\(model.snapshot.player?.displayName ?? "播放器")", "Open \(model.snapshot.player?.displayName ?? "player")"))
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
                .help(LyricLocalization.text("回到当前句", "Return to current line")).accessibilityLabel(LyricLocalization.text("回到当前句", "Return to current line"))
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
            transportButton("backward.end.fill", label: LyricLocalization.text("上一首", "Previous track"), enabled: model.snapshot.capabilities.canPrevious) { model.perform(.previous) }
            transportButton(model.snapshot.state == .playing ? "pause.fill" : "play.fill",
                            label: model.snapshot.state == .playing ? LyricLocalization.text("暂停", "Pause") : LyricLocalization.text("播放", "Play"),
                            enabled: model.snapshot.state == .playing ? model.snapshot.capabilities.canPause : model.snapshot.capabilities.canPlay,
                            primaryButton: true) { model.togglePlayback() }
            transportButton("forward.end.fill", label: LyricLocalization.text("下一首", "Next track"), enabled: model.snapshot.capabilities.canNext) { model.perform(.next) }
        }
        .frame(maxWidth: .infinity)
        .help(model.actionMessage ?? LyricLocalization.text("控制\(model.snapshot.player?.displayName ?? "当前播放器")", "Control \(model.snapshot.player?.displayName ?? "current player")"))
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
                    .accessibilityLabel(LyricLocalization.text("歌曲进度", "Track position")).focused($controlsFocused)
                } else {
                    GeometryReader { geometry in
                        Capsule().fill(secondary.opacity(0.18)).overlay(alignment: .leading) {
                            if let position = model.playbackPositionMS, let duration = model.durationMS {
                                Capsule().fill(primary).frame(width: geometry.size.width * min(1, max(0, Double(position) / Double(duration))))
                            }
                        }
                    }
                    .frame(height: 3)
                    .accessibilityLabel(model.playbackPositionMS == nil ? LyricLocalization.text("当前播放器未提供进度", "This player does not report playback position") : LyricLocalization.text("当前播放器不支持拖动进度", "This player does not support seeking"))
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
