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
        guard let lifetime = feed?.lifetime(of: member.key) else { return NSItemProvider() }
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

struct NativeSpaceNavigator: View {
    let catalog: NativeSpaceCatalog
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows?
    let badges: [String: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let canSwitch, canMove: Bool
    let select: (NativeSidebarDestination, NativeSidebarMember?) -> Void
    let move: (NativeSidebarMember, NativeSidebarDestination, UUID) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(catalog.rows.enumerated()), id: \.element.id) { index, row in
                let destination = NativeSidebarDestination(row, in: catalog)
                let title = row.record.fullscreenUUID == nil ? "桌面 \(index + 1)" : "全屏"
                ZStack(alignment: .topLeading) {
                    Button {
                        if let destination { select(destination, nil) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                if row.record.isCurrent { Image(systemName: "circle.fill").font(.system(size: 5)) }
                                Text(title).font(.caption.weight(.medium))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(destination == nil || !canSwitch)
                    .accessibilityAddTraits(row.record.isCurrent ? .isSelected : [])
                    .accessibilityLabel(title + (row.record.isCurrent ? "，当前桌面" : ""))
                    .accessibilityIdentifier("native-space-row:\(catalog.display.id):\(row.id)")

                    GeometryReader { proxy in
                        let screen = catalog.display.frame
                        let scale = min(proxy.size.width / screen.width, proxy.size.height / screen.height)
                        let dx = (proxy.size.width - screen.width * scale) / 2
                        let dy = (proxy.size.height - screen.height * scale) / 2
                        ZStack(alignment: .topLeading) {
                            if row.windows.isEmpty {
                                Text(row.membershipComplete ? "空桌面" : "窗口归属尚未读全")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                            }
                            ForEach(row.windows.reversed()) { window in
                                if let dest = destination, let member = NativeSidebarMember(window, source: dest),
                                   let clipped = window.bounds.geometry.intersection(
                                    SurfaceRect(x: 0, y: 0, width: screen.width, height: screen.height).geometry) {
                                    miniature(member, name: badges[window.id]?.name ?? "窗口", icon: badges[window.id]?.icon,
                                              width: clipped.width * scale, height: clipped.height * scale)
                                        .offset(x: dx + clipped.x * scale, y: dy + clipped.y * scale)
                                }
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                    .padding(.top, 22).padding(.horizontal, 4).padding(.bottom, 4)
                }
                .frame(maxWidth: .infinity).aspectRatio(1.9, contentMode: .fit)
                .background(.primary.opacity(row.record.isCurrent ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(row.record.isCurrent ? 0.4 : 0.16)).allowsHitTesting(false) }
                .contextMenu {
                    if let destination {
                        ForEach(row.windows) { w in
                            if let m = NativeSidebarMember(w, source: destination) {
                                let sameApp = row.windows.filter { $0.metadata?.pid == m.key.pid }
                                let ordinal = sameApp.firstIndex(of: w).map { " · \($0 + 1)" } ?? ""
                                Button((badges[w.id]?.name ?? "窗口") + (sameApp.count > 1 ? ordinal : "")) {
                                    select(destination, m)
                                }
                            }
                        }
                    }
                }
                .onDrop(of: [NativeSidebarDrag.type], isTargeted: nil) { items in
                    guard canMove, let destination else { return false }
                    return drag.receive(items) { move($0, destination, $1) }
                }
            }
        }
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
        .modifier(NativeWindowDragSource(member: canMove ? member : nil, drag: drag, feed: feed))
    }
}
