import AppKit
import SwiftUI
import RiftletCore
import NearpaneCore

private typealias ViewState<T> = State<T>

public struct TraySurface: View {
    let module: TrayModule
    let left: Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Namespace private var morph
    let settings: DisplaySettings
    public init(_ module: TrayModule, left: Bool, settings: DisplaySettings = .init()) {
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
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }.frame(width: cell.width, height: cell.height)
                                    .buttonStyle(.plain).accessibilityLabel("展开截图方式")
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
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }
                                    .accessibilityLabel(action.label).help(action.label)
                                }
                            }
                            .buttonStyle(.plain).frame(height:layout.menu?.height)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
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
        .font(settings.measures[.trayButtonSize].map { .system(size:$0.points(in:outer.size.height)) } ?? .body)
        .padding(settings.points(.trayPadding,in:outer.size.width))
        .background(.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius:settings.measures[.cornerRadius]?.points(in:outer.size.width) ?? 8))
        .overlay(alignment: .bottomLeading) {
            if let issue = module.issue {
                Text(issue).font(.caption2).lineLimit(2).help(issue)
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
            TrayImage(row: row, size: size, module: module)
                .opacity(module.flyingID == row.id ? 0 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if let symbol = statusSymbol(row.status) {
                        Image(systemName: symbol).font(.caption2).padding(2).background(.regularMaterial, in: Circle())
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
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
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
            guard let row, let module, let window,
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
