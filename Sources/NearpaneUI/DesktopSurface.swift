import SwiftUI
import NearpaneCore

@Observable @MainActor final class SurfaceDisplay {
    var id: String?
    var primaryID: String?
    var referenceHeight: Double?
    var content: PanelContent = .full
    var secondary = false
    var sizeForm: PanelSizeForm = .full
    var interactionVisible = false
    @ObservationIgnored weak var pointer: WorkspacePointerRegistry?
}

private typealias PreviewState<T> = SwiftUI.State<T>

struct DesktopSurface: View {
    let host: HostSession
    let displayID: String?
    let enabled: Bool
    var display: SurfaceDisplay?
    var settings: DisplaySettings = .init()

    @PreviewState private var thumbnails = WorkspaceWindowThumbnails()

    var body: some View {
        Group {
            if enabled, !host.providerFailed, let snapshot = host.bus.desktop, let native = snapshot.native {
                TimelineView(.periodic(from: .now, by: 2)) { tick in
                    if snapshot.nativeIsFresh(now: tick.date, uptime: ProcessInfo.processInfo.systemUptime),
                       !native.windowLimitReached, snapshot.displays.contains(where: { $0.id == displayID }) {
                        let windows = snapshot.windows.filter { $0.displayID == displayID }
                            .sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
                        let showImages = settings.showsWindowContents && display?.interactionVisible == true
                        let observedSpace = native.rows.contains { $0.displayID == displayID }
                        GeometryReader { proxy in
                            let width = min(proxy.size.width, settings.points(.desktopWidth, in: proxy.size.width))
                            let height = min(proxy.size.height, settings.points(.scrollHeight, in: proxy.size.height))
                            let pad = min(settings.measures[.spacePadding]?.points(in: width) ?? width * 0.047,
                                          min(width, height) / 3)
                            let available = min(height, settings.points(.desktopHeight, in: height))
                            let gap = settings.points(.spaceRowGap, in: available)
                            let rowHeight = min(available, settings.measures[.spaceRowHeight]?.points(in: available)
                                ?? max(1, (available - 2 * pad - 3 * gap) / 4))
                            let gallery = !observedSpace && showImages && windows.contains { thumbnails.image(for: $0) != nil }
                            ScrollView(.vertical) {
                                if gallery {
                                    // Unknown membership cannot create a Space. Each actual window is a read-only tile.
                                    LazyVStack(spacing: gap) {
                                        ForEach(windows) { window in
                                            if let image = thumbnails.image(for: window) {
                                                Image(decorative: image, scale: 1)
                                                    .resizable().scaledToFit()
                                                    .padding(3)
                                                    .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)
                                                    .frame(maxWidth: .infinity)
                                                    .frame(height: max(1, rowHeight))
                                                    .background(previewBackground)
                                                    .clipShape(RoundedRectangle(cornerRadius: max(3, pad * 0.7)))
                                                    .accessibilityHidden(false)
                                                    .accessibilityLabel("本屏窗口预览，空间未确认")
                                                    .accessibilityIdentifier("desktop-window-preview")
                                            }
                                        }
                                    }.padding(pad)
                                } else {
                                    let canvas = max(1, rowHeight)
                                    let bounds = SurfaceRect(x: pad, y: pad, width: max(1, width - 2 * pad), height: max(1, canvas - 2 * pad))
                                    if let preview = DesktopPreview(snapshot: snapshot, displayID: displayID,
                                        viewport: bounds, now: tick.date, uptime: ProcessInfo.processInfo.systemUptime,
                                        restrictToDisplay: true, rowGap: gap, rowViewport: .init(width: width, height: canvas)) {
                                        drawing(preview, windows: windows, showImages: showImages)
                                            .overlay {
                                                if snapshot.capabilities.spaceSwitching, let display {
                                                    WorkspacePointerSurface(host: host, preview: preview, sample: snapshot, display: display)
                                                }
                                            }
                                            .frame(width: width, height: canvas)
                                    }
                                }
                                if let issue = host.workspaceIssue {
                                    status(issue == .minimumSize ? "窗口最小尺寸超出可用区域" : "当前无法执行工作空间操作")
                                } else if showImages && !CGPreflightScreenCaptureAccess() {
                                    status("窗口内容预览需要屏幕录制权限")
                                } else if !observedSpace && !gallery {
                                    status("本屏窗口 · 空间未确认")
                                }
                            }
                            .frame(width: width, height: height)
                            .frame(maxWidth: .infinity)
                        }
                        .task(id: RefreshKey(session: snapshot.sessionID, revision: snapshot.revision, screen: displayID,
                                             visible: showImages)) {
                            if showImages { await thumbnails.refresh(windows, population: native.population) }
                            else { thumbnails.clear() }
                        }
                        .onDisappear { thumbnails.clear() }
                    } else { status(snapshot.freshness == .transient ? "桌面正在变化" : "等待完整桌面快照") }
                }
            } else { status(enabled ? "空间归属尚未确认" : "空间预览已停用") }
        }
        .accessibilityHint("只读预览")
        .accessibilityIdentifier("desktop-reserved-region")
    }

    private struct RefreshKey: Equatable {
        let session: UUID, revision: UInt64, screen: String?, visible: Bool
    }

    private var previewBackground: LinearGradient {
        LinearGradient(colors: [Color(red: 0.44, green: 0.45, blue: 0.92).opacity(0.60),
                                Color(red: 0.24, green: 0.40, blue: 0.90).opacity(0.65)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func drawing(_ preview: DesktopPreview, windows: [WindowObservation], showImages: Bool) -> some View {
        let observations = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        return Canvas { context, _ in
            for row in preview.rows {
                let desktop = row.desktop
                let desktopRect = CGRect(x: desktop.x, y: desktop.y, width: desktop.width, height: desktop.height)
                let shape = Path(roundedRect: desktopRect, cornerRadius: min(8, desktop.width * 0.035))
                context.fill(shape, with: .linearGradient(
                    Gradient(colors: [.indigo.opacity(0.45), .blue.opacity(0.40)]),
                    startPoint: desktopRect.origin, endPoint: CGPoint(x: desktopRect.maxX, y: desktopRect.maxY)))
                for window in row.windows.reversed() {
                    let r = window.frame
                    let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                    let outline = Path(roundedRect: rect, cornerRadius: min(2.5, min(r.width, r.height) / 5))
                    context.fill(outline, with: .color(.white.opacity(0.62)))
                    if showImages, let observation = observations[window.id], let pixels = thumbnails.image(for: observation) {
                        let scale = min(rect.width / CGFloat(pixels.width), rect.height / CGFloat(pixels.height))
                        let width = CGFloat(pixels.width) * scale, height = CGFloat(pixels.height) * scale
                        var clipped = context
                        clipped.clip(to: outline)
                        clipped.draw(Image(decorative: pixels, scale: 1),
                            in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
                    }
                    context.stroke(outline, with: .color(.white.opacity(0.82)),
                        style: .init(lineWidth: settings.points(.borderWidth, in: row.rowFrame.width),
                                     dash: window.confidence == .corroboratedMetadata ? [] : [2, 1]))
                }
            }
        }
        .accessibilityChildren {
            ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                VStack {
                    Text(row.kind == .visibleDisplay ? "本屏可见窗口，空间归属未确认" : "已确认的当前空间")
                    Text("可见轮廓 \(row.windows.count) 个")
                    if row.hasUnassignedWindows { Text("另有窗口的空间归属未确认") }
                    ForEach(Array(row.windows.enumerated()), id: \.element.id) { index, window in
                        Text(Self.windowDescription(index: index, frame: window.frame, within: row.desktop))
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

    private func status(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
