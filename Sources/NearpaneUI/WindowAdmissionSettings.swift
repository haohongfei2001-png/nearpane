import AppKit
import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>

@MainActor protocol AdmissionReading {
    func applications() -> [AdmissionApplication]
    func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]
    func inspect(_ app: AdmissionApplication, selected: [AdmissionWindowChoice]) async throws -> [AdmissionPair]
    func safeguards(_ app: AdmissionApplication) -> (exclusive: Bool?, recoveryClear: Bool?)
    func storedLayout(_ app: AdmissionApplication) -> (layout: ManagedWindowTiler?, originals: [ManagedWindowID: SurfaceRect])?
}
extension WindowAdmissionReader: AdmissionReading {}

/// Coordinates observations only. A completed read belongs to the selection that started it.
@MainActor @Observable final class AdmissionSelection {
    struct Pick {
        let app: AdmissionApplication
        let choice: AdmissionWindowChoice
    }

    private let reader: any AdmissionReading
    private var generation = 0
    var apps = [AdmissionApplication]()
    var app: AdmissionApplication?
    var choices = [AdmissionWindowChoice]()
    var picks = [Pick]()
    var result: AdmissionPreviewResult?
    var sampledScreen: SurfaceRect?
    var samples = [AdmissionSample]()
    var sampledAt: Date?
    var failure: String?
    var reading = false
    var expired = false

    init(reader: any AdmissionReading) { self.reader = reader }

    func invalidate() {
        generation += 1
        result = nil
        sampledAt = nil
        samples = []
        sampledScreen = nil
        failure = nil
        reading = false
        expired = false
    }

    func close() {
        invalidate()
        apps = []
        app = nil
        choices = []
        picks = []
    }

    func open() {
        close()
        apps = reader.applications()
    }

    func select(_ target: AdmissionApplication) async {
        guard apps.contains(target) else { return }
        invalidate()
        let request = generation
        // Listing again requires an explicit new selection for this app, even when a number reappears.
        picks.removeAll { $0.app.pid == target.pid }
        app = target
        choices = []
        reading = true
        defer { if request == generation { reading = false } }
        do {
            let windows = try await reader.windows(target)
            if request == generation { choices = windows }
        } catch {
            if request == generation { failure = error.localizedDescription }
        }
    }

    func toggle(_ choice: AdmissionWindowChoice) {
        guard let app, choices.contains(where: { $0.id == choice.id }) else { return }
        invalidate()
        if picks.contains(where: { $0.choice.id == choice.id }) { picks.removeAll { $0.choice.id == choice.id } }
        else { picks.append(Pick(app: app, choice: choice)) }
    }

