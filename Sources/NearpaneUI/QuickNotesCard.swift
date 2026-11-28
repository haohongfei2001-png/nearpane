import AppKit
import SwiftUI

extension SidebarNotebook {
    /// An intrinsic request to the shared compositor, not another width or
    /// material system. The host can provide less space; content then scrolls.
    func sidebarHeight(width: Double) -> Double {
        if !readable { return 96 }
        guard activeRecord != nil || !unfinishedTasks.isEmpty else { return issue == nil ? 44 : 84 }
        let note = activeRecord.map { Self.editorHeight($0.body, width: width - 32) } ?? 26
        let rows = unfinishedTasks.prefix(3).reduce(0.0) { $0 + Self.taskRowHeight($1.body, width: width - 64) }
        return min(280, note + rows + 48 + (activeRecord != nil && !unfinishedTasks.isEmpty ? 12 : 0) + (issue == nil ? 0 : 36))
    }

    static func editorHeight(_ body: String, width: Double) -> Double {
        let rect = (body as NSString).boundingRect(with: NSSize(width: max(80, width), height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return min(120, max(60, ceil(rect.height) + 10))
    }

    static func taskRowHeight(_ body: String, width: Double) -> Double {
        let rect = (body as NSString).boundingRect(with: NSSize(width: max(60, width), height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(52, max(30, ceil(rect.height) + 8))
    }
}

/// One piece of paper: an active thought followed by a bounded list of actions.
struct QuickNotesCard: View {
    let notebook: SidebarNotebook
    let openLibrary: (UUID?) -> Void
    @State private var hovered = false
    @State private var editing = false
    @State private var noteFocus = 0
    @State private var focusedTask: UUID?
    @State private var taskFocus = 0
    @State private var completedFeedback: UUID?
    @State private var calculationResult: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleTasks: [SidebarNotebook.Record] {
        notebook.records.filter { $0.kind == .task && (!$0.isCompleted || $0.id == completedFeedback) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private var idle: Bool { notebook.activeRecord == nil && visibleTasks.isEmpty }
    private var controlsVisible: Bool { hovered || editing }

    var body: some View {
        GeometryReader { geometry in
            if !notebook.readable {
                NotebookSaveStatus(notebook: notebook).padding(12)
            } else if idle {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        startButton
                        smallButton("添加待办", symbol: "checklist", id: "quick-notes-add-task", action: addTask)
                            .opacity(hovered ? 1 : 0)
                        smallButton("打开记录仓库", symbol: "tray", id: "quick-notes-open-library") { openLibrary(nil) }
                            .opacity(hovered ? 1 : 0)
                    }
                    if notebook.issue != nil { NotebookSaveStatus(notebook: notebook) }
                }.padding(.horizontal, 10).frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                if let note = notebook.activeRecord {
                                    noteEditor(note, width: geometry.size.width)
                                        .id(note.id)
                                    if !visibleTasks.isEmpty { Divider().opacity(0.35).padding(.vertical, 6) }
                                } else {
                                    startButton.frame(height: 28)
                                }
                                ForEach(visibleTasks) { item in
                                    taskRow(item, width: geometry.size.width).id(item.id)
                                }
                            }
                        }.scrollIndicators(.automatic)
                            .onChange(of: taskFocus) { _, _ in
                                if let id = focusedTask { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .bottom) } }
                            }
                            .onChange(of: noteFocus) { _, _ in
                                if let id = notebook.activeRecordID { proxy.scrollTo(id, anchor: .top) }
                            }
                    }
                    footer.padding(.top, 3)
                    if notebook.issue != nil { NotebookSaveStatus(notebook: notebook).padding(.top, 5) }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .onHover { hovered = $0 }
        .task(id: completedFeedback) {
            guard completedFeedback != nil else { return }
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { completedFeedback = nil }
        }
        .onDisappear { completedFeedback = nil; editing = false }
    }

    private var startButton: some View {
        Button(action: newNote) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                Text("记下一点想法…").font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }.foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("开始记录")
            .accessibilityIdentifier("quick-notes-start")
    }

