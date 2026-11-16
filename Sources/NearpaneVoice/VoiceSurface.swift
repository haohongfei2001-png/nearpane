import AppKit
import SwiftUI
import SaytileKit
import SaytileVoiceUI
import NearpaneCore

// Use the public property wrapper on CLT installations without SwiftUIMacros.
private typealias ViewState<T> = State<T>

public struct VoiceSurface: View {
    let module: VoiceModule
    @ViewState private var editing: UUID?
    @ViewState private var draft = ""
    @ViewState private var copied = false
    @ViewState private var settling = false
    @ViewState private var releaseEditorFocus: (() -> Void)?
    private let pasteboard: NSPasteboard
    private let settings: DisplaySettings
    public init(_ module: VoiceModule, pasteboard: NSPasteboard = .general) { self.init(module,pasteboard:pasteboard,settings:.init()) }
    public init(_ module: VoiceModule, pasteboard: NSPasteboard, settings: DisplaySettings) {
        self.settings = settings
        self.module = module
        self.pasteboard = pasteboard
    }

    public var body: some View {
        GeometryReader { content(size:$0.size) }
    }

    static func captureButtonSize(in size: CGSize, settings: DisplaySettings) -> CGSize {
        let reference = SaytileVoiceUI.VoicePanelFootprint.controlSize
        let height = settings.measures[.voiceButtonHeight]?.points(in: size.height) ?? reference.height
        if let saved = settings.measures[.voiceButtonWidth] {
            return CGSize(width: saved.points(in: size.width), height: height)
        }
        let copy = max(height, settings.points(.copySize, in: size.height))
        let available = size.width - copy - 2 * settings.points(.textPadding, in: size.width)
            - 2 * settings.points(.buttonGap, in: size.width)
        // Retain Nearpane's compact hit target while expanding into the shared Saytile capsule.
        let minimum = settings.points(.voiceButtonWidth, in: size.width)
        return CGSize(width: max(minimum, min(reference.width, available)), height: height)
    }

