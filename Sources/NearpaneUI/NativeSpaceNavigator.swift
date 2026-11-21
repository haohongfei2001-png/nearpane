import AppKit
import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

/// Both the drag and its destination bind to the original card lifetimes. The drop point
/// is local to the destination card, including its caption and transparent hit area.
struct SidebarPairDrop {
    let dragged, target: NativeSidebarMember
    let draggedLifetime, targetLifetime: UUID
    let draggedOnLeft: Bool

    static func left(at x: CGFloat, width: CGFloat) -> Bool? {
        guard width.isFinite, width > 0, x.isFinite, x >= 0, x <= width else { return nil }
        return x < width / 2
    }
}

struct SidebarWindowDragAndDrop: ViewModifier {
    let member: NativeSidebarMember?
    let lifetime: UUID?
    let width: CGFloat
    let feed: CurrentDesktopWindows?
    let select: () -> Void
    let place: (SidebarPairDrop) -> Void
    var prepare: () -> Void = {}

    @ViewState private var highlightedSide: Bool?

    @ViewBuilder func body(content: Content) -> some View {
        if let member, let lifetime, let feed, member.source.kind == .ordinary {
            content
                .background(SidebarCardPointer(member: member, lifetime: lifetime,
                    current: { feed.lifetime(of: member.key) == lifetime }, select: select, place: place,
                    highlight: { highlightedSide = $0 }, prepare: prepare).accessibilityHidden(true))
                .overlay(alignment: highlightedSide == true ? .leading : .trailing) { indicator }
                .accessibilityHint(member.selectionOnly ? "将这扇窗口切换到前台" : "拖到另一扇窗口预览的左半或右半可在本屏分屏")
        } else { content }
    }

    @ViewBuilder private var indicator: some View {
        if highlightedSide != nil {
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                .frame(width: width / 2).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

}

/// Only an explicit multiwindow group uses a desktop-shaped canvas.
struct NativeWindowGroupCard: View {
    let destination: NativeSidebarDestination
    let display: DisplayObservation
    let feed: CurrentDesktopWindows
    let badges: [String: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let workArea: SurfaceRect?
    let select: (NativeSidebarMember) -> Void
    let id: UUID
    let windows: [WindowObservation]
    let snapshot: DesktopSnapshot
    let place: (SidebarPairDrop) -> Void
    let remove: (NativeSidebarMember) -> Void
    let dissolve: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ordered = windows.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
        let canvas = workArea
        let unplaced = ordered.filter { projectedFrame($0, canvas: canvas) == nil }
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                GeometryReader { proxy in
                    let scale = canvas.map { min(proxy.size.width / $0.width, proxy.size.height / $0.height) } ?? 0
                    let dx = (proxy.size.width - (canvas?.width ?? 0) * scale) / 2
                    let dy = (proxy.size.height - (canvas?.height ?? 0) * scale) / 2
                    ZStack(alignment: .topLeading) {
                        ForEach(DesktopWindowRow.rows(ordered).reversed()) { row in
                            let window = row.window
                            if let canvas, let frame = projectedFrame(window, canvas: canvas),
                               let member = NativeSidebarMember(window, source: destination) {
                                miniature(member, window: window, name: badges[window.id]?.name ?? "窗口", icon: badges[window.id]?.icon,
                                          width: frame.width * scale, height: frame.height * scale)
                                    .offset(x: dx + (frame.x - canvas.x) * scale, y: dy + (frame.y - canvas.y) * scale)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .clipped()
                if !unplaced.isEmpty {
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(unplaced) { window in
                                if let member = NativeSidebarMember(window, source: destination) {
                                    Button(badges[window.id]?.name ?? "窗口") { select(member) }
                                }
                            }
                        } label: {
                            Image(systemName: "macwindow.on.rectangle").font(.caption2)
                        }
                        .menuStyle(.borderlessButton).fixedSize().padding(3)
                        .accessibilityLabel("另有 " + String(unplaced.count) + " 扇窗口的位置尚未确认")
                    }
                }
            }
            .frame(maxWidth: .infinity).aspectRatio(canvas.map { $0.width / $0.height } ?? 1.9, contentMode: .fit)
            .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.4)).allowsHitTesting(false) }
            HStack(spacing: 3) {
                ForEach(Array(appIcons(for: ordered).prefix(4).enumerated()), id: \.offset) { _, badge in
                    Image(nsImage: badge.icon).resizable().scaledToFit().frame(width: 12, height: 12)
                }
                Text("窗口组合").font(.caption2).lineLimit(1)
            }.frame(height: 18).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口组合")
        .accessibilityIdentifier("native-window-group:\(id)")
        .contextMenu {
            Button("解散窗口组合", action: dissolve)
            ForEach(ordered) { window in
                if let member = NativeSidebarMember(window, source: destination) {
                    let siblings = ordered.filter { $0.metadata?.pid == member.key.pid }
                    let index = siblings.firstIndex(of: window).map { " · \($0 + 1)" } ?? ""
                    Button((badges[window.id]?.name ?? "窗口") + (siblings.count > 1 ? index : "")) { select(member) }
                }
            }
        }
    }

    private func appIcons(for windows: [WindowObservation]) -> [WindowAppBadges.Badge] {
        var seen = Set<Int32>()
        return windows.compactMap { window in
            guard let pid = window.metadata?.pid, seen.insert(pid).inserted else { return nil }
            return badges[window.id]
        }
    }

    private func projectedFrame(_ window: WindowObservation, canvas: SurfaceRect?) -> SurfaceRect? {
        guard let canvas, let meta = window.metadata else { return nil }
        let frame: SurfaceRect
        if let logical = meta.catalogLogicalFrame {
            frame = .init(x: logical.x - display.frame.x, y: logical.y - display.frame.y,
                          width: logical.width, height: logical.height)
        } else {
            guard meta.hasCatalogGeometry == true else { return nil }
            frame = window.bounds
        }
        return frame.geometry.intersection(canvas.geometry) == nil ? nil : frame
    }

    private func miniature(_ member: NativeSidebarMember, window: WindowObservation, name: String, icon: NSImage?,
                           width: CGFloat, height: CGFloat) -> some View {
        let dest = member.source
        let target = DesktopWindowTarget.preview(window, in: snapshot)
        return Button { select(member) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(DesktopWindowCard.windowBacking(for: scheme))
                if let target {
                    WindowPanePicture(gallery: gallery, target: target, permitted: permitted)
                } else if let icon, min(width, height) > 11 {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: min(16, width), height: min(16, height))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.45), lineWidth: 0.8) }
            .frame(width: width, height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { Button("从组合中移出") { remove(member) } }
        .modifier(GalleryCardExposure(gallery: gallery, target: target))
        .help(name)
        .accessibilityLabel(name)
        .accessibilityIdentifier("native-space-window:\(dest.display):\(dest.space):\(member.key.pid):\(member.key.number)")
        .modifier(SidebarWindowDragAndDrop(member: member, lifetime: feed.lifetime(of: member.key),
            width: width, feed: feed, select: { select(member) }, place: place))
    }
}
