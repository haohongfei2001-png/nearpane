import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

struct WorkspaceDisplaySettings: View {
    let host: HostSession, screens: [ScreenGeometry], request: (String) -> Void
    @ViewState private var chosen = ""
    @ViewState private var key = DisplayMetric.panelWidth
    var body: some View {
        ScrollView {
            if let screen = screens.first(where: { $0.id == chosen }) ?? screens.first {
                let primary = screens.first(where: { $0.id == host.configuration.preferredDisplayID })?.id ?? screens.first?.id
                let settings = host.configuration.displays[screen.id] ?? .init()
                let save: (DisplaySettings) -> Void = { host.setDisplaySettings($0,id:screen.id) }
                Form {
                    Picker("配置显示器",selection:Binding(get:{ screen.id },set:{ chosen = $0 })) {
                        ForEach(Array(screens.enumerated()),id:\.element.id) { i,s in
                            Text("显示器 \(i+1) · \(Int(s.visibleFrame.width)) × \(Int(s.visibleFrame.height))").tag(s.id)
                        }
                    }
                    if primary != screen.id {
                        Picker("空间面板",selection:Binding(get:{settings.policy},set:{ var s = settings; s.policy = $0; save(s) })) {
                            Text("按需").tag(SecondaryPolicy.onDemand)
                            Text("多目标自动").tag(SecondaryPolicy.contextualAuto)
                            Text("固定").tag(SecondaryPolicy.pinned)
                        }
                        if settings.policy == .onDemand {
                            Button("在此屏显示空间面板") { request(screen.id) }
                            Text("有多个已确认目标时可唤出。").font(.caption)
                        }
                    }
                    Picker("停靠边缘",selection:Binding(get:{settings.edge},set:{ var s = settings; s.edge = $0; save(s) })) {
                        Text("默认").tag(nil as SurfaceEdge?)
                        Text("左").tag(SurfaceEdge?.some(.left)); Text("右").tag(SurfaceEdge?.some(.right))
                    }
                    Picker("纵向锚点",selection:Binding(get:{settings.anchor},set:{ var s = settings; s.anchor = $0; save(s) })) {
                        Text("顶部").tag(PanelAnchor.top); Text("居中").tag(PanelAnchor.center); Text("底部").tag(PanelAnchor.bottom)
                    }
                    Picker("调整项目",selection:$key) {
                        ForEach(DisplayMetric.allCases,id:\.self) { Text($0.label).tag($0) }
                    }
                    let defaultMeasure = key == .reservedWidth && primary != screen.id ? Measure(0) : key.factory
                    let basis = settings.referenceExtent(for:key,screen:screen,primary:primary == screen.id)
                    MeasureEditor(metric:key, configured:settings.measures[key], factory:defaultMeasure, extent:basis) { value in
                        var updated = settings; updated.measures[key] = value; save(updated)
                    }.id("\(screen.id)-\(key.rawValue)-\(String(describing:settings.measures[key]))")
                    if key == .reservedWidth {
                        Text(primary == screen.id ? "默认随主面板宽度。隐藏界面时仍保留，真实窗口避让等待实机验证。" : "副屏默认无预留。").font(.caption)
                    }
                }.padding()
            }
        }
    }
}

private struct MeasureEditor: View {
    let metric: DisplayMetric, factory: Measure, extent: Double, save: (Measure?) -> Void
    @ViewState private var draft: Measure
    init(metric:DisplayMetric,configured:Measure?,factory:Measure,extent:Double,save:@escaping (Measure?) -> Void) {
        self.metric = metric; self.factory = factory; self.extent = extent; self.save = save
        _draft = State(initialValue:configured ?? factory)
    }
    var body: some View {
        let maximum = draft.unit == .percent ? 100.0 : min(16384,max(1,extent,draft.value))
        VStack(alignment:.leading) {
            HStack {
                TextField("精确值",value:$draft.value,format:.number).frame(width:86)
                Stepper("微调",value:$draft.value,in:0...maximum,step:draft.step).labelsHidden()
                Picker("单位",selection:Binding(get:{draft.unit},set:{ u in
                    let pt = draft.points(in:extent)
                    draft = .init(u == .points ? pt : min(100,100 * pt / max(1,extent)),u)
                })) { ForEach(MeasureUnit.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(width:100)
            }
            Slider(value:$draft.value,in:0...maximum,step:draft.step)
            Text("预览 \(draft.points(in:extent),format:.number.precision(.fractionLength(1))) pt · 参考长度 \(extent,format:.number.precision(.fractionLength(1))) pt")
                .font(.caption).monospacedDigit()
            HStack {
                Button("应用此项") { save(draft) }.disabled(!draft.valid)
                Button("重置此项") { draft = factory; save(nil) }
            }
        }
    }
}

private extension DisplayMetric {
    var label: String {
        switch self {
        case .panelWidth:"面板宽度"; case .panelHeight:"面板高度"; case .reservedWidth:"持久预留宽度"
        case .sideInset:"侧边留距"; case .topInset:"顶部留距"; case .bottomInset:"底部留距"; case .verticalOffset:"纵向偏移"
        case .voiceHeight:"语音区高度"; case .trayHeight:"托盘区高度"; case .spacesHeight:"空间区高度"; case .sectionGap:"模块间距"
        case .textHeight:"文字区高度"; case .textPadding:"文字内边距"; case .textSize:"文字字号"; case .lineGap:"文字行间距"
        case .voiceButtonWidth:"状态按钮宽"; case .voiceButtonHeight:"状态按钮高"; case .copySize:"复制图标"; case .buttonGap:"按钮间距"
        case .waveformSize:"波形宽度"; case .cellWidth:"微图位宽"; case .cellHeight:"微图位高"; case .columnGap:"托盘列间距"
        case .rowGap:"托盘行间距"; case .trayPadding:"托盘内边距"; case .trayMenuHeight:"展开托盘高度"; case .trayButtonSize:"截图按钮字号"
        case .spaceRowHeight:"空间行高"; case .spaceRowGap:"空间行距"; case .desktopWidth:"缩略桌面宽"; case .desktopHeight:"缩略桌面高"
        case .spacePadding:"空间内边距"; case .scrollHeight:"空间滚动视口"; case .cornerRadius:"容器圆角"; case .borderWidth:"窗口边线"
        case .iconSize:"模块图标大小"; case .labelSize:"空间标签字号"; case .hitSize:"模块点击目标"; case .railHeight:"模块条高度"
        case .railButtonWidth:"模块入口宽度"; case .modulePadding:"模块内边距"; case .moduleHeight:"展开模块高度"
        }
    }
}
