import AppKit
import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>

/// Only Apply passes these values to the Host. A default height retains the automatic
/// content-fitting behaviour of an untouched display configuration.
struct PanelSizeDraft: Equatable {
    struct Dimension: Equatable {
        private(set) var text: String
        private(set) var unit: MeasureUnit
        private(set) var usesDefault: Bool

        init(_ saved: Measure?, factory: Measure) {
            let value = saved ?? factory
            text = Self.format(value.value)
            unit = value.unit
            usesDefault = saved == nil
        }

        var measure: Measure? {
            let decimal = Locale.current.decimalSeparator ?? "."
            let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: decimal, with: ".")
            guard let n = Double(normalized) else { return nil }
            let m = Measure(n, unit)
            return m.validPanelExtent ? m : nil
        }

        mutating func enter(_ input: String) {
            text = input
            usesDefault = false
        }

        mutating func set(_ number: Double) { enter(Self.format(number)) }

        mutating func convert(to next: MeasureUnit, extent: Double) {
            guard unit != next, let measure, extent > 0 else { return }
            let points = measure.points(in: extent)
            unit = next
            set(next == .points ? points : min(100, 100 * points / extent))
        }

        private static func format(_ value: Double) -> String {
            var result = String(value)
            if result.hasSuffix(".0") { result.removeLast(2) }
            return result.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
        }
    }

    var width: Dimension
    var height: Dimension

    init(_ settings: DisplaySettings = .init()) {
        width = Dimension(settings.measures[.panelWidth], factory: DisplayMetric.panelWidth.factory)
        height = Dimension(settings.measures[.panelHeight], factory: DisplayMetric.panelHeight.factory)
    }

    func settings(over saved: DisplaySettings, on screen: ScreenGeometry) -> DisplaySettings? {
        var result = saved
        for (axis, draft) in [(DisplayMetric.panelWidth, width), (.panelHeight, height)] {
            guard let measure = draft.measure else { return nil }
            if draft.usesDefault {
                result.measures[axis] = nil
            } else if measure != saved.measures[axis] {
                let extent = axis == .panelWidth ? screen.visibleFrame.width : screen.visibleFrame.height
                guard extent > 0 && extent.isFinite else { return nil }
                let range = saved.panelExtentRange(for: axis, on: screen)
                let points = measure.points(in: extent)
                if range.contains(points) {
                    result.measures[axis] = measure
                } else {
                    let effective = min(range.upperBound, max(range.lowerBound, points))
                    result.measures[axis] = Measure(measure.unit == .points ? effective : 100 * effective / extent, measure.unit)
                }
            }
        }
        return result
    }
}

/// Both native controls edit the same live draft, including between SwiftUI redraws.
@MainActor @Observable final class PanelSizeEditing {
    var draft: PanelSizeDraft
    init(_ settings: DisplaySettings) { draft = PanelSizeDraft(settings) }

    func dimension(_ axis: WritableKeyPath<PanelSizeDraft, PanelSizeDraft.Dimension>) -> Binding<PanelSizeDraft.Dimension> {
        Binding(get: { self.draft[keyPath: axis] }, set: { self.draft[keyPath: axis] = $0 })
    }
}

class PanelDimensionTextField: NSTextField, NSTextFieldDelegate {
    var edited: (String) -> Void = { _ in }

    private var composing: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() == true }

    func controlTextDidChange(_ notification: Notification) {
        guard !composing else { return }
        edited(currentEditor()?.string ?? stringValue)
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEnabled, isEditable, !composing, let text = accessibilityValue as? String else { return }
        display(text)
        edited(text)
    }

    func display(_ text: String) {
        guard !composing else { return }
        if stringValue != text { stringValue = text }
        if let editor = currentEditor(), editor.string != text { editor.string = text }
    }
}

private struct PanelDimensionInput: NSViewRepresentable {
    let dimension: Binding<PanelSizeDraft.Dimension>
    let label: String
    let identifier: String

    func makeNSView(context: Context) -> PanelDimensionTextField {
        let field = PanelDimensionTextField(frame: .zero)
        field.delegate = field
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: PanelDimensionTextField, context: Context) {
        field.edited = { dimension.wrappedValue.enter($0) }
        field.display(dimension.wrappedValue.text)
    }
}

struct PanelSizeEditor: View {
    let settings: DisplaySettings
    let screen: ScreenGeometry
    let edge: SurfaceEdge
    let primary: Bool
    let content: PanelContent
    let voice: Bool
    let tray: Bool
    let apply: (PanelSizeDraft) -> Void
    @ViewState private var editing: PanelSizeEditing

    init(settings: DisplaySettings, screen: ScreenGeometry, edge: SurfaceEdge, primary: Bool, content: PanelContent,
         voice: Bool, tray: Bool, apply: @escaping (PanelSizeDraft) -> Void) {
        self.settings = settings
        self.screen = screen
        self.edge = edge
        self.primary = primary
        self.content = content
        self.voice = voice
        self.tray = tray
        self.apply = apply
        _editing = State(initialValue: PanelSizeEditing(settings))
    }

