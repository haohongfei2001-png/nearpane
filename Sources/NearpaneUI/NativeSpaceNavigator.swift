import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NearpaneCore

/// Drag data stays inside this process. The item carries a one-use gesture ID,
/// never a serialised action or authority to control an arbitrary window.
@MainActor final class NativeSidebarDrag {
    static let type = UTType(exportedAs: "com.holdsnow.nearpane.space-window")
    private var gesture: (UUID, NativeSidebarMember, UUID, ContinuousClock.Instant)?

    func begin(_ member: NativeSidebarMember, feed: CurrentDesktopWindows?) -> NSItemProvider {
        guard member.source.kind == .ordinary, let lifetime = feed?.lifetime(of: member.key) else { return NSItemProvider() }
        let token = UUID()
        gesture = (token, member, lifetime, .now.advanced(by: .seconds(20)))
        let item = NSItemProvider()
        let data = Data(token.uuidString.utf8)
        item.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return item
    }

    func receive(_ items: [NSItemProvider], action: @escaping @MainActor (NativeSidebarMember, UUID) -> Void) -> Bool {
        guard let gesture, gesture.3 >= .now, items.count == 1, let item = items.first,
              item.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        item.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, _ in
            guard let data, data == Data(gesture.0.uuidString.utf8) else { return }
            Task { @MainActor in
                guard let self, self.gesture?.0 == gesture.0, gesture.3 >= .now else { return }
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
        if let member { content.onDrag { drag.begin(member, feed: feed) } } else { content }
    }
}

/// The current window list is also a return drop target, without a second picture of the current Space.
struct CurrentSpaceRegion: ViewModifier {
    let destination: NativeSidebarDestination?
    let canMove: Bool
    let drag: NativeSidebarDrag
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let destination {
            content.accessibilityElement(children: .contain)
                .accessibilityLabel("当前桌面").accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("native-space-row:\(destination.display):\(destination.space)")
                .onDrop(of: [NativeSidebarDrag.type], isTargeted: nil) { items in
                    guard canMove, destination.kind == .ordinary else { return false }
                    return drag.receive(items) { move($0, destination, $1) }
                }
        } else { content }
    }
}

