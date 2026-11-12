import AppKit
import NearpaneCore
import SwiftUI

/// Owns one serialized manager for the whole Host, independent of panel visibility.
@MainActor @Observable public final class CandidateWorkRect {
    let support: URL
    let ordinary: OrdinaryWindowManager
    private weak var host: HostSession?
    public internal(set) var scopedDisplay: String?
    public func restrictOrdinaryAcceptance(to display: String) { scopedDisplay = display }
    private var supervisorReady = false
    private var suspended = false
    private enum DesktopWitness {
        case ordinary(until: Double)
        case withheld
        case awaitingSource
    }
    private var desktopWitnesses = [String: DesktopWitness]()
    private var holds = Set<String>()
    public func setOrdinaryHold(_ reason: String, active: Bool) {
        if active { holds.insert(reason) } else { holds.remove(reason) }
        suspended = !holds.isEmpty
    }
    public func ordinaryPresentation(_ state: String, display: String, deadline: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        let managedHere = ordinary.activeDisplay == display
        switch state {
        case "hold":
            desktopWitnesses[display] = managedHere ? .awaitingSource : .withheld
        case "ordinary", "returned":
            if case .awaitingSource = desktopWitnesses[display], managedHere && state != "returned" { return }
            guard let deadline, deadline.isFinite, deadline > now,
                  deadline - now <= FullscreenDisplaySample.maximumLifetime else {
                if case .awaitingSource = desktopWitnesses[display] { return }
                desktopWitnesses[display] = .withheld
                return
            }
            desktopWitnesses[display] = .ordinary(until: deadline)
        default:
            if case .ordinary = desktopWitnesses[display] { desktopWitnesses[display] = .withheld }
        }
    }
    func presentationPauseReason(on display: String, uptime: Double) -> String? {
        if permitsOrdinaryPresentation(on: display, uptime: uptime) { return nil }
        if case .awaitingSource = desktopWitnesses[display] {
            return "等待确认已返回全屏前的空间和窗口。原布局记录已保留。"
        }
        return "本屏普通桌面状态尚待核对，窗口调整已暂停。"
    }
    func permitsOrdinaryPresentation(on display: String, uptime: Double) -> Bool {
        switch desktopWitnesses[display] {
        // With no desktop observation source the existing independent target checks still apply.
        case nil: true
        case let .ordinary(until): uptime.isFinite && uptime < until
        case .withheld, .awaitingSource: false
        }
    }
    func connect(to host: HostSession) {
        self.host = host
        ordinary.liveContext = { [weak self] display in self?.context(for: display) }
        ordinary.saveExclusion = { [weak host] id in
            guard let host else { throw OrdinaryRefusal.storage }
            var preferences = host.workspacePreferencesDraft
            preferences.windows[id] = .exclude
            guard host.setWorkspacePreferences(preferences) else { throw OrdinaryRefusal.storage }
        }
    }
    func context(for display: String) -> AdmissionContext? {
        let screens = SystemScreens.geometry()
        guard let host, host.unsavedWorkspacePreferences == nil, let first = screens.first, let target = screens.dropFirst().first(where: { $0.id == display }),
              scopedDisplay == nil || scopedDisplay == display, !suspended,
              permitsOrdinaryPresentation(on: display, uptime: ProcessInfo.processInfo.systemUptime),
              supervisorReady, !blocked, mode == "off" else { return nil }
        func quartz(_ r: SurfaceRect) -> SurfaceRect {
            .init(x: r.x, y: first.frame.y + first.frame.height - r.y - r.height, width: r.width, height: r.height)
        }
        let cfg = host.configuration
        let primary = cfg.preferredDisplayID.flatMap { id in screens.first { $0.id == id }?.id } ?? first.id
        var context = AdmissionContext(display: display, screen: quartz(target.frame), usable: quartz(target.visibleFrame), primary: primary == display,
                                       settings: cfg.displays[display] ?? .init(), edge: cfg.edge, preferences: cfg.workspaces, recoveryClear: true, exclusive: true)
        context.displayGeometry = target
        return context
    }

    private var process: Process?
    private var input: FileHandle?
    private var monitor: Task<Void, Never>?
    private(set) var mode = "off"
    private(set) var count = 0
    public private(set) var windows = [ManagedWindowID]()
    private(set) var message = "正在读取管理设置…"
    private(set) var blocked = false
    private(set) var trusted = false