    func inspect(host: HostSession, blocked: Bool, scenario: AdmissionPlacement, ratio: Double, swap: Bool, custom: Bool) async {
        invalidate()
        guard !picks.isEmpty else { return }
        let request = generation
        reading = true
        defer { if generation == request { reading = false } }
        do {
            let selected = picks
            var observed = [UUID: AdmissionPair]()
            var processes = Set<Int32>()
            var exclusive: Bool? = true
            var recovery = !blocked
            var saved: ManagedWindowTiler?
            var originals = [ManagedWindowID: SurfaceRect]()
            for pick in selected where processes.insert(pick.app.pid).inserted {
                let group = selected.filter { $0.app.pid == pick.app.pid }
                let pairs = try await reader.inspect(pick.app, selected: group.map(\.choice))
                guard generation == request else { return }
                guard pairs.count == group.count else { throw AdmissionSelectionError.changed }
                for (pick, pair) in zip(group, pairs) { observed[pick.choice.id] = pair }
                let safety = reader.safeguards(pick.app)
                if safety.exclusive == false || exclusive == false { exclusive = false }
                else if safety.exclusive == nil { exclusive = nil }
                recovery = recovery && safety.recoveryClear == true
                if let prior = reader.storedLayout(pick.app) {
                    saved = prior.layout
                    originals.merge(prior.originals) { old, _ in old }
                }
            }

            let pairs = try selected.map { pick in
                guard let sample = observed[pick.choice.id] else { throw AdmissionSelectionError.changed }
                return sample
            }
            let config = host.configuration
            let screens = SystemScreens.geometry()
            let display = pairs.compactMap { $0.second.display }.first ?? ""
            // A missing display retains an empty area and the original failure reasons.
            let geometry = screens.first { $0.id == display }
            let screen = geometry.map { Self.quartz($0.frame, screens: screens) } ?? SurfaceRect(width: 0, height: 0)
            let usable = geometry.map { Self.quartz($0.visibleFrame, screens: screens) } ?? SurfaceRect(width: 0, height: 0)
            var settings = config.displays[display] ?? .init()
            var primary = display == (config.preferredDisplayID.flatMap { id in screens.first { $0.id == id }?.id } ?? screens.first?.id)
            if scenario != .current {
                settings.placement = scenario == .docked ? .docked : .floating
                // In the product Floating belongs to a secondary-role panel.
                if scenario == .floating { primary = false }
            }
            var context = AdmissionContext(display: display, screen: screen, usable: usable, primary: primary,
                                           settings: settings, edge: config.edge, preferences: config.workspaces,
                                           recoveryClear: recovery, exclusive: exclusive, ratio: custom ? ratio : 0.5, swapped: custom && swap)
            context.hypothetical = scenario != .current || custom
            context.pairCustomized = custom
            context.savedLayout = saved
            context.originalFrames = originals
            let sample = WindowAdmissionPreview.evaluate(pairs, context: context, uptime: ProcessInfo.processInfo.systemUptime)
            result = sample
            sampledScreen = screen
            samples = pairs.map(\.second)
            sampledAt = Date()
            if let validUntil = sample.validUntil {
                let delay = max(0, validUntil - ProcessInfo.processInfo.systemUptime)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.generation == request else { return }
                    self.expired = true
                }
            }
        } catch {
            if generation == request { failure = error.localizedDescription }
        }
    }

    private static func quartz(_ frame: SurfaceRect, screens: [ScreenGeometry]) -> SurfaceRect {
        guard let menuDisplay = screens.first else { return SurfaceRect(width: 0, height: 0) }
        return SurfaceRect(x: frame.x, y: menuDisplay.frame.y + menuDisplay.frame.height - frame.y - frame.height,
                           width: frame.width, height: frame.height)
    }
}

private enum AdmissionSelectionError: LocalizedError {
    case changed
    var errorDescription: String? { "窗口清单已变化，请重新选择。" }
}

enum AdmissionPlacement: String, CaseIterable {
    case current, docked, floating
    var title: String {
        switch self {
        case .current: "此屏设置"
        case .docked: "驻留试算"
        case .floating: "浮动试算"
        }
    }
}

@MainActor struct WindowAdmissionSettings: View {
    let host: HostSession
    let manager: CandidateWorkRect
    let fixtureOnly: Bool
    @ViewState private var selection: AdmissionSelection
    @ViewState private var opened = false
    @ViewState private var scenario = AdmissionPlacement.current
    @ViewState private var custom = false
    @ViewState private var ratio = 60
    @ViewState private var swap = false

