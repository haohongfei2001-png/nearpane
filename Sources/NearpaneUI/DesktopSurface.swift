import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

@Observable @MainActor final class SurfaceDisplay {
    var id: String?
    var primaryID: String?
    var referenceHeight: Double?
    var content: PanelContent = .full
    var secondary = false
    var sizeForm: PanelSizeForm = .full
    var usesDefaultExpandedRim = false
    var interactionVisible = false
    @ObservationIgnored weak var pointer: WorkspacePointerRegistry?
}

struct DesktopSurface: View {
    let host: HostSession
    let displayID: String?
    let enabled: Bool
    var display: SurfaceDisplay?
    var settings: DisplaySettings = .init()
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var appBadges: [String: WindowAppBadges.Badge] = [:]
    @ViewState private var badgeSource: BadgeRefresh?

    var body: some View {
        Group {
            if enabled, !host.providerFailed, let snapshot = host.bus.desktop, let native = snapshot.native {
                TimelineView(.periodic(from: .now, by: 2)) { tick in
                    let uptime = ProcessInfo.processInfo.systemUptime
                    if snapshot.nativeIsFresh(now: tick.date, uptime: uptime), !native.windowLimitReached,
                       !native.rows.isEmpty || snapshot.displays.contains(where: { $0.id == displayID }) {
                        VStack(spacing: 3) {
                            GeometryReader { size in
                                let pad = min(settings.points(.spacePadding,in:size.size.width), min(size.size.width,size.size.height) / 3)
                                let width = min(size.size.width,settings.points(.desktopWidth,in:size.size.width))
                                let height = min(size.size.height,settings.points(.scrollHeight,in:size.size.height))
                                let available = min(height,settings.points(.desktopHeight,in:height))
                                let rows = displayID.map { max(1, snapshot.desktopPreviewRowCount(for: $0)) } ?? 1
                                let desired = settings.points(.spaceRowHeight,in:available) * Double(rows)
                                let canvasHeight = max(1,desired)
                                ScrollView(.vertical) {
                                    let bounds = SurfaceRect(x:(size.size.width-width)/2+pad,y:pad,width:width-pad*2,height:canvasHeight-pad*2)
                                    if let preview = DesktopPreview(snapshot:snapshot,displayID:displayID,viewport:bounds,now:tick.date,
                                        uptime:uptime,restrictToDisplay:true,rowGap:settings.points(.spaceRowGap,in:available),
                                        rowViewport:.init(width:size.size.width,height:canvasHeight)) {
                                        drawing(preview, snapshot: snapshot)
                                            .overlay {
                                                if snapshot.capabilities.spaceSwitching, let display { WorkspacePointerSurface(host:host,preview:preview,sample:snapshot,display:display) }
                                            }
                                            .frame(width:size.size.width,height:canvasHeight)
                                    }
                                }.frame(height:height)
                            }
                            Text(host.workspaceIssue.map { issue in
                                issue == .minimumSize ? "窗口最小尺寸超出可用区域" : "当前无法执行工作空间操作"
                            } ?? (native.rows.contains(where: { $0.displayID == displayID }) ? "已确认的当前空间" : "此屏可见窗口 · 空间未确认"))
                                .font(settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600).map { .system(size: $0) } ?? .caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 3)
                        }
                    } else { status(snapshot.freshness == .transient ? "桌面正在变化" : "等待完整桌面快照") }
                }
            } else { status(enabled ? "空间归属尚未确认" : "空间预览已停用") }
        }
        .accessibilityHint("只读预览")
        .accessibilityIdentifier("desktop-reserved-region")
    }

    private func drawing(_ preview: DesktopPreview, snapshot: DesktopSnapshot) -> some View {
        let content = display?.pointer?.windowPreviews
        let chosen = content?.binding
        let snapshotWindow = chosen?.window(in: snapshot)?.id
        let observedRevision = content?.revision
        let key = BadgeRefresh(session: snapshot.sessionID, revision: snapshot.revision, visible: display?.interactionVisible == true)
        let badges = key == badgeSource ? appBadges : [:]
        return Canvas { context, _ in
            // A queued Canvas draw can run after a permission change. Resolve the
            // revocable source at draw time; never retain an admitted image in the view.
            let still = observedRevision == snapshot.revision ? content?.image(in: snapshot) : nil
            for row in preview.rows {
                let desktop = row.desktop
                let path = Path(roundedRect: CGRect(x: desktop.x, y: desktop.y, width: desktop.width, height: desktop.height),
                                cornerRadius: min(12, min(desktop.width, desktop.height) / 8))
                let accent = host.configuration.accent.color
                var inside = context
                inside.clip(to: path)
                inside.fill(path, with: .linearGradient(Gradient(colors: [accent.opacity(0.10), accent.opacity(0.26)]),
                    startPoint: CGPoint(x: desktop.x, y: desktop.y), endPoint: CGPoint(x: desktop.x + desktop.width, y: desktop.y + desktop.height)))
                if case .previouslyWitnessedSpace = row.kind {
                    let caption = Text("此前的桌面 · 布局未读取").font(.caption2).foregroundStyle(.secondary)
                    if desktop.width >= 90, desktop.height >= 20 {
                        inside.draw(caption, at: CGPoint(x: desktop.x + desktop.width / 2, y: desktop.y + desktop.height / 2))
                    }
                }
                for window in row.windows.reversed() {
                    let r = window.frame
                    let outline = Path(roundedRect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height),
                                       cornerRadius: min(4, min(r.width, r.height) / 8))
                    var sheet = inside
                    sheet.addFilter(.shadow(color: .black.opacity(0.20), radius: 1.5, y: 1))
                    sheet.fill(outline, with: .color(Color(nsColor: .controlBackgroundColor)))
                    let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                    var clipped = inside
                    clipped.clip(to: outline)
                    if let still, window.canShowContent, window.id == snapshotWindow {
                        clipped.draw(Image(decorative: still, scale: 1), in: rect)
                    } else if let badge = badges[window.id], window.presentation == .confirmed, min(r.width, r.height) >= 18 {
                        let side = min(18, min(r.width, r.height) * 0.55)
                        clipped.draw(Image(nsImage: badge.icon), in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
                    }
                    inside.stroke(outline, with: .color(.primary.opacity(contrast == .increased ? 0.80 : 0.37)), style: .init(lineWidth: settings.points(.borderWidth,in:row.rowFrame.width),
                        dash: window.confidence == .corroboratedMetadata && window.presentation == .confirmed ? [] : [2, 1]))
                }
                inside.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
        }
        .task(id: key) {
            guard display?.interactionVisible == true else { appBadges = [:]; return }
            appBadges = WindowAppBadges.resolve(snapshot)
            badgeSource = key
            guard content?.binding?.display == displayID else { return }
            await content?.validate(snapshot)
        }
        .accessibilityChildren {
            ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                VStack {
                    switch row.kind {
                    case .previouslyWitnessedSpace: Text("此前已确认的桌面，当前窗口布局未读取")
                    case .visibleDisplay: Text("本屏可见窗口，空间归属未确认")
                    case .witnessedSpace: Text("已确认的当前空间")
                    }
                    if !row.windows.isEmpty { Text("可见轮廓 \(row.windows.count) 个") }
                    if row.hasUnassignedWindows { Text("另有窗口的空间归属未确认") }
                    ForEach(Array(row.windows.enumerated()), id: \.element.id) { index, window in
                        Text((window.presentation == .confirmed ? (badges[window.id].map { $0.name + "，" } ?? "") : "系统呈现位置，窗口布局未确认，") + Self.windowDescription(index: index, frame: window.frame, within: row.desktop))
                            .accessibilityIdentifier("desktop-window-outline")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityLabel("只读窗口布局，从前到后")
    }

    static func windowDescription(index: Int, frame: SurfaceRect, within desktop: SurfaceRect) -> String {
        func percent(_ extent: Double, of total: Double) -> Int { Int((extent / total * 100).rounded()) }
        let left = percent(frame.x - desktop.x, of: desktop.width)
        let top = percent(frame.y - desktop.y, of: desktop.height)
        return "窗口 \(index + 1)，左距 \(left)%，上距 \(top)%，宽 \(percent(frame.width, of: desktop.width))%，高 \(percent(frame.height, of: desktop.height))%"
    }

    private struct BadgeRefresh: Equatable {
        let session: UUID, revision: UInt64, visible: Bool
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
