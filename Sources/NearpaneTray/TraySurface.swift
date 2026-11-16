import AppKit
import SwiftUI
import RiftletCore
import NearpaneCore

private typealias ViewState<T> = State<T>

public struct TraySurface: View {
    let module: TrayModule
    let left: Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var morph
    let settings: DisplaySettings
    public init(_ module: TrayModule, left: Bool) { self.init(module,left:left,settings:.init()) }
    public init(_ module: TrayModule, left: Bool, settings: DisplaySettings) {
        self.module = module; self.left = left; self.settings = settings
    }

    public var body: some View {
        GeometryReader { outer in
          Group {
            if module.connected {
                GeometryReader { g in
                    let layout = TrayLayout(ids: module.rows.map(\.id), size: g.size,
                                            captureEntry: module.captureEntry, expanded: module.expanded, settings:settings)
                    let cell = layout.cellSize
                    let unit = g.size.width / 246
                    let buttonSize = settings.points(.trayButtonSize, in: outer.size.height)
                    VStack(spacing:layout.rowGap) {
                        ScrollView(.vertical) {
                            LazyVGrid(columns:[GridItem(.fixed(cell.width),spacing:layout.columnGap),GridItem(.fixed(cell.width))],spacing:layout.rowGap) {
                                ForEach(module.rows) { row in
                                    thumbnail(row, cell: cell, unit: unit)
                                }
                                if module.captureEntry && !module.expanded {
                                    Button { module.toggleMenu() } label: {
                                        TrayCameraGlyph(width: min(buttonSize, cell.width * 0.75, cell.height))
                                            .matchedGeometryEffect(id: "systemCamera", in: morph)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }.frame(width: cell.width, height: cell.height)
                                    .buttonStyle(TrayCaptureStyle(unit: unit)).accessibilityLabel("展开截图方式")
                                }
                            }
                            .padding(.top, layout.cells.first?.frame.minY ?? 0)
                        }
                        .frame(height: layout.imageViewport)
                        .onScrollPhaseChange { _, phase in if phase != .idle { module.cancelArrival() } }
                        if layout.menu != nil {
                            HStack(spacing: min(4 * unit, layout.columnGap)) {
                                ForEach(module.menuOrder, id: \.self) { action in
                                    Button { module.capture(action) } label: {
                                        Group {
                                            if action == .system {
                                                Image(systemName: action.symbol).matchedGeometryEffect(id: "systemCamera", in: morph)
                                            } else { Image(systemName: action.symbol) }
                                        }.fontWeight(.medium)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }
                                    .accessibilityLabel(action.label).help(action.label)
                                    .accessibilityAction(named: "收起截图方式") { module.collapseMenu() }
                                }
                            }
                            .buttonStyle(TrayCaptureStyle(unit: unit)).frame(height:layout.menu?.height)
                            .contextMenu { Button("收起截图方式") { module.toggleMenu() } }
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { if module.expanded { module.toggleMenu() } } }
                    .onExitCommand { if module.expanded { module.toggleMenu() } }
                    .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: module.expanded)
                    .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: module.rows.map(\.id))
                    .clipped()
                }
            } else {
                Text("尚未连接截图托盘").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size:settings.points(.trayButtonSize,in:outer.size.height)))
        .padding(settings.points(.trayPadding,in:outer.size.width))
        .overlay(alignment: .bottomLeading) {
            if let message = module.issue ?? module.attachmentFeedback {
                Text(message).font(.caption2).lineLimit(2).help(message)
                    .padding(3).background(.regularMaterial).allowsHitTesting(false)
            }
        }
        }
    }

    private func thumbnail(_ row: AssetRecord, cell: CGSize, unit: CGFloat) -> some View {
        let rim = min(2.75 * unit, cell.width / 8, cell.height / 8)
        let foot = min(0.75 * unit, cell.height / 10)
        let size = TrayLayout.fitted(pixels: .init(width: row.image.pixelWidth, height: row.image.pixelHeight),
                                     cell: .init(width: cell.width - 2 * rim, height: cell.height - 2 * rim - foot))
        let leaving = module.swallowing.contains(row.id)
        return ZStack(alignment: .center) {
            TrayImage(row: row, size: size, module: module)
                .opacity(module.flyingID == row.id ? 0 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if let symbol = statusSymbol(row.status) {
                        Image(systemName: symbol).font(.caption2.weight(.medium)).padding(3)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.1), lineWidth: 0.5))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay { ThumbnailHit(row: row, module: module, arrivalID: module.arrival?.id, left: left) }
                .padding(rim).padding(.bottom, foot)
                .background {
                    TrayTileBackground(radius: min((size.width + 2 * rim) * 9 / 114, (size.height + 2 * rim + foot) / 2))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .offset(x: leaving && !reducedMotion ? (left ? -56 : 56) : 0)
                .opacity(leaving ? 0 : 1)
                .animation(reducedMotion ? nil : .easeIn(duration: 0.12), value: leaving)
        }.frame(width: cell.width, height: cell.height)
    }
    private func statusSymbol(_ state: QueueStatus) -> String? {
        switch state {
        case .unknown: "questionmark"
        case .failed: "arrow.clockwise"
        case .missing: "exclamationmark.triangle"
        case .transferring: "ellipsis"
        case .used, .pending: nil
        }
    }
}