    init(support: URL) {
        self.support = support
        ordinary = OrdinaryWindowManager(support: support)
        ordinary.presentationHeld = { [weak self] display in
            self?.permitsOrdinaryPresentation(on: display, uptime: ProcessInfo.processInfo.systemUptime) != true
        }
    }
    public func start() {
        guard process == nil, let folder = Bundle.main.resourceURL else { return }
        supervisorReady = false
        let child = Process(), commands = Pipe(), replies = Pipe()
        guard let python = AppleHelperRuntime.python else {
            message = AppleHelperRuntime.Missing.interpreter.localizedDescription
            blocked = true
            return
        }
        child.executableURL = python
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
                    supervisorReady = true
                    mode = reply.mode; count = reply.members; windows = reply.windows
                    message = reply.detail; blocked = reply.blocked; trusted = reply.trusted
                }
            } catch { message = error.localizedDescription; blocked = true }
            supervisorReady = false
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
        await ordinary.finish()
        if input != nil { send("quit") }
        try? input?.close(); input = nil
        await monitor?.value
    }
}

private typealias ViewState<T> = State<T>
public struct CandidateWorkRectView: View {
    let session: CandidateWorkRect, host: HostSession
    private let admissionFixtureOnly: Bool
    private let owners: [AdmissionFixtureOwner]
    private let previewExposure: SettingsPreviewExposure?
    @ViewState private var confirm = false
    @AppStorage("managementPairPercent") private var percent = 60
    @AppStorage("managementPairSwap") private var swap = false

    public init(session: CandidateWorkRect, host: HostSession, admissionFixtureOnly: Bool = false, owners: [AdmissionFixtureOwner] = [],
                previewExposure: SettingsPreviewExposure? = nil) {
        self.previewExposure = previewExposure
        self.owners = owners
        self.session = session
        self.host = host
        self.admissionFixtureOnly = admissionFixtureOnly
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WindowAdmissionSettings(host: host, manager: session, fixtureOnly: admissionFixtureOnly, owners: owners,
                                        exposure: previewExposure)
                Divider()
                Text("随包兼容应用 · 自动管理").font(.headline)
                Text("此开关仅影响随包兼容应用。普通窗口需在上方逐窗选择和授权。").font(.callout)
                Text(session.message).textSelection(.enabled)
                if session.mode == "off" && !session.blocked {
                    Button("启用自动窗口管理…") { confirm = true }.disabled(!session.ordinary.activeIDs.isEmpty || session.ordinary.blocked || session.ordinary.busy)
                        .alert("允许自动调整副屏兼容窗口？", isPresented: $confirm) {
                            Button("取消", role: .cancel) {}
                            Button("允许并启用") { session.send("enable") }
                        } message: { Text("当前及以后打开的兼容窗口将按工作区域排列。退出时撤销自动布局，保留你保存的分割位置。") }
                } else {
                    HStack {
                        if session.mode != "off" && !session.blocked {
                            Button(session.mode == "paused" ? "继续管理" : "暂停管理") {
                                session.send(session.mode == "paused" ? "resume" : "pause")
                            }
                        }
                        Button("停止并恢复") { session.send("disable") }
                        if session.blocked { Button("重新核对并恢复") { session.send("retry") } }
                    }
                }
                Text(session.trusted ? "控制器辅助功能已核对 · 已登记 \(session.windows.count) 扇 · 当前范围 \(session.count) 扇" : "窗口写入需要单独核对随包控制器的辅助功能权限。")
                    .font(.caption)
                HStack {
                    Button("打开兼容应用窗口") { session.send("open") }
                    if !session.windows.isEmpty { Button("关闭末个兼容窗口") { session.send("close") } }
                }
                ForEach(session.windows, id: \.self) { id in
                    let excluded = (try? host.configuration.workspaces.excluded(id, bundle: "org.nearpane.lab.NearpaneFixtureWindows")) != false
                    Toggle("允许纳入管理范围 · 窗口 #\(String(id.number))", isOn: Binding(get: { !excluded }, set: { include in
                        var prefs = host.workspacePreferencesDraft
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
