import SwiftUI
import NearpaneCore

extension DesktopWindowKey {
    init?(_ window: WindowObservation) {
        guard let m = window.metadata, m.pid > 1, let birth = m.launchMicroseconds, birth > 0, m.number > 0 else { return nil }
        self.init(pid: m.pid, birth: birth, number: m.number)
    }
}

struct DesktopWindowRow: Identifiable {
    let id: DesktopWindowKey
    let index: Int
    let window: WindowObservation

    static func rows(_ windows: [WindowObservation]) -> [Self] {
        let keys = Dictionary(grouping: windows.compactMap(DesktopWindowKey.init), by: { $0 })
        return windows.enumerated().compactMap { index, window in
            guard let id = DesktopWindowKey(window), keys[id]?.count == 1 else { return nil }
            return Self(id: id, index: index, window: window)
        }
    }
}

struct GalleryCardExposure: ViewModifier {
    let gallery: DesktopWindowGallery?
    let target: DesktopWindowTarget?

    func body(content: Content) -> some View {
        // A reader revision has new observation IDs even when the same native window
        // is still mounted. Tie ownership to the physical display and window incarnation.
        if let target, let gallery {
            let bound = content
                .onAppear { gallery.setCard(target.key, on: target.display, visible: true) }
                .onDisappear { gallery.setCard(target.key, on: target.display, visible: false) }
            if #available(macOS 15, *) {
                bound.onScrollVisibilityChange(threshold: 0.01) { visible in
                    gallery.setViewport(target.key, on: target.display, visible: visible)
                }
            } else { bound }
        } else { content }
    }
}

struct CurrentWindowCard: View {
    let label: String
    let badge: WindowAppBadges.Badge?
    let size: CGSize?
    let target: DesktopWindowTarget?
    let key: DesktopWindowKey
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let border, fontSize: CGFloat
    let selected: @MainActor () -> CGImage?
    let describe: (String) -> String
    let select: @MainActor () -> Void
    let selectable: Bool

    var body: some View {
        let image = target.flatMap { gallery?.image(for: $0, permitted: permitted) }
        let picked = image == nil ? selected() : nil
        let previous = image == nil && picked == nil ? target.flatMap { gallery?.previousImage(for: $0, permitted: permitted) } : nil
        let _ = gallery?.recordCardSource(key, image != nil ? .liveImage : picked != nil ? .selectedImage : previous != nil ? .previousImage : .outline)
        let missing = permitted && target.map { gallery?.lacksPicture($0) == true } == true
        let caption = previous == nil ? label : "上次画面 · " + label
        let source = image != nil ? "窗口画面" : picked != nil ? "所选快照" : previous != nil ? "上次画面" : "窗口轮廓"
        Button(action: select) {
            DesktopWindowCard(label: caption, icon: badge?.icon, image: image ?? picked ?? previous,
                pictureSize: size, borderWidth: border, labelSize: fontSize, unavailable: missing ? "无法读取窗口画面" : nil)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .modifier(GalleryCardExposure(gallery: gallery, target: target))
        .accessibilityLabel(label)
        .accessibilityHint(selectable ? "将这扇窗口切换到前台" : "只读窗口预览")
        .accessibilityIdentifier("current-desktop-window:\(key.pid):\(key.number)")
        .accessibilityValue(describe(source))
        .help(missing ? "系统暂未提供这扇窗口的画面" : selectable ? "切换到" + label : "只读窗口预览")
    }
}

/// One read-only surface per member, including the actual divider and asymmetric sizes.
struct DesktopSplitViewCard: View {
    let layout: NativeSplitViewLayout
    let snapshot: DesktopSnapshot
    let width: CGFloat
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let badges: [DesktopWindowKey: WindowAppBadges.Badge]

    var body: some View {
        let scale = width / layout.displayFrame.width
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                pane(layout.left, frame: layout.leftFrame, scale: scale)
                pane(layout.right, frame: layout.rightFrame, scale: scale)
            }
            .frame(width: width, height: layout.displayFrame.height * scale, alignment: .topLeading)
            .clipped()
            Text("分屏").font(.caption2).frame(height: 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本屏分屏")
        .accessibilityIdentifier("current-split-view:\(layout.displayID):\(layout.spaceID)")
    }

    @ViewBuilder private func pane(_ window: WindowObservation, frame: SurfaceRect, scale: CGFloat) -> some View {
        if let target = DesktopWindowTarget.preview(window, in: snapshot) {
            WindowPanePicture(gallery: gallery, target: target, permitted: permitted)
                .frame(width: frame.width * scale, height: frame.height * scale)
                .modifier(GalleryCardExposure(gallery: gallery, target: target))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badges[target.key]?.name ?? "窗口")
                .accessibilityIdentifier("split-view-member:\(target.key.pid):\(target.key.number)")
                .offset(x: frame.x * scale, y: frame.y * scale)
                .id(target.key)
        }
    }
}

struct WindowPanePicture: View {
    let gallery: DesktopWindowGallery?
    let target: DesktopWindowTarget
    let permitted: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(DesktopWindowCard.windowBacking(for: scheme))
            if let image = gallery?.image(for: target, permitted: permitted) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if permitted && gallery?.lacksPicture(target) == true {
                Text("无法读取画面").font(.caption2).lineLimit(1)
            }
        }.clipped()
    }
}
