import AppKit
import SwiftUI

enum NotebookLibraryKind { case notes, tasks, vocabulary }

/// Uses the same notebook as the sidebar. Disabling a surface never removes or
/// moves its content, and edits made here appear immediately when it returns.
struct NotebookLibraryView: View {
    let notebook: SidebarNotebook
    let kind: NotebookLibraryKind
    @State private var query = ""
    @State private var taskFilter = 0
    @State private var newTask = ""
    @State private var pendingRemoval: UUID?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !notebook.readable {
                MainWindowEmptyState(symbol: "exclamationmark.doc", title: "暂时无法打开资料",
                                     message: notebook.issue ?? "原有内容已保留，请稍后重试。")
            } else {
                switch kind {
                case .notes: notes
                case .tasks: tasks
                case .vocabulary: vocabulary
                }
            }
            if let issue = notebook.issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 28).padding(.bottom, 24)
            .accessibilityIdentifier("notebook-library")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("与侧栏中的备忘录保持同步").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制全文", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copy(notebook.contents.memo)
                }.disabled(notebook.contents.memo.isEmpty)
                    .accessibilityIdentifier("notebook-copy-memo")
            }
            ZStack(alignment: .topLeading) {
                if notebook.contents.memo.isEmpty {
                    Text("写下一点想法…").foregroundStyle(.tertiary).padding(.horizontal, 7).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { notebook.contents.memo }, set: { value in
                    copied = false
                    notebook.edit { $0.memo = value }
                }))
                .font(.system(size: 15)).lineSpacing(5).scrollContentBackground(.hidden)
                .accessibilityLabel("备忘录内容").accessibilityIdentifier("library-memo-editor")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("自动保存").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var filteredTasks: [SidebarNotebook.Entry] {
        notebook.contents.tasks.filter { item in
            (taskFilter == 0 || (taskFilter == 1 && !item.done) || (taskFilter == 2 && item.done)) &&
            (query.isEmpty || item.title.localizedStandardContains(query))
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("筛选待办", selection: $taskFilter) {
                    Text("全部").tag(0)
                    Text("未完成").tag(1)
                    Text("已完成").tag(2)
                }.pickerStyle(.segmented).frame(maxWidth: 260)
                Spacer()
                Text("\(notebook.contents.tasks.filter { !$0.done }.count) 项未完成")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("添加一项待办", text: $newTask).textFieldStyle(.roundedBorder).onSubmit(addTask)
                    .accessibilityIdentifier("library-task-input")
                Button("添加", systemImage: "plus", action: addTask)
                    .disabled(newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if filteredTasks.isEmpty {
                MainWindowEmptyState(symbol: "checkmark.circle", title: taskFilter == 2 ? "尚无已完成的待办" : "这里很清爽",
                                     message: taskFilter == 1 ? "当前待办都已完成。" : "记下接下来想做的事，它也会出现在侧栏。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredTasks) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Toggle(item.title, isOn: Binding(get: {
                                    notebook.contents.tasks.first(where: { $0.id == item.id })?.done == true
                                }, set: { done in
                                    notebook.edit { contents in
                                        if let i = contents.tasks.firstIndex(where: { $0.id == item.id }) { contents.tasks[i].done = done }
                                    }
                                })).toggleStyle(.checkbox).foregroundStyle(item.done ? .secondary : .primary)
                                    .strikethrough(item.done).frame(maxWidth: .infinity, alignment: .leading)
                                removalButton(item.id) {
                                    notebook.edit { $0.tasks.removeAll { $0.id == item.id } }
                                }
                            }.padding(.vertical, 13)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
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

    private func addTask() {
        let value = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if notebook.edit({ $0.tasks.append(.init(title: value)) }) { newTask = "" }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
    }
}
