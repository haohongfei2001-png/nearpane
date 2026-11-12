import AppKit
import SwiftUI
import SaytileKit
import SaytileVoiceUI

private typealias ViewState<T> = State<T>

public struct VoiceSurface: View {
    let module: VoiceModule
    private let pasteboard: NSPasteboard
    @StateObject private var access = PanelTranscriptAccess<VoiceHistoryEntry>()
    @ViewState private var selected = ""
    @ViewState private var reading = false
    @ViewState private var latestRequest = 0
    @ViewState private var editing: UUID?
    @ViewState private var draft = ""
    @ViewState private var settling = false

    public init(_ module: VoiceModule, pasteboard: NSPasteboard = .general) {
        self.module = module
        self.pasteboard = pasteboard
    }

    private var capture: VoicePanelCapture { module.control.surface(running: module.capture.isRunning) }

    public var body: some View {
        let history = module.history
        let empty = history.entries.allSatisfy { $0.displayText.isEmpty }
        let document = displayedDocument(history)
        VoiceSurfacePanel(document: document, access: access, capture: capture,
            canCopy: !selected.isEmpty || !history.copyText.isEmpty, selectedText: selected,
            onCopy: {
                let selection = access.view?.selectionSnapshot ?? ""
                if !selection.isEmpty { _ = copy(selection, to: pasteboard); return }
                guard let rendered = access.view?.rendered else { return }
                module.copyLatestGroup(snapshot: history.copySnapshot(rendered: rendered), to: pasteboard)
            }, onToggle: { Task { await module.toggle() } },
            onPage: { if $0 { Task { await module.loadEarlier() } } },
            onSelectionChange: { selected = $0 }, onFollowChange: { reading = !$0 },
            editing: editing != nil, latestRequest: latestRequest, fillContextMenu: fillMenu,
            onEdit: empty ? nil : { @MainActor in editSelection() },
            applyEdits: { edits in
                try module.applyPanelEdits(edits)
                return module.history.document
            },
            notice: module.panelEditIssue ?? module.issue ?? module.insertionNotice,
            placeholder: empty ? (module.capture == .paused ? "点右下角，开始说话。" : "说一句话试试。") : nil,
            captureDisabled: module.busy || !module.active) { secondaryActions }
            .onAppear { access.view?.transcriptView.commandPasteboard = pasteboard }
            .popover(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let id = editing {
                    VStack(alignment: .leading) {
                        TextEditor(text: Binding(get: { draft }, set: { draft = $0; module.stageDraft(id, text: $0) }))
                            .frame(minWidth: 210, minHeight: 96)
                        HStack {
                            Button("取消") { finish(id, saving: false) }
                            Spacer()
                            Button("保存") { finish(id, saving: true) }
                        }
                    }.padding().disabled(settling)
                }
            }
    }

    private func finish(_ id: UUID, saving: Bool) {
        settling = true
        Task {
            let done = saving ? await module.saveEdit(id, text: draft) : await module.discardDraft(id)
            if done { editing = nil }
            settling = false
        }
    }

    private func beginEdit(_ id: UUID) {
        Task {
            guard let text = await module.editText(id) else { return }
            draft = text
            editing = id
        }
    }

    private func row(at character: Int) -> UUID? {
        access.view?.rendered.spans.first { NSLocationInRange(character, $0.range) }?.entry.id
    }

    private func editSelection() {
        guard let view = access.view else { return }
        if let id = row(at: view.transcriptView.selectedRange().location) ?? view.rendered.spans.last?.entry.id {
            beginEdit(id)
        }
    }

    /// Bind each action to its recording now; later ASR revisions can move character ranges.
    private func fillMenu(_ menu: NSMenu) {
        if let selection = access.view?.selectionSnapshot, !selection.isEmpty {
            menu.addItem(VoiceMenuItem("复制所选文字") { _ = copy(selection, to: pasteboard) })
        }
        if let character = access.view?.transcriptView.contextCharacter, let id = row(at: character) {
            menu.insertItem(VoiceMenuItem("修改这段文字…") { beginEdit(id) }, at: 0)
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        if access.view?.rendered.spans.isEmpty == false {
            Button("修改这段文字…") { editSelection() }
        }
        if reading {
            Button("回到最新文字") { latestRequest += 1 }
        }
        if module.hasEarlier {
            Button("较早文字") { Task { await module.loadEarlier() } }
        }
        if let failed = module.rows.last(where: { $0.recognitionState == .failed }) {
            Button("重试识别") { Task { await module.retry(failed.id) } }
        }
        if module.offersManualInput {
            Button("插入当前文字") { access.view?.settleLivePresentation(); module.insertDisplayedText() }
                .disabled(module.inserting || editing != nil || module.transcript.isEmpty)
        }
    }

    private func displayedDocument(_ history: VoiceHistoryProjection) -> PanelTimelineDocument<VoiceHistoryEntry> {
        var page = history.document
        if reading || editing != nil || capture.state != .recognizing { page.liveTailID = nil }
        return page
    }

    func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor final class VoiceMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?
    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
    @objc private func performAction() { handler?() }
}

extension PanelCapturePresentation {
    func surface(running: Bool) -> VoicePanelCapture {
        VoicePanelCapture(state: state, level: liveVoiceLevel, actionLabel: running ? "暂停收音" : "开始或恢复收音",
                          accessibilityValue: state == .standby ? "待命" : state == .recognizing ? "正在识别" : "暂停")
    }
}
