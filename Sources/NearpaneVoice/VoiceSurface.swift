import AppKit
import SwiftUI
import SaytileKit
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
    private func content(size: CGSize) -> some View {
        let fontSize = settings.readableFontSize(.textSize, in: size.height)
        let buttonWidth = settings.points(.voiceButtonWidth,in:size.width)
        let buttonHeight = settings.points(.voiceButtonHeight,in:size.height)
        return VStack(alignment: .leading, spacing: 4) {
            if let id = editing {
                TextEditor(text: Binding(get: { draft }, set: { draft = $0; module.stageDraft(id, text: $0) }))
                    .font(fontSize.map { .system(size:$0) } ?? .body).disabled(settling)
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
                                TranscriptLine(text: row.text, fontSize:fontSize) { panel in
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
            if let issue = module.issue {
                Text(issue).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(issue)
            }
            HStack(spacing:settings.points(.buttonGap,in:size.width)) {
                Button {
                    copied = copy(module.transcript, to: pasteboard)
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(settings.measures[.copySize].map { .system(size:$0.points(in:size.height)) } ?? .body) }
                .disabled(module.transcript.isEmpty).accessibilityLabel("复制当前文字").help("复制当前文字")
                .onChange(of: module.transcript) { copied = false }
                Spacer()
                Button { Task { await module.toggle() } } label: {
                    VoiceCaptureGlyph(presentation: module.control, width:settings.points(.waveformSize,in:size.width)).foregroundStyle(.indigo).frame(minWidth:buttonWidth,minHeight:buttonHeight).contentShape(Rectangle())
                }
                .disabled(module.busy || !module.active)
                .help(module.capture.isRunning ? "暂停收音" : "开始或恢复收音")
                .accessibilityLabel(module.capture.isRunning ? "暂停收音" : "开始或恢复收音")
                .accessibilityValue(module.control.state == .standby ? "待命" : module.control.state == .recognizing ? "正在识别" : "暂停")
            }.buttonStyle(.plain)
        }
        .padding(settings.points(.textPadding,in:size.width)).background(.white.opacity(0.12))
    }

    func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// AppKit supplies the selection menu for selectable text. Add the row's edit action to that same menu.
struct TranscriptLine: NSViewRepresentable {
    let text: String
    var fontSize: Double? = nil
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
        if view.string != text { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