    init(host: HostSession, manager: CandidateWorkRect, fixtureOnly: Bool) {
        self.host = host
        self.manager = manager
        self.fixtureOnly = fixtureOnly
        let reader = WindowAdmissionReader(support: manager.support, fixtureOnly: fixtureOnly)
        _selection = State(initialValue: AdmissionSelection(reader: reader))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(opened ? "收起管理范围预演" : "预览管理范围…") {
                opened.toggle()
                if opened { selection.open() } else { selection.close() }
            }.accessibilityIdentifier("admission-open")
            if opened { scope }
        }
        .onChange(of: host.configuration.workspaces) { selection.invalidate() }
        .onChange(of: host.configuration.displays) { selection.invalidate() }
        .onChange(of: host.configuration.edge) { selection.invalidate() }
        .onChange(of: host.configuration.preferredDisplayID) { selection.invalidate() }
        .onChange(of: manager.blocked) { selection.invalidate() }
        .onChange(of: manager.mode) { selection.invalidate() }
        .onChange(of: manager.windows) { selection.invalidate() }
        .onChange(of: scenario) { selection.invalidate() }
        .onChange(of: custom) { selection.invalidate() }
        .onChange(of: ratio) { selection.invalidate() }
        .onChange(of: swap) { selection.invalidate() }
        .onDisappear { opened = false; selection.close() }
    }

    @ViewBuilder private var scope: some View {
        Text("选择应用和具体窗口，查看资格与预计位置。预演只读，不授予自动管理权限。")
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("admission-scope")
        HStack {
            if fixtureOnly {
                ForEach(selection.apps, id: \.pid) { app in
                    Button("选择兼容应用 · PID \(app.pid)") { Task { await selection.select(app) } }
                        .accessibilityIdentifier("admission-fixture-app")
                }
            } else {
                Menu(selection.app.map { "\($0.name) · PID \($0.pid)" } ?? "选择应用…") {
                    ForEach(selection.apps, id: \.pid) { app in
                        Button("\(app.name) · PID \(app.pid)") { Task { await selection.select(app) } }
                    }
                }.fixedSize().accessibilityIdentifier("admission-app")
            }
            Button("刷新清单") { selection.open() }.accessibilityIdentifier("admission-refresh")
        }
        if selection.apps.isEmpty {
            Text("没有可列出的应用。").font(.caption)
        } else if selection.app != nil && selection.choices.isEmpty && !selection.reading && selection.failure == nil {
            Text("没有可选窗口。可先检查该应用是否已打开普通窗口。").font(.caption)
        }
        if !selection.choices.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(selection.choices, id: \.id) { choice in
                        let chosen = selection.picks.firstIndex { $0.choice.id == choice.id }
                        Button {
                            selection.toggle(choice)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: chosen == nil ? "circle" : "checkmark.circle.fill")
                                Text(choice.number.map { "窗口 #\($0)" } ?? "窗口 \(choice.index) · 编号未确认")
                                if let chosen { Text("第 \(chosen + 1) 个").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(chosen == nil ? [] : .isSelected)
                        .accessibilityIdentifier("admission-window-" + (choice.number.map(String.init) ?? choice.id.uuidString))
                    }
                }
            }.frame(height: min(96, CGFloat(selection.choices.count) * 24))
        }
        if !selection.picks.isEmpty {
            Text(selection.picks.map { pick in
                pick.app.name + " " + (pick.choice.number.map { "#" + String($0) } ?? "编号未确认")
            }.joined(separator: "、"))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("admission-selection")
            HStack {
                ForEach(AdmissionPlacement.allCases, id: \.self) { mode in
                    Button(mode.title) { scenario = mode }
                        .foregroundStyle(scenario == mode ? Color.accentColor : Color.primary)
                        .accessibilityAddTraits(scenario == mode ? .isSelected : [])
                        .accessibilityIdentifier("admission-" + mode.rawValue)
                }
                if selection.picks.count == 2 {
                    Toggle("试算双窗比例", isOn: $custom).accessibilityIdentifier("admission-custom")
                }
            }
            if custom && selection.picks.count == 2 {
                HStack {
                    Stepper("左侧 \(ratio)%", value: $ratio, in: 20...80)
                    Toggle("交换槽位", isOn: $swap)
                }
            }
            HStack {
                Button(selection.reading ? "正在核对…" : "核对所选窗口（\(selection.picks.count)）") {
                    Task { await selection.inspect(host: host, blocked: manager.blocked, scenario: scenario,
                                                   ratio: Double(ratio) / 100, swap: swap, custom: custom && selection.picks.count == 2) }
                }.disabled(selection.reading).accessibilityIdentifier("admission-read")
                Button("清空") { selection.invalidate(); selection.picks = [] }
            }
        }
        if let failure = selection.failure {
            Text("当前条件不足 · " + failure).font(.callout).accessibilityIdentifier("admission-verdict")
        }
        if let result = selection.result {
            AdmissionResultView(result: result, samples: selection.samples, screen: selection.sampledScreen, sampled: selection.sampledAt, expired: selection.expired,
                                simulated: scenario != .current || (custom && selection.picks.count == 2))
        }
    }
}

