import SwiftUI
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

public struct EdgeSurfaceView: View {
    private let host: HostSession
    private let modules: EmbeddedModules?
    private let display: SurfaceDisplay?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init(host: HostSession, modules: EmbeddedModules? = nil) { self.host = host; self.modules = modules; display = nil }
    init(host: HostSession, modules: EmbeddedModules?, display: SurfaceDisplay) {
        self.host = host; self.modules = modules; self.display = display
    }

    private var settings: DisplaySettings {
        let id = display?.id ?? host.configuration.preferredDisplayID ?? ""
        var settings = host.panelPresentationSettings(on: id)
        if display?.usesDefaultExpandedRim == true { settings.glass.rimWidth = nil }
        return settings
    }
    private var innerMaterialStrength: Double {
        SurfaceGlassLevels(settings.glass, dark: scheme == .dark, reduceTransparency: reduceTransparency).innerMaterial
    }
    public var body: some View {
        GeometryReader { geometry in
            let layout = LayoutComposer.compose(width: geometry.size.width, height: geometry.size.height,
                                                pinnedCount: display?.secondary == true ? 0 : host.registry.pinnedModules.count,
                                                expanded: host.registry.expandedID != nil, settings:settings, content:display?.content ?? .full,
                                                voiceEnabled:enabled(BuiltinCatalog.voice),trayEnabled:enabled(BuiltinCatalog.screenshots),
                                                referenceHeight: display?.referenceHeight, voiceCompact: modules?.voiceCompact ?? false,
                                                trayRows: modules?.trayRowCount ?? 1, lyricsHeight: modules?.lyricsHeight ?? 0, toolOrder: host.registry.preferences.filter(\.enabled).map(\.id))
            ZStack(alignment: .topLeading) {
                SurfaceShell(layout: layout, width: geometry.size.width, settings: settings)
                if layout.voice.height > 0 { voice.surfaceCard(width: geometry.size.width, settings: settings).place(in:layout.voice) }
                if layout.screenshots.height > 0 { screenshots.surfaceCard(width: geometry.size.width, settings: settings).place(in:layout.screenshots) }
                #if canImport(NearpaneLyricsModule)
                if let lyrics = modules?.lyrics, let rect = layout.additionalTools[BuiltinCatalog.lyrics], rect.height > 0 {
                    HostLyricsCard(lyrics: lyrics).place(in: rect)
                }
                #endif
                if let notebook = modules?.notebook {
                    ForEach(Array(layout.additionalTools.keys.sorted()), id: \.self) { id in
                        if id == BuiltinCatalog.memo || id == BuiltinCatalog.tasks, let rect = layout.additionalTools[id] {
                            NotebookCard(notebook: notebook, tasks: id == BuiltinCatalog.tasks)
                                .surfaceCard(width: geometry.size.width, settings: settings).place(in: rect)
                        }
                    }
                }
                if let rail = layout.moduleRail { moduleRail(width:geometry.size.width,height:rail.height).place(in:rail) }
                if display?.content != .toolsOnly, layout.windowArea.height > 0 { desktop.padding(.horizontal, settings.glass.inset(width: geometry.size.width)).place(in: layout.windowArea) }
                if display?.secondary != true, let rect = layout.expanded, let id = host.registry.expandedID {
                    // Kept alongside the underlying desktop view: expansion never replaces or resizes it.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { host.handle(.collapse) }
                        .place(in: layout.windowArea)
                    expandedModule(id,width:geometry.size.width).place(in:rect)
                }
            }
            .foregroundStyle(Color(nsColor: SidebarTextColor.primary))
            // Offset children don't contribute their offsets to a ZStack's measured size.
            // Clip at the whole panel, not at the height of its largest individual region.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onChange(of: layout, initial: true) { _, next in display?.updateMaterial?(next) }
            #if canImport(NearpaneTray)
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                let r = layout.screenshots
                if !CGRect(x: r.x, y: r.y, width: r.width, height: r.height).contains(event.location) {
                    modules?.tray.collapseMenu()
                }
            })
            #endif
        }
        .productAccent(host.configuration.accent)
    }

    private func enabled(_ id: String) -> Bool {
        host.registry.preferences.first(where: { $0.id == id })?.enabled == true
    }

    @ViewBuilder private var voice: some View {
        #if canImport(NearpaneVoice)
        if let modules, host.registry.states[BuiltinCatalog.voice] == .resident {
            VoiceSurface(modules.voice, pasteboard: modules.voicePasteboard, settings:settings)
        } else { unavailableVoice }
        #else
        unavailableVoice
        #endif
    }

    private var unavailableVoice: some View {
        Text(enabled(BuiltinCatalog.voice) ? "语音模块暂不可用" : "语音模块已停用")
            .font(.caption).foregroundStyle(Color(nsColor: SidebarTextColor.secondary)).padding(8)
    }

    @ViewBuilder private var screenshots: some View {
        #if canImport(NearpaneTray)
        if let tray = modules?.tray, host.registry.states[BuiltinCatalog.screenshots] == .resident {
            TraySurface(tray, left: (settings.edge ?? host.configuration.edge) == .left, settings:settings)
        } else { unavailableTray }
        #else
        unavailableTray
        #endif
    }

    private var unavailableTray: some View {
        Text(enabled(BuiltinCatalog.screenshots) ? "截图托盘暂不可用" : "截图模块已停用")
            .font(.caption).foregroundStyle(Color(nsColor: SidebarTextColor.secondary)).padding(8)
    }

    private var desktop: some View {
        DesktopSurface(host: host, displayID: display?.id ?? host.configuration.preferredDisplayID,
                       enabled: enabled(BuiltinCatalog.desktop), display:display, settings:settings)
    }

    private func moduleRail(width:Double,height:Double) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 4) {
                ForEach(host.registry.pinnedModules) { module in
                    Button {
                        host.handle(host.registry.expandedID == module.id ? .collapse : .expand(module.id))
                    } label: {
                        let minimumWidth = max(settings.points(.railButtonWidth,in:width), settings.points(.hitSize,in:width))
                        let railHeight = min(height, max(26, settings.points(.hitSize,in:width)))
                        Group {
                            if module.id == BuiltinCatalog.clock, clockVisible {
                                TimelineView(.everyMinute) { tick in
                                    Text(LocalClock.time(tick.date)).font(.callout).monospacedDigit().fixedSize()
                                }
                                .frame(minWidth: minimumWidth).frame(height: railHeight)
                            } else {
                                Image(systemName:module.symbol)
                                    .font(settings.measures[.iconSize].map { .system(size:$0.points(in:width)) } ?? .body)
                                    .frame(width: minimumWidth, height: railHeight)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(module.name)
                    .accessibilityLabel(module.name)
                    .accessibilityIdentifier(module.id)
                    .foregroundStyle(host.registry.expandedID == module.id ? host.configuration.accent.color : Color(nsColor: SidebarTextColor.secondary))
                }
            }.padding(.horizontal, 8)
        }
        .background { Rectangle().fill(.regularMaterial).opacity(innerMaterialStrength) }
    }

    private var clockVisible: Bool {
        host.isRunning && !host.configuration.surfaceHidden && display?.interactionVisible != false
    }

    private func expandedModule(_ id: String,width:Double) -> some View {
        let manifest = host.registry.manifests.first { $0.id == id }
        let projection = host.bus.moduleSnapshots[id]?.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(manifest?.name ?? "Sample").font(.callout)
                Spacer()
                Button { host.handle(.collapse) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭模块").accessibilityIdentifier("nearpane-module-close")
            }
            ScrollView {
                if id == BuiltinCatalog.clock {
                    if clockVisible { ClockDetails(host: host) }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(projection?.message ?? "Module unavailable.").font(.callout)
                        Text("Sample refreshes: \(projection?.refreshCount ?? 0)").font(.caption).monospacedDigit()
                        Button("Refresh sample") { host.handle(.module(id, .refresh)) }
                        Text("This is a Host lifecycle sample. Module data remains owned by its future adapter.")
                            .font(.caption2).foregroundStyle(Color(nsColor: SidebarTextColor.secondary))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(settings.points(.modulePadding,in:width))
        .background {
            RoundedRectangle(cornerRadius:settings.measures[.cornerRadius]?.points(in:width) ?? 10)
                .fill(.regularMaterial).opacity(innerMaterialStrength)
        }
        .overlay(RoundedRectangle(cornerRadius:settings.measures[.cornerRadius]?.points(in:width) ?? 10)
            .stroke(.secondary.opacity(0.2 * innerMaterialStrength)))
        .shadow(color: .black.opacity(0.12 * innerMaterialStrength), radius: 8, y: 3)
    }
}

private extension View {
    func place(in rect: SurfaceRect) -> some View {
        frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipped().offset(x: rect.x, y: rect.y)
    }
}

/// A single button remains reachable when the normal controls no longer fit. Its image
/// is the icon Finder resolves for this very bundle (including the system fallback).
struct FoldedSurfaceButton: View {
    let host: HostSession
    let modules: EmbeddedModules?
    let display: SurfaceDisplay
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    private var symbols: [String] {
        var result: [String] = []
        if !display.secondary {
            #if canImport(NearpaneVoice)
            if let voice = modules?.voice, voice.active {
                switch voice.capture {
                case .speaking: result.append("waveform")
                case .listening: result.append("mic")
                default: result.append("pause")
                }
            }
            if let tray = modules?.tray, tray.connected {
                result.append(tray.visibleIDs.isEmpty ? "photo" : "photo.stack")
            }
            #endif
        }
        if !display.secondary, (modules?.lyricsHeight ?? 0) > 0 { result.append("music.note") }
        if display.content == .full || display.content == .spacesOnly { result.append("rectangle.3.group") }
        return result
    }

    var body: some View {
        GeometryReader { g in
            let horizontal = g.size.width >= g.size.height
            let axis = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
            let available = max(g.size.width, g.size.height) - PanelSizeMetrics.glassInset * 2
            let count = display.sizeForm == .compact ? max(0, Int((available + 4) / (PanelSizeMetrics.iconSide + 4)) - 1) : 0
            Button(action: open) {
                axis {
                    Image(nsImage: Self.appIcon).resizable().scaledToFit()
                        .frame(width: PanelSizeMetrics.iconSide, height: PanelSizeMetrics.iconSide)
                    ForEach(Array(symbols.prefix(count)), id: \.self) { symbol in
                        Image(systemName: symbol).font(.caption).foregroundStyle(Color(nsColor: SidebarTextColor.secondary))
                            .frame(width: PanelSizeMetrics.iconSide, height: PanelSizeMetrics.iconSide)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                SurfaceGlassPalette(dark: scheme == .dark, increasedContrast: contrast == .increased,
                                    reduceTransparency: reduceTransparency,
                                    settings: host.panelPresentationSettings(on: display.id ?? "").glass).folded
            }
            .help("展开 Nearpane")
            .accessibilityLabel("展开 Nearpane")
            .accessibilityIdentifier("nearpane-open-panel")
        }
    }
}
