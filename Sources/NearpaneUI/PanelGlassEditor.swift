import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

struct PanelGlassEditor: View {
    let saved: PanelGlassSettings
    let width: Double
    let preview: (PanelGlassSettings?) -> Void
    let apply: (PanelGlassSettings) -> Void
    @ViewState private var draft: PanelGlassSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduced

    init(saved: PanelGlassSettings, width: Double, preview: @escaping (PanelGlassSettings?) -> Void,
         apply: @escaping (PanelGlassSettings) -> Void) {
        self.saved = saved
        self.width = width
        self.preview = preview
        self.apply = apply
        _draft = .init(initialValue: saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("玻璃外观").font(.headline)
            opacityRow("整体透明度", key: \.overallTransparency, fallback: 0, id: "overall")
            opacityRow("外框透明度", key: \.outerTransparency,
                       fallback: SurfaceGlassLevels.outerDefault(dark: scheme == .dark), id: "outer")
            opacityRow("内卡透明度", key: \.innerTransparency,
                       fallback: SurfaceGlassLevels.innerDefault(dark: scheme == .dark), id: "inner")
            let rim = draft.rimWidth ?? Measure(PanelSizeMetrics.cardInset(width: width))
            HStack {
                Text("四边等宽").frame(width: 82, alignment: .leading)
                let maximum = rim.unit == .points ? width / 2 : 50
                let value = Binding(get: { rim.value }, set: { draft.rimWidth = .init($0, rim.unit) })
                Slider(value: Binding(get: { min(maximum, max(0, value.wrappedValue)) }, set: { newValue in
                    value.wrappedValue = min(maximum, (newValue / rim.step).rounded() * rim.step)
                }), in: 0...max(1, maximum))
                    .accessibilityLabel("外框留白宽度").accessibilityIdentifier("glass-rim-width")
                TextField("外框宽度", value: value, format: .number).frame(width: 50)
                    .accessibilityIdentifier("glass-rim-value")
                Picker("外框宽度单位", selection: Binding(get: { rim.unit }, set: { unit in
                    let points = rim.points(in: width)
                    draft.rimWidth = Measure(unit == .points ? points : points * 100 / max(1, width), unit)
                })) {
                    ForEach(MeasureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("glass-rim-unit")
            }
            Text(reduced ? "系统已开启降低透明度。透明度偏好会保存，当前使用实色背景。" :
                "100% 为全透明。整体透明度作用于玻璃背景；外框留白的百分比按面板宽度计算。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("应用外观") { apply(draft) }.disabled(!acceptable || draft == saved)
                    .accessibilityIdentifier("glass-apply")
                Button("撤销预览") { draft = saved }.disabled(draft == saved)
                Button("恢复出厂外观") { draft = .init() }.disabled(draft == .init())
                    .accessibilityIdentifier("glass-defaults")
            }
        }
        .onChange(of: draft) { _, next in preview(acceptable && next != saved ? next : nil) }
        .onDisappear { preview(nil) }
    }

    private var acceptable: Bool {
        draft.valid && (draft.rimWidth.map { $0.points(in: width) <= width / 2 } ?? true)
    }

    private func opacityRow(_ title: String, key: WritableKeyPath<PanelGlassSettings, Double?>,
                            fallback: Double, id: String) -> some View {
        let value = Binding(get: { draft[keyPath: key] ?? fallback }, set: { newValue in
            var updated = draft
            updated[keyPath: key] = newValue
            draft = updated
        })
        return HStack {
            Text(title).frame(width: 82, alignment: .leading)
            Slider(value: Binding(get: { min(100, max(0, value.wrappedValue)) }, set: {
                value.wrappedValue = $0.rounded()
            }), in: 0...100)
                .accessibilityLabel(title).accessibilityIdentifier("glass-" + id)
            TextField(title, value: value, format: .number).frame(width: 50)
                .accessibilityIdentifier("glass-" + id + "-value")
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }
}
