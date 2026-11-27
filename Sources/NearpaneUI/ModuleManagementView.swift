import NearpaneCore
import SwiftUI

/// Management lives here, leaving the desktop surface entirely about its content.
struct ModuleManagementView: View {
    let host: HostSession
    let modules: EmbeddedModules?
    let switches: ModuleSwitchCoordinator
    let open: (String) -> Void

    private var enabled: [ModuleManifest] { manifests(enabled: true) }
    private var disabled: [ModuleManifest] { manifests(enabled: false) }
    private func manifests(enabled: Bool) -> [ModuleManifest] {
        host.registry.preferences.filter { $0.enabled == enabled }.compactMap { preference in
            host.registry.manifests.first { $0.id == preference.id }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("让需要的工具留在身边。启用后即可使用，停用会保留设置和历史内容。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 7) {
                    sectionHeader("已启用", count: enabled.count, detail: enabled.count > 1 ? "拖动调整侧栏顺序" : nil)
                    if enabled.isEmpty {
                        MainWindowEmptyState(symbol: "rectangle.righthalf.inset.filled", title: "选择你的第一个工具",
                                             message: "从下方启用语音、截图或歌词，侧栏会随内容自然展开。")
                            .frame(height: 134)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(enabled) { manifest in
                                row(manifest, enabled: true, movable: true)
                            }
                            Color.clear.frame(height: 12)
                                .contentShape(Rectangle())
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let id = ids.first, enabled.contains(where: { $0.id == id }) else { return false }
                                    return host.moveModule(id, before: nil)
                                }
                                .accessibilityIdentifier("module-order-end")
                        }
                    }
                }
                if !disabled.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionHeader("未启用", count: disabled.count, detail: "随时添加")
                        VStack(spacing: 0) {
                            ForEach(disabled) { manifest in row(manifest, enabled: false, movable: false) }
                        }
                    }
                }
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
        .accessibilityIdentifier("module-management")
    }

    private func sectionHeader(_ title: String, count: Int, detail: String?) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(.bottom, 2)
    }

    private func row(_ manifest: ModuleManifest, enabled: Bool, movable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleManagementRow(host: host, modules: modules, switches: switches, manifest: manifest, enabled: enabled, movable: movable, open: open)
            ModuleSwitchNotice(switches: switches, id: manifest.id, host: host, modules: modules)
                .padding(.bottom, switches.changing.contains(manifest.id) || switches.issues[manifest.id] != nil ? 12 : 0)
        }
    }
}

private struct ModuleManagementRow: View {
    let host: HostSession
    let modules: EmbeddedModules?
    let switches: ModuleSwitchCoordinator
    let manifest: ModuleManifest
    let enabled: Bool
    let movable: Bool
    let open: (String) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 14) {
            if movable {
                detailButton.draggable(manifest.id) {
                    Label(ModulePresentation.title(manifest), systemImage: manifest.symbol)
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            } else { detailButton }
            if enabled && host.registry.states[manifest.id] == .degraded {
                Button("重试") { switches.setEnabled(manifest.id, true, host: host, modules: modules) }
                    .controlSize(.small).accessibilityIdentifier("module-retry-" + manifest.id)
            }
            Toggle("启用" + ModulePresentation.title(manifest), isOn: Binding(get: {
                host.registry.preferences.first(where: { $0.id == manifest.id })?.enabled == true
            }, set: { switches.setEnabled(manifest.id, $0, host: host, modules: modules) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(switches.changing.contains(manifest.id))
            .accessibilityIdentifier("module-enabled-" + manifest.id)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
        .overlay(alignment: .top) {
            if targeted { RoundedRectangle(cornerRadius: 1).fill(host.configuration.accent.color).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard movable, let id = ids.first, id != manifest.id,
                  host.registry.preferences.contains(where: { $0.id == id && $0.enabled }) else { return false }
            return host.moveModule(id, before: manifest.id)
        } isTargeted: { targeted = movable && $0 }
    }

    private var detailButton: some View {
        Button { open(manifest.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: manifest.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(enabled ? host.configuration.accent.color : .secondary)
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(ModulePresentation.title(manifest)).font(.system(size: 14, weight: .semibold))
                        if let brand = ModulePresentation.brand(manifest.id) {
                            Text(brand).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        if let state = ModulePresentation.status(host.registry.states[manifest.id] ?? .available) {
                            Text(state).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        } else if enabled && manifest.kind == .builtin && !BuiltinCatalog.sidebarTools.contains(manifest.id) &&
                                    host.registry.preferences.first(where: { $0.id == manifest.id })?.pinned == false {
                            Text("未显示").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text(manifest.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("module-open-" + manifest.id)
            .help(movable ? "打开设置；也可拖动调整侧栏顺序" : "打开模块设置")
    }
}

struct MainWindowEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
