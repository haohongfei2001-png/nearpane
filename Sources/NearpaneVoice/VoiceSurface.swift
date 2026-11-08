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
    public init(_ module: VoiceModule) { self.module = module }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let id = editing {
                TextEditor(text: $draft).font(.body)
                HStack {
                    Button("取消") { editing = nil }
                    Button("保存") { Task { if await module.saveEdit(id, text: draft) { editing = nil } } }
                }.controlSize(.small)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if module.hasEarlier {
                            Button("较早文字") { Task { await module.loadEarlier() } }.font(.caption2)
                        }
                        ForEach(module.rows) { row in
                            if !row.text.isEmpty {
                                Text(verbatim: row.text).textSelection(.enabled)
                                    .contextMenu { Button("修改这段文字…") { draft = row.text; editing = row.id } }
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
                    copied = copy(module.transcript, to: .general)
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
