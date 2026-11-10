import AppKit
import NearpaneCore
import SwiftUI

/// Owns one serialized manager for the whole Host, independent of panel visibility.
@MainActor @Observable public final class CandidateWorkRect {
    private let support: URL
    private var process: Process?
    private var input: FileHandle?
    private var monitor: Task<Void, Never>?
    private(set) var mode = "off"
    private(set) var count = 0
    public private(set) var windows = [ManagedWindowID]()
    private(set) var message = "正在读取管理设置…"
    private(set) var blocked = false
    private(set) var trusted = false

    init(support: URL) { self.support = support }
    public func start() {
        guard process == nil, let folder = Bundle.main.resourceURL else { return }
        let child = Process(), commands = Pipe(), replies = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", "-B", "-u", folder.appendingPathComponent("WorkRect/window-management.py").path, support.path]
        child.standardInput = commands; child.standardOutput = replies
        do { try child.run() } catch { message = error.localizedDescription; blocked = true; return }
        process = child; input = commands.fileHandleForWriting
        monitor = Task {
            struct Reply: Decodable {
                let mode: String, members: Int, windows: [ManagedWindowID], detail: String, blocked: Bool, trusted: Bool
            }
            do {
                for try await line in replies.fileHandleForReading.bytes.lines {
                    let reply = try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
                    mode = reply.mode; count = reply.members; windows = reply.windows
                    message = reply.detail; blocked = reply.blocked; trusted = reply.trusted
                }
            } catch { message = error.localizedDescription; blocked = true }
            try? input?.close(); input = nil
            await Task.detached { child.waitUntilExit() }.value
            process = nil
            if child.terminationStatus != 0 { blocked = true }
        }
    }
    public func send(_ command: String) {
        if process == nil { start() }
        guard let input else { return }
        do { try input.write(contentsOf: Data((command + "\n").utf8)) }
        catch { message = error.localizedDescription; blocked = true }
    }
    public func finish() async {
        if input != nil { send("quit") }
        try? input?.close(); input = nil
        await monitor?.value
    }
}

private typealias ViewState<T> = State<T>
public struct CandidateWorkRectView: View {
    let session: CandidateWorkRect, host: HostSession
    @ViewState private var confirm = false
    @AppStorage("managementPairPercent") private var percent = 60
    @AppStorage("managementPairSwap") private var swap = false

    public init(session: CandidateWorkRect, host: HostSession) { self.session = session; self.host = host }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("已核准应用：Nearpane 随附的兼容窗口应用，仅管理在副屏登记的窗口。TextEdit、计算器和预览暂未开放。")
                Text(session.message).textSelection(.enabled)
                if session.mode == "off" {
                    Button("启用自动窗口管理…") { confirm = true }
                        .alert("允许自动调整副屏兼容窗口？", isPresented: $confirm) {
                            Button("取消", role: .cancel) {}
                            Button("允许并启用") { session.send("enable") }
                        } message: { Text("当前及以后打开的兼容窗口将按工作区域排列。退出时撤销自动布局，保留你保存的分割位置。") }
                } else {
                    HStack {
                        Button(session.mode == "paused" ? "继续管理" : "暂停管理") {
                            session.send(session.mode == "paused" ? "resume" : "pause")
                        }
                        Button("停止并恢复") { session.send("disable") }
                        if session.blocked { Button("重新核对并恢复") { session.send("retry") } }
                    }
                }
                Text(session.trusted ? "辅助功能已核对 · 范围内窗口 \(session.count)" : "写入前将核对控制器的辅助功能权限")
                    .font(.caption)
                HStack {
                    Button("打开兼容应用窗口") { session.send("open") }
                    if !session.windows.isEmpty { Button("关闭末个兼容窗口") { session.send("close") } }
                }
                ForEach(session.windows, id: \.self) { id in
                    let excluded = (try? host.configuration.workspaces.excluded(id, bundle: "org.nearpane.lab.NearpaneFixtureWindows")) != false
                    Toggle("管理窗口 \(String(id.number))", isOn: Binding(get: { !excluded }, set: { include in
                        var prefs = host.configuration.workspaces
                        prefs.windows[id] = include ? .include : .exclude
                        host.setWorkspacePreferences(prefs)
                    }))
                }
                if session.mode == "active" && session.count == 2 {
                    Stepper("左侧比例  \(percent)%", value: $percent, in: 20...80)
                    Toggle("交换左右槽位", isOn: $swap)
                    HStack {
                        Button("应用双窗布局") { session.send("pair \(percent) \(swap ? "swap" : "original")") }
                        Button("保存窗口上的手动调整") { session.send("adopt") }
                    }
                }
                Text("工作区域位于「尺寸与呈现」。应用排除和新窗口归属位于「窗口规则」。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }
}
