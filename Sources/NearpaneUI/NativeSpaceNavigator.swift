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
    var stack: SidebarCardPointer.StackPosition?
    var detach: (() -> Void)?

    @ViewState private var highlightedSide: Bool?

    @ViewBuilder func body(content: Content) -> some View {
        if let member, let lifetime, let feed, member.source.kind == .ordinary {
            content
                .background(SidebarCardPointer(member: member, lifetime: lifetime,
                    current: {
                        if let stack { return feed.stillGroups(member, in: stack.group, appearance: lifetime) }
                        return feed.lifetime(of: member.key) == lifetime
                    }, select: select, place: place,
                    highlight: { highlightedSide = $0 }, prepare: prepare, stack: stack, detach: detach).accessibilityHidden(true))
                .overlay(alignment: highlightedSide == true ? .leading : .trailing) { indicator }
                .accessibilityHint(member.selectionOnly ? "将这扇窗口切换到前台" : detach == nil ?
                    "拖到另一扇窗口预览的左半或右半可在本屏分屏" : "拖到另一扇预览可分屏，拖出侧栏到本屏工作区可独立成组")
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
enum StageSidebarSelection {
    case group, member

    func withoutEngine(focusMember: () -> Void) throws {
        guard self == .member else { throw StageSwitchError.unavailable }
        focusMember()
    }
}

struct StageGroupMemberChoice: Identifiable {
    let window: WindowObservation
    let member: NativeSidebarMember
    let lifetime: UUID
    let label: String
    var id: DesktopWindowKey { member.key }

    /// Number siblings in sidebar order, independently of which miniature is drawn in front.
    static func rows(_ windows: [WindowObservation], source: NativeSidebarDestination,
                     lifetime: (DesktopWindowKey) -> UUID?, name: (WindowObservation) -> String) -> [Self] {
        let rows = DesktopWindowRow.rows(windows)
        let siblings = Dictionary(grouping: rows, by: { $0.id.pid })
        return rows.compactMap { row in
            guard let appearance = lifetime(row.id), let member = NativeSidebarMember(row.window, source: source),
                  let family = siblings[row.id.pid], let index = family.firstIndex(where: { $0.id == row.id }) else { return nil }
            let suffix = family.count > 1 ? " · \(index + 1)" : ""
            return Self(window: row.window, member: member, lifetime: appearance, label: name(row.window) + suffix)
        }
    }
}

/// The clickable viewport is the visible intersection; the picture keeps its
/// original dimensions and is cropped inside that viewport.
struct StageGroupMiniatureFrame: Equatable {
    let original: SurfaceRect
    let visible: SurfaceRect

    init?(original: SurfaceRect, canvas: SurfaceRect) {
        guard let intersection = original.geometry.intersection(canvas.geometry) else { return nil }
        self.original = original
        self.visible = SurfaceRect(intersection)
    }

    var pictureInVisibleFrame: SurfaceRect {
        SurfaceRect(x: original.x - visible.x, y: original.y - visible.y,
                    width: original.width, height: original.height)
    }
}

struct NativeWindowGroupCard: View {
    let destination: NativeSidebarDestination
    let display: DisplayObservation
    let feed: CurrentDesktopWindows
    let badges: [String: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let workArea: SurfaceRect?
    let select: (NativeSidebarMember, UUID) -> Void
    let selectGroup: (() -> Void)?
    let id: UUID
    let name: String?
    let windows: [WindowObservation]
    let snapshot: DesktopSnapshot
    let place: (SidebarPairDrop) -> Void
    let remove: (NativeSidebarMember) -> Void
    let rename: () -> Void
    let dissolve: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ordered = windows.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
        let canvas = workArea
        let choices = StageGroupMemberChoice.rows(windows, source: destination, lifetime: feed.lifetime(of:),
                                                  name: { badges[$0.id]?.name ?? "窗口" })
        let byKey = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
        let unplaced = choices.filter { projectedFrame($0.window, canvas: canvas) == nil }
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let selectGroup {
                    Button(action: selectGroup) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name.map { "切换到窗口组合 " + $0 } ?? "切换到此窗口组合")
                        .accessibilityIdentifier("stage-group-select:" + id.uuidString)
                }
                GeometryReader { proxy in
                    let scale = canvas.map { min(proxy.size.width / $0.width, proxy.size.height / $0.height) } ?? 0
                    let dx = (proxy.size.width - (canvas?.width ?? 0) * scale) / 2
                    let dy = (proxy.size.height - (canvas?.height ?? 0) * scale) / 2
                    ZStack(alignment: .topLeading) {
                        ForEach(DesktopWindowRow.rows(ordered).reversed()) { row in
                            let window = row.window
                            if let canvas, let frame = projectedFrame(window, canvas: canvas) {
                                Group {
                                    if let choice = byKey[row.id] {
                                        miniature(choice, icon: badges[window.id]?.icon, frame: frame, scale: scale)
                                    } else if feed.departingPictures != nil, let target = DesktopWindowTarget(window, in: snapshot) {
                                        croppedPicture(frame, scale: scale) {
                                            WindowPanePicture(gallery: gallery, target: target, permitted: permitted, icon: badges[window.id]?.icon)
                                        }
                                    }
                                }
                                .offset(x: dx + (frame.visible.x - canvas.x) * scale,
                                        y: dy + (frame.visible.y - canvas.y) * scale)
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
                            memberButtons(unplaced)
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
            let caption = HStack(spacing: 3) {
                ForEach(Array(appIcons(for: ordered).prefix(4).enumerated()), id: \.offset) { _, badge in
                    Image(nsImage: badge.icon).resizable().scaledToFit().frame(width: 12, height: 12)
                }
                Text(name ?? "窗口组合").font(.caption2).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: 18).contentShape(Rectangle())
            if let selectGroup {
                Button(action: selectGroup) { caption }.buttonStyle(.plain).accessibilityHidden(true)
            } else {
                Menu { memberButtons(choices) } label: { caption }
                    .menuStyle(.borderlessButton)
                    .disabled(choices.isEmpty)
                    .accessibilityLabel((name ?? "窗口组合") + "，选择组内窗口")
                    .accessibilityIdentifier("stage-group-members:" + id.uuidString)
                    .help("选择要置前的组内窗口")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name ?? "窗口组合")
        .accessibilityIdentifier("native-window-group:\(id)")
        .contextMenu {
            Button("命名窗口组…", action: rename)
            Button("解散窗口组合", action: dissolve)
            memberButtons(choices)
        }
    }

    private func memberButtons(_ choices: [StageGroupMemberChoice]) -> some View {
        ForEach(choices) { choice in
            Button(choice.label) { select(choice.member, choice.lifetime) }
        }
    }

    private func appIcons(for windows: [WindowObservation]) -> [WindowAppBadges.Badge] {
        var seen = Set<Int32>()
        return windows.compactMap { window in
            guard let pid = window.metadata?.pid, seen.insert(pid).inserted else { return nil }
            return badges[window.id]
        }
    }

    private func projectedFrame(_ window: WindowObservation, canvas: SurfaceRect?) -> StageGroupMiniatureFrame? {
        guard let canvas, let meta = window.metadata else { return nil }
        let frame: SurfaceRect
        if let logical = meta.catalogLogicalFrame {
            frame = .init(x: logical.x - display.frame.x, y: logical.y - display.frame.y,
                          width: logical.width, height: logical.height)
        } else {
            guard meta.hasCatalogGeometry == true else { return nil }
            frame = window.bounds
        }
        return StageGroupMiniatureFrame(original: frame, canvas: canvas)
    }

    private func croppedPicture<Content: View>(_ frame: StageGroupMiniatureFrame, scale: CGFloat,
                                               @ViewBuilder content: () -> Content) -> some View {
        let picture = frame.pictureInVisibleFrame
        return content()
            .frame(width: picture.width * scale, height: picture.height * scale)
            .offset(x: picture.x * scale, y: picture.y * scale)
            .frame(width: frame.visible.width * scale, height: frame.visible.height * scale, alignment: .topLeading)
            .clipped()
    }

    private func miniature(_ choice: StageGroupMemberChoice, icon: NSImage?,
                           frame: StageGroupMiniatureFrame, scale: CGFloat) -> some View {
        let member = choice.member
        let dest = member.source
        let target = DesktopWindowTarget.preview(choice.window, in: snapshot)
        let width = frame.visible.width * scale, height = frame.visible.height * scale
        let pictureWidth = frame.original.width * scale, pictureHeight = frame.original.height * scale
        return Button { select(member, choice.lifetime) } label: {
            croppedPicture(frame, scale: scale) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(DesktopWindowCard.windowBacking(for: scheme))
                    if let target {
                        WindowPanePicture(gallery:gallery,target:target,permitted:permitted,icon:icon,groupHistory:{
                            gallery?.observedImage(member.key,group:id,snapshot:snapshot,permitted:permitted)
                        })
                    } else if let icon, min(pictureWidth, pictureHeight) > 11 {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: min(16, pictureWidth), height: min(16, pictureHeight))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.45), lineWidth: 0.8) }
            .frame(width: width, height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .contextMenu { Button("从组合中移出") { remove(member) } }
        .modifier(GalleryCardExposure(gallery: gallery, target: target))
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityIdentifier("native-space-window:\(dest.display):\(dest.space):\(member.key.pid):\(member.key.number)")
        .modifier(SidebarWindowDragAndDrop(member: member, lifetime: choice.lifetime,
            width: width, feed: feed, select: { select(member, choice.lifetime) }, place: place,
            stack: choice.window.metadata.map { .init(group:id,session:snapshot.sessionID,revision:snapshot.revision,frontToBack:$0.frontToBack) },
            detach: { remove(member) }))
    }
}
