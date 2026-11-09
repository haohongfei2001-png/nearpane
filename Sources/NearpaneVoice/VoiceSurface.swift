import AppKit
import SwiftUI
import SaytileKit

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
    public init(_ module: VoiceModule, pasteboard: NSPasteboard = .general) {
        self.module = module
        self.pasteboard = pasteboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let id = editing {
                TextEditor(text: Binding(get: { draft }, set: { draft = $0; module.stageDraft(id, text: $0) }))
                    .font(.body).disabled(settling)
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
                    VStack(alignment: .leading, spacing: 2) {
                        if module.hasEarlier {
                            Button("较早文字") { Task { await module.loadEarlier() } }.font(.caption2)
                        }
                        ForEach(module.rows) { row in
                            if !row.text.isEmpty {
                                TranscriptLine(text: row.text) { panel in
                                    Task {
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
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let issue = module.issue {
                Text(issue).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(issue)
            }
            HStack {
                Button {
                    copied = copy(module.transcript, to: pasteboard)
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .disabled(module.transcript.isEmpty).accessibilityLabel("复制当前文字")
                .onChange(of: module.transcript) { copied = false }
                Spacer()
                Button { Task { await module.toggle() } } label: {
                    VoiceCaptureGlyph(presentation: module.control).foregroundStyle(.indigo).frame(minWidth: 32, minHeight: 26)
                }
                .disabled(module.busy || !module.active)
                .accessibilityLabel(module.capture.isRunning ? "暂停收音" : "开始或恢复收音")
                .accessibilityValue(module.control.state == .standby ? "待命" : module.control.state == .recognizing ? "正在识别" : "暂停")
            }.buttonStyle(.plain)
        }
        .padding(8).background(.white.opacity(0.12))
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
    let edit: (NSWindow?) -> Void

    final class TextView: NSTextView {
        var editLine: (() -> Void)?
        override var needsPanelToBecomeKey: Bool { false }
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
