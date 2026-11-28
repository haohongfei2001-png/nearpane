import NearpaneCore
import SwiftUI

/// User-facing controls are deliberately narrower than internal layout tokens.
public enum DisplaySettingsScope: Equatable, Sendable {
    case global, voice, tray, spaces
    var metrics: [DisplayMetric] {
        switch self {
        case .global: [.panelWidth]
        case .voice: [.textSize]
        case .tray: []
        case .spaces: [.labelSize]
        }
    }
}

public struct WorkspaceDisplaySettings: View {
    let host: HostSession, screens: [ScreenGeometry], request: (String) -> Void, dismiss: (String) -> Void
    let stillCurrent: (ScreenGeometry) -> Bool
    let scope: DisplaySettingsScope
    @State private var chosen = ""

    // Historical acceptance callers remain source-compatible; old element-size
    // arguments no longer expose controls or override product defaults.
    public init(host: HostSession, screens: [ScreenGeometry], request: @escaping (String) -> Void,
                dismiss: @escaping (String) -> Void, initialMetric: DisplayMetric = .panelWidth,
                stillCurrent: @escaping (ScreenGeometry) -> Bool = { _ in true },
                previewExposure: SettingsPreviewExposure? = nil, voiceCompact: Bool = false,
                trayRows: Int = 1, lyricsHeight: Double = 0, scope: DisplaySettingsScope = .global) {
        self.host = host; self.screens = screens; self.request = request; self.dismiss = dismiss
        self.stillCurrent = stillCurrent; self.scope = scope
    }

    public var body: some View {
        if scope == .global {
            ScrollView {
                if let screen = selectedScreen {
                    settingsContent(screen)
                        .frame(maxWidth: 650, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ContentUnavailableView("没有可配置的显示器", systemImage: "display",
                        description: Text("连接显示器后，可在这里调整侧栏。"))
                }
            }
        } else {
            ModuleTextSizeSettings(host: host, screens: screens, scope: scope, stillCurrent: stillCurrent)
        }
    }

    private var selectedScreen: ScreenGeometry? {
        screens.first(where: { $0.id == chosen })
            ?? screens.first(where: { $0.id == host.configuration.preferredDisplayID }) ?? screens.first
    }
    private var primaryID: String? {
        screens.first(where: { $0.id == host.configuration.preferredDisplayID })?.id ?? screens.first?.id
    }

    private func settingsContent(_ screen: ScreenGeometry) -> some View {
        let settings = host.configuration.displays[screen.id] ?? .init()
        return VStack(alignment: .leading, spacing: 24) {
            if screens.count > 1 {
                Picker("应用到", selection: Binding(get: { screen.id }, set: { chosen = $0 })) {
                    ForEach(Array(screens.enumerated()), id: \.element.id) { index, display in
                        Text("显示器 \(index + 1)" + (display.id == primaryID ? " · 主驻留屏" : "")).tag(display.id)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("panel-size-display")
            }
            VStack(alignment: .leading, spacing: 20) {
                heading("侧栏外观")
                VStack(alignment: .leading, spacing: 10) {
                    Text("宽度").font(.system(size: 13, weight: .medium))
                    Slider(value: Binding(get: {
                        WorkbenchVisualPolicy.width(in: screen.visibleFrame.width, settings: settings)
                    }, set: { value in
                        update(screen) { next in
                            next.measures[.panelWidth] = Measure(value.rounded())
                            next.measures[.reservedWidth] = nil
                        }
                    }), in: WorkbenchVisualPolicy.widthRange(in: screen.visibleFrame.width), step: 10)
                        .accessibilityLabel("侧栏宽度").accessibilityIdentifier("sidebar-width")
                    HStack { Text("紧凑"); Spacer(); Text("宽松") }
                        .font(.caption).foregroundStyle(.secondary)
                    Text("所有模块共享宽度，高度随内容自动调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().opacity(0.5)
                PanelGlassEditor(saved: settings.glass, apply: { glass in update(screen) { $0.glass = glass } })
                Divider().opacity(0.5)
                AccentSettings(host: host)
                Text("强调色用于所有显示器和模块。")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func update(_ screen: ScreenGeometry, _ change: (inout DisplaySettings) -> Void) {
        guard stillCurrent(screen) else { return }
        var next = host.configuration.displays[screen.id] ?? .init()
        change(&next)
        host.setDisplaySettings(next, id: screen.id)
    }
}

/// A bounded typography choice belongs to the module whose text it changes.
struct ModuleTextSizeSettings: View {
    let host: HostSession, screens: [ScreenGeometry], scope: DisplaySettingsScope
    var stillCurrent: (ScreenGeometry) -> Bool = { _ in true }
    @State private var chosen = ""

    var body: some View {
        if let metric = scope.metrics.first, scope == .voice || scope == .spaces,
           let screen = screens.first(where: { $0.id == chosen })
            ?? screens.first(where: { $0.id == host.configuration.preferredDisplayID }) ?? screens.first {
            VStack(alignment: .leading, spacing: 12) {
                if scope == .spaces && screens.count > 1 {
                    Picker("显示器", selection: Binding(get: { screen.id }, set: { chosen = $0 })) {
                        ForEach(Array(screens.enumerated()), id: \.element.id) { index, display in
                            Text("显示器 \(index + 1)").tag(display.id)
                        }
                    }
                }
                HStack(spacing: 20) {
                    Text(scope == .voice ? "侧栏文字大小" : "窗口名称大小")
                    Spacer(minLength: 8)
                    Picker("文字大小", selection: Binding(get: {
                        let settings = host.configuration.displays[screen.id] ?? .init()
                        return TextSize.nearest(settings.measures[metric]?.points(in: screen.visibleFrame.width)
                            ?? metric.factory.value, metric: metric)
                    }, set: { size in
                        guard stillCurrent(screen) else { return }
                        var settings = host.configuration.displays[screen.id] ?? .init()
                        settings.measures[metric] = size == .standard ? nil : Measure(size.points(metric: metric))
                        host.setDisplaySettings(settings, id: screen.id)
                    })) {
                        Text("小").tag(TextSize.small)
                        Text("标准").tag(TextSize.standard)
                        Text("大").tag(TextSize.large)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        .accessibilityIdentifier(scope == .voice ? "voice-text-size" : "spaces-text-size")
                }
            }
        }
    }

    private enum TextSize: Int, CaseIterable {
        case small, standard, large
        func points(metric: DisplayMetric) -> Double {
            metric == .textSize ? WorkbenchVisualPolicy.voiceTextSizes[rawValue] : WorkbenchVisualPolicy.windowLabelSizes[rawValue]
        }
        static func nearest(_ value: Double, metric: DisplayMetric) -> Self {
            allCases.min { abs($0.points(metric: metric) - value) < abs($1.points(metric: metric) - value) } ?? .standard
        }
    }
}

/// Compatibility for historical recovery receipts; there is no user-facing reset control.
struct DisplaySizeReset {
    let screen: ScreenGeometry, saved: DisplaySettings, group: DisplayMetricGroup?
    func applying(to current: DisplaySettings, on live: ScreenGeometry) -> DisplaySettings? {
        guard live == screen, current == saved else { return nil }
        let next = current.restoringSizes(group: group)
        return next == current ? nil : next
    }
}
