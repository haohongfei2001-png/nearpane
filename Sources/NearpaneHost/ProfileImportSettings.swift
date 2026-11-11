#if canImport(SaytileKit)
import AppKit
import SwiftUI

struct ProfileReply: Decodable, Sendable {
    let ok: Bool
    let message: String
    struct Summary: Decodable, Sendable {
        let voiceRecords, voiceRevisions, voiceDrafts, voiceAudioChunks: Int
        let trayAssets, trayOperations, trayUnknown, trayFailed, displaySettings: Int
    }
    let summary: Summary?
    let token: String?
    let rollbackToken: String?
    let canRollback: Bool?
}

enum ProfileHelper {
    static func run(_ action: String, root: URL, source: URL? = nil, sections: [String] = [],
                    token: String? = nil) async throws -> ProfileReply {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("Profile/profile-migration.py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await Task.detached {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var arguments = ["-I", "-B", script.path, action, "--container", root.path]
            if let source { arguments += ["--source", source.path, "--sections", sections.joined(separator: ",")] }
            if let token { arguments += ["--token", token] }
            child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = pipe
            try child.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard bytes.count <= 512 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let reply = try JSONDecoder().decode(ProfileReply.self, from: bytes)
            guard child.terminationStatus == 0, reply.ok else {
                throw NSError(domain: "Nearpane.Profile", code: 2, userInfo: [NSLocalizedDescriptionKey: reply.message])
            }
            return reply
        }.value
    }
}

@MainActor @Observable final class ProfileImportOptions {
    static let sources = ["P5.2", "P5.1", "P5.0", "P4.9", "P4.8.1", "P4.8"]
    let root: URL
    private let applyChange: (String, URL?, [String], String) async throws -> ProfileReply
    var version = ""
    var sections: Set<String> = ["voice", "tray", "settings"]
    var preview: ProfileReply?
    var rollbackToken: String?
    var message = ""
    var busy = false

    init(root: URL, apply: @escaping (String, URL?, [String], String) async throws -> ProfileReply) {
        self.root = root
        self.applyChange = apply
    }

    func resetPreview() { preview = nil; message = "" }

    static func requireClosed(_ version: String) throws {
        guard sources.contains(version) else { throw CocoaError(.fileReadInvalidFileName) }
        let id = "com.holdsnow.nearpane.candidate.p" + version.dropFirst().replacingOccurrences(of: ".", with: "")
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).allSatisfy(\.isTerminated) else {
            throw NSError(domain: "Nearpane.Profile", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先退出 Nearpane " + version + "，再预览或导入它的资料。"])
        }
    }

    func loadStatus() async {
        do {
            let reply = try await ProfileHelper.run("status", root: root)
            rollbackToken = reply.canRollback == true ? reply.rollbackToken : nil
        } catch { message = error.localizedDescription }
    }

    func perform(_ action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if action == "rollback" {
                guard let rollbackToken else { return }
                _ = try await applyChange(action, nil, [], rollbackToken)
                return
            }
            try Self.requireClosed(version)
            let source = root.deletingLastPathComponent().appendingPathComponent("Nearpane Alpha " + version)
            let groups = sections.sorted()
            guard !groups.isEmpty else { return }
            if action == "preview" {
                resetPreview()
                preview = try await ProfileHelper.run(action, root: root, source: source, sections: groups)
            } else if action == "import", let token = preview?.token {
                _ = try await applyChange(action, source, groups, token)
            }
        } catch { preview = nil; message = error.localizedDescription }
    }
}

private typealias FormState<T> = State<T>

struct ProfileImportSettings: View {
    @Bindable var options: ProfileImportOptions
    @FormState private var expanded = false
    @FormState private var confirmRollback = false

    init(options: ProfileImportOptions, initiallyExpanded: Bool = false) {
        self.options = options
        _expanded = FormState(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup("从此前 Nearpane 版本导入", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("来源", selection: $options.version) {
                    Text("选择版本").tag("")
                    ForEach(ProfileImportOptions.sources, id: \.self) { Text("Nearpane " + $0).tag($0).accessibilityIdentifier("np.profile.source" + $0.dropFirst().replacingOccurrences(of: ".", with: "")) }
                }
                .accessibilityIdentifier("np.profile.version")
                .onChange(of: options.version) { _, _ in options.resetPreview() }
                HStack {
                    ForEach([("voice", "文字与修订"), ("tray", "截图与历史"), ("settings", "设置")], id: \.0) { key, label in
                        Toggle(label, isOn: Binding(get: { options.sections.contains(key) }, set: { enabled in
                            if enabled { options.sections.insert(key) } else { options.sections.remove(key) }
                            options.resetPreview()
                        }))
                    }
                }
                Text("选中的项目将替换当前对应资料，其余项目继续保留。可恢复到切换前的整份资料。")
                    .font(.caption)
                Button("预览导入") { Task { await options.perform("preview") } }
                    .disabled(options.version.isEmpty || options.sections.isEmpty)
                    .accessibilityIdentifier("np.profile.preview")
                if let preview = options.preview {
                    Text(preview.message)
                    if let info = preview.summary {
                        if options.sections.contains("voice") {
                            Text("语音资料含 \(info.voiceRecords) 条记录、\(info.voiceRevisions) 条修订、\(info.voiceDrafts) 条编辑草稿。原始录音块 \(info.voiceAudioChunks) 个，保留在旧版本。").font(.caption)
                        }
                        if options.sections.contains("tray") {
                            Text("托盘含 \(info.trayAssets) 张截图、\(info.trayOperations) 项历史操作，其中 \(info.trayUnknown) 项结果未知、\(info.trayFailed) 项失败。历史操作不会重发。").font(.caption)
                        }
                        if options.sections.contains("settings") {
                            Text("保留 \(info.displaySettings) 份显示器设置。窗口管理需重新授权。").font(.caption)
                        }
                    }
                    Text("文件夹书签、钥匙串及系统授权须在新版本单独设置。").font(.caption)
                    Text("确认后会停止当前模块。重新打开 Nearpane 后使用导入资料；附件和窗口权限需重新确认。").font(.caption)
                    Button("确认导入所选资料") { Task { await options.perform("import") } }
                        .disabled(preview.token == nil).accessibilityIdentifier("np.profile.import")
                }
                if options.rollbackToken != nil {
                    Button("恢复上一份资料…") { confirmRollback = true }
                        .confirmationDialog("恢复到上次切换前的整份资料？", isPresented: $confirmRollback) {
                            Button("确认回退并停止模块") { Task { await options.perform("rollback") } }
                        } message: { Text("当前资料会单独保留。重新打开 Nearpane 后使用恢复的资料。") }
                }
                if options.busy { ProgressView().controlSize(.small) }
                if !options.message.isEmpty { Text(options.message).font(.callout).textSelection(.enabled) }
            }
            .padding(.vertical, 6).disabled(options.busy)
            .task { await options.loadStatus() }
        }
    }
}
#endif