private struct AdmissionResultView: View {
    let result: AdmissionPreviewResult
    let samples: [AdmissionSample]
    let screen: SurfaceRect?
    let sampled: Date?
    let expired: Bool
    let simulated: Bool

    private var verdict: String {
        switch result.status {
        case .reviewable: return simulated ? "符合所选试算条件" : "可以进入进一步授权"
        case .insufficient: return simulated && result.reasons == [.hypothetical] ? "仅供布局试算" : "当前条件不足"
        case .ineligible: return "明确不可管理"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((expired ? "快照已过期 · 上次采样" : "采样结果") + " · " + verdict)
                .font(.headline).accessibilityIdentifier("admission-verdict")
            if let sampled { Text(sampled, style: .time).font(.caption).foregroundStyle(.secondary) }
            if !result.reasons.isEmpty {
                Text(result.reasons.map(\.text).joined(separator: "；"))
                    .font(.callout).accessibilityIdentifier("admission-reason")
            }
            if let work = result.workRect {
                Text("预计工作区  " + bounds(work) + " pt")
                    .font(.caption).accessibilityIdentifier("admission-workrect")
            }
            if let screen, !result.current.isEmpty, !result.proposed.isEmpty {
                HStack(spacing: 16) {
                    footprint("当前", frames: result.current, screen: screen)
                    footprint("预计", frames: result.proposed, screen: screen)
                }.accessibilityHidden(true)
            }
            ForEach(result.current.keys.sorted { ($0.pid, $0.number) < ($1.pid, $1.number) }, id: \.self) { id in
                VStack(alignment: .leading, spacing: 2) {
                    if let frame = result.current[id] { Text("窗口 #\(id.number)   当前 " + bounds(frame)) }
                    if let target = result.proposed[id] { Text("预计 " + bounds(target)) }
                    if let exit = result.exitFrames[id] { Text("退出预计 " + bounds(exit)) }
                    if let minimum = samples.first(where: { $0.id == id })?.minimum {
                        Text("最小 " + dimension(minimum.width) + " × " + dimension(minimum.height) + " pt").foregroundStyle(.secondary)
                    }
                }.font(.caption.monospacedDigit()).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("admission-frame-\(id.number)")
            }
            if !result.notes.isEmpty {
                Text(result.notes.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("admission-layout")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footprint(_ title: String, frames: [ManagedWindowID: SurfaceRect], screen: SurfaceRect) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                guard screen.width > 0, screen.height > 0 else { return }
                let factor = min((size.width - 2) / screen.width, (size.height - 2) / screen.height)
                let origin = CGPoint(x: (size.width - factor * screen.width) / 2, y: (size.height - factor * screen.height) / 2)
                func rect(_ r: SurfaceRect) -> CGRect {
                    .init(x: origin.x + (r.x - screen.x) * factor, y: origin.y + (r.y - screen.y) * factor,
                          width: r.width * factor, height: r.height * factor)
                }
                context.stroke(Path(rect(screen)), with: .color(.secondary))
                if let work = result.workRect {
                    context.fill(Path(rect(work)), with: .color(.secondary.opacity(0.10)))
                }
                for sample in samples {
                    guard let id = sample.id, let frame = frames[id] else { continue }
                    let shape = Path(rect(frame))
                    context.fill(shape, with: .color(.accentColor.opacity(0.18)))
                    context.stroke(shape, with: .color(.accentColor))
                }
            }.frame(width: 90, height: 56)
        }
    }

    private func dimension(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func bounds(_ r: SurfaceRect) -> String {
        let n = [r.x, r.y, r.width, r.height].map { $0.formatted(.number.precision(.fractionLength(0...2))) }
        return "(\(n[0]), \(n[1]))  \(n[2]) × \(n[3])"
    }
}
