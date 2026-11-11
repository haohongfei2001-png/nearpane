import NearpaneCore
import SwiftUI

struct FullscreenToolPreferencesView: View {
    let host: HostSession, display: String

    private func preference<T>(_ key: WritableKeyPath<FullscreenToolSettings, T>) -> Binding<T> {
        Binding(get: {
            (host.configuration.displays[display] ?? DisplaySettings()).fullscreenTools[keyPath: key]
        }, set: { value in
            var latest = host.configuration.displays[display] ?? DisplaySettings()
            latest.fullscreenTools[keyPath: key] = value
            host.setDisplaySettings(latest, id: display)
        })
    }

    var body: some View {
        Section("原生全屏") {
            if let status = host.fullscreenStatus[display] {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("显示精简工具状态条", isOn: preference(\.enabled))
                .accessibilityIdentifier("np.fullscreen.enabled")
            if host.configuration.displays[display]?.fullscreenTools.enabled == true {
                Picker("状态条位置", selection: preference(\.corner)) {
                    Text("左上").tag(FullscreenStripCorner.topLeft)
                    Text("右上").tag(FullscreenStripCorner.topRight)
                    Text("左下").tag(FullscreenStripCorner.bottomLeft)
                    Text("右下").tag(FullscreenStripCorner.bottomRight)
                }
                HStack {
                    Toggle("语音", isOn: preference(\.voice))
                    Toggle("截图", isOn: preference(\.capture))
                }
                if host.configuration.displays[display]?.toolAnchor != nil {
                    Button("恢复浮层默认位置") {
                        var latest = host.configuration.displays[display] ?? DisplaySettings()
                        latest.toolAnchor = nil
                        host.setDisplaySettings(latest, id: display)
                    }
                }
                Text("确认全屏时可点击状态条打开工具。收起浮层不暂停收音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
