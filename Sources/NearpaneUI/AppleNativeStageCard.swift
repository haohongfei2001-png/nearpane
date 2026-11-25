import SwiftUI
import NearpaneCore

typealias AppleCardState<T> = State<T>

/// Presentation only. Apple reports membership and order; this cache remembers full-size rectangles.
struct AppleNativeStageCard: View {
    struct Measurement: Equatable {
        let frame: SurfaceRect
        let lifetime: UUID?
    }

    let group: AppleNativeStages.Group
    let snapshot: DesktopSnapshot
    let screen: DisplayObservation
    let width: CGFloat
    let pictureHeight, border, fontSize: CGFloat
    let rows: [DesktopWindowKey: WindowObservation]
    let badges: [DesktopWindowKey: WindowAppBadges.Badge]
    let gallery: DesktopWindowGallery?
    let permitted, interactive: Bool
    let lifetime: (DesktopWindowKey) -> UUID?
    let choose: (DesktopWindowKey?) -> Void
    @AppleCardState var retained: [DesktopWindowKey: Measurement] = [:]

    static func fullFrame(_ window: WindowObservation, currentStage: Bool, on display: DisplayObservation) -> SurfaceRect? {
        guard window.displayID == display.id, let m = window.metadata else { return nil }
        let frame = m.catalogLogicalFrame ?? (currentStage && m.presentation == .confirmed && m.axStandardWindowNumber == m.number ? m.axFrame : nil)
        guard let frame, frame.geometry.isValid, frame.geometry.intersection(display.frame.geometry) != nil else { return nil }
        return frame
    }

    private func target(_ key: DesktopWindowKey) -> DesktopWindowTarget? {
        rows[key].flatMap {
            DesktopWindowTarget.preview($0, in: snapshot, now: snapshot.sampledTo, uptime: snapshot.native?.endedUptime ?? 0)
        }
    }

    static func layoutFrames(_ keys: [DesktopWindowKey], currentStage: Bool, screen: DisplayObservation,
                             rows: [DesktopWindowKey: WindowObservation], retained: [DesktopWindowKey: Measurement],
                             lifetime: (DesktopWindowKey) -> UUID?) -> [DesktopWindowKey: Measurement] {
        keys.reduce(into: [:]) { frames, key in
            let appearance = lifetime(key)
            if let row = rows[key], let frame = fullFrame(row, currentStage: currentStage, on: screen) {
                frames[key] = Measurement(frame: frame, lifetime: appearance)
            } else if let appearance, let previous = retained[key], previous.lifetime == appearance {
                frames[key] = previous
            }
        }
    }

    var body: some View {
        let measured = Self.layoutFrames(group.members, currentStage: group.current, screen: screen, rows: rows,
                                         retained: retained, lifetime: lifetime)
        Group {
            if group.members.count == 1, let key = group.members.first {
                CurrentWindowCard(label: badges[key]?.name ?? "窗口", badge: badges[key], size: nil,
                    pictureLimit: CGSize(width: width, height: pictureHeight), target: target(key), key: key,
                    gallery: gallery, permitted: permitted, border: border, fontSize: fontSize, selected: { nil },
                    describe: { $0 }, select: { choose(key) }, selectable: interactive)
            } else {
                VStack(spacing: 2) {
                    if measured.count == group.members.count {
                        layout(measured)
                    } else {
                        // Rectangles for the system's strip cannot describe the document layout.
                        HStack(spacing: 2) {
                            ForEach(group.members, id: \.self) { key in
                                member(key).frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: min(44, width * 0.45))
                    }
                    Button { choose(nil) } label: {
                        Text("\(group.members.count) 扇窗口").font(.caption2)
                            .frame(maxWidth: .infinity, minHeight: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!interactive)
                    .accessibilityLabel("切换到此窗口组合")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .overlay {
            if group.current {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.tint.opacity(0.6), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(group.current ? .isSelected : [])
        .accessibilityIdentifier("apple-stage:" + group.id)
        .onChange(of: measured, initial: true) { _, frames in
            if frames != retained { retained = frames }
        }
    }

    private func layout(_ measured: [DesktopWindowKey: Measurement]) -> some View {
        let scale = width / max(1, screen.frame.width)
        return ZStack(alignment: .topLeading) {
            Button { choose(nil) } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!interactive).accessibilityHidden(true)
            ForEach(group.members.reversed(), id: \.self) { key in
                if let f = measured[key]?.frame {
                    member(key).frame(width: f.width * scale, height: f.height * scale)
                        .offset(x: (f.x - screen.frame.x) * scale, y: (f.y - screen.frame.y) * scale)
                }
            }
        }
        .frame(width: width, height: screen.frame.height * scale, alignment: .topLeading)
        .clipped()
    }

    private func member(_ key: DesktopWindowKey) -> some View {
        let picture = target(key)
        return Button { choose(key) } label: {
            if let picture {
                WindowPanePicture(gallery: gallery, target: picture, permitted: permitted, icon: badges[key]?.icon)
            } else {
                (badges[key].map { Image(nsImage: $0.icon) } ?? Image(systemName: "macwindow"))
                    .resizable().scaledToFit().frame(maxWidth: 24, maxHeight: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain).disabled(!interactive)
        .modifier(GalleryCardExposure(gallery: gallery, target: picture))
        .accessibilityLabel(badges[key]?.name ?? "窗口")
        .accessibilityIdentifier("apple-stage-member:\(key.pid):\(key.number)")
    }
}