    private func noteEditor(_ note: SidebarNotebook.Record, width: Double) -> some View {
        NotebookTextEditor(text: Binding(get: { notebook.records.first { $0.id == note.id }?.body ?? "" },
            set: { calculationResult = nil; _ = notebook.updateRecord(note.id, body: $0) }), identifier: "quick-notes-editor",
            focusRequest: noteFocus, onFocusChanged: { editing = $0 })
            .id(note.id)
            .frame(height: SidebarNotebook.editorHeight(note.body, width: width - 24))
            .overlay(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("记下一点想法…").font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.top, 3).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .contextMenu {
                Button("在仓库中查看") { openLibrary(note.id) }
                Button("结束当前记录") { _ = notebook.endNote() }
                Button("计算最后一行") {
                    let line = note.body.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                    calculationResult = NoteArithmetic.result(line) ?? "表达式不完整"
                }
            }
    }

    private func taskRow(_ item: SidebarNotebook.Record, width: Double) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                let completed = !item.isCompleted
                if notebook.setCompleted(item.id, completed: completed) {
                    completedFeedback = completed ? item.id : nil
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 22, height: 25).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(item.isCompleted ? "取消完成" : "完成待办")
                .accessibilityIdentifier("quick-notes-toggle-" + item.id.uuidString)
            NotebookTextEditor(text: Binding(get: { notebook.records.first { $0.id == item.id }?.body ?? "" },
                set: { _ = notebook.updateRecord(item.id, body: $0) }),
                identifier: "quick-notes-task-editor-" + item.id.uuidString, fontSize: 13,
                focusRequest: focusedTask == item.id ? taskFocus : 0, onFocusChanged: { editing = $0 })
                .frame(height: SidebarNotebook.taskRowHeight(item.body, width: width - 64) - 4)
                .opacity(item.isCompleted ? 0.45 : 1)
                .overlay(alignment: .topLeading) {
                    if item.body.isEmpty {
                        Text("接下来想做的事…").font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.top, 3).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .contextMenu {
                    Button("恢复为普通记录") { _ = notebook.convertRecord(item.id, to: .note); noteFocus += 1 }
                    Button("在仓库中查看") { openLibrary(item.id) }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            smallButton("新建记录", symbol: "square.and.pencil", id: "quick-notes-new", action: newNote)
            smallButton("添加待办", symbol: "checklist", id: "quick-notes-add-task", action: addTask)
            if let note = notebook.activeRecord, !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                smallButton("转为待办", symbol: "checkmark.circle", id: "quick-notes-convert-to-task") {
                    if notebook.convertRecord(note.id, to: .task) { focusedTask = note.id; taskFocus += 1 }
                }
            }
            Spacer(minLength: 0)
            if let result = calculationResult {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                } label: { Text(result).font(.caption).lineLimit(1) }
                    .buttonStyle(.plain).help("复制计算结果")
            }
            smallButton("打开记录仓库", symbol: "tray", id: "quick-notes-open-library") {
                openLibrary(notebook.activeRecord?.id ?? visibleTasks.first?.id)
            }
        }.opacity(controlsVisible ? 1 : 0.38)
    }

    private func smallButton(_ label: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 25, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private func newNote() {
        NotebookTextEditor.finishMarkedText()
        if notebook.beginNote() != nil { noteFocus += 1; editing = true; focusedTask = nil; calculationResult = nil }
    }

    private func addTask() {
        if let id = notebook.createTask(body: "") { focusedTask = id; taskFocus += 1; editing = true }
    }
}

struct NotebookSaveStatus: View {
    let notebook: SidebarNotebook
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let issue = notebook.issue { Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if notebook.hasUnsavedChanges {
                Button("重试保存") { _ = notebook.retrySave() }.font(.caption).buttonStyle(.borderless)
            } else if notebook.recoveryAvailable {
                Button("恢复最近保存的副本") { _ = notebook.recoverLastSavedCopy() }.font(.caption).buttonStyle(.borderless)
            }
        }
    }
}