/// The raised viewfinder and centered lens use Riftlet's 28 × 24 camera outline.
struct TrayCameraGlyph: View {
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 28, y: size.height / 24)
            var path = Path()
            path.addLines([CGPoint(x: 3, y: 5.5), CGPoint(x: 8.3, y: 5.5), CGPoint(x: 10.8, y: 1.4),
                           CGPoint(x: 17.2, y: 1.4), CGPoint(x: 19.8, y: 5.5),
                           CGPoint(x: 25.2, y: 5.5)])
            path.addQuadCurve(to: CGPoint(x: 26.8, y: 7.2), control: CGPoint(x: 26.8, y: 5.5))
            path.addLine(to: CGPoint(x: 26.8, y: 20.9))
            path.addQuadCurve(to: CGPoint(x: 25.2, y: 22.5), control: CGPoint(x: 26.8, y: 22.5))
            path.addLine(to: CGPoint(x: 2.8, y: 22.5))
            path.addQuadCurve(to: CGPoint(x: 1.2, y: 20.9), control: CGPoint(x: 1.2, y: 22.5))
            path.addLine(to: CGPoint(x: 1.2, y: 7.2))
            path.addQuadCurve(to: CGPoint(x: 3, y: 5.5), control: CGPoint(x: 1.2, y: 5.5))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 9.5, y: 9.3, width: 9, height: 9))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2.55, lineJoin: .round))
        }.frame(width: width, height: width * 24 / 28)
    }
}

/// Riftlet's glass card follows the fitted bitmap. The grid slot stays fixed;
/// only the image above this passive backing accepts draft input.
private struct TrayTileBackground: View {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var scale

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    var body: some View {
        shape.fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                shape.fill(.tint.opacity(colorScheme == .dark ? 0.16 : 0.075))
            }
            .opacity(reduceTransparency || contrast == .increased ? 1 : 0.90)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.55) : Color.white.opacity(colorScheme == .dark ? 0.25 : 0.6),
                                   lineWidth: contrast == .increased ? 1 : 1 / max(1, scale))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.15), radius: min(3, radius / 3), y: 1.5)
    }
}

