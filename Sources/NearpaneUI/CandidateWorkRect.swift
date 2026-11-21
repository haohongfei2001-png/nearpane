import AppKit
import NearpaneCore
import SwiftUI

/// Owns one serialized manager for the whole Host, independent of panel visibility.
@MainActor @Observable public final class CandidateWorkRect {
    let support: URL
    let ordinary: OrdinaryWindowManager
    let desktopTiling: DesktopAutomaticTiling
    private var enrolledDesktopFeed: CurrentDesktopWindows?
    weak var stageEngine: StageWindowEngineHost?
    func permitsStageEngine(on display: String) -> Bool {
        !suspended && supervisorReady && !blocked && mode == "off" && count == 0 && !ordinary.blocksUpdateRelaunch &&
            desktopTiling.scope == nil && !desktopTiling.starting && context(for:display) != nil
    }
    public func enrollDesktopTrial(_ owners: [AdmissionFixtureOwner], display: String) -> Bool {
        guard scopedDisplay == display, enrolledDesktopFeed == nil, desktopTiling.scope == nil,
              owners.count == 2, Set(owners.map(\.pid)).count == 2, let read = NativeDesktopProvider.packagedReader(overview: true)
        else { return false }
        let feed = CurrentDesktopWindows(read: read)
        desktopTiling.connect(feed) { key in owners.contains { $0.pid == key.pid && $0.launch == key.birth } }
        enrolledDesktopFeed = feed
        return true
    }
    fileprivate var hasDesktopTrial: Bool { enrolledDesktopFeed != nil }
    /// Readiness of the signed application and its packaged inventory reader. No AX setters or UI.
    public static func desktopTilingReadiness() async -> [String: Bool] {
        let screens = SystemScreens.geometry()
        var result = ["oneDisplay": screens.count == 1, "currentOrdinarySpace": false,
                      "hostAccessibility": AXIsProcessTrusted(), "readerAccessibility": false]
        guard screens.count == 1, let display = screens.first?.id, let read = NativeDesktopProvider.packagedReader(overview: true),
              let sample = try? await read(.init(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: nil,
                                                 anchors: [], experimentalSpaces: false)) else { return result }
        result["currentOrdinarySpace"] = DesktopTilingRoster(sample, display: display) != nil
        result["readerAccessibility"] = sample.native?.accessibility == .available
        return result
    }
    private weak var host: HostSession?
    public internal(set) var scopedDisplay: String?
    public func restrictOrdinaryAcceptance(to display: String) { scopedDisplay = display }
    fileprivate private(set) var supervisorReady = false
    private var suspended = false
    private enum DesktopWitness {
        case ordinary(until: Double)
        case withheld
        case awaitingSource
    }
    private var desktopWitnesses = [String: DesktopWitness]()
    private var holds = Set<String>()
    public func setOrdinaryHold(_ reason: String, active: Bool) {
        let previous = suspended
        if active { holds.insert(reason) } else { holds.remove(reason) }
        suspended = !holds.isEmpty
        if suspended != previous { desktopTiling.dispatchAvailabilityChanged(!suspended) }
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
        desktopTiling.nativeModeAvailable = { [weak self, weak host] in
            self?.suspended == false && host?.workspaceMode.mode == .native
        }
        ordinary.liveContext = { [weak self] display in self?.context(for: display) }
        ordinary.saveExclusion = { [weak host] id in
            guard let host else { throw OrdinaryRefusal.storage }
            var preferences = host.workspacePreferencesDraft
            preferences.windows[id] = .exclude
            guard host.setWorkspacePreferences(preferences) else { throw OrdinaryRefusal.storage }
        }
    }
    /// A saved acceptance scope is a restriction, never a fallback to the remaining screen.
    static func selectedDisplay(_ id: String, on screens: [ScreenGeometry], restrictedTo scope: String?) -> ScreenGeometry? {
        guard !id.isEmpty, scope == nil || scope == id else { return nil }
        let matches = screens.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    func context(for display: String) -> AdmissionContext? {
        let screens = SystemScreens.geometry()
        guard let host, host.unsavedWorkspacePreferences == nil, let first = screens.first,
              let target = Self.selectedDisplay(display, on: screens, restrictedTo: scopedDisplay), !suspended,
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
    var updateRequiresManagementToFinish: Bool {
        !supervisorReady || mode != "off" || count != 0 || blocked || ordinary.blocksUpdateRelaunch || desktopTiling.scope != nil || desktopTiling.starting
    }

    init(support: URL) {
        self.support = support
        ordinary = OrdinaryWindowManager(support: support)
        desktopTiling = DesktopAutomaticTiling(manager: ordinary)
        ordinary.stageEngineOwnsWindows = { [weak self] in self?.stageEngine?.holdsDispatch == true }
        ordinary.presentationHeld = { [weak self] display in
            guard let self else { return true }
            return suspended || !permitsOrdinaryPresentation(on: display, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }
    public func restoreCleanDesktopPermission() {
        do {
            if let desktop = try OrdinaryJournal(support: support).takeCleanDesktop() {
                desktopTiling.awaitCleanDesktop(desktop)
            }
        } catch { ordinary.report(error) }
    }
    public func start() {
        guard process == nil else { return }
        supervisorReady = false
        let child = Process(), commands = Pipe(), replies = Pipe()
        do { child.executableURL = try BundledAutomation.executable() }
        catch { message = error.localizedDescription; blocked = true; return }
        child.arguments = ["workrect", support.path]
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
        guard command == "quit" || stageEngine?.holdsDispatch != true else { return }
        if process == nil { start() }
        guard let input else { return }
        do { try input.write(contentsOf: Data((command + "\n").utf8)) }
        catch { message = error.localizedDescription; blocked = true }
    }
    public func finish() async {
        let desktop = await desktopTiling.prepareForExit()
        await ordinary.finish()
        desktopTiling.end()
        if let desktop, ordinary.activeIDs.isEmpty, !ordinary.blocked {
            do { try OrdinaryJournal(support: support).rememberCleanDesktop(desktop) }
            catch { ordinary.report(error) }
        }
        if input != nil { send("quit") }
        try? input?.close(); input = nil
        await monitor?.value
    }
}

private typealias ViewState<T> = State<T>
public struct CandidateWorkRectView: View {
    let session: CandidateWorkRect, host: HostSession
    private let admissionFixtureOnly: Bool
    private let showsTestTools: Bool
    private let owners: [AdmissionFixtureOwner]
    private let previewExposure: SettingsPreviewExposure?
    @ViewState private var showingCompatibility = false
    @ViewState private var confirm = false
    @ViewState private var desktopChoice: OrdinaryDesktopIdentity?
    @ViewState private var confirmingDesktop = false
    @AppStorage("managementPairPercent") private var percent = 60
    @AppStorage("managementPairSwap") private var swap = false

    public init(session: CandidateWorkRect, host: HostSession, admissionFixtureOnly: Bool = false, showsTestTools: Bool = false, owners: [AdmissionFixtureOwner] = [],
                previewExposure: SettingsPreviewExposure? = nil) {
        self.showsTestTools = showsTestTools
        self.previewExposure = previewExposure
        self.owners = owners
        self.session = session
        self.host = host
        self.admissionFixtureOnly = admissionFixtureOnly
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if (!admissionFixtureOnly && !showsTestTools) || session.hasDesktopTrial {
                    desktopControls
                    Divider()
                }
                WindowAdmissionSettings(host: host, manager: session, fixtureOnly: admissionFixtureOnly, owners: owners,
                                        exposure: previewExposure)
                if showsTestTools {
                    Divider()
                    DisclosureGroup("随包兼容应用", isExpanded: $showingCompatibility) {
                        compatibilityControls
                    }
                    .onAppear { if session.blocked || session.mode != "off" { showingCompatibility = true } }
                    .onChange(of: session.blocked) { _, blocked in if blocked { showingCompatibility = true } }
                } else if session.blocked || session.mode != "off" {
                    Divider()
                    Text(session.message).font(.callout).textSelection(.enabled)
                    if session.blocked {
                        Button("重新核对窗口并恢复") { session.send("retry") }
                    } else {
                        Button("停止兼容窗口管理并恢复位置") { session.send("disable") }
                    }
                }
                Text("在「外观与尺寸」调整预留宽度，在「窗口规则」设置应用排除。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }

    private var desktopControls: some View {
        let tiling = session.desktopTiling
        return VStack(alignment: .leading, spacing: 6) {
            if tiling.scope != nil {
                Text("本桌面自动分屏已启用")
                HStack {
                    Button("停止自动分屏并恢复") {
                        Task {
                            do { try await session.ordinary.performUserAction { try await session.ordinary.stop() } }
                            catch { session.ordinary.report(error) }
                        }
                    }.disabled(session.ordinary.unavailableForUserAction).accessibilityIdentifier("desktop-tiling-stop")
                    Button("重新核对窗口") { tiling.retry() }.disabled(session.ordinary.paused || session.ordinary.blocked)
                }
            } else if tiling.waitingForDesktop != nil {
                Text("等待上次允许的桌面。")
                Button("停止自动分屏") { tiling.end() }
            } else {
                if confirmingDesktop, let choice = desktopChoice {
                    Text("允许排列本桌面上符合条件的已有窗口和新窗口，包括不同应用。正常退出会恢复布局，下次打开会重新核对这个桌面。选择停止可撤销授权。")
                        .font(.callout)
                    HStack {
                        Button("允许并自动分屏") {
                            confirmingDesktop = false; desktopChoice = nil
                            Task { await tiling.start(choice) }
                        }.accessibilityIdentifier("desktop-tiling-confirm")
                        Button("取消") { confirmingDesktop = false; desktopChoice = nil }
                    }
                } else {
                    Button("启用本桌面自动分屏…") {
                        Task {
                            let screens = SystemScreens.geometry()
                            let number = NSApp.keyWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                            let id = session.scopedDisplay ?? number.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
                                .map { CFUUIDCreateString(nil, $0) as String } ?? (screens.count == 1 ? screens.first?.id : nil)
                            guard let id, screens.contains(where: { $0.id == id }) else {
                                session.ordinary.report(OrdinaryRefusal.scope); return
                            }
                            desktopChoice = await tiling.proposed(on: id)
                            confirmingDesktop = desktopChoice != nil
                        }
                    }
                    .disabled(tiling.starting || !session.ordinary.activeIDs.isEmpty || session.ordinary.blocked)
                    .accessibilityIdentifier("desktop-tiling-enable")
                }
                Text("一扇窗口占满工作区，两扇默认左右平分。也可以在下方只选择指定窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tiling.notice.isEmpty { Text(tiling.notice).font(.caption).foregroundStyle(.secondary) }
            if tiling.unpresented > 0 {
                Text("另有 \(tiling.unpresented) 扇窗口属于此桌面，目前未呈现。可在侧栏选中它们。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if StageManagerPreference.read() == true {
                Text("台前调度已开启。要让不同组的窗口同时参与分屏，可在「系统设置 → 桌面与程序坞」关闭台前调度。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开桌面与程序坞设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
            }
        }
    }

    private var compatibilityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Group {
                if session.supervisorReady {
                    Text(session.trusted ? "控制器辅助功能已核对 · 已登记 \(session.windows.count) 扇 · 当前范围 \(session.count) 扇" : "窗口控制器本次未取得辅助功能访问。")
                } else { Text("等候窗口控制器状态。") }
            }.font(.caption)
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
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
}
