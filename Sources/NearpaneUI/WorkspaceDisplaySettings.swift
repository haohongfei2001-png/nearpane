import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>

public struct WorkspaceDisplaySettings: View {
    let host: HostSession, screens: [ScreenGeometry], request: (String) -> Void, dismiss: (String) -> Void
    let stillCurrent: (ScreenGeometry) -> Bool
    @ViewState private var pendingReset: DisplaySizeReset?
    @ViewState private var chosen = ""
    @ViewState private var key: DisplayMetric
    public init(host: HostSession, screens: [ScreenGeometry], request: @escaping (String) -> Void, dismiss: @escaping (String) -> Void,
                initialMetric: DisplayMetric = .reservedWidth, stillCurrent: @escaping (ScreenGeometry) -> Bool = { _ in true }) {
        self.host = host
        self.screens = screens
        self.request = request
        self.dismiss = dismiss
        self.stillCurrent = stillCurrent
        _key = State(initialValue: initialMetric)
    }

    public var body: some View {
        ScrollView {
            if let screen = screens.first(where: { $0.id == chosen })
                ?? screens.first(where: { $0.id == host.configuration.preferredDisplayID }) ?? screens.first {
                let primary =
                    screens.first(where: { $0.id == host.configuration.preferredDisplayID })?.id ?? screens.first?.id
                let settings = host.configuration.displays[screen.id] ?? .init()
                let save: (DisplaySettings) -> Void = { value in
                    guard stillCurrent(screen) else { return }
                    host.setDisplaySettings(value, id: screen.id)
                }
                Form {
                    Picker("配置显示器", selection: Binding(get: { screen.id }, set: { chosen = $0; pendingReset = nil })) {
                        ForEach(Array(screens.enumerated()), id: \.element.id) { i, s in
                            Text("显示器 \(i+1) · \(Int(s.visibleFrame.width)) × \(Int(s.visibleFrame.height))").tag(s.id)
                        }
                    }.accessibilityIdentifier("panel-size-display")
                    PanelSizeEditor(settings: settings, screen: screen, edge: host.configuration.edge,
                                    primary: primary == screen.id, content: host.panelContents[screen.id] ?? .hidden,
                                    voice: host.registry.preferences.contains { $0.id == BuiltinCatalog.voice && $0.enabled },
                                    tray: host.registry.preferences.contains { $0.id == BuiltinCatalog.screenshots && $0.enabled }) { draft in
                        let latest = host.configuration.displays[screen.id] ?? .init()
                        if let applied = draft.settings(over: latest, on: screen), applied != latest { save(applied) }
                    }
                    .id([screen.id, String(describing: settings.measures[.panelWidth]), String(describing: settings.measures[.panelHeight])])
                    if primary == screen.id {
                        FullscreenToolPreferencesView(host: host, display: screen.id)
                    }
                    if primary != screen.id {
                        Picker(
                            "空间面板",
                            selection: Binding(
                                get: { settings.policy },
                                set: {
                                    var s = settings
                                    s.policy = $0
                                    save(s)
                                })
                        ) {
                            Text("按需").tag(SecondaryPolicy.onDemand)
                            Text("多目标自动").tag(SecondaryPolicy.contextualAuto)
                            Text("固定").tag(SecondaryPolicy.pinned)
                        }
                        Picker(
                            "占用形态",
                            selection: Binding(
                                get: { settings.placement },
                                set: {
                                    var s = settings
                                    s.placement = $0
                                    save(s)
                                })
                        ) {
                            Text("驻留 · 持续预留").tag(SpacePanelPlacement.docked)
                            Text("浮窗 · 无预留").tag(SpacePanelPlacement.floating)
                        }
                    }
                    if primary != screen.id && settings.placement == .floating {
                        Text("按住 Option 拖动此屏的空间面板可保存浮窗位置。").font(.caption)
                        if settings.floatingPosition != nil {
                            Button("恢复配置锚点") {
                                var updated = settings
                                updated.floatingPosition = nil
                                save(updated)
                            }
                        }
                    }
                    HStack {
                        Button("唤出本屏空间视图") { request(screen.id) }
                        Button("隐藏本屏空间视图") { dismiss(screen.id) }
                    }
                    Picker(
                        "停靠边缘",
                        selection: Binding(
                            get: { settings.edge },
                            set: {
                                var s = settings
                                s.edge = $0
                                save(s)
                            })
                    ) {
                        Text("默认").tag(nil as SurfaceEdge?)
                        Text("左").tag(SurfaceEdge?.some(.left))
                        Text("右").tag(SurfaceEdge?.some(.right))
                    }
                    Picker(
                        "纵向锚点",
                        selection: Binding(
                            get: { settings.anchor },
                            set: {
                                var s = settings
                                s.anchor = $0
                                save(s)
                            })
                    ) {
                        Text("顶部").tag(PanelAnchor.top)
                        Text("居中").tag(PanelAnchor.center)
                        Text("底部").tag(PanelAnchor.bottom)
                    }
                    Picker("调整项目", selection: $key) {
                        ForEach(DisplayMetric.allCases.filter { $0 != .panelWidth && $0 != .panelHeight && ($0.group != .voice || $0 == .voiceHeight) }, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    let defaultMeasure = key == .reservedWidth ? settings.measures[.panelWidth] ?? key.factory : key.factory
                    let basis = settings.referenceExtent(for: key, screen: screen, primary: primary == screen.id)
                    MeasureEditor(metric: key, configured: settings.measures[key], factory: defaultMeasure, extent: basis) {
                        value in
                        var updated = settings
                        updated.measures[key] = value
                        save(updated)
                    }.id("\(screen.id)-\(key.rawValue)-\(String(describing:settings.measures[key]))")
                    if primary == screen.id, let panel = settings.panel(on: screen, fallbackEdge: host.configuration.edge) {
                        let h = panel.height
                        let total = [DisplayMetric.voiceHeight, .trayHeight, .spacesHeight].map { settings.points($0, in: h) }.reduce(0, +) + 2 * settings.points(.sectionGap, in: h)
                        if total > h + 0.01 {
                            let actual = settings.contentHeights(h, content: .full, voice: true, tray: true)
                            Text("分区合计超过面板高度，当前等比适配。实际高度为文字 \(actual.voice, specifier: "%.1f")、托盘 \(actual.tray, specifier: "%.1f")、空间 \(actual.spaces, specifier: "%.1f") pt。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if key == .reservedWidth {
                        Text(primary == screen.id ? "默认随主面板宽度。隐藏界面时仍保留，窗口避让仅对已明确授权且符合条件的窗口生效。" : "驻留式在隐藏时仍保留边界；浮窗式始终无预留。").font(
                            .caption)
                    }
                    HStack {
                        Button("恢复" + key.group.label + "尺寸…") {
                            pendingReset = DisplaySizeReset(screen: screen, saved: settings, group: key.group)
                        }.disabled(!settings.measures.keys.contains { $0.group == key.group })
                        .accessibilityIdentifier("sizes-reset-group")
                        Button("恢复本屏全部尺寸…") {
                            pendingReset = DisplaySizeReset(screen: screen, saved: settings, group: nil)
                        }.disabled(settings.measures.isEmpty)
                        .accessibilityIdentifier("sizes-reset-display")
                    }
                    if let reset = pendingReset, reset.screen == screen {
                        VStack(alignment: .leading) {
                            Text(reset.group == nil || reset.group == .panel
                                 ? "恢复后，面板与持久预留宽度将使用出厂值。已授权的窗口可能重新平铺。"
                                 : "仅恢复" + (reset.group?.label ?? "") + "的尺寸，其余设置不变。")
                                .font(.caption)
                            HStack {
                                Button("取消") { pendingReset = nil }
                                    .accessibilityIdentifier("sizes-reset-cancel")
                                Button("应用恢复") {
                                    let current = host.configuration.displays[screen.id] ?? .init()
                                    if let updated = reset.applying(to: current, on: screen) { save(updated) }
                                    pendingReset = nil
                                }.accessibilityIdentifier("sizes-reset-apply")
                            }
                        }
                    }
                }.padding()
            } else { Text("没有可配置的显示器。").foregroundStyle(.secondary) }
        }
        .onChange(of: screens) { _, _ in pendingReset = nil }
        .onChange(of: key) { _, _ in pendingReset = nil }
    }
}

struct DisplaySizeReset {
    let screen: ScreenGeometry, saved: DisplaySettings, group: DisplayMetricGroup?

    func applying(to current: DisplaySettings, on live: ScreenGeometry) -> DisplaySettings? {
        guard live == screen, current == saved else { return nil }
        let next = current.restoringSizes(group: group)
        return next == current ? nil : next
    }
}

private extension DisplayMetricGroup {
    var label: String {
        switch self {
        case .panel: "面板"
        case .voice: "文字与语音"
        case .tray: "截图托盘"
        case .spaces: "空间预览"
        case .modules: "可选模块"
        }
    }
}

private struct MeasureEditor: View {
    let metric: DisplayMetric, factory: Measure, extent: Double, save: (Measure?) -> Void
    @ViewState private var draft: Measure
    init(metric: DisplayMetric, configured: Measure?, factory: Measure, extent: Double, save: @escaping (Measure?) -> Void) {
        self.metric = metric
        self.factory = factory
        self.extent = extent
        self.save = save
        _draft = State(initialValue: configured ?? factory)
    }
    var body: some View {
        let maximum = draft.unit == .percent ? 100.0 : min(16384, max(1, extent, draft.value))
        VStack(alignment: .leading) {
            HStack {
                TextField("精确值", value: $draft.value, format: .number).frame(width: 86)
                Stepper("微调", value: $draft.value, in: 0...maximum, step: draft.step).labelsHidden()
                Picker(
                    "单位",
                    selection: Binding(
                        get: { draft.unit },
                        set: { u in
                            let pt = draft.points(in: extent)
                            draft = .init(u == .points ? pt : min(100, 100 * pt / max(1, extent)), u)
                        })
                ) { ForEach(MeasureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 100)
            }
            Slider(value: $draft.value, in: 0...maximum, step: draft.step)
            Text(
                "预览 \(draft.points(in:extent),format:.number.precision(.fractionLength(1))) pt · 参考长度 \(extent,format:.number.precision(.fractionLength(1))) pt"
            )
            .font(.caption).monospacedDigit()
            HStack {
                Button("应用此项") { save(draft) }.disabled(!draft.valid)
                Button("重置此项") {
                    draft = factory
                    save(nil)
                }
            }
        }
    }
}

extension DisplayMetric {
    fileprivate var label: String {
        switch self {
        case .panelWidth: "面板宽度"
        case .panelHeight: "面板高度"
        case .reservedWidth: "持久预留宽度"
        case .sideInset: "侧边留距"
        case .topInset: "顶部留距"
        case .bottomInset: "底部留距"
        case .verticalOffset: "纵向偏移"
        case .voiceHeight: "语音区高度"
        case .trayHeight: "托盘区高度"
        case .spacesHeight: "空间区高度"
        case .sectionGap: "模块间距"
        case .textHeight: "文字区高度"
        case .textPadding: "文字内边距"
        case .textSize: "文字字号"
        case .lineGap: "文字行间距"
        case .voiceButtonWidth: "状态按钮宽"
        case .voiceButtonHeight: "状态按钮高"
        case .copySize: "复制图标"
        case .buttonGap: "按钮间距"
        case .waveformSize: "波形宽度"
        case .cellWidth: "微图位宽"
        case .cellHeight: "微图位高"
        case .columnGap: "托盘列间距"
        case .rowGap: "托盘行间距"
        case .trayPadding: "托盘内边距"
        case .trayMenuHeight: "展开托盘高度"
        case .trayButtonSize: "截图按钮字号"
        case .spaceRowHeight: "空间行高"
        case .spaceRowGap: "空间行距"
        case .desktopWidth: "缩略桌面宽"
        case .desktopHeight: "缩略桌面高"
        case .spacePadding: "空间内边距"
        case .scrollHeight: "空间滚动视口"
        case .cornerRadius: "容器圆角"
        case .borderWidth: "窗口边线"
        case .iconSize: "模块图标大小"
        case .labelSize: "空间标签字号"
        case .hitSize: "模块点击目标"
        case .railHeight: "模块条高度"
        case .railButtonWidth: "模块入口宽度"
        case .modulePadding: "模块内边距"
        case .moduleHeight: "展开模块高度"
        }
    }
}