    private func content(size: CGSize) -> some View {
        let fontSize = settings.readableFontSize(.textSize, in: size.height)
        let lineSpacing = settings.measures[.lineGap]?.points(in: size.height)
        let captureButton = Self.captureButtonSize(in: size, settings: settings)
        let buttonWidth = captureButton.width
        let buttonHeight = captureButton.height
        let copySide = max(buttonHeight, settings.points(.copySize,in:size.height))
        return VStack(alignment: .leading, spacing: 4) {
            if let id = editing {
                TranscriptEditor(text: Binding(get: { draft }, set: { draft = $0; module.stageDraft(id, text: $0) }),
                                 fontSize: fontSize, lineSpacing: lineSpacing)
                    .disabled(settling)
                    .onDisappear {
                        releaseEditorFocus?()
                        releaseEditorFocus = nil
                    }
                HStack {
                    Button("取消") {
                        settling = true
                        Task { if await module.discardDraft(id) { editing = nil }; settling = false }
                    }
                    Button("保存") {
                        settling = true
                        Task { if await module.saveEdit(id, text: draft) { editing = nil }; settling = false }
                    }
                }.controlSize(.small).disabled(settling)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:settings.points(.lineGap,in:size.height)) {
                        if module.rows.allSatisfy({ $0.text.isEmpty && $0.recognitionState != .failed }),
                           module.capture == .paused, module.issue == nil {
                            Text("点播放按钮开始收音")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if module.hasEarlier {
                            Button("较早文字") { Task { await module.loadEarlier() } }.font(.caption2)
                        }
                        ForEach(module.rows) { row in
                            if !row.text.isEmpty {
                                TranscriptLine(text: row.text, fontSize:fontSize, lineSpacing:lineSpacing) { panel in
                                    Task { [weak panel] in
                                        guard let text = await module.editText(row.id) else { return }
                                        releaseEditorFocus = { [weak panel] in
                                            guard let panel, panel.isKeyWindow, panel.styleMask.contains(.nonactivatingPanel) else { return }
                                            panel.makeFirstResponder(nil)
                                            NSApp.deactivate()
                                        }
                                        draft = text
                                        editing = row.id
                                    }
                                }
                            }
                            if row.recognitionState == .failed {
                                Button("重试识别") { Task { await module.retry(row.id) } }
                                    .font(.caption).help(row.lastError ?? "保留原音和文字")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: min(size.height,settings.points(.textHeight,in:size.height)), alignment: .topLeading)
            }
            if let issue = module.issue ?? module.insertionNotice {
                Text(issue).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(issue)
            }
            HStack(spacing:settings.points(.buttonGap,in:size.width)) {
                Button {
                    copied = copy(module.transcript, to: pasteboard)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(settings.measures[.copySize].map { .system(size:$0.points(in:size.height)) } ?? .body)
                        .frame(minWidth:copySide,minHeight:buttonHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(VoiceGlassControlStyle(copy: true, height: buttonHeight))
                .disabled(module.transcript.isEmpty).accessibilityLabel("复制当前文字").help("复制当前文字")
                .onChange(of: module.transcript) { copied = false }
                .contextMenu {
                    if module.offersManualInput {
                        Button("插入当前文字") { module.insertDisplayedText() }
                            .disabled(module.inserting || editing != nil || module.transcript.isEmpty)
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await module.toggle() } } label: {
                    VoiceCaptureGlyph(presentation: module.control, width:settings.points(.waveformSize,in:size.width)).frame(minWidth:buttonWidth,minHeight:buttonHeight).contentShape(Capsule())
                }
                .buttonStyle(VoiceGlassControlStyle(copy: false, height: buttonHeight))
                .disabled(module.busy || !module.active)
                .help(module.capture.isRunning ? "暂停收音" : "开始或恢复收音")
                .accessibilityLabel(module.capture.isRunning ? "暂停收音" : "开始或恢复收音")
                .accessibilityValue(module.control.state == .standby ? "待命" : module.control.state == .recognizing ? "正在识别" : "暂停")
            }
        }
        .padding(settings.points(.textPadding,in:size.width))
    }

    func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Quiet glass controls share the existing panel material; the chrome adds no
/// layout padding, so saved glyph and control dimensions retain their meaning.
private struct VoiceGlassControlStyle: ButtonStyle {
    let copy: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque

    func makeBody(configuration: Configuration) -> some View {
        let scale = height / ReferencePanelStyle.controlHeight
        let outline = RoundedRectangle(cornerRadius: (copy ? 13 : ReferencePanelStyle.controlHeight / 2) * scale,
                                       style: .continuous)
        configuration.label
            .foregroundStyle(scheme == .light && contrast == .standard ? ReferencePanelStyle.copyInk : Color.primary)
            .background {
                if scheme == .light && !opaque && contrast == .standard {
                    ReferenceControlSurface(copy: copy, scale: scale)
                } else {
                    outline.fill(opaque ? Color(nsColor: .controlBackgroundColor) : .white.opacity(0.10))
                        .overlay { outline.strokeBorder(contrast == .increased ? Color.primary : .white.opacity(0.25),
                                                        lineWidth: contrast == .increased ? 1 : 0.7) }
                }
            }
            .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.62 : 1)
    }
}

/// Explicit spacing applies to both reading and editing. An unset value preserves
/// the existing system typography used by the factory appearance.
struct TranscriptEditor: View {
    @Binding var text: String
    let fontSize: Double?
    let lineSpacing: Double?

    var body: some View {
        TextEditor(text: $text)
            .font(fontSize.map { .system(size: $0) } ?? .body)
            .lineSpacing(lineSpacing ?? 0)
            .scrollContentBackground(.hidden)
    }
}

/// AppKit supplies the selection menu for selectable text. Add the row's edit action to that same menu.
struct TranscriptLine: NSViewRepresentable {
    let text: String
    var fontSize: Double? = nil
    var lineSpacing: Double? = nil
    let edit: (NSWindow?) -> Void

    final class TextView: NSTextView {
        var editLine: (() -> Void)?
        override var needsPanelToBecomeKey: Bool { false }
        override func accessibilityPerformPress() -> Bool {
            guard let editLine else { return false }
            editLine()
            return true
        }
        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            if selector == #selector(accessibilityPerformPress) { return editLine != nil }
            return super.isAccessibilitySelectorAllowed(selector)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            let item = NSMenuItem(title: "修改这段文字…", action: #selector(editThisLine), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            return menu
        }
        @objc private func editThisLine() { editLine?() }
    }

    func makeNSView(context: Context) -> TextView {
        let view = TextView(frame: .zero)
        view.setAccessibilityHelp("修改这段文字…")
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        let font = fontSize.map { NSFont.systemFont(ofSize:max(1,$0)) } ?? NSFont.preferredFont(forTextStyle:.body)
        if view.font != font { view.font = font }
        view.editLine = { [weak view] in edit(view?.window) }
        let textChanged = view.string != text
        if textChanged { view.string = text }
        if let spacing = lineSpacing.map({ CGFloat($0) }), textChanged || view.defaultParagraphStyle?.lineSpacing != spacing {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            view.defaultParagraphStyle = paragraph
            view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                                          range: NSRange(location: 0, length: view.string.utf16.count))
        } else if lineSpacing == nil, view.defaultParagraphStyle != nil {
            view.defaultParagraphStyle = nil
            view.textStorage?.removeAttribute(.paragraphStyle,
                                             range: NSRange(location: 0, length: view.string.utf16.count))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
