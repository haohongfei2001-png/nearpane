import SwiftUI
import NearpaneCore

/// One optical control for the whole sidebar. Layer balance and geometry are design tokens.
struct PanelGlassEditor: View {
    let saved: PanelGlassSettings
    let apply: (PanelGlassSettings) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("透明度").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("透明度方式", selection: Binding(get: { saved.overallTransparency != nil }, set: { custom in
                    var next = PanelGlassSettings()
                    next.overallTransparency = custom ? (scheme == .dark ? 22 : 32) : nil
                    apply(next)
                })) {
                    Text("随系统外观").tag(false)
                    Text("自定").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .accessibilityIdentifier("glass-mode")
            }
            if let transparency = saved.overallTransparency {
                Slider(value: Binding(get: { min(100, max(0, transparency)) }, set: { value in
                    var next = PanelGlassSettings()
                    next.overallTransparency = value
                    apply(next)
                }), in: 0...100, step: 5)
                    .accessibilityLabel("侧栏透明度").accessibilityIdentifier("glass-overall")
                HStack { Text("更清晰"); Spacer(); Text("更通透") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(reduced ? "系统已开启「降低透明度」，当前使用实色背景。" : "玻璃材质随浅色和深色外观调整，文字与控件始终清晰。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
