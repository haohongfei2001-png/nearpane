import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NearpaneCore

private typealias ViewState<T> = State<T>

/// Drag data stays inside this process. The item carries a one-use gesture ID,
/// never a serialised action or authority to control an arbitrary window.
@MainActor final class NativeSidebarDrag {
    static let type = UTType(exportedAs: "com.holdsnow.nearpane.space-window")
    private let navigation: NativeSidebarNavigation
    init(navigation: NativeSidebarNavigation = .shared) { self.navigation = navigation }
    private var gesture: (UUID, NativeSidebarMember, UUID, ContinuousClock.Instant, UUID)?

    var pendingMember: NativeSidebarMember? {
        guard let gesture, navigation.dispatchAvailable, navigation.ownershipEpoch == gesture.4, gesture.3 >= .now else { return nil }
        return gesture.1
    }

    func begin(_ member: NativeSidebarMember, feed: CurrentDesktopWindows?) -> NSItemProvider {
        guard navigation.dispatchAvailable, !member.selectionOnly, member.source.kind == .ordinary, let lifetime = feed?.lifetime(of: member.key) else { return NSItemProvider() }
        let token = UUID()
        gesture = (token, member, lifetime, .now.advanced(by: .seconds(20)), navigation.ownershipEpoch)
        let item = NSItemProvider()
        let data = Data(token.uuidString.utf8)
        item.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return item
    }

    func receive(_ items: [NSItemProvider], accepts: (NativeSidebarMember) -> Bool = { _ in true }, action: @escaping @MainActor (NativeSidebarMember, UUID) -> Void) -> Bool {
        guard let gesture, navigation.dispatchAvailable, navigation.ownershipEpoch == gesture.4, gesture.3 >= .now, accepts(gesture.1), items.count == 1, let item = items.first,
              item.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        let input = NativeSelectionPermit.inputCounters()
        item.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, _ in
            guard let data, data == Data(gesture.0.uuidString.utf8) else { return }
            Task { @MainActor in
                guard let self, self.gesture?.0 == gesture.0, self.navigation.dispatchAvailable, self.navigation.ownershipEpoch == gesture.4,
                      gesture.3 >= .now, NativeSelectionPermit.inputCounters() == input else { return }
                self.gesture = nil
                action(gesture.1, gesture.2)
            }
        }
        return true
    }
}

struct NativeWindowDragSource: ViewModifier {
    let member: NativeSidebarMember?
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows?
    @ViewBuilder func body(content: Content) -> some View {
        if let member, !member.selectionOnly { content.onDrag { drag.begin(member, feed: feed) } } else { content }
    }
}

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
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows?
    let canMove: Bool
    let select: () -> Void
    let place: (SidebarPairDrop) -> Void
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void

    @ViewState private var highlightedSide: Bool?

    @ViewBuilder func body(content: Content) -> some View {
        if let member, let lifetime, let feed, member.source.kind == .ordinary {
            if !canMove {
                content
                    .background(SidebarCardPointer(member: member, lifetime: lifetime,
                        current: { feed.lifetime(of: member.key) == lifetime }, select: select, place: place,
                        highlight: { highlightedSide = $0 }).accessibilityHidden(true))
                    .overlay(alignment: highlightedSide == true ? .leading : .trailing) { indicator }
                    .accessibilityHint(member.selectionOnly ? "将这扇窗口切换到前台" : "拖到另一扇窗口预览的左半或右半可在本屏分屏")
            } else if !member.selectionOnly {
                content.modifier(NativeWindowDragSource(member: member, drag: drag, feed: feed))
                    .overlay(alignment: highlightedSide == true ? .leading : .trailing) { indicator }
                .onDrop(of: [NativeSidebarDrag.type], delegate: CardDrop(member: member, width: width,
                    drag: drag, highlighted: $highlightedSide, accepts: { source in
                        feed.lifetime(of: member.key) == lifetime && source.key != member.key &&
                            (source.source == member.source || canMove)
                    }, perform: { source, birth, left in
                        guard feed.lifetime(of: member.key) == lifetime else { return }
                        if source.source == member.source {
                            place(.init(dragged: source, target: member, draggedLifetime: birth,
                                        targetLifetime: lifetime, draggedOnLeft: left))
                        } else if canMove { move(source, member.source, birth) }
                    }))
                .accessibilityHint("拖到另一扇窗口预览的左半或右半可在本屏分屏")
            } else { content }
        } else { content }
    }

    @ViewBuilder private var indicator: some View {
        if highlightedSide != nil {
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                .frame(width: width / 2).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @MainActor private struct CardDrop: DropDelegate {
        let member: NativeSidebarMember, width: CGFloat, drag: NativeSidebarDrag
        @Binding var highlighted: Bool?
        let accepts: (NativeSidebarMember) -> Bool
        let perform: (NativeSidebarMember, UUID, Bool) -> Void

        func validateDrop(info: DropInfo) -> Bool { drag.pendingMember.map(accepts) == true }
        func dropEntered(info: DropInfo) { update(info) }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            update(info)
            return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
        }
        private func update(_ info: DropInfo) {
            let side = drag.pendingMember?.source == member.source && validateDrop(info: info)
                ? SidebarPairDrop.left(at: info.location.x, width: width) : nil
            if highlighted != side { highlighted = side }
        }
        func dropExited(info: DropInfo) { highlighted = nil }
        func performDrop(info: DropInfo) -> Bool {
            highlighted = nil
            guard let left = SidebarPairDrop.left(at: info.location.x, width: width) else { return false }
            return drag.receive(info.itemProviders(for: [NativeSidebarDrag.type]), accepts: accepts) { perform($0, $1, left) }
        }
    }
}

