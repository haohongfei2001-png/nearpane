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
    public init(host: HostSession, modules: EmbeddedModules? = nil) { self.host = host; self.modules = modules; display = nil }
    init(host: HostSession, modules: EmbeddedModules?, display: SurfaceDisplay) {
        self.host = host; self.modules = modules; self.display = display
    }

    private var settings: DisplaySettings {
        let id = display?.id ?? host.configuration.preferredDisplayID ?? ""
        return host.configuration.displays[id] ?? .init()
    }
    public var body: some View {
        GeometryReader { geometry in
            let layout = LayoutComposer.compose(width: geometry.size.width, height: geometry.size.height,
                                                pinnedCount: host.registry.pinnedModules.count,
                                                expanded: host.registry.expandedID != nil, settings:settings, content:display?.content ?? .full,
                                                voiceEnabled:enabled(BuiltinCatalog.voice),trayEnabled:enabled(BuiltinCatalog.screenshots),
                                                referenceHeight:display?.referenceHeight)
            ZStack(alignment: .topLeading) {
                if layout.voice.height > 0 { voice.place(in:layout.voice) }
                if layout.screenshots.height > 0 { screenshots.place(in:layout.screenshots) }
                if layout.desktop.height > 0 { desktop.place(in:layout.desktop) }
                if display?.secondary != true, let rect = layout.expanded, let id = host.registry.expandedID {
                    // Kept alongside the underlying desktop view: expansion never replaces or resizes it.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { host.handle(.collapse) }
                        .place(in: layout.desktop)
                    expandedModule(id,width:geometry.size.width).place(in:rect)
                }
                if display?.secondary != true, let rail = layout.moduleRail { moduleRail(width:geometry.size.width,height:rail.height).place(in:rail) }
            }
            // Offset children don't contribute their offsets to a ZStack's measured size.
            // Clip at the whole panel, not at the height of its largest individual region.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
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
        .tint(.indigo)
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
            .font(.caption).foregroundStyle(.secondary).padding(8)
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
            .font(.caption).foregroundStyle(.secondary).padding(8)
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
                        Image(systemName:module.symbol)
                            .font(settings.measures[.iconSize].map { .system(size:$0.points(in:width)) } ?? .body)
                            .frame(width:max(settings.points(.railButtonWidth,in:width),settings.points(.hitSize,in:width)),
                                   height:min(height,max(26,settings.points(.hitSize,in:width))))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(module.name)
                    .accessibilityLabel(module.name)
                    .foregroundStyle(host.registry.expandedID == module.id ? Color.indigo : Color.secondary)
                }
            }.padding(.horizontal, 8)
        }
        .background(.regularMaterial)
    }

    private func expandedModule(_ id: String,width:Double) -> some View {
        let manifest = host.registry.manifests.first { $0.id == id }
        let projection = host.bus.moduleSnapshots[id]?.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(manifest?.name ?? "Sample").font(.callout)
                Spacer()
                Button { host.handle(.collapse) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close module")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(projection?.message ?? "Module unavailable.").font(.callout)
                    Text("Sample refreshes: \(projection?.refreshCount ?? 0)").font(.caption).monospacedDigit()
                    Button("Refresh sample") { host.handle(.module(id, .refresh)) }
                    Text("This is a Host lifecycle sample. Module data remains owned by its future adapter.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(settings.points(.modulePadding,in:width))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius:settings.measures[.cornerRadius]?.points(in:width) ?? 10))
        .overlay(RoundedRectangle(cornerRadius:settings.measures[.cornerRadius]?.points(in:width) ?? 10).stroke(.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
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
    let modules: EmbeddedModules?
    let display: SurfaceDisplay
    let open: () -> Void

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
                        Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                            .frame(width: PanelSizeMetrics.iconSide, height: PanelSizeMetrics.iconSide)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开 Nearpane")
            .accessibilityLabel("展开 Nearpane")
            .accessibilityIdentifier("nearpane-open-panel")
        }
    }
}
