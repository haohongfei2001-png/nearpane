import SwiftUI
import NearpaneCore

public struct EdgeSurfaceView: View {
    private let host: HostSession
    public init(host: HostSession) { self.host = host }

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
                        .place(in: SurfaceRect(width: geometry.size.width, height: geometry.size.height))
                    expandedModule(id).place(in: rect)
                }
                if let rail = layout.moduleRail { moduleRail.place(in: rail) }
            }
            .clipped()
        }
        .tint(.indigo)
    }

    private func enabled(_ id: String) -> Bool {
        host.registry.preferences.first(where: { $0.id == id })?.enabled == true
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(enabled(BuiltinCatalog.voice) ? "Voice adapter not connected." : "Voice module disabled.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "mic.slash").accessibilityLabel("Voice capture unavailable")
                Spacer()
                Image(systemName: "doc.on.doc").foregroundStyle(.tertiary)
                    .accessibilityLabel("Copy unavailable")
            }.foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(enabled(BuiltinCatalog.screenshots) ? "Screenshot adapter not connected." : "Screenshot module disabled.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.18))
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                        .aspectRatio(1.5, contentMode: .fit)
                }
            }.accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
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
