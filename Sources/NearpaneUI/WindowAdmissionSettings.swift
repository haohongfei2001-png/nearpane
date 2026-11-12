import AppKit
import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>

@MainActor protocol AdmissionReading {
    func applications() -> [AdmissionApplication]
    func handle(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> OrdinaryWindowAX?
    func releaseChoices()
    func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]
    func refreshedWindows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]?
    func inspect(_ app: AdmissionApplication, selected: [AdmissionWindowChoice]) async throws -> [AdmissionPair]
    func safeguards(_ app: AdmissionApplication) -> AdmissionSafeguards
}
extension AdmissionReading {
    func handle(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> OrdinaryWindowAX? { nil }
    func releaseChoices() {}
    func refreshedWindows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]? { nil }
}
extension WindowAdmissionReader: AdmissionReading {}

/// Coordinates observations only. A completed read belongs to the selection that started it.
@MainActor @Observable final class AdmissionSelection {
    struct Pick {
        let app: AdmissionApplication
        let choice: AdmissionWindowChoice
    }

    private let reader: any AdmissionReading
    private let exposure: SettingsPreviewExposure?
    private(set) var opened = false
    @ObservationIgnored var cancelOrdinaryPreview: (() -> Void)?
    private var generation = 0
    var apps = [AdmissionApplication]()
    var app: AdmissionApplication?
    var choices = [AdmissionWindowChoice]()
    var picks = [Pick]()
    var ordinaryReview: OrdinaryWindowReview?
    var ordinaryContext: AdmissionContext?
    struct Readout: Identifiable {
        let group: AdmissionDisplayPreview
        let result: AdmissionPreviewResult
        var id: String { group.id }
    }
    var readouts = [Readout]()
    var result: AdmissionPreviewResult? { readouts.count == 1 ? readouts[0].result : nil }
    var sampledAt: Date?
    var failure: String?
    var reading = false
    var expired = false

    init(reader: any AdmissionReading, exposure: SettingsPreviewExposure? = nil) {
        self.reader = reader
        self.exposure = exposure
    }

    func invalidate(discardPlan: Bool = true) {
        if discardPlan { cancelOrdinaryPreview?() }
        generation += 1
        ordinaryReview = nil
        ordinaryContext = nil
        readouts = []
        sampledAt = nil
        failure = nil
        reading = false
        expired = false
    }

    func close() {
        opened = false
        invalidate()
        reader.releaseChoices()
        apps = []
        app = nil
        choices = []
        picks = []
    }

