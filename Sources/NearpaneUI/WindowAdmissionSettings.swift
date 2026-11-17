import AppKit
import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>

@MainActor protocol AdmissionReading {
    func applications() -> [AdmissionApplication]
    func handle(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> OrdinaryWindowAX?
    func retainedRuleID(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> ManagedWindowID?
    func releaseChoices()
    func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]
    func refreshedWindows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]?
    func inspect(_ app: AdmissionApplication, selected: [AdmissionWindowChoice]) async throws -> [AdmissionPair]
    func safeguards(_ app: AdmissionApplication) -> AdmissionSafeguards
}
extension AdmissionReading {
    func handle(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> OrdinaryWindowAX? { nil }
    func retainedRuleID(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> ManagedWindowID? {
        handle(choice, app: app)?.id
    }
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
    @ObservationIgnored private var expiration: Task<Void, Never>?
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
    var ruleNotice: String?
    private(set) var permissionDenied = false
    var reading = false
    var expired = false

    init(reader: any AdmissionReading, exposure: SettingsPreviewExposure? = nil) {
        self.reader = reader
        self.exposure = exposure
    }

    func invalidate(discardPlan: Bool = true) {
        expiration?.cancel()
        expiration = nil
        if discardPlan { cancelOrdinaryPreview?() }
        generation += 1
        ordinaryReview = nil
        ordinaryContext = nil
        readouts = []
        sampledAt = nil
        failure = nil
        ruleNotice = nil
        permissionDenied = false
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

    func label(for app: AdmissionApplication) -> String {
        let matches = apps.filter { $0.name == app.name }
        guard matches.count > 1, let index = matches.firstIndex(of: app) else { return app.name }
        return "\(app.name)（实例 \(index + 1)）"
    }

    func label(for id: ManagedWindowID, requireSameElement: Bool = false) -> String? {
        guard let pick = picks.first(where: {
            $0.app.pid == id.pid && $0.app.launch == id.launch && $0.choice.number == id.number
                && (!requireSameElement || $0.choice.id == id.element)
        }) else { return nil }
        return "\(label(for: pick.app)) · 窗口 \(pick.choice.index)"
    }

    private func report(_ error: Error) {
        permissionDenied = error as? AdmissionReadFailure == .permission
        failure = error.localizedDescription
    }

    private func expire(at uptime: TimeInterval) {
        expiration?.cancel()
        let request = generation
        let delay = max(0, uptime - ProcessInfo.processInfo.systemUptime)
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == request else { return }
            if self.ordinaryReview != nil {
                self.cancelOrdinaryPreview?()
                self.ordinaryReview = nil
                self.ordinaryContext = nil
            }
            self.expired = true
        }
    }

    func present(_ review: OrdinaryWindowReview, context: AdmissionContext) {
        ordinaryReview = review
        ordinaryContext = context
        sampledAt = Date()
        expire(at: review.validUntil)
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
            if request == generation { report(error) }
        }
    }

    func toggle(_ choice: AdmissionWindowChoice) {
        guard let app, choices.contains(where: { $0.id == choice.id }) else { return }
        invalidate()
        if picks.contains(where: { $0.choice.id == choice.id }) { picks.removeAll { $0.choice.id == choice.id } }
        else { picks.append(Pick(app: app, choice: choice)) }
    }

    var ruleID: ManagedWindowID? {
        guard opened, picks.count == 1, let pick = picks.first, app == pick.app,
              choices.contains(pick.choice),
              let id = reader.retainedRuleID(pick.choice, app: pick.app), id.pid == pick.app.pid,
              id.launch == pick.app.launch, id.number == pick.choice.number, id.element == pick.choice.id
        else { return nil }
        return id
    }

    /// Reuse the original retained AX object when the user explicitly asks for a still.
    /// Refreshing the selected owner catches close/recreate even when its number is reused.
    @available(macOS 15.2, *)
    func photograph(using previews: WindowContentPreview, host: HostSession) async {
        guard let id = ruleID, let owner = app, !reading else { return }
        let consent = previewConsent(for: id, owner: owner)
        await previews.captureSelected(id, bundle: owner.bundle, host: host, stillSelected: consent)
    }

    func previewConsent(for id: ManagedWindowID, owner: AdmissionApplication) -> @MainActor () async -> Bool {
        let request = generation
        return { [weak self] in
            guard let self, self.generation == request, self.ruleID == id,
                  let rows = try? await self.reader.refreshedWindows(owner),
                  self.generation == request, self.ruleID == id else { return false }
            let matches = rows.filter { $0.number == id.number }
            return matches.count == 1 && matches[0].id == id.element
        }
    }

    /// Persist only the identity kept alive by this selection's controller.
    /// A read-only desktop snapshot's per-sample AX token cannot identify a later authorization.
    func setRule(_ rule: WindowRule, host: HostSession, isManaged: (ManagedWindowID) -> Bool) async {
        guard !reading, let selected = ruleID, let owner = app, !isManaged(selected) else { return }
        invalidate()
        let request = generation
        reading = true
        defer { if request == generation { reading = false } }
        do {
            let current = try await reader.refreshedWindows(owner)
            guard request == generation, !Task.isCancelled, host.isRunning else { return }
            guard let matches = current?.filter({ $0.number == selected.number }), matches.count == 1,
                  matches[0].id == selected.element, ruleID == selected, !isManaged(selected)
            else { throw AdmissionSelectionError.changed }
            var prefs = host.workspacePreferencesDraft
            if rule == .include {
                guard prefs.excludedApps.contains(owner.bundle) else { throw AdmissionSelectionError.changed }
                guard !prefs.windows.contains(where: { id, rule in
                    rule == .exclude && id != selected && id.pid == selected.pid &&
                        id.launch == selected.launch && id.number == selected.number
                }) else { failure = "此前的排除规则仍占用这个窗口编号。请先在「窗口规则」核对。"; return }
            }
            prefs.windows[selected] = rule
            if host.setWorkspacePreferences(prefs) {
                ruleNotice = rule == .exclude ? "已保存此窗的排除规则。" : "已保存单窗例外。可继续预览并单独授权。"
            } else { failure = "窗口规则未保存。请在「窗口规则」中重试。" }
        } catch { if request == generation { report(error) } }
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
            let remaining = picks.compactMap { pick -> Pick? in
                guard pick.app == target else { return pick }
                return rows.first { $0.id == pick.choice.id && $0.number == pick.choice.number }.map { Pick(app: target, choice: $0) }
            }
            if remaining.count != picks.count {
                invalidate()
                failure = "原窗口已从所选清单消失或身份变化，请重新选择需要管理的窗口。"
            }
            if remaining.map(\.choice) != picks.map(\.choice) { picks = remaining }
            if choices != rows { choices = rows }
            return true
        } catch {
            guard !Task.isCancelled, request == generation, target == app else { return target == app }
            invalidate()
            choices = []
            picks.removeAll { $0.app == target }
            report(error)
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
                            self.present(review, context: live)
                        }
                        return
                    } catch {
                        guard generation == request else { return }
                        report(error)
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            readouts = groups.map {
                .init(group: $0, result: WindowAdmissionPreview.evaluate($0.pairs, context: $0.context, uptime: now))
            }
            sampledAt = Date()
            if let validUntil = readouts.compactMap(\.result.validUntil).min() {
                expire(at: validUntil)
            }
        } catch {
            if generation == request { report(error) }
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
    @Environment(WindowContentPreview.self) private var previews: WindowContentPreview?
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

    private func managed(_ id: ManagedWindowID) -> Bool {
        // An already managed window is released through its original observer and journal.
        manager.ordinary.activeIDs.contains { $0.pid == id.pid && $0.launch == id.launch && $0.number == id.number }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(selection.opened ? "收起管理范围预演" : "选择窗口并预览…") {
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
                Menu(selection.app.map { selection.label(for: $0) } ?? "选择应用…") {
                    ForEach(selection.apps, id: \.pid) { app in
                        Button(selection.label(for: app)) { Task { await selection.select(app) } }
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
                                Text(choice.number == nil ? "窗口 \(choice.index) · 身份待核对" : "窗口 \(choice.index)")
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
                "\(selection.label(for: pick.app)) · 窗口 \(pick.choice.index)"
            }.joined(separator: "、"))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("admission-selection")
            if #available(macOS 15.2, *), let previews, selection.ruleID != nil {
                Button("拍摄此窗的桌面预览") {
                    Task { await selection.photograph(using: previews, host: host) }
                }.disabled(selection.reading || previews.choosing || previews.visibleDisplays.isEmpty)
                if !previews.notice.isEmpty { Text(previews.notice).font(.caption).foregroundStyle(.secondary) }
            }
            if let id = selection.ruleID, !managed(id) {
                Menu("此窗规则") {
                    Button("排除此窗") {
                        Task { await selection.setRule(.exclude, host: host, isManaged: managed) }
                    }
                    if let app = selection.app, host.workspacePreferencesDraft.excludedApps.contains(app.bundle) {
                        Button("允许此窗作为应用例外") {
                            Task { await selection.setRule(.include, host: host, isManaged: managed) }
                        }
                    }
                }.disabled(selection.reading)
            }
            if let notice = selection.ruleNotice { Text(notice).font(.caption) }
            HStack {
                ForEach(AdmissionPlacement.allCases, id: \.self) { mode in
                    Button(mode.title) { scenario = mode }
                        .foregroundStyle(scenario == mode ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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
        if selection.expired && selection.readouts.isEmpty {
            Text("布局预览已过期，请重新核对所选窗口。").font(.callout)
                .accessibilityIdentifier("admission-verdict")
        }
        if selection.permissionDenied || selection.readouts.contains(where: { $0.result.reasons.contains(.permission) }) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                Link("打开系统辅助功能设置", destination: url)
            }
        }
        if let review = selection.ordinaryReview, let context = selection.ordinaryContext {
            Text("确认后将按预计位置排列这些窗口。").font(.callout)
            AdmissionLayoutComparison(screen: context.screen,
                                      work: try? DesktopWorkArea(display: context.display, screen: context.screen,
                                          usable: context.usable, primary: context.primary, settings: context.settings,
                                          fallbackEdge: context.edge).ordinary,
                                      current: review.current, proposed: review.proposed)
            ForEach(review.proposed.keys.sorted { $0.number < $1.number }, id: \.self) { id in
                if let r = review.proposed[id] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection.label(for: id, requireSameElement: true) ?? manager.ordinary.managedWindowLabel(id))
                        if let before = review.current[id] { Text("当前 " + admissionBounds(before) + " pt") }
                        Text("预计 " + admissionBounds(r) + " pt")
                    }.font(.caption.monospacedDigit()).accessibilityElement(children: .combine)
                }
            }
            Text("拖动时窗口可以暂时越过屏幕或停靠边界。松手后会核对位置并将获准窗口移回工作区。五秒内再次越界会暂停纠正。停止管理时保留最近核对过的手动布局。")
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
                                simulated: selection.readouts.count > 1 || scenario != .current || (custom && selection.picks.count == 2),
                                label: { selection.label(for: $0) ?? "所选窗口" })
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
    let label: (ManagedWindowID) -> String

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
                Text(result.reasons.contains(.permission) ? AdmissionReason.permission.text : result.reasons.map(\.text).joined(separator: "；"))
                    .font(.callout).accessibilityIdentifier("admission-reason")
            }
            if let work = result.workRect {
                Text("预计工作区  " + admissionBounds(work) + " pt")
                    .font(.caption).accessibilityIdentifier("admission-workrect")
            }
            if let screen, !result.current.isEmpty, !result.proposed.isEmpty {
                AdmissionLayoutComparison(screen: screen, work: result.workRect, current: result.current,
                                          proposed: result.proposed)
            }
            ForEach(result.current.keys.sorted { ($0.pid, $0.number) < ($1.pid, $1.number) }, id: \.self) { id in
                VStack(alignment: .leading, spacing: 2) {
                    if let frame = result.current[id] { Text(label(id) + "   当前 " + admissionBounds(frame)) }
                    if let target = result.proposed[id] { Text("预计 " + admissionBounds(target)) }
                    if let exit = result.exitFrames[id] { Text("退出预计 " + admissionBounds(exit)) }
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

    private func dimension(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(0...2)))
    }

}

private func admissionBounds(_ r: SurfaceRect) -> String {
    let n = [r.x, r.y, r.width, r.height].map { $0.formatted(.number.precision(.fractionLength(0...2))) }
    return "(\(n[0]), \(n[1]))  \(n[2]) × \(n[3])"
}

private struct AdmissionLayoutComparison: View {
    let screen: SurfaceRect, work: SurfaceRect?
    let current, proposed: [ManagedWindowID: SurfaceRect]

    var body: some View {
        HStack(spacing: 16) {
            footprint("当前", frames: current)
            footprint("预计", frames: proposed)
        }.accessibilityHidden(true)
    }

    private func footprint(_ title: String, frames: [ManagedWindowID: SurfaceRect]) -> some View {
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
                if let work {
                    context.fill(Path(rect(work)), with: .color(.secondary.opacity(0.10)))
                }
                for frame in frames.values {
                    let shape = Path(rect(frame))
                    context.fill(shape, with: .style(.tint.opacity(0.18)))
                    context.stroke(shape, with: .style(.tint))
                }
            }.frame(width: 90, height: 56)
        }
    }

}
