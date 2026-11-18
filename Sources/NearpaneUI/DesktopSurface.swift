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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var appBadges: [String: WindowAppBadges.Badge] = [:]
    @ViewState private var layoutBadges: [String: WindowAppBadges.Badge] = [:]
    @ViewState private var layoutExpanded = false
    @ViewState private var choices = WindowChoiceQueue()
    @ViewState private var sidebarDrag = NativeSidebarDrag()
    @ViewState private var selectionIssue: String?
    @ViewState private var badgeSource: BadgeRefresh?

    private var overview: DesktopSnapshot? {
        if let feed = display?.pointer?.windowPreviews?.currentDesktop {
            return WindowContentPreview.sessionAvailable() ? (feed.snapshot ?? feed.lastPresentation) : nil
        }
        return host.providerFailed ? nil : host.bus.desktop
    }

    var body: some View {
        Group {
            if enabled, let snapshot = overview, let native = snapshot.native {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let now = Date.now
                    let uptime = ProcessInfo.processInfo.systemUptime
                    if snapshot.nativeIsFresh(now: now, uptime: uptime), !native.windowLimitReached,
                       !native.rows.isEmpty || snapshot.displays.contains(where: { $0.id == displayID }) {
                        VStack(alignment: .leading, spacing: 3) {
                            GeometryReader { size in
                                let pad = min(settings.points(.spacePadding,in:size.size.width), min(size.size.width,size.size.height) / 3)
                                let width = min(size.size.width,settings.points(.desktopWidth,in:size.size.width))
                                let height = min(size.size.height,settings.points(.scrollHeight,in:size.size.height))
                                let available = min(height,settings.points(.desktopHeight,in:height))
                                let layout = host.bus.desktop
                                let rows = max(1, layout?.desktopPreviewRowCount(for: displayID) ?? 0)
                                let desired = settings.points(.spaceRowHeight,in:available) * Double(rows)
                                let members = snapshot.currentDesktopWindows(on: displayID ?? "", now: now, uptime: uptime)
                                let canvasHeight = members.isEmpty ? max(1, desired) : min(max(1, desired), max(44, min(width * 0.70, available * 0.42)) * Double(rows))
                                if let catalog = NativeSpaceCatalog(snapshot, displayID: displayID ?? "", now: now, uptime: uptime),
                                   let feed = display?.pointer?.windowPreviews?.currentDesktop {
                                    let inset = pad + 2
                                    VStack(alignment: .leading, spacing: 5) {
                                        if !members.isEmpty {
                                            ScrollView(.vertical) {
                                                windowList(members, snapshot: snapshot, width: max(1, width - 2 * inset))
                                                    .padding(.horizontal, inset).padding(.top, pad)
                                            }
                                            .defaultScrollAnchor(.top)
                                            .frame(maxHeight: min(height * 0.56, CGFloat(members.count) * 132 + 26))
                                        }
                                        ScrollView(.vertical) {
                                            NativeSpaceNavigator(catalog: catalog, drag: sidebarDrag, feed: feed, badges: appBadges,
                                                gallery: display?.pointer?.windowPreviews?.gallery,
                                                permitted: host.configuration.showsWindowThumbnails && CGPreflightScreenCaptureAccess()
                                                    && WindowContentPreview.sessionAvailable() && canNavigate,
                                                canSwitch: feed.snapshot != nil && NativeSidebarNavigation.shared.canSwitch,
                                                canMove: feed.snapshot != nil && NativeSidebarNavigation.shared.canMove,
                                                select: { dest, member in
                                                    NativeSidebarNavigation.shared.select(dest, member: member, feed: feed, allowed: { canNavigate })
                                                }, move: { member, dest, lifetime in
                                                    NativeSidebarNavigation.shared.move(member, into: dest, lifetime: lifetime, feed: feed, allowed: { canNavigate })
                                                })
                                                .padding(.horizontal, inset)
                                        }
                                        .defaultScrollAnchor(.top)
                                    }
                                    .frame(width: width, height: height, alignment: .topLeading)
                                    .task(id: ProbeKey(session: catalog.session, topology: catalog.topology,
                                                       available: canNavigate, accessibility: snapshot.native?.accessibility)) {
                                        if canNavigate { await NativeSidebarNavigation.shared.probe(display: catalog.display.id) }
                                    }
                                    .task(id: BadgeRefresh(session: snapshot.sessionID, revision: snapshot.revision, visible: canNavigate)) {
                                        if canNavigate { appBadges = WindowAppBadges.resolve(snapshot) }
                                    }
                                } else {
                                ScrollView(.vertical) {
                                    let bounds = SurfaceRect(x:(size.size.width-width)/2+pad,y:pad,width:width-pad*2,height:canvasHeight-pad*2)
                                    if !members.isEmpty {
                                        windowList(members, snapshot: snapshot, width: max(0, width - 2 * (pad + 2)))
                                            .padding(.horizontal, pad + 2).padding(.vertical, pad)
                                            .frame(width: width, alignment: .topLeading)
                                    }
                                    if members.isEmpty || rows > 1 || layoutExpanded || display?.pointer?.windowPreviews?.hasStill == true {
                                        if let layout, let preview = DesktopPreview(snapshot:layout,displayID:displayID,viewport:bounds,now:now,
                                            uptime:uptime,restrictToDisplay:true,rowGap:settings.points(.spaceRowGap,in:available),
                                            rowViewport:.init(width:size.size.width,height:canvasHeight)) {
                                            drawing(preview, snapshot: layout)
                                                .overlay {
                                                    if layout.capabilities.spaceSwitching, let display {
                                                        WorkspacePointerSurface(host:host,preview:preview,sample:layout,display:display)
                                                    } else {
                                                        DesktopMapWindowSelection(target: { point in
                                                            guard let current = overview,
                                                                  let w = preview.presentedWindow(atX: point.x, y: point.y, now: .now, uptime: ProcessInfo.processInfo.systemUptime),
                                                                  let m = w.metadata, layout.topologyFingerprint == current.topologyFingerprint else { return nil }
                                                            return current.currentDesktopWindows(on: w.displayID, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                                                                .compactMap { DesktopWindowTarget($0, in: current) }.first {
                                                                    $0.key.number == m.number && $0.key.pid == m.pid && $0.key.birth == m.launchMicroseconds &&
                                                                    $0.publiclyVisible && $0.frame == m.globalFrame
                                                                }
                                                        }, select: { target in
                                                            guard let current = overview else { return }
                                                            selectWindow(target, snapshot: current, hasAX: AXIsProcessTrusted() || current.native?.accessibility == .available || current.native?.accessibility == .partial)
                                                        })
                                                    }
                                                }
                                                .frame(width:size.size.width,height:canvasHeight)
                                        }
                                    }
                                    if !members.isEmpty && rows == 1 {
                                        Button(layoutExpanded ? "收起桌面布局" : "查看桌面布局") { layoutExpanded.toggle() }
                                            .buttonStyle(.link).font(.caption)
                                            .accessibilityIdentifier("desktop-layout-disclosure")
                                    }
                                }
                                .defaultScrollAnchor(.top)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .frame(height: height, alignment: .topLeading)
                                }
                            }
                            if let issue = NativeSidebarNavigation.shared.issue ?? selectionIssue ?? host.workspaceIssue.map({ issue in
                                issue == .minimumSize ? "窗口最小尺寸超出可用区域" : "当前无法执行工作空间操作"
                            }) {
                                Text(issue)
                                    .font(settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600).map { .system(size: $0) } ?? .caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
                            }
                        }
                    } else { status(snapshot.freshness == .transient ? "桌面正在变化" : "等待完整桌面快照") }
                }
            } else { status(enabled ? "空间归属尚未确认" : "空间预览已停用") }
        }
        .accessibilityHint("选择当前桌面的一扇窗口可将它置前")
        .accessibilityIdentifier("desktop-reserved-region")
    }

    private struct ProbeKey: Equatable {
        let session: UUID, topology: String, available: Bool, accessibility: AXReadStatus?
    }

    private var canNavigate: Bool {
        host.isRunning && !host.configuration.surfaceHidden && display?.interactionVisible == true && display?.id == displayID
    }

    private struct GalleryRun: Equatable {
        let display: String, visible: Bool, permitted: Bool, generation: UInt64
    }

    private func windowList(_ windows: [WindowObservation], snapshot: DesktopSnapshot, width: CGFloat) -> some View {
        let previews = display?.pointer?.windowPreviews
        let gallery = previews?.gallery
        let id = displayID ?? ""
        let visible = display?.interactionVisible == true && !host.configuration.surfaceHidden
        let permitted = visible && host.configuration.showsWindowThumbnails && CGPreflightScreenCaptureAccess() && WindowContentPreview.sessionAvailable()
        let hasAX = AXIsProcessTrusted() || snapshot.native?.accessibility == .available || snapshot.native?.accessibility == .partial
        let run = GalleryRun(display: id, visible: visible, permitted: permitted, generation: gallery?.generation ?? 0)
        let pictureHeight = max(42, min(96, width * 0.61))
        let groups = Dictionary(grouping: windows, by: { $0.metadata?.pid })
        return VStack(alignment: .leading, spacing: 7) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(windows, id: \.metadata?.number) { window in
                    let badge = appBadges[window.id]
                    let siblings = groups[window.metadata?.pid] ?? []
                    let ordinal = siblings.firstIndex(of: window).map { $0 + 1 } ?? 1
                    let name = badge?.name ?? "窗口"
                    let label = siblings.count > 1 ? "\(name) · \(ordinal)" : name
                    let target = DesktopWindowTarget(window, in: snapshot)
                    let picture = target.flatMap { gallery?.image(for: $0, permitted: permitted) }
                    let origin = snapshot.scopes.first(where: { $0.displayID == id })?.records.first(where: { $0.isCurrent })
                    let member: NativeSidebarMember? = origin.flatMap { record in
                        guard let uuid = record.ordinaryUUID else { return nil }
                        let source = NativeSidebarDestination(session: snapshot.sessionID, topology: snapshot.topologyFingerprint,
                                                             display: id, space: record.id, uuid: uuid)
                        return NativeSidebarMember(window, source: source)
                    }
                    Button {
                        if let member, let feed = previews?.currentDesktop {
                            NativeSidebarNavigation.shared.select(member.source, member: member, feed: feed, allowed: { canNavigate })
                        } else if let target { selectWindow(target, snapshot: snapshot, hasAX: hasAX) }
                    } label: {
                        DesktopWindowCard(label: label, icon: badge?.icon, image: picture, pictureHeight: pictureHeight,
                                          unavailable: permitted && target.map { gallery?.lacksPicture($0) == true } == true)
                    }
                    .buttonStyle(.plain).disabled(target == nil)
                    .modifier(NativeWindowDragSource(member: NativeSidebarNavigation.shared.canMove ? member : nil, drag: sidebarDrag, feed: previews?.currentDesktop))
                    .accessibilityLabel(label).accessibilityHint("将这扇窗口切换到前台")
                    .accessibilityIdentifier("current-desktop-window")
                    .help(target == nil ? "窗口身份或呈现状态尚未确认" : "切换到" + label)
                    .id(target?.key)
                    .onAppear { if let target { gallery?.setCard(target.key, on: id, visible: true) } }
                    .onDisappear { if let target { gallery?.setCard(target.key, on: id, visible: false) } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("当前桌面，\(windows.count) 扇窗口")
            if visible && ((!permitted && host.configuration.showsWindowThumbnails) || !hasAX) {
                Menu("窗口权限") {
                    if host.configuration.showsWindowThumbnails && !permitted {
                        Button("允许窗口缩略图", action: WindowOverviewAccess.requestThumbnails)
                    }
                    if !hasAX { Button("允许精确切换窗口", action: WindowOverviewAccess.requestFocus) }
                }.menuStyle(.borderlessButton).font(.caption)
            }
        }
        .task(id: BadgeRefresh(session: snapshot.sessionID, revision: snapshot.revision, visible: visible)) {
            if visible { appBadges = WindowAppBadges.resolve(snapshot) }
        }
        .task(id: run) {
            guard permitted, let gallery else { return }
            await gallery.run(on: id, snapshot: { overview }, allowed: {
                host.isRunning && !host.configuration.surfaceHidden && host.configuration.showsWindowThumbnails &&
                    display?.interactionVisible == true && previews?.visibleDisplays.contains(id) == true
            }, recheck: previews?.currentDesktop.map { feed in { await feed.readNow() } })
        }
    }

    private func selectWindow(_ target: DesktopWindowTarget, snapshot: DesktopSnapshot, hasAX: Bool) {
        guard let native = snapshot.native, let previews = display?.pointer?.windowPreviews else { return }
        let generation = previews.gallery.generation
        let visibility = previews.visibilityGeneration[target.display]
        func stillCurrent() -> Bool {
            host.isRunning && !host.configuration.surfaceHidden && display?.interactionVisible == true &&
                display?.id == target.display && generation == previews.gallery.generation &&
                visibility == previews.visibilityGeneration[target.display] && target.present(in: overview)
        }
        guard stillCurrent() else { selectionIssue = "桌面已变化，请重新选择。"; return }
        selectionIssue = nil
        choices.choose(target.key) {
            let verifySpace: (() async -> Bool)? = previews.currentDesktop.map { feed in
                { target.present(in: await feed.readNow()) }
            }
            try await DesktopWindowSelection.select(target, deadline: native.beganUptime + 12, hasAX: hasAX,
                                                   verifySpace: verifySpace, stillCurrent: stillCurrent)
        } failed: { selectionIssue = $0.localizedDescription }
    }

    private func drawing(_ preview: DesktopPreview, snapshot: DesktopSnapshot) -> some View {
        let content = display?.pointer?.windowPreviews
        let chosen = content?.binding
        let snapshotWindow = chosen?.window(in: snapshot)?.id
        let observedRevision = content?.revision
        let key = BadgeRefresh(session: snapshot.sessionID, revision: snapshot.revision, visible: display?.interactionVisible == true)
        let badges = key == badgeSource ? layoutBadges : [:]
        return Canvas { context, _ in
            // A queued Canvas draw can run after a permission change. Resolve the
            // revocable source at draw time; never retain an admitted image in the view.
            let still = observedRevision == snapshot.revision ? content?.image(in: snapshot) : nil
            for row in preview.rows {
                let desktop = row.desktop
                let path = Path(roundedRect: CGRect(x: desktop.x, y: desktop.y, width: desktop.width, height: desktop.height),
                                cornerRadius: min(12, min(desktop.width, desktop.height) / 8))
                let accent = Color.primary
                var inside = context
                inside.clip(to: path)
                inside.fill(path, with: .linearGradient(Gradient(colors: [accent.opacity(0.035), accent.opacity(0.085)]),
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
                    sheet.fill(outline, with: .color(DesktopWindowCard.windowBacking(for: scheme)))
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
            guard display?.interactionVisible == true else { layoutBadges = [:]; return }
            layoutBadges = WindowAppBadges.resolve(snapshot)
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
        .accessibilityLabel("桌面窗口布局，从前到后")
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
        Text(text).font(.caption).foregroundStyle(.secondary).padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
