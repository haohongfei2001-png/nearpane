import Foundation
import NearpaneCore
import Observation
import SwiftUI

/// Shared by every management entry in one profile. A Spaces off switch commits
/// only after the existing reversible group-edit barrier proves windows returned.
/// Shutdown's terminal ownership latch is deliberately not used for this action.
@MainActor @Observable
final class ModuleSwitchCoordinator {
    typealias PrepareSpaces = @MainActor (@escaping @MainActor () -> Bool) async throws -> Void
    private(set) var changing = Set<String>()
    private(set) var issues = [String: String]()
    @ObservationIgnored private let navigation: NativeSidebarNavigation
    @ObservationIgnored private let prepareSpacesOverride: PrepareSpaces?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var completionWatch: Task<Void, Never>?

    init(navigation: NativeSidebarNavigation = .shared, prepareSpaces: PrepareSpaces? = nil) {
        self.navigation = navigation
        prepareSpacesOverride = prepareSpaces
    }

    func setEnabled(_ id: String, _ enabled: Bool, host: HostSession, modules: EmbeddedModules?) {
        guard !changing.contains(id) else { return }
        issues[id] = nil
        let stage = modules?.windowPreviews.currentDesktop?.stageEngine
        guard id == BuiltinCatalog.desktop, !enabled, stage != nil || prepareSpacesOverride != nil else {
            apply(id, enabled, host: host, modules: modules)
            return
        }
        guard host.isRunning, host.registry.preferences.contains(where: { $0.id == id && $0.enabled }) else { return }
        guard navigation.dispatchAvailable else {
            issues[id] = "请回到普通桌面后重试停用，已隐藏的窗口需要先返回。"
            return
        }
        let operation = UUID()
        request = operation
        changing.insert(id)
        let prepareOverride = prepareSpacesOverride
        navigation.submit(selection: false, stage: true) { [weak self, weak host, weak modules] token in
            guard let self, let host, request == operation else { return }
            defer { finish(operation) }
            let current: @MainActor () -> Bool = { [weak self, weak host] in
                guard let self, let host else { return false }
                return request == operation && host.isRunning && navigation.isCurrent(token) &&
                    host.registry.preferences.contains { $0.id == id && $0.enabled }
            }
            do {
                guard current() else { throw StageSwitchError.interrupted }
                if let prepareOverride { try await prepareOverride(current) }
                else if let stage { try await stage.prepareForGroupEdit(current: current) }
                guard current() else { throw StageSwitchError.interrupted }
                // No suspension between the last return/current check and the
                // persisted preference: another sidebar action cannot slip in.
                apply(id, false, host: host, modules: modules)
            } catch {
                issues[id] = "尚未确认所有窗口已返回，空间调度保持启用。请稍后重试。"
            }
        }
        // The shared lane can discard a queued action when macOS takes over.
        // A skipped closure never runs its defer, so also observe lane completion.
        completionWatch?.cancel()
        completionWatch = Task { @MainActor [weak self] in
            guard let self else { return }
            while request == operation && navigation.isDispatching {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            guard request == operation else { return }
            issues[id] = "这次停用被其他窗口操作中断，空间调度保持启用。请重试。"
            finish(operation)
        }
    }

    private func finish(_ operation: UUID) {
        guard request == operation else { return }
        changing.remove(BuiltinCatalog.desktop)
        request = nil
    }

    private func apply(_ id: String, _ enabled: Bool, host: HostSession, modules: EmbeddedModules?) {
        let result = host.handle(.setEnabled(id, enabled))
        if result != .accepted {
            issues[id] = "暂时无法更改模块状态，请稍后重试。"
        } else if host.configurationSaveFailed {
            issues[id] = "模块状态已更改，但设置尚未保存。请检查资料目录。"
        } else if id == BuiltinCatalog.desktop && !enabled {
            modules?.stopWindowContentPreview()
        }
    }
}

struct ModuleSwitchNotice: View {
    let switches: ModuleSwitchCoordinator
    let id: String
    let host: HostSession
    let modules: EmbeddedModules?

    var body: some View {
        if switches.changing.contains(id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在让已隐藏的窗口返回…").font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("module-changing-" + id)
        } else if let issue = switches.issues[id] {
            HStack(alignment: .top, spacing: 10) {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if id == BuiltinCatalog.desktop,
                   host.registry.preferences.contains(where: { $0.id == id && $0.enabled }) {
                    Button("重试停用") { switches.setEnabled(id, false, host: host, modules: modules) }
                        .controlSize(.small).fixedSize()
                }
            }.accessibilityIdentifier("module-switch-issue-" + id)
        }
    }
}
