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
    }
    struct Contents: Codable {
        var memo = ""
        var calculation = ""
        var tasks: [Entry] = []
        var words: [Word] = []
    }

    private let file: URL
    private(set) var contents = Contents()
    private(set) var issue: String?
    private(set) var readable = true

    init(directory: URL) {
        file = directory.appendingPathComponent("sidebar-notebook.json")
        do { contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file)) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile {}
        catch { readable = false; issue = "暂时无法打开已保存的工具资料。" }
    }

    @discardableResult func edit(_ body: (inout Contents) -> Void) -> Bool {
        guard readable else { return false }
        var next = contents
        body(&next)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            contents = next
            issue = nil
            return true
        } catch { issue = "保存失败：" + error.localizedDescription; return false }
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
