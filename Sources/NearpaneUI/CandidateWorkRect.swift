import AppKit
import SwiftUI

/// The supervisor accepts a closed command vocabulary and enrolls its own child windows.
@MainActor @Observable public final class CandidateWorkRect {
    private let support: URL
    private var process: Process?
    private var input: FileHandle?
    private var monitor: Task<Void, Never>?
    private(set) var ready = false
    private(set) var busy = false
    private(set) var count = 0
    private(set) var message = "仅管理本次创建的副屏示例窗。"
    var running: Bool { process != nil }
    init(support: URL) { self.support = support }

    func start() {
        guard process == nil, let folder = Bundle.main.resourceURL else { return }
        let child = Process(), commands = Pipe(), replies = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", "-B", "-u", folder.appendingPathComponent("WorkRect/candidate-workrect.py").path, support.path]
        child.standardInput = commands
        child.standardOutput = replies
        do { try child.run() } catch { message = error.localizedDescription; return }
        process = child
        input = commands.fileHandleForWriting
        busy = true
        message = "正在核对副屏、辅助功能与控制器身份…"
        monitor = Task {
            defer { input = nil; process = nil; ready = false; busy = false; count = 0 }
            do {
                for try await line in replies.fileHandleForReading.bytes.lines {
                    struct Reply: Decodable { let ready: Bool, members: Int, detail: String? }
                    let reply = try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
                    ready = reply.ready
                    busy = false
                    count = reply.members
                    message = reply.detail ?? "已就绪，可以添加测试窗口。"
                }
            } catch { message = error.localizedDescription }
            try? input?.close()
            await Task.detached { child.waitUntilExit() }.value
            if child.terminationStatus != 0 { message = "已停止 · " + message }
        }
    }
    func send(_ command: String) {
        guard ready, !busy, let input else { return }
        do { try input.write(contentsOf: Data((command + "\n").utf8)); busy = true }
        catch { message = error.localizedDescription }
    }
    func end() {
        try? input?.close()
        input = nil
        ready = false
    }
    public func finish() async { end(); await monitor?.value }
}

struct CandidateWorkRectView: View {
    let session: CandidateWorkRect
    @AppStorage("alphaPairPercent") private var percent = 60
    @AppStorage("alphaPairSwap") private var swap = false
    var body: some View {
        Form {
            Text("副屏测试窗口")
            if session.running {
                HStack {
                    Button("添加一窗") { session.send("add") }.disabled(session.count >= 5)
                    Button("移除末窗") { session.send("remove") }.disabled(session.count <= 1)
                }.disabled(!session.ready || session.busy)
                Stepper("左侧比例  \(percent)%", value: $percent, in: 20...80, step: 1)
                Toggle("交换双窗位置", isOn: $swap)
                Button("应用双窗布局") { session.send("pair \(Double(percent)/100) \(swap ? "swap" : "original")") }
                    .disabled(!session.ready || session.busy || session.count != 2)
                Button("结束并恢复") { session.end() }
            } else {
                Button("开始副屏窗口体验") { session.start() }
            }
            Text(session.message).font(.caption).textSelection(.enabled)
        }.padding()
    }
}