    func open() {
        close()
        guard exposure?.open(self) != false else { return }
        opened = true
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

    /// Read only the explicitly selected application. New sibling windows always start unselected.
    func refresh(_ target: AdmissionApplication) async -> Bool {
        guard target == app else { return false }
        guard !reading else { return true }
        let request = generation
        do {
            guard let rows = try await reader.refreshedWindows(target) else { return false }
            guard !Task.isCancelled, target == app else { return false }
            guard request == generation else { return true }
            let remaining = picks.filter { pick in
                pick.app != target || rows.contains { $0.id == pick.choice.id && $0.number == pick.choice.number }
            }
            if remaining.count != picks.count {
                invalidate()
                picks = remaining
                failure = "原窗口已从所选清单消失或身份变化，请重新选择需要管理的窗口。"
            }
            if choices != rows { choices = rows }
            return true
        } catch {
            guard !Task.isCancelled, request == generation, target == app else { return target == app }
            invalidate()
            choices = []
            picks.removeAll { $0.app == target }
            failure = error.localizedDescription
            return false
        }
    }

    func inspect(host: HostSession, blocked: Bool, scenario: AdmissionPlacement, ratio: Double, swap: Bool, custom: Bool, manager: CandidateWorkRect? = nil) async {
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
                if let prior = safety.storedLayout {
                    saved = prior.layout
                    originals.merge(prior.originals) { old, _ in old }
                }
            }

            let pairs = try selected.map { pick in
                guard let sample = observed[pick.choice.id] else { throw AdmissionSelectionError.changed }
                return sample
            }
            var groups = AdmissionDisplayPreview.groups(pairs, screens: SystemScreens.geometry(), config: host.configuration,
                                                        scenario: scenario, ratio: ratio, swap: swap, custom: custom,
                                                        recovery: recovery, exclusive: exclusive)
            for index in groups.indices {
                let ids = Set(groups[index].pairs.compactMap(\.second.id))
                if groups.count == 1 || saved?.members.allSatisfy({ ids.contains($0.id) }) == true {
                    groups[index].context.savedLayout = saved
                    groups[index].context.originalFrames = originals.filter { ids.contains($0.key) }
                }
            }
            // Mixed selections are read-only independent display projections. Never pass a
            // subset of a cross-display selection to the writer as implicit consent.
            if let manager, scenario == .current, groups.count == 1, let display = groups.first?.id, !display.isEmpty {
                let handles = selected.compactMap { reader.handle($0.choice, app: $0.app) }
                if handles.count == selected.count, var live = manager.context(for: display) {
                    live.ratio = custom ? ratio : 0.5
                    live.swapped = custom && swap
                    live.pairCustomized = custom
                    do {
                        try await manager.ordinary.performUserAction {
                            guard self.generation == request else { throw AdmissionSelectionError.changed }
                            let review = try await manager.ordinary.prepare(handles, context: live)
                            guard self.generation == request else { return }
                            self.ordinaryReview = review
                            self.ordinaryContext = live
                            self.sampledAt = Date()
                        }
                        return
                    } catch {
                        guard generation == request else { return }
                        failure = error.localizedDescription
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            readouts = groups.map {
                .init(group: $0, result: WindowAdmissionPreview.evaluate($0.pairs, context: $0.context, uptime: now))
            }
            sampledAt = Date()
            if let validUntil = readouts.compactMap(\.result.validUntil).min() {
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
    let owners: [AdmissionFixtureOwner]
    @ViewState private var selection: AdmissionSelection
    @ViewState private var scenario = AdmissionPlacement.current
    @ViewState private var custom = false
    @ViewState private var ratio = 60
    @ViewState private var swap = false

    init(host: HostSession, manager: CandidateWorkRect, fixtureOnly: Bool, owners: [AdmissionFixtureOwner] = [],
         exposure: SettingsPreviewExposure?) {
        self.owners = owners
        self.host = host
        self.manager = manager
        self.fixtureOnly = fixtureOnly
        let reader = WindowAdmissionReader(support: manager.support, fixtureOnly: fixtureOnly, owners: owners)
        let scope = AdmissionSelection(reader: reader, exposure: exposure)
        scope.cancelOrdinaryPreview = { [weak manager] in manager?.ordinary.cancelPreview() }
        _selection = State(initialValue: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(selection.opened ? "收起管理范围预演" : "预览管理范围…") {
                if selection.opened { selection.close() } else { selection.open() }
            }.accessibilityIdentifier("admission-open")
            if selection.opened { scope }
            OrdinaryManagementStatus(manager: manager)

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
        .task(id: selection.app) {
            guard let app = selection.app else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !(await selection.refresh(app)) { return }
            }
        }
        .onDisappear { selection.close() }
    }

    @ViewBuilder private var scope: some View {
        Text("选择应用和具体窗口，查看资格与预计位置。预演只读，不授予自动管理权限。")
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("admission-scope")
        HStack {
            if fixtureOnly {
                ForEach(selection.apps, id: \.pid) { app in
                    Button("\(app.name) · PID \(String(app.pid))") { Task { await selection.select(app) } }
                        .accessibilityIdentifier(owners.isEmpty ? "admission-fixture-app" : "admission-ordinary-app" + (owners.count > 1 ? "-" + String(app.pid) : ""))
                }
            } else {
                Menu(selection.app.map { "\($0.name) · PID \($0.pid)" } ?? "选择应用…") {
                    ForEach(selection.apps, id: \.pid) { app in
                        Button("\(app.name) · PID \(String(app.pid))") { Task { await selection.select(app) } }
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
                                                   ratio: Double(ratio) / 100, swap: swap, custom: custom && selection.picks.count == 2, manager: manager) }
                }.disabled(selection.reading).accessibilityIdentifier("admission-read")
                Button("清空") { selection.invalidate(); selection.picks = [] }
            }
        }
        if let failure = selection.failure {
            Text("当前条件不足 · " + failure).font(.callout).accessibilityIdentifier("admission-verdict")
        }
        if let review = selection.ordinaryReview, let context = selection.ordinaryContext {
            Text("可逐窗授权 · 仅调整下列窗口").font(.callout)
            ForEach(review.proposed.keys.sorted { $0.number < $1.number }, id: \.self) { id in
                if let r = review.proposed[id] {
                    Text("窗口 #\(String(id.number)) → (\(Int(r.x)), \(Int(r.y)))  \(Int(r.width)) × \(Int(r.height)) pt").font(.caption)
                }
            }
            Text("停止时仅恢复仍能连续核对的原窗口。若你或其他应用改变布局，会保留现状。")
                .font(.caption).foregroundStyle(.secondary)
            Button("授权所列窗口并应用布局") {
                selection.invalidate(discardPlan: false)
                Task {
                    do {
                        try await manager.ordinary.performUserAction {
                            try await manager.ordinary.confirm(review, context: context)
                        }
                    }
                    catch { manager.ordinary.report(error) }
                }
            }.disabled(manager.ordinary.unavailableForUserAction).accessibilityIdentifier("ordinary-confirm")
        }
        if selection.readouts.count > 1 {
            Text("已按显示器分别预演。逐窗授权时请选择同一显示器上的窗口。")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(selection.readouts) { item in
            if selection.readouts.count > 1 { Text(item.group.label).font(.subheadline) }
            AdmissionResultView(result: item.result, samples: item.group.pairs.map(\.second),
                                screen: item.group.context.screen, sampled: selection.sampledAt, expired: selection.expired,
                                simulated: selection.readouts.count > 1 || scenario != .current || (custom && selection.picks.count == 2))
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
                    if let frame = result.current[id] { Text("窗口 #\(String(id.number))   当前 " + bounds(frame)) }
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
