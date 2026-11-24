import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

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

    private struct Address: Hashable {
        let gallery: ObjectIdentifier
        let display: String
        let key: DesktopWindowKey
    }

    func body(content: Content) -> some View {
        // A reader revision has new observation IDs even when the same native window
        // is still mounted. Tie ownership to the physical display and window incarnation.
        if let target, let gallery {
            content
                .modifier(MountedCard(gallery: gallery, key: target.key, display: target.display))
                .id(Address(gallery: ObjectIdentifier(gallery), display: target.display, key: target.key))
        } else { content }
    }

    private struct MountedCard: ViewModifier {
        private final class Appearance {
            let token = UUID()
            var mounted = false
            var viewport: Bool?
        }

        let gallery: DesktopWindowGallery
        let key: DesktopWindowKey
        let display: String
        @ViewState private var appearance = Appearance()

        init(gallery: DesktopWindowGallery, key: DesktopWindowKey, display: String) {
            self.gallery = gallery
            self.key = key
            self.display = display
        }

        func body(content: Content) -> some View {
            let bound = content
                .onAppear {
                    guard !appearance.mounted else { return }
                    appearance.mounted = true
                    gallery.setCard(key, on: display, owner: appearance.token, visible: true)
                    if let viewport = appearance.viewport {
                        gallery.setViewport(key, on: display, owner: appearance.token, visible: viewport)
                    }
                }
                .onDisappear {
                    appearance.mounted = false
                    appearance.viewport = nil
                    gallery.setCard(key, on: display, owner: appearance.token, visible: false)
                }
            if #available(macOS 15, *) {
                bound.onScrollVisibilityChange(threshold: 0.01) { visible in
                    appearance.viewport = visible
                    if appearance.mounted {
                        gallery.setViewport(key, on: display, owner: appearance.token, visible: visible)
                    }
                }
            } else { bound }
        }
    }
}

struct CurrentWindowCard: View {
    let label: String
    let badge: WindowAppBadges.Badge?
    let size: CGSize?
    let pictureLimit: CGSize
    let target: DesktopWindowTarget?
    let key: DesktopWindowKey
    let gallery: DesktopWindowGallery?
    let permitted: Bool
    let border, fontSize: CGFloat
    let selected: @MainActor () -> CGImage?
    let describe: (String) -> String
    let select: @MainActor () -> Void
    let selectable: Bool
    var groupHistory: (() -> CGImage?)? = nil

    var body: some View {
        let image = target.flatMap { gallery?.image(for: $0, permitted: permitted) }
        let lastFrame = image == nil ? target.flatMap { gallery?.previousImage(for: $0, permitted: permitted) } : nil
        let picked = image == nil && lastFrame == nil ? selected() : nil
        let previous = lastFrame ?? (image == nil && picked == nil ? groupHistory?() : nil)
        let pixels = image ?? picked ?? previous
        let fitted = size ?? pixels.map {
            let scale = min(pictureLimit.width / CGFloat($0.width), pictureLimit.height / CGFloat($0.height))
            return CGSize(width: CGFloat($0.width) * scale, height: CGFloat($0.height) * scale)
        }
        let _ = gallery?.recordCardSource(key, image != nil ? .liveImage : picked != nil ? .selectedImage : previous != nil ? .previousImage : .outline)
        let source = image != nil ? "窗口画面" : picked != nil ? "所选快照" : previous != nil ? "上次画面" : "窗口轮廓"
        Button(action: select) {
            DesktopWindowCard(label: label, icon: badge?.icon, image: pixels,
                pictureSize: fitted, borderWidth: border, labelSize: fontSize, showsAppFallback: true)
                .equatable()
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .modifier(GalleryCardExposure(gallery: gallery, target: target))
        .accessibilityLabel(label)
        .accessibilityHint(selectable ? "将这扇窗口切换到前台" : "只读窗口预览")
        .accessibilityIdentifier("current-desktop-window:\(key.pid):\(key.number)")
        .accessibilityValue(describe(source))
        .help(selectable ? "切换到" + label : "只读窗口预览")
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
            WindowPanePicture(gallery: gallery, target: target, permitted: permitted, icon: badges[target.key]?.icon)
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
    var icon: NSImage?
    var groupHistory: (() -> CGImage?)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let picture = gallery?.image(for: target, permitted: permitted) ?? gallery?.previousImage(for: target, permitted: permitted)
        let history = permitted && picture == nil ? groupHistory?() : nil
        ZStack {
            Rectangle().fill(DesktopWindowCard.windowBacking(for: scheme))
            if let image = picture ?? history {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        if history != nil { Text("历史").font(.caption2).padding(1).background(.regularMaterial) }
                    }
            } else {
                (icon.map(Image.init(nsImage:)) ?? Image(systemName: "macwindow"))
                    .resizable().scaledToFit().frame(maxWidth: 24, maxHeight: 24).accessibilityHidden(true)
            }
        }.clipped()
    }
}