/// A list of actual windows also accepts a drop into their verified ordinary Space.
struct NativeWindowDropTarget: ViewModifier {
    let destination: NativeSidebarDestination?
    let canMove: Bool
    let drag: NativeSidebarDrag
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if canMove, let destination, destination.kind == .ordinary {
            content.onDrop(of: [NativeSidebarDrag.type], isTargeted: nil) { items in
                drag.receive(items, accepts: { $0.source != destination }) { move($0, destination, $1) }
            }
        } else { content }
    }
}

/// Only an explicit multiwindow group uses a desktop-shaped canvas.
struct NativeWindowGroupCard: View {
    let destination: NativeSidebarDestination
    let display: DisplayObservation
    let isCurrent: Bool
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows
    let badges: [String: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let canSwitch, canMove: Bool
    let workArea: SurfaceRect?
    let select: (NativeSidebarMember?) -> Void
    let id: UUID
    let windows: [WindowObservation]
    let snapshot: DesktopSnapshot
    let place: (SidebarPairDrop) -> Void
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void
    let dissolve: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ordered = windows.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
        let canvas = workArea
        let unplaced = ordered.filter { projectedFrame($0, canvas: canvas) == nil }
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Button { select(nil) } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!isCurrent && !canSwitch)
                .accessibilityLabel("窗口组合")
                .accessibilityIdentifier("native-window-group:\(id)")

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
                        .disabled(!isCurrent && !canSwitch)
                        .accessibilityLabel("另有 " + String(unplaced.count) + " 扇窗口的位置尚未确认")
                    }
                }
            }
            .frame(maxWidth: .infinity).aspectRatio(canvas.map { $0.width / $0.height } ?? 1.9, contentMode: .fit)
            .background(.primary.opacity(isCurrent ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(isCurrent ? 0.4 : 0.16)).allowsHitTesting(false) }
            HStack(spacing: 3) {
                ForEach(Array(appIcons(for: ordered).prefix(4).enumerated()), id: \.offset) { _, badge in
                    Image(nsImage: badge.icon).resizable().scaledToFit().frame(width: 12, height: 12)
                }
                Text("窗口组合").font(.caption2).lineLimit(1)
            }.frame(height: 18).accessibilityHidden(true)
        }
        .contextMenu {
            Button("解散窗口组合", action: dissolve)
            ForEach(ordered) { window in
                if let member = NativeSidebarMember(window, source: destination) {
                    let siblings = ordered.filter { $0.metadata?.pid == member.key.pid }
                    let index = siblings.firstIndex(of: window).map { " · \($0 + 1)" } ?? ""
                    Button((badges[window.id]?.name ?? "窗口") + (siblings.count > 1 ? index : "")) { select(member) }
                        .disabled(!isCurrent && !canSwitch)
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
        let target = isCurrent ? DesktopWindowTarget.preview(window, in: snapshot) : nil
        let history = isCurrent ? nil : gallery?.imageForMap(key: member.key, display: dest.display, space: dest.space,
            session: dest.session, topology: dest.topology, permitted: permitted)
        return Button { select(member) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(DesktopWindowCard.windowBacking(for: scheme))
                if let target {
                    WindowPanePicture(gallery: gallery, target: target, permitted: permitted)
                } else if let history {
                    Image(decorative: history, scale: 1).resizable().scaledToFit()
                } else if let icon, min(width, height) > 11 {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: min(16, width), height: min(16, height))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.45), lineWidth: 0.8) }
            .frame(width: width, height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCurrent && !canSwitch)
        .modifier(GalleryCardExposure(gallery: gallery, target: target))
        .help(name + (history == nil ? "" : " · 最近画面"))
        .accessibilityLabel(name + (history == nil ? "" : "，最近画面"))
        .accessibilityIdentifier("native-space-window:\(dest.display):\(dest.space):\(member.key.pid):\(member.key.number)")
        .modifier(SidebarWindowDragAndDrop(member: isCurrent || canMove ? member : nil, lifetime: feed.lifetime(of: member.key),
            width: width, drag: drag, feed: feed, canMove: canMove, select: { select(member) }, place: place, move: move))
    }
}
