import AppKit
import NearpaneCore
import SwiftUI

/// The registry controls visibility. Private text stays inside the profile and never enters the Host bus.
@MainActor final class NotebookModule: HostModule {
    func start() throws {}
    func stop() {}
    func suspend() {}
    func resume() throws {}
    func perform(_ action: ModuleAction) throws {}
    func snapshot() throws -> ModuleProjection { .init(message: "") }
}

/// The active profile owns the note, calculation draft, tasks and explicitly looked-up vocabulary.
@MainActor @Observable final class SidebarNotebook {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var done = false
    }
    struct Word: Codable, Identifiable, Equatable {
        var id = UUID()
        let source: String
        let translation: String
        let language: String
        var sourceLanguage: String?
        var providerVersion: String?
        var committedAt: Date?
        var requestID: UUID?
        var sourceSHA256: String?

        var normalizedSource: String {
            source.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
        }
    }
    private let file: URL
    private let recoveryFile: URL
    private let legacyFile: URL
    private var pendingLegacyBackup: Data?
    private var recoverableContents: Contents?
    private(set) var contents = Contents()
    private(set) var issue: String?
    private(set) var readable = true
    private(set) var hasUnsavedChanges = false
    private(set) var recoveryAvailable = false

    init(directory: URL) {
        file = directory.appendingPathComponent("sidebar-notebook.json")
        recoveryFile = directory.appendingPathComponent("sidebar-notebook.recovery.json")
        legacyFile = directory.appendingPathComponent("sidebar-notebook.v1-backup.json")
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.userInfo[.notebookMigrationDate] =
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date ?? Date()
            contents = try decoder.decode(Contents.self, from: data)
            try contents.validate()
            if contents.migratedFromLegacy {
                pendingLegacyBackup = data
                hasUnsavedChanges = true
                _ = retrySave()
            }
        } catch let error as NotebookStorageError {
            readable = false
            issue = error.errorDescription
            if case .unsupportedVersion = error { return }
            findRecoveryCopy()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A missing primary beside an existing recovery copy is not a new notebook.
            if FileManager.default.fileExists(atPath: recoveryFile.path) {
                readable = false
                issue = "记录文件暂时不可用。恢复副本和原有资料均已保留。"
                findRecoveryCopy()
            }
        } catch {
            readable = false
            issue = "暂时无法打开已保存的工具资料。原文件已保留。"
            findRecoveryCopy()
        }
    }

    func words(matching query: String) -> [Word] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return contents.words }
        return contents.words.filter { $0.source.localizedStandardContains(term) || $0.translation.localizedStandardContains(term) }
    }

    /// A saved answer can stand on its own only for the same text and known translation direction.
    func savedTranslation(for source: String, from: String, to: String) -> String? {
        guard readable else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let answers = Set(contents.words.compactMap { word -> String? in
            guard word.sourceLanguage == from, word.language == to,
                  word.source.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return nil }
            let answer = word.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        })
        return answers.count == 1 ? answers.first : nil
    }

    func diskWord(for request: UUID) throws -> Word? {
        do {
            return try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file)).words.first { $0.requestID == request }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func commit(_ request: TranslationRequest, answer: String, from: String, to: String, provider: String) throws -> Word {
        if let saved = try diskWord(for: request.id) { return saved }
        let word = Word(source: request.source, translation: answer, language: to, sourceLanguage: from,
                        providerVersion: provider, committedAt: Date(), requestID: request.id, sourceSHA256: request.hash)
        guard edit({ data in
            data.words.removeAll { $0.normalizedSource == word.normalizedSource && $0.language == to &&
                $0.sourceLanguage == from && $0.providerVersion == provider }
            data.words.insert(word, at: 0)
        }), let readback = try diskWord(for: request.id), readback == word else { throw CocoaError(.fileWriteUnknown) }
        return readback
    }

    @discardableResult func edit(_ body: (inout Contents) -> Void) -> Bool {
        guard readable else { return false }
        var next = contents
        body(&next)
        guard next != contents || hasUnsavedChanges else { return true }
        do { try next.validate() }
        catch { issue = "无法保存这次更改：" + error.localizedDescription; return false }
        // Keep the user's text visible if a disk write fails; retry never needs retyping.
        contents = next
        hasUnsavedChanges = true
        return retrySave()
    }

    @discardableResult func retrySave() -> Bool {
        guard readable else { return false }
        do {
            try contents.validate()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let original = pendingLegacyBackup {
                let destination: URL
                if FileManager.default.fileExists(atPath: legacyFile.path),
                   (try Data(contentsOf: legacyFile)) != original {
                    destination = file.deletingLastPathComponent()
                        .appendingPathComponent("sidebar-notebook.v1-backup-" + UUID().uuidString + ".json")
                } else { destination = legacyFile }
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try original.write(to: destination, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    try synchronizeFile(destination)
                }
                pendingLegacyBackup = nil
            }
            let data = try JSONEncoder().encode(contents)
            try writeDocument(data, to: file)
            hasUnsavedChanges = false
            contents.migratedFromLegacy = false
            issue = nil
            // This mirror contains the latest committed document, including the last keystroke.
            do { try writeDocument(data, to: recoveryFile) }
            catch { issue = "记录已保存，但恢复副本暂时无法更新。" }
            return true
        } catch { issue = "保存失败：" + error.localizedDescription; return false }
    }

    /// Recovery is explicit, so an unreadable or newer primary is never silently overwritten.
    @discardableResult func recoverLastSavedCopy() -> Bool {
        guard !readable, recoveryAvailable, let recovered = recoverableContents else { return false }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let preserved = file.deletingLastPathComponent()
                    .appendingPathComponent("sidebar-notebook.unreadable-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: file, to: preserved)
            }
            let data = try JSONEncoder().encode(recovered)
            try writeDocument(data, to: file)
            contents = recovered
            readable = true
            hasUnsavedChanges = false
            recoveryAvailable = false
            recoverableContents = nil
            issue = nil
            return true
        } catch { issue = "暂时无法恢复记录：" + error.localizedDescription; return false }
    }

    private func findRecoveryCopy() {
        guard let data = try? Data(contentsOf: recoveryFile),
              let recovered = try? JSONDecoder().decode(Contents.self, from: data),
              (try? recovered.validate()) != nil else { return }
        recoverableContents = recovered
        recoveryAvailable = true
    }

    private func writeDocument(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try synchronizeFile(destination)
    }

    private func synchronizeFile(_ destination: URL) throws {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

/// A numeric expression in the note never executes code or resolves variable names.
enum NoteArithmetic {
    private enum ParseError: Error { case invalid }
    static func result(_ text: String) -> String? {
        var parser = Parser(input: Array(text.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")))
        guard let number = try? parser.expression(), parser.next == nil, !number.isNaN else { return nil }
        return NSDecimalNumber(decimal: number).stringValue
    }
    private struct Parser {
        let input: [Character]
        var position = 0
        var depth = 0
        var next: Character? {
            mutating get {
                while position < input.count && input[position].isWhitespace { position += 1 }
                return position < input.count ? input[position] : nil
            }
        }
        mutating func expression() throws -> Decimal {
            var value = try term()
            while let op = next, op == "+" || op == "-" {
                position += 1
                let other = try term()
                value = op == "+" ? value + other : value - other
            }
            return value
        }
        mutating func term() throws -> Decimal {
            var value = try factor()
            while let op = next, op == "*" || op == "/" {
                position += 1
                let other = try factor()
                guard op != "/" || other != 0 else { throw ParseError.invalid }
                value = op == "*" ? value * other : value / other
            }
            return value
        }
        mutating func factor() throws -> Decimal {
            var negative = false
            while let op = next, op == "-" || op == "+" {
                if op == "-" { negative.toggle() }
                position += 1
            }
            let value: Decimal
            if next == "(" {
                guard depth < 64 else { throw ParseError.invalid }
                position += 1
                depth += 1
                value = try expression()
                guard next == ")" else { throw ParseError.invalid }
                position += 1
                depth -= 1
            } else {
                let start = position
                while position < input.count && ("0123456789.".contains(input[position])) { position += 1 }
                let token = String(input[start..<position])
                guard token.contains(where: { $0.isNumber }), token.filter({ $0 == "." }).count <= 1,
                      let parsed = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else { throw ParseError.invalid }
                value = parsed
            }
            return negative ? -value : value
        }
    }
}

private typealias NotebookState<T> = State<T>

struct WordbookSection: View {
    let notebook: SidebarNotebook
    @NotebookState private var query = ""

    var body: some View {
        DisclosureGroup("单词本") {
            if !notebook.readable {
                Text(notebook.issue ?? "暂时无法打开单词本。").font(.caption)
            } else if notebook.contents.words.isEmpty {
                Text("尚无查询记录").font(.caption)
            } else {
                HStack {
                    TextField("查找原文或译文", text: $query)
                        .accessibilityIdentifier("wordbook-search")
                    if !query.isEmpty {
                        Button("清除搜索") { query = "" }.buttonStyle(.borderless)
                    }
                }
                let matches = notebook.words(matching: query)
                if matches.isEmpty { Text("没有匹配的词条").font(.caption) }
                ForEach(matches) { word in
                    LabeledContent(word.source, value: word.translation).textSelection(.enabled)
                }
            }
        }
    }
}

struct NotebookCard: View {
    let notebook: SidebarNotebook
    let tasks: Bool
    @NotebookState private var inDraft = false
    @NotebookState private var result: String?
    @NotebookState private var newTask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tasks {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(notebook.contents.tasks) { item in
                            Toggle(item.title, isOn: Binding(get: { item.done }, set: { value in
                                notebook.edit { c in
                                    if let i = c.tasks.firstIndex(where: { $0.id == item.id }) { c.tasks[i].done = value }
                                }
                            }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("添加待办", text: $newTask).textFieldStyle(.plain).onSubmit {
                    let value = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, notebook.edit({ $0.tasks.append(.init(title: value)) }) { newTask = "" }
                }
            } else {
                let text = inDraft ? notebook.contents.calculation : notebook.contents.memo
                TextEditor(text: Binding(get: { inDraft ? notebook.contents.calculation : notebook.contents.memo }, set: { value in
                    result = nil
                    notebook.edit { if inDraft { $0.calculation = value } else { $0.memo = value } }
                })).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .accessibilityLabel(inDraft ? "计算草稿" : "备忘录")
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(inDraft ? "输入算式，点等号计算" : "随手记下一句话")
                                .font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.top, 3)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                HStack {
                    if let result {
                        Text(result).lineLimit(1).textSelection(.enabled)
                        Button { self.result = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("取消计算结果")
                    }
                    Spacer()
                    Button {
                        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                        result = NoteArithmetic.result(line) ?? "表达式不完整"
                    } label: { Image(systemName: "equal") }.accessibilityLabel("计算最后一行")
                    Button {
                        inDraft.toggle()
                        result = nil
                    } label: { Image(systemName: inDraft ? "arrow.uturn.backward" : "square.and.pencil") }
                        .accessibilityLabel(inDraft ? "返回备忘录" : "打开计算草稿")
                }.buttonStyle(.borderless)
            }
            if let issue = notebook.issue { Text(issue).font(.caption).lineLimit(2).help(issue) }
        }.padding(10).disabled(!notebook.readable)
    }
}