struct TrayCaptureStyle: ButtonStyle {
    var unit: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        configuration.label
            .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .background {
                // Riftlet's camera key has a raised face and a short contact edge.
                // Keep the full key as the button's hit area in both menu states.
                GeometryReader { proxy in
                    let shape = RoundedRectangle(cornerRadius: min(12 * unit, proxy.size.height / 2, proxy.size.width / 2), style: .continuous)
                    let depth = configuration.isPressed ? 0 : min(proxy.size.height * 0.08, 4.5 * unit)
                    shape.fill(.background)
                        .overlay { shape.fill(.tint.opacity(dark ? 0.42 : 0.29)) }
                        .opacity(opaque ? 1 : 0.80)
                    shape.fill(.background)
                        .overlay { shape.fill(.tint.opacity(dark ? 0.27 : 0.11)) }
                        .opacity(opaque || contrast == .increased ? 1 : dark ? 0.85 : 0.95)
                        .overlay { shape.strokeBorder(contrast == .increased ? Color.primary : .white.opacity(dark ? 0.27 : 0.42),
                                                      lineWidth: contrast == .increased ? 1 : 1 / max(1, scale)) }
                        .padding(.bottom, depth)
                }.allowsHitTesting(false)
            }
    }
}

private struct TrayImage: View {
    let row: AssetRecord
    let size: CGSize
    let module: TrayModule
    @Environment(\.displayScale) private var scale
    @ViewState private var pixels: CGImage?
    private var maxPixels: Int { max(1, Int(ceil(max(size.width, size.height) * scale))) }
    var body: some View {
        Group {
            if let pixels { Image(decorative: pixels, scale: scale).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .task(id: maxPixels) { module.thumbnail(row, pixels: maxPixels) { pixels = $0 } }
        .accessibilityHidden(true)
    }
}

/// Freeze both the screenshot and the draft on mouse-down. Reflow can never make mouse-up
/// append the replacement under the pointer. The upstream gate is shared by all cells.
private struct ThumbnailHit: NSViewRepresentable {
    let row: AssetRecord
    let module: TrayModule
    let arrivalID: UUID?
    let left: Bool
    func makeNSView(context: Context) -> HitView { HitView() }
    func updateNSView(_ view: HitView, context: Context) {
        if view.row?.id != row.id || view.row?.visibilityRevision != row.visibilityRevision { view.abort() }
        view.module = module; view.row = row
        if arrivalID == row.id {
            module.thumbnail(row, pixels: 256) { [weak view] image in
                guard let view, view.row?.id == row.id, let image else { return }
                DispatchQueue.main.async { module.presentArrival(row, view: view, left: left, image: image) }
            }
        }
        view.setAccessibilityElement(true)
        if module.localOnly {
            view.setAccessibilityRole(.image)
            view.setAccessibilityLabel("截图 " + String(row.sequence))
            view.toolTip = "已存入托盘。当前仅支持在专用测试草稿中附加。"
            return
        }
        view.setAccessibilityRole(.button)
        let action = row.status == .failed ? "重试附加" : row.status == .unknown ? "核对原操作" : "附加到草稿"
        view.setAccessibilityLabel(action + "，截图 " + String(row.sequence))
        view.toolTip = action
    }
    static func dismantleNSView(_ view: HitView, coordinator: ()) { view.abort() }

    final class HitView: NSView {
        weak var module: TrayModule?
        var row: AssetRecord?
        var held: TrayPress?
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let row, let module, !module.localOnly, let window,
                  module.pointer.begin(assetID: row.id, screenPoint: window.convertPoint(toScreen: event.locationInWindow),
                    timestamp: event.timestamp, clickCount: event.clickCount, doubleClickInterval: NSEvent.doubleClickInterval,
                    acceptsSelection: true) else { return }
            held = module.beginPress(row)
            if held == nil { module.pointer.cancel() }
        }
        override func mouseUp(with event: NSEvent) {
            guard let module, let press = held else { return }
            held = nil
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            guard module.pointer.end(inside: inside) == press.id, row?.id == press.id else { press.target.cancel(); return }
            Task { await module.finishPress(press) }
        }
        func abort() {
            if let held { held.target.cancel(); module?.pointer.cancel() }
            held = nil
        }
        override func accessibilityPerformPress() -> Bool {
            guard let module, let row, let press = module.beginPress(row) else { return false }
            Task { await module.finishPress(press) }; return true
        }
    }
}