struct NativeSpaceNavigator: View {
    let catalog: NativeSpaceCatalog
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows?
    let badges: [String: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let canSwitch, canMove: Bool
    let workArea: SurfaceRect?
    let select: (NativeSidebarDestination, NativeSidebarMember?) -> Void
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void
    struct WindowGroup {
        let id: UUID
        let windows: [WindowObservation]
        let dissolve: () -> Void
    }
    var group: WindowGroup? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(catalog.rows.enumerated().filter { $0.element.record.isCurrent == (group != nil) }), id: \.element.id) { index, row in
                let destination = NativeSidebarDestination(row, in: catalog)
                let display = catalog.display
                let canvas = row.record.fullscreenUUID == nil ? workArea : SurfaceRect(width: display.frame.width, height: display.frame.height)
                let windows = group.map { $0.windows.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) } } ?? row.windows
                let unplaced = windows.filter { projectedFrame($0, canvas: canvas) == nil }
                let title = group != nil ? "窗口组合" : row.record.fullscreenUUID == nil ? "桌面 \(index + 1)" : "全屏"
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Button {
                            if let destination { select(destination, nil) }
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(destination == nil || (!canSwitch && !row.record.isCurrent))
                        .accessibilityLabel(title)
                        .accessibilityIdentifier(group.map { "native-window-group:\($0.id)" } ?? "native-space-row:\(catalog.display.id):\(row.id)")

                        GeometryReader { proxy in
                            let scale = canvas.map { min(proxy.size.width / $0.width, proxy.size.height / $0.height) } ?? 0
                            let dx = (proxy.size.width - (canvas?.width ?? 0) * scale) / 2
                            let dy = (proxy.size.height - (canvas?.height ?? 0) * scale) / 2
                            ZStack(alignment: .topLeading) {
                                if windows.isEmpty {
                                    Text(row.regularWindowListComplete ? "未发现普通窗口" : "窗口归属尚未读全")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                                }
                                ForEach(windows.reversed()) { window in
                                    if let canvas, let frame = projectedFrame(window, canvas: canvas),
                                       let dest = destination, let member = NativeSidebarMember(window, source: dest) {
                                        miniature(member, name: badges[window.id]?.name ?? "窗口", icon: badges[window.id]?.icon,
                                                  width: frame.width * scale, height: frame.height * scale)
                                            .offset(x: dx + (frame.x - canvas.x) * scale, y: dy + (frame.y - canvas.y) * scale)
                                    }
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        }
                        .clipped()
                        if let destination, !unplaced.isEmpty {
                            // An unlocated window is still selectable from its own identity.
                            // The menu stays outside the scaled desktop geometry.
                            HStack {
                                Spacer()
                                Menu {
                                    ForEach(unplaced) { window in
                                        if let member = NativeSidebarMember(window, source: destination) {
                                            Button(badges[window.id]?.name ?? "窗口") { select(destination, member) }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "macwindow.on.rectangle").font(.caption2)
                                }
                                .menuStyle(.borderlessButton).fixedSize().padding(3)
                                .disabled(!canSwitch && destination.space != catalog.current.id)
                                .accessibilityLabel("另有 " + String(unplaced.count) + " 扇窗口的位置尚未确认")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).aspectRatio(canvas.map { $0.width / $0.height } ?? 1.9, contentMode: .fit)
                    .background(.primary.opacity(row.record.isCurrent ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(row.record.isCurrent ? 0.4 : 0.16)).allowsHitTesting(false) }
                    HStack(spacing: 3) {
                        ForEach(Array(appIcons(for: windows).prefix(4).enumerated()), id: \.offset) { _, badge in
                            Image(nsImage: badge.icon).resizable().scaledToFit().frame(width: 12, height: 12)
                        }
                        Text(title).font(.caption2).lineLimit(1)
                    }.frame(height: 18).accessibilityHidden(true)
                }
                .contextMenu {
                    if let group { Button("解散窗口组合", action: group.dissolve) }
                    if let destination {
                        ForEach(windows) { w in
                            if let m = NativeSidebarMember(w, source: destination) {
                                let sameApp = windows.filter { $0.metadata?.pid == m.key.pid }
                                let ordinal = sameApp.firstIndex(of: w).map { " · \($0 + 1)" } ?? ""
                                Button((badges[w.id]?.name ?? "窗口") + (sameApp.count > 1 ? ordinal : "")) {
                                    select(destination, m)
                                }
                                .disabled(!canSwitch && destination.space != catalog.current.id)
                            }
                        }
                    }
                }
                .onDrop(of: [NativeSidebarDrag.type], isTargeted: nil) { items in
                    guard canMove, let destination, destination.kind == .ordinary else { return false }
                    return drag.receive(items) { move($0, destination, $1) }
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
            frame = .init(x: logical.x - catalog.display.frame.x, y: logical.y - catalog.display.frame.y,
                          width: logical.width, height: logical.height)
        } else {
            guard meta.hasCatalogGeometry == true else { return nil }
            frame = window.bounds
        }
        return frame.geometry.intersection(canvas.geometry) == nil ? nil : frame
    }

    private func miniature(_ member: NativeSidebarMember, name: String, icon: NSImage?,
                           width: CGFloat, height: CGFloat) -> some View {
        let dest = member.source
        let history = gallery?.imageForMap(key: member.key, display: dest.display, space: dest.space,
            session: dest.session, topology: dest.topology, permitted: permitted)
        return Button { select(dest, member) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(DesktopWindowCard.windowBacking(for: scheme))
                if let history {
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
        .disabled(dest.space != catalog.current.id && !canSwitch)
        .help(name + (history == nil ? "" : " · 最近画面"))
        .accessibilityLabel(name + (history == nil ? "" : "，最近画面"))
        .accessibilityIdentifier("native-space-window:\(dest.display):\(dest.space):\(member.key.pid):\(member.key.number)")
        .modifier(NativeWindowDragSource(member: canMove && dest.kind == .ordinary ? member : nil, drag: drag, feed: feed))
    }
}
