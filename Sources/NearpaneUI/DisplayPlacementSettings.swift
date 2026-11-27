import NearpaneCore
import SwiftUI

/// Screen placement and fullscreen presentation share one destination.
struct DisplayPlacementSettings: View {
    let host: HostSession, screens: [ScreenGeometry]
    let request: (String) -> Void, dismiss: (String) -> Void
    let stillCurrent: (ScreenGeometry) -> Bool
    let placementChanged: () -> Void
    @State private var chosen = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    heading("默认位置")
                    Picker("停靠位置", selection: Binding(get: { host.configuration.edge }, set: {
                        host.setPlacement(edge: $0, displayID: host.configuration.preferredDisplayID)
                        placementChanged()
                    })) {
                        Text("左侧").tag(SurfaceEdge.left)
                        Text("右侧").tag(SurfaceEdge.right)
                    }.pickerStyle(.segmented)
                    Picker("主驻留显示器", selection: Binding(get: { host.configuration.preferredDisplayID ?? "" }, set: {
                        host.setPlacement(edge: host.configuration.edge, displayID: $0.isEmpty ? nil : $0)
                        placementChanged()
                    })) {
                        Text("跟随菜单栏所在屏幕").tag("")
                        ForEach(Array(screens.enumerated()), id: \.element.id) { index, screen in
                            Text("显示器 \(index + 1) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))").tag(screen.id)
                        }
                        if let missing = host.configuration.preferredDisplayID, !screens.contains(where: { $0.id == missing }) {
                            Text("首选显示器暂未连接（已保留选择）").tag(missing)
                        }
                    }.pickerStyle(.menu)
                    Text("完整侧栏仅在主驻留屏显示。拔除首选屏时暂用可用屏，重新连接后恢复选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let screen = selectedScreen {
                    Divider().opacity(0.5)
                    screenPlacement(screen)
                    if primaryID == screen.id {
                        Divider().opacity(0.5)
                        FullscreenToolPreferencesView(host: host, display: screen.id)
                    }
                }
            }
            .frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var selectedScreen: ScreenGeometry? {
        screens.first(where: { $0.id == chosen })
            ?? screens.first(where: { $0.id == host.configuration.preferredDisplayID }) ?? screens.first
    }

    private var primaryID: String? {
        screens.first(where: { $0.id == host.configuration.preferredDisplayID })?.id ?? screens.first?.id
    }

    private func screenPlacement(_ screen: ScreenGeometry) -> some View {
        let settings = host.configuration.displays[screen.id] ?? .init()
        let spacesEnabled = host.registry.preferences.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }
        return VStack(alignment: .leading, spacing: 14) {
            heading("每屏位置")
            if screens.count > 1 {
                Picker("显示器", selection: Binding(get: { screen.id }, set: { chosen = $0 })) {
                    ForEach(Array(screens.enumerated()), id: \.element.id) { index, display in
                        Text("显示器 \(index + 1)" + (display.id == primaryID ? " · 主驻留屏" : "")).tag(display.id)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("display-placement-screen")
            }
            Picker("停靠位置", selection: Binding(get: { settings.edge }, set: { value in update(screen) { $0.edge = value } })) {
                Text("跟随默认").tag(nil as SurfaceEdge?)
                Text("左侧").tag(SurfaceEdge?.some(.left))
                Text("右侧").tag(SurfaceEdge?.some(.right))
            }.pickerStyle(.segmented).accessibilityIdentifier("sidebar-position")
            Text("选择「跟随默认」时，这一屏幕沿用上方的默认停靠位置。")
                .font(.caption).foregroundStyle(.secondary)
            if primaryID != screen.id && spacesEnabled {
                Picker("Spaces 显示方式", selection: Binding(get: { settings.policy }, set: { value in update(screen) { $0.policy = value } })) {
                    Text("手动唤出").tag(SecondaryPolicy.onDemand)
                    Text("有多个窗口时").tag(SecondaryPolicy.contextualAuto)
                    Text("始终显示").tag(SecondaryPolicy.pinned)
                }
                Picker("呈现方式", selection: Binding(get: { settings.placement }, set: { value in update(screen) { $0.placement = value } })) {
                    Text("贴边驻留").tag(SpacePanelPlacement.docked)
                    Text("浮动").tag(SpacePanelPlacement.floating)
                }
                if settings.placement == .floating {
                    Text("按住 Option 拖动 Spaces 面板，可调整它的位置。")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.floatingPosition != nil {
                        Button("回到默认位置") { update(screen) { $0.floatingPosition = nil } }
                    }
                }
                HStack(spacing: 12) {
                    Button("显示 Spaces") { if stillCurrent(screen) { request(screen.id) } }
                    Button("收起 Spaces") { if stillCurrent(screen) { dismiss(screen.id) } }
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func update(_ screen: ScreenGeometry, _ change: (inout DisplaySettings) -> Void) {
        guard stillCurrent(screen) else { return }
        var next = host.configuration.displays[screen.id] ?? .init()
        change(&next)
        host.setDisplaySettings(next, id: screen.id)
    }
}
