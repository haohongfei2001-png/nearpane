import AppKit
import SwiftUI
import NearpaneCore

public struct SettingsView: View {
    private let host: HostSession
    private let screens: [ScreenGeometry]
    private let placementChanged: () -> Void
    public init(host: HostSession, screens: [ScreenGeometry], placementChanged: @escaping () -> Void) {
        self.host = host; self.screens = screens; self.placementChanged = placementChanged
    }

    public var body: some View {
        TabView {
            modules.tabItem { Text("Modules") }
            appearance.tabItem { Text("Placement") }
            mockSettings.tabItem { Text("Mock & diagnostics") }
        }
        .padding(16)
        .frame(width: 600, height: 540)
    }

    private var modules: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Core adapters are placeholders. Optional entries are bundled lifecycle samples.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(host.registry.preferences, id: \.id) { pref in
                    if let manifest = host.registry.manifests.first(where: { $0.id == pref.id }) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle(manifest.name, isOn: Binding(get: { pref.enabled }, set: { host.handle(.setEnabled(pref.id, $0)) }))
                                Spacer()
                                if manifest.kind == .builtin {
                                    Toggle("Pin", isOn: Binding(get: { pref.pinned }, set: { host.handle(.setPinned(pref.id, $0)) }))
                                        .fixedSize()
                                    Button { host.handle(.move(pref.id, -1)) } label: { Image(systemName: "arrow.up") }
                                        .accessibilityLabel("Move \(manifest.name) up")
                                    Button { host.handle(.move(pref.id, 1)) } label: { Image(systemName: "arrow.down") }
                                        .accessibilityLabel("Move \(manifest.name) down")
                                }
                            }
                            HStack {
                                Text(host.registry.states[pref.id]?.rawValue ?? "available").font(.caption).foregroundStyle(.secondary)
                                if host.registry.states[pref.id] == .degraded {
                                    Button("Restart sample") { host.handle(.setEnabled(pref.id, true)) }
                                }
                            }
                        }
                        Divider()
                    }
                }
                Text("Core order and region sizes remain fixed. Unpinning or disabling does not delete domain data.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var appearance: some View {
        Form {
            Picker("Edge", selection: Binding(get: { host.configuration.edge }, set: {
                host.setPlacement(edge: $0, displayID: host.configuration.preferredDisplayID); placementChanged()
            })) {
                ForEach(SurfaceEdge.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Display", selection: Binding(get: { host.configuration.preferredDisplayID ?? "" }, set: {
                host.setPlacement(edge: host.configuration.edge, displayID: $0.isEmpty ? nil : $0); placementChanged()
            })) {
                Text("Menu-bar display").tag("")
                ForEach(Array(screens.enumerated()), id: \.element.id) { index, screen in
                    Text("Display \(index + 1) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))").tag(screen.id)
                }
                if let missing = host.configuration.preferredDisplayID, !screens.contains(where: { $0.id == missing }) {
                    Text("Preferred display unavailable (retained)").tag(missing)
                }
            }
            Text("Width follows one eighth of the selected screen. Placement uses its visible area. A missing display falls back to the menu-bar display without losing your preference.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(16)
    }

    private var mockSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Fixture", selection: Binding(get: { host.configuration.fixture }, set: { fixture in
                    Task { await host.selectFixture(fixture) }
                })) { ForEach(DesktopFixture.allCases) { Text($0.label).tag($0) } }
                Button("Refresh mock snapshot") { Task { await host.refreshDesktop() } }
                if let snapshot = host.bus.desktop {
                    Text("Revision \(snapshot.revision) · \(snapshot.displays.count) synthetic displays")
                    Text("Internal scope record counts: \(snapshot.scopes.map { String($0.records.count) }.joined(separator: " + "))")
                    Text("User-facing Space semantics: UNKNOWN. Counts above are internal records, not independent desktops.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Simulated permissions (no macOS prompts)").font(.headline)
                let key = PermissionKey(moduleID: BuiltinCatalog.calendar, permission: .calendarRead)
                HStack {
                    Text("Calendar sample: \(host.permissions.decision(for: key).rawValue)")
                    Button("Grant mock") { host.permissions.setDecision(.granted, for: key) }
                    Button("Revoke mock") { host.permissions.setDecision(.denied, for: key) }
                }
                Text("Enabling a module does not request permissions. Refreshing the Calendar sample checks this simulated grant.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if host.configurationProtected {
                    Text("Configuration could not be read. The original file is protected; this session's changes will not be saved.")
                        .foregroundStyle(.orange)
                } else if host.configurationSaveFailed {
                    Text("Configuration could not be saved. Changes are in memory only.").foregroundStyle(.orange)
                } else { Text("Configuration persistence ready.").font(.caption) }
                Text("Diagnostics: \(host.diagnostics.records.count) bounded local records. No content or desktop identifiers.")
                    .font(.caption)
                ForEach(Array(host.diagnostics.records.suffix(6).enumerated()), id: \.offset) { _, record in
                    Text(record.code.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Spaces Preview: NOT IMPLEMENTED / NOT VALIDATED. First-party integrations and all real desktop actions are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}
