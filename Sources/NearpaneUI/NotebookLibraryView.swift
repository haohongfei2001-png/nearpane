import AppKit
import SwiftUI

enum NotebookLibraryKind { case notes, tasks, vocabulary }

/// One retained main-window library, sharing the sidebar's canonical records.
struct NotebookLibraryView: View {
    let notebook: SidebarNotebook
    let kind: NotebookLibraryKind
    var navigation: SettingsNavigation?
    @State private var query = ""
    @State private var filter: SidebarNotebook.Filter = .all
    @State private var selectedID: UUID?
    @State private var pendingRemoval: UUID?
    @State private var copied = false
    @State private var editorFocus = 0
    @State private var showsCalculation = false
    @State private var calculationResult: String?

    private var matches: [SidebarNotebook.Record] { notebook.records(matching: query, filter: filter) }
    private var selected: SidebarNotebook.Record? { selectedID.flatMap { notebook.record($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !notebook.readable {
                MainWindowEmptyState(symbol: "exclamationmark.doc", title: "暂时无法打开资料",
                    message: notebook.issue ?? "原有内容已保留，请稍后重试。")
            } else if kind == .vocabulary {
                vocabulary
            } else {
                toolbar
                GeometryReader { geometry in
                    if geometry.size.width >= 540 {
                        HStack(alignment: .top, spacing: 22) {
                            recordList.frame(width: min(244, geometry.size.width * 0.38))
                            Divider().opacity(0.5)
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 14) {
                            recordList.frame(height: min(180, geometry.size.height * 0.34))
                            Divider().opacity(0.5)
                            detail
                        }
                    }
                }
            }
            if notebook.issue != nil { NotebookSaveStatus(notebook: notebook) }
        }.padding(.horizontal, 28).padding(.bottom, 24)
            .onAppear(perform: applyNavigation)
            .onChange(of: navigation?.notebookNavigationRevision) { _, _ in applyNavigation() }
            .onChange(of: query) { _, _ in selectFirstMatch() }
            .onChange(of: filter) { _, _ in selectFirstMatch() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 4) {
                ForEach(SidebarNotebook.Filter.allCases, id: \.self) { value in
                    Button { filter = value } label: {
                        Text(value.title).font(.system(size: 12, weight: filter == value ? .medium : .regular))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .foregroundStyle(filter == value ? .primary : .secondary)
                            .background(filter == value ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(filter == value ? .isSelected : [])
                        .accessibilityIdentifier("notebook-filter-" + value.rawValue)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索记录", text: $query).textFieldStyle(.plain).accessibilityIdentifier("notebook-search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Button("新建记录", systemImage: "square.and.pencil") { create(.note) }
                    .buttonStyle(.borderless).accessibilityIdentifier("notebook-new")
                Button { create(.task) } label: { Image(systemName: "checklist") }
                    .buttonStyle(.borderless).help("新建待办").accessibilityLabel("新建待办")
                    .accessibilityIdentifier("notebook-new-task")
                Menu {
                    Button("计算草稿") { showsCalculation = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 22).help("更多")
            }
        }
    }

    private var recordList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if matches.isEmpty && selected == nil {
                        Text(query.isEmpty ? "还没有记录" : "没有匹配的记录")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(matches) { record in
                        Button {
                            selectedID = record.id; pendingRemoval = nil; copied = false; showsCalculation = false
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top, spacing: 7) {
                                    if record.kind == .task {
                                        Image(systemName: record.isCompleted ? "checkmark.circle" : "circle")
                                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 2)
                                    }
                                    Text(record.body).font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading)
                                        .foregroundStyle(record.isCompleted ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text(record.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == record.id ? Color.primary.opacity(0.055) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                        }.buttonStyle(.plain).id(record.id)
                            .accessibilityIdentifier("notebook-row-" + record.id.uuidString)
                            .accessibilityAddTraits(selectedID == record.id ? .isSelected : [])
                    }
                }
            }.onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    @ViewBuilder private var detail: some View {
        if showsCalculation {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("计算草稿").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("返回记录") { showsCalculation = false }.buttonStyle(.borderless)
                }
                NotebookTextEditor(text: Binding(get: { notebook.contents.calculation }, set: { value in
                    calculationResult = nil; notebook.edit { $0.calculation = value }
                }), identifier: "notebook-calculation-editor", fontSize: 15)
                HStack {
                    if let result = calculationResult { Text(result).textSelection(.enabled) }
                    Spacer()
                    Button("计算最后一行") {
                        let line = notebook.contents.calculation.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                        calculationResult = NoteArithmetic.result(line) ?? "表达式不完整"
                    }.buttonStyle(.borderless)
                }
            }
        } else if let record = selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if record.kind == .task {
                        Button {
                            _ = notebook.setCompleted(record.id, completed: !record.isCompleted)
                        } label: {
                            Label(record.isCompleted ? "已完成" : "完成", systemImage: record.isCompleted ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).accessibilityIdentifier("notebook-toggle-completed")
                    } else { Text("记录").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Button {
                        _ = notebook.convertRecord(record.id, to: record.kind == .note ? .task : .note)
                    } label: { Image(systemName: record.kind == .note ? "checklist" : "note.text") }
                        .buttonStyle(.borderless).help(record.kind == .note ? "转为待办" : "恢复为普通记录")
                        .accessibilityLabel(record.kind == .note ? "转为待办" : "恢复为普通记录")
                        .accessibilityIdentifier("notebook-convert")
                    Button { copy(record.body) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help(copied ? "已复制" : "复制全文")
                        .accessibilityLabel("复制全文").accessibilityIdentifier("notebook-copy")
                    Button { pendingRemoval = record.id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除记录")
                        .accessibilityLabel("删除记录").accessibilityIdentifier("notebook-delete")
                }
                if pendingRemoval == record.id {
                    HStack {
                        Text("删除这条记录？").font(.callout)
                        Spacer(minLength: 0)
                        Button("取消") { pendingRemoval = nil }.buttonStyle(.borderless)
                        Button("删除", role: .destructive) {
                            if notebook.deleteRecord(record.id) { selectedID = matches.first?.id; pendingRemoval = nil }
                        }.buttonStyle(.borderless).accessibilityIdentifier("notebook-confirm-delete")
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                NotebookTextEditor(text: Binding(get: { notebook.record(record.id)?.body ?? "" },
                    set: { copied = false; _ = notebook.updateRecord(record.id, body: $0) }),
                    identifier: "notebook-editor", fontSize: 15, focusRequest: editorFocus)
                    .id(record.id)
                    .overlay(alignment: .topLeading) {
                        if record.body.isEmpty {
                            Text(record.kind == .note ? "写下一点想法…" : "接下来想做的事…")
                                .font(.system(size: 15)).foregroundStyle(.tertiary).padding(.top, 3)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                HStack {
                    Text(record.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    Spacer(minLength: 0)
                    Text(notebook.hasUnsavedChanges ? "等待保存" : "已自动保存")
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            MainWindowEmptyState(symbol: "note.text", title: query.isEmpty ? "随时记下一点想法" : "没有匹配的记录",
                message: query.isEmpty ? "侧栏里的记录和待办都保存在这里。" : "试试搜索正文里的其他词句。")
        }
    }

    private func create(_ kind: SidebarNotebook.RecordKind) {
        NotebookTextEditor.finishMarkedText()
        query = ""; filter = .all; showsCalculation = false
        selectedID = kind == .note ? notebook.beginNote() : notebook.createTask(body: "")
        editorFocus += 1
    }

    private func applyNavigation() {
        guard kind != .vocabulary else { return }
        showsCalculation = false
        filter = SidebarNotebook.Filter(rawValue: navigation?.notebookFilter ?? "") ?? (kind == .tasks ? .unfinished : .all)
        if let id = navigation?.selectedNotebookRecordID, notebook.record(id) != nil {
            query = ""; filter = .all; selectedID = id
        } else if selected == nil { selectedID = matches.first?.id }
        pendingRemoval = nil
    }

    private func selectFirstMatch() {
        guard kind != .vocabulary else { return }
        if query.isEmpty, let record = selected, record.isEmpty,
           filter == .all || (filter == .notes && record.kind == .note) ||
           (filter == .unfinished && record.kind == .task && !record.isCompleted) { return }
        if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
        pendingRemoval = nil
    }

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索原文或译文", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("wordbook-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            let matches = notebook.words(matching: query)
            if matches.isEmpty {
                MainWindowEmptyState(symbol: "character.book.closed", title: query.isEmpty ? "尚无词条" : "没有匹配的词条",
                                     message: query.isEmpty ? "已查询并保存的词句会出现在这里。" : "试试搜索其他原文或译文。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { word in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(word.source).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button { copy(word.source + "\n" + word.translation) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless).accessibilityLabel("复制词条")
                                    removalButton(word.id) { notebook.edit { $0.words.removeAll { $0.id == word.id } } }
                                }
                                Text(word.translation).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let date = word.committedAt {
                                    Text(date, format: .dateTime.year().month().day()).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }.padding(.vertical, 16)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func removalButton(_ id: UUID, remove: @escaping () -> Void) -> some View {
        if pendingRemoval == id {
            HStack(spacing: 8) {
                Button("删除", role: .destructive) { remove(); pendingRemoval = nil }
                Button("取消") { pendingRemoval = nil }
            }.buttonStyle(.borderless).font(.caption)
        } else {
            Button { pendingRemoval = id } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary).accessibilityLabel("删除此项")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
    }
}