    var body: some View {
        let proposed = editing.draft.settings(over: settings, on: screen)
        VStack(alignment: .leading, spacing: 7) {
            dimension(editing.dimension(\.width), label: "面板宽度", id: "panel-width", extent: screen.visibleFrame.width,
                      bounds: settings.panelExtentRange(for: .panelWidth, on: screen))
            dimension(editing.dimension(\.height), label: "面板高度", id: "panel-height", extent: screen.visibleFrame.height,
                      bounds: settings.panelExtentRange(for: .panelHeight, on: screen))
            if let proposed, let layout = PanelSizeLayout(settings: proposed, screen: screen, edge: edge,
                                                         content: content, voice: voice, tray: tray, floating: !primary) {
                PanelSizePreview(screen: screen, layout: layout, settings: proposed, content: content, voice: voice, tray: tray)
            } else {
                Text("请输入有效尺寸。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("应用宽高") { apply(editing.draft) }
                    .disabled(proposed == nil || proposed == settings)
                    .accessibilityIdentifier("panel-size-apply")
                Button("恢复默认宽高") { editing.draft = PanelSizeDraft() }
                    .accessibilityIdentifier("panel-size-defaults")
            }
        }
    }

    private func dimension(_ dimension: Binding<PanelSizeDraft.Dimension>, label: String, id: String,
                           extent: Double, bounds: ClosedRange<Double>) -> some View {
        let d = dimension.wrappedValue
        let convert = d.unit == .points ? 1 : 100 / max(1, extent)
        let limits = (bounds.lowerBound * convert)...(bounds.upperBound * convert)
        func clamp(_ value: Double) -> Double { min(max(value, limits.lowerBound), limits.upperBound) }
        let number = Binding<Double>(get: { clamp(dimension.wrappedValue.measure?.value ?? limits.lowerBound) },
                                     set: { dimension.wrappedValue.set(clamp($0)) })
        return HStack(spacing: 6) {
            Text(label).fixedSize()
            PanelDimensionInput(dimension: dimension, label: label, identifier: id + "-value").frame(width: 78)
            Picker(label + "单位", selection: Binding(get: { dimension.wrappedValue.unit },
                                                    set: { dimension.wrappedValue.convert(to: $0, extent: extent) })) {
                ForEach(MeasureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 53).accessibilityIdentifier(id + "-unit")
            if limits.lowerBound < limits.upperBound {
                Stepper(label + "微调", value: number, in: limits, step: d.unit == .points ? 0.5 : 0.1).labelsHidden()
                Slider(value: number, in: limits)
                    .accessibilityLabel(label).accessibilityIdentifier(id + "-slider")
            }
        }
    }
}

/// Draw just the panel footprint and its section layout. No running domain views,
/// external window actions or saved settings take part in the preview.
private struct PanelSizePreview: View {
    let screen: ScreenGeometry, layout: PanelSizeLayout, settings: DisplaySettings, content: PanelContent
    let voice: Bool, tray: Bool
    var body: some View {
        let frame = layout.frame
        let form = layout.form
        let kind = content == .hidden ? "此屏已隐藏" : (form == .full ? "完整" : (form == .compact ? "精简" : "图标"))
        return HStack(spacing: 10) {
            Canvas { context, size in
                let safe = screen.visibleFrame
                guard safe.width > 0, safe.height > 0 else { return }
                let scale = min((size.width - 2) / safe.width, (size.height - 2) / safe.height)
                let screenRect = CGRect(x: (size.width - safe.width * scale) / 2,
                                        y: (size.height - safe.height * scale) / 2,
                                        width: safe.width * scale, height: safe.height * scale)
                context.stroke(Path(screenRect), with: .color(.secondary), lineWidth: 1)
                let pane = CGRect(x: screenRect.minX + (frame.x - safe.x) * scale,
                                  y: screenRect.minY + (safe.y + safe.height - frame.y - frame.height) * scale,
                                  width: frame.width * scale, height: frame.height * scale)
                if content == .hidden {
                    context.stroke(Path(pane), with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    return
                }
                context.fill(Path(pane), with: .color(.accentColor.opacity(0.22)))
                if form == .full {
                    let sections = LayoutComposer.compose(width: frame.width, height: frame.height, pinnedCount: 0,
                                                          expanded: false, settings: settings, content: content,
                                                          voiceEnabled: voice, trayEnabled: tray, referenceHeight: layout.referenceHeight)
                    for section in [sections.voice, sections.screenshots] where section.height > 0 {
                        let boundary = CGRect(x: pane.minX, y: pane.minY + (section.y + section.height) * scale,
                                              width: pane.width, height: min(1, pane.height))
                        context.fill(Path(boundary), with: .color(.secondary))
                    }
                }
                context.stroke(Path(pane), with: .color(.accentColor), lineWidth: 1)
            }.frame(width: 110, height: 76)
            VStack(alignment: .leading, spacing: 2) {
                Text("布局预览 · " + kind)
                Text("\(frame.width, format: .number.precision(.fractionLength(0...2))) × \(frame.height, format: .number.precision(.fractionLength(0...2))) pt")
                    .monospacedDigit()
            }.font(.caption)
            if form == .icon && content != .hidden {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().scaledToFit()
                    .frame(width: PanelSizeMetrics.iconSide, height: PanelSizeMetrics.iconSide)
                    .padding(PanelSizeMetrics.glassInset)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: PanelSizeMetrics.glassInset))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("panel-size-preview")
    }
}
