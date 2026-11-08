import SwiftUI
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

public struct EdgeSurfaceView: View {
    private let host: HostSession
    private let modules: EmbeddedModules?
    public init(host: HostSession, modules: EmbeddedModules? = nil) { self.host = host; self.modules = modules }

    public var body: some View {
        GeometryReader { geometry in
            let layout = LayoutComposer.compose(width: geometry.size.width, height: geometry.size.height,
                                                pinnedCount: host.registry.pinnedModules.count,
                                                expanded: host.registry.expandedID != nil)
            ZStack(alignment: .topLeading) {
                voice.place(in: layout.voice)
                screenshots.place(in: layout.screenshots)
                desktop.place(in: layout.desktop)
                if let rect = layout.expanded, let id = host.registry.expandedID {
                    // Kept alongside the underlying desktop view: expansion never replaces or resizes it.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { host.handle(.collapse) }
                        .place(in: layout.desktop)
                    expandedModule(id).place(in: rect)
                }
                if let rail = layout.moduleRail { moduleRail.place(in: rail) }
            }
            .clipped()
            #if canImport(NearpaneTray)
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
        if let voice = modules?.voice, host.registry.states[BuiltinCatalog.voice] == .resident {
            VoiceSurface(voice)
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
            TraySurface(tray, left: host.configuration.edge == .left)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !enabled(BuiltinCatalog.desktop) {
                    Text("Desktop mock disabled.")
                } else {
                    Label("Synthetic data", systemImage: "rectangle.dashed").font(.caption)
                    Text("Spaces Preview is not connected.").font(.callout)
                    if let latest = host.bus.desktop {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            let freshness = latest.effectiveFreshness(at: context.date)
                            Text(freshness == .fresh ? "Mock snapshot" : (freshness == .stale ? "Stale snapshot · actions unavailable" : "Updating · last stable sample retained"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        let shown = latest.freshness == .transient ? (host.bus.lastStableDesktop ?? latest) : latest
                        ForEach(shown.displays) { display in
                            VStack(alignment: .leading, spacing: 7) {
                                Image(systemName: display.rotationDegrees == 90 ? "rectangle.portrait" : "display")
                                Text("Synthetic display").font(.caption)
                                Text("\(Int(display.frame.width)) × \(Int(display.frame.height)) · \(display.rotationDegrees)°")
                                    .font(.caption2).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("User-facing Spaces: unknown").font(.caption)
                        Text("Display samples are not Space rows. Switching and window activation are unavailable.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if host.providerFailed {
                        Text("Mock provider unavailable. Retained data is not current.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // The control layer overlays this view; this gutter only prevents metadata from being obscured.
            .padding(.bottom, 32)
        }
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .accessibilityIdentifier("desktop-reserved-region")
    }

    private var moduleRail: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 4) {
                ForEach(host.registry.pinnedModules) { module in
                    Button {
                        host.handle(host.registry.expandedID == module.id ? .collapse : .expand(module.id))
                    } label: {
                        Image(systemName: module.symbol).frame(width: 28, height: 26)
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

    private func expandedModule(_ id: String) -> some View {
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private extension View {
    func place(in rect: SurfaceRect) -> some View {
        frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipped().offset(x: rect.x, y: rect.y)
    }
}
