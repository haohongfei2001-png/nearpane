import SwiftUI
import NearpaneCore

@Observable @MainActor final class SurfaceDisplay {
    var id: String?
    var primaryID: String?
    var referenceHeight: Double?
    var content: PanelContent = .full
    var secondary = false
    @ObservationIgnored weak var pointer: WorkspacePointerRegistry?
}

struct DesktopSurface: View {
    let host: HostSession
    let displayID: String?
    let enabled: Bool
    var display: SurfaceDisplay?
    var settings: DisplaySettings = .init()

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
                                let rows = max(1,native.rows.filter { $0.displayID == displayID }.count)
                                let desired = settings.points(.spaceRowHeight,in:available) * Double(rows)
                                let canvasHeight = max(1,desired)
                                ScrollView(.vertical) {
                                    let bounds = SurfaceRect(x:(size.size.width-width)/2+pad,y:pad,width:width-pad*2,height:canvasHeight-pad*2)
                                    if let preview = DesktopPreview(snapshot:snapshot,displayID:displayID,viewport:bounds,now:tick.date,
                                        uptime:uptime,restrictToDisplay:true,rowGap:settings.points(.spaceRowGap,in:available),
                                        rowViewport:.init(width:size.size.width,height:canvasHeight)) {
                                        drawing(preview)
                                            .overlay {
                                                if let display { WorkspacePointerSurface(host:host,preview:preview,sample:snapshot,display:display) }
                                            }
                                            .frame(width:size.size.width,height:canvasHeight)
                                    }
                                }.frame(height:height)
                            }
                            Text(host.workspaceIssue.map { issue in
                                issue == .minimumSize ? "窗口最小尺寸超出可用区域" : "当前无法执行工作空间操作"
                            } ?? (native.rows.contains(where: { $0.displayID == displayID }) ? "已确认的当前空间" : "此屏可见窗口 · 空间未确认"))
                                .font(settings.measures[.labelSize].map { .system(size:$0.points(in:display?.referenceHeight ?? 600)) } ?? .caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 3)
                        }
                    } else { status(snapshot.freshness == .transient ? "桌面正在变化" : "等待完整桌面快照") }
                }
            } else { status(enabled ? "空间归属尚未确认" : "空间预览已停用") }
        }
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .accessibilityHint("只读预览")
        .accessibilityIdentifier("desktop-reserved-region")
    }

    private func drawing(_ preview: DesktopPreview) -> some View {
        Canvas { context, _ in
            for row in preview.rows {
                let desktop = row.desktop
                let path = Path(CGRect(x: desktop.x, y: desktop.y, width: desktop.width, height: desktop.height))
                context.fill(path, with: .color(.secondary.opacity(0.08)))
                for window in row.windows.reversed() {
                    let r = window.frame
                    let outline = Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
                    context.fill(outline, with: .color(Color(nsColor: .controlBackgroundColor)))
                    context.stroke(outline, with: .color(.secondary.opacity(0.85)), style: .init(lineWidth: settings.points(.borderWidth,in:row.rowFrame.width),
                        dash: window.confidence == .corroboratedMetadata ? [] : [2, 1]))
                }
                context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("窗口轮廓 " + String(preview.rows.flatMap(\.windows).count) +
            (preview.rows.contains(where: \.hasUnassignedWindows) ? "，部分归属未知" : ""))
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
