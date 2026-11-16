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
    @Environment(\.colorScheme) private var colorScheme
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
                    VStack(spacing:layout.rowGap) {
                        ScrollView(.vertical) {
                            LazyVGrid(columns:[GridItem(.fixed(cell.width),spacing:layout.columnGap),GridItem(.fixed(cell.width))],spacing:layout.rowGap) {
                                ForEach(module.rows) { row in
                                    thumbnail(row, cell: cell)
                                }
                                if module.captureEntry && !module.expanded {
                                    Button { module.toggleMenu() } label: {
                                        Image(systemName: "camera").matchedGeometryEffect(id: "systemCamera", in: morph)
                                            .fontWeight(.medium)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }.frame(width: cell.width, height: cell.height)
                                    .buttonStyle(TrayCaptureStyle()).accessibilityLabel("展开截图方式")
                                }
                            }
                            .padding(.top, layout.cells.first?.frame.minY ?? 0)
                        }
                        .frame(height: layout.imageViewport)
                        .onScrollPhaseChange { _, phase in if phase != .idle { module.cancelArrival() } }
                        if layout.menu != nil {
                            HStack(spacing: 0) {
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
                            .buttonStyle(TrayCaptureStyle(radius: 6)).frame(height:layout.menu?.height)
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

    private func thumbnail(_ row: AssetRecord, cell: CGSize) -> some View {
        let size = TrayLayout.fitted(pixels: .init(width: row.image.pixelWidth, height: row.image.pixelHeight),
                                     cell: .init(width: max(0, cell.width - 2), height: max(0, cell.height - 2)))
        let leaving = module.swallowing.contains(row.id)
        return ZStack {
            // Decoration belongs to the fixed cell, not the image or its input region.
            // Keep every source pixel fitted and the existing mouse-down binding intact.
            TrayTileBackground(radius: 7)
                .allowsHitTesting(false).accessibilityHidden(true)
            TrayImage(row: row, size: size, module: module)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 1.5, y: 1)
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
                .offset(x: leaving && !reducedMotion ? (left ? -56 : 56) : 0)
                .opacity(leaving ? 0 : 1)
                .animation(reducedMotion ? nil : .easeIn(duration: 0.12), value: leaving)
        }.frame(width: cell.width, height: cell.height).clipped()
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

/// A passive backing for the reference's fixed, rounded thumbnail cells. It never
/// clips image pixels, changes Fit geometry, or participates in attachment input.
private struct TrayTileBackground: View {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var scale

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    var body: some View {
        shape.fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(colorScheme == .dark ? 0.06 : 0.24))
            .overlay {
                shape.fill(LinearGradient(colors: [
                    Color.indigo.opacity(0.025),
                    Color.purple.opacity(0.055)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.55) : Color.white.opacity(colorScheme == .dark ? 0.25 : 0.6),
                                   lineWidth: contrast == .increased ? 1 : 1 / max(1, scale))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.055), radius: 1.5, y: 1)
    }
}

private struct TrayCaptureStyle: ButtonStyle {
    var radius: CGFloat = 7
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.displayScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        let face = dark ? Color(red: 0.32, green: 0.30, blue: 0.46) : Color(red: 0.918, green: 0.909, blue: 1)
        let foot = dark ? Color(red: 0.28, green: 0.25, blue: 0.43) : Color(red: 0.820, green: 0.761, blue: 1)
        let ink = dark ? Color(red: 0.83, green: 0.78, blue: 1) : Color(red: 0.600, green: 0.477, blue: 0.980)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .foregroundStyle(contrast == .increased ? Color.primary : ink)
            .background {
                // Riftlet's camera key has a raised face and a short contact edge.
                // Keep the full key as the button's hit area in both menu states.
                GeometryReader { proxy in
                    let depth = configuration.isPressed ? 0 : min(proxy.size.height * 0.08, 3)
                    shape.fill(foot.opacity(opaque ? 1 : 0.80))
                    shape.fill(face.opacity(opaque || contrast == .increased ? 1 : dark ? 0.78 : 0.94))
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
