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
    @ObservationIgnored var updateMaterial: ((SurfaceLayout) -> Void)?
    @ObservationIgnored weak var pointer: WorkspacePointerRegistry?
}

struct DesktopSurface: View {
    let host: HostSession
    let displayID: String?
    let enabled: Bool
    var display: SurfaceDisplay?
    var settings: DisplaySettings = .init()
    @ViewState private var appBadges: [String: WindowAppBadges.Badge] = [:]
    @ViewState private var drag = NativeSidebarDrag()
    private let navigation = NativeSidebarNavigation.shared
    private var canNavigate: Bool {
        enabled && host.isRunning && !host.configuration.surfaceHidden &&
            display?.interactionVisible == true && display?.id == displayID && WindowContentPreview.sessionAvailable()
    }
    @ViewState private var selectionIssue: String?

    private var rawOverview: DesktopSnapshot? {
        if let feed = display?.pointer?.windowPreviews?.currentDesktop {
            return WindowContentPreview.sessionAvailable() ? feed.snapshot : nil
        }
        return host.providerFailed ? nil : host.bus.desktop
    }

    private var overview: DesktopSnapshot? {
        guard var snapshot = rawOverview else { return nil }
        if snapshot.native?.population == .workWindows && snapshot.native?.catalogComplete == nil {
            // The general desktop reader has no catalogue role field. Its exact AX
            // standard-window witness is the only usable fallback for actual users.
            snapshot.windows.removeAll { !$0.canWitnessCurrentSpace }
        }
        return snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            roster
            if let selectionIssue = navigation.issue ?? selectionIssue {
                Text(selectionIssue).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .layoutPriority(1)
            }
            if enabled, display?.interactionVisible == true, !host.configuration.surfaceHidden,
               WindowContentPreview.sessionAvailable() {
                WindowAccessGuide(showPictures: host.configuration.showsWindowThumbnails)
                    .layoutPriority(1)
            }
        }
        // Scope the region identifier to its own AX group. On macOS a VStack's identifier
        // otherwise propagates to sibling text and buttons, including the permission guide.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本屏窗口总览")
        .accessibilityHint("选择当前屏幕的一扇窗口可将它置前")
        .accessibilityIdentifier("desktop-reserved-region")
        .refreshWindowPermissions()
    }

    @ViewBuilder private var roster: some View {
        if enabled, let snapshot = overview, let native = snapshot.native,
           let screen = snapshot.displays.first(where: { $0.id == displayID }) {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let now = Date.now
                let uptime = ProcessInfo.processInfo.systemUptime
                if snapshot.nativeIsFresh(now: now, uptime: uptime), !native.windowLimitReached {
                    let feed = display?.pointer?.windowPreviews?.currentDesktop
                    let observed = snapshot.currentDesktopWindows(on: screen.id, now: now, uptime: uptime)
                    let windows = feed?.ordered(observed) ?? observed
                    let catalog = NativeSpaceCatalog(snapshot, displayID: screen.id, now: now, uptime: uptime)
                    GeometryReader { area in
                        let width = min(area.size.width, settings.points(.desktopWidth, in: area.size.width))
                        let inset = min(settings.points(.spacePadding, in: width) + 4, max(0, width / 4))
                        let innerWidth = max(0, width - 2 * inset)
                        let current = catalog.flatMap { map in
                            map.rows.first(where: { $0.record.isCurrent }).flatMap { NativeSidebarDestination($0, in: map) }
                        }
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 11) {
                                currentRoster(windows, snapshot: snapshot, screen: screen, width: innerWidth, source: current)
                                    .modifier(CurrentSpaceRegion(destination: current, canMove: navigation.canMove, drag: drag) { m, d, l in
                                        if let feed { move(m, to: d, lifetime: l, feed: feed) }
                                    })
                                if let catalog, let feed, catalog.rows.count > 1 {
                                    Divider()
                                    NativeSpaceNavigator(catalog: catalog, drag: drag, feed: feed, badges: appBadges,
                                        gallery: display?.pointer?.windowPreviews?.gallery,
                                        permitted: canNavigate && host.configuration.showsWindowThumbnails && WindowPermissionProbe.screen.allowed(),
                                        canSwitch: canNavigate && navigation.canSwitch, canMove: canNavigate && navigation.canMove,
                                        workArea: workArea(for: screen),
                                        select: { dest, member in
                                            selectionIssue = nil
                                            navigation.select(dest, member: member, feed: feed, allowed: { canNavigate })
                                        }, move: { move($0, to: $1, lifetime: $2, feed: feed) })
                                }
                            }
                            .frame(width: innerWidth, alignment: .topLeading)
                            .padding(inset)
                        }
                        .frame(width: width, alignment: .leading)
                        .task(id: ProbeKey(session: snapshot.sessionID, topology: snapshot.topologyFingerprint,
                                           available: canNavigate, grants: WindowOverviewAccess.shared.grants,
                                           accessibility: snapshot.native?.accessibility, post: CGPreflightPostEventAccess())) {
                            if canNavigate, catalog != nil { await navigation.probe(display: screen.id) }
                        }
                        .task(id: BadgeRefresh(session: snapshot.sessionID, members: snapshot.windows.map(\.id), visible: canNavigate)) {
                            if canNavigate { appBadges = WindowAppBadges.resolve(snapshot.windows) }
                        }
                    }
                } else { status("正在更新本屏窗口") }
            }
        } else { status(enabled ? "正在读取本屏窗口" : "窗口预览已停用") }
    }

    private struct ProbeKey: Equatable {
        let session: UUID, topology: String, available: Bool
        let grants: Set<WindowOverviewAccess.Permission>, accessibility: AXReadStatus?, post: Bool
    }

    private func workArea(for screen: DisplayObservation) -> SurfaceRect? {
        guard let usable = screen.usable else { return nil }
        let bounds = SurfaceRect(width: screen.frame.width, height: screen.frame.height)
        return try? DesktopWorkArea(display: screen.id, screen: bounds, usable: usable,
            primary: display?.secondary != true, settings: settings, fallbackEdge: host.configuration.edge).ordinary
    }

    private func move(_ member: NativeSidebarMember, to destination: NativeSidebarDestination, lifetime: UUID, feed: CurrentDesktopWindows) {
        selectionIssue = nil
        navigation.move(member, into: destination, lifetime: lifetime, feed: feed, allowed: { canNavigate })
    }

    @ViewBuilder private func currentRoster(_ windows: [WindowObservation], snapshot: DesktopSnapshot, screen: DisplayObservation,
                                            width: CGFloat, source: NativeSidebarDestination?) -> some View {
        if windows.isEmpty {
            if (rawOverview ?? snapshot).unconfirmedCurrentDesktopWindowCount(on: screen.id, now: .now,
                uptime: ProcessInfo.processInfo.systemUptime) > 0 {
                status(snapshot.native?.accessibility == .denied ? "允许辅助功能后可显示窗口" : "正在核对窗口")
                    .accessibilityIdentifier("window-roster-unconfirmed")
            } else {
                status("当前桌面没有可显示的窗口")
            }
        } else {
            windowList(windows, snapshot: snapshot, screen: screen, width: width, source: source)
        }
    }

    private struct GalleryRun: Equatable {
        let display: String, visible: Bool, permitted: Bool, generation: UInt64
    }

    private func windowList(_ windows: [WindowObservation], snapshot: DesktopSnapshot, screen: DisplayObservation,
                            width: CGFloat, source: NativeSidebarDestination?) -> some View {
        let previews = display?.pointer?.windowPreviews
        let gallery = previews?.gallery
        let id = screen.id
        let visible = display?.interactionVisible == true && !host.configuration.surfaceHidden
        let pictures = visible && host.configuration.showsWindowThumbnails && WindowContentPreview.sessionAvailable()
        let permitted = pictures && WindowPermissionProbe.screen.allowed()
        let run = GalleryRun(display: id, visible: visible, permitted: permitted, generation: gallery?.generation ?? 0)
        var captured = gallery?.capturedSizes(for: windows, in: snapshot, permitted: permitted) ?? [:]
        if pictures, let proof = previews?.binding, captured[proof.number] == nil,
           let window = windows.first(where: { $0.metadata?.number == proof.number }),
           let target = DesktopWindowTarget(window, in: snapshot), selectedPicture(for: target) != nil {
            captured[proof.number] = CGSize(width: proof.bounds.width, height: proof.bounds.height)
        }
        let thumbnailLayout = DesktopWindowThumbnailLayout(windows: windows, display: screen, availableWidth: width, capturedSizes: captured)
        let labelSize = settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600) ?? 10
        let spacing = settings.points(.spaceRowGap, in: display?.referenceHeight ?? 600)
        let groups = Dictionary(grouping: windows, by: { $0.metadata?.pid })
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                let badge = appBadges[window.id]
                let siblings = groups[window.metadata?.pid] ?? []
                let ordinal = siblings.firstIndex(of: window).map { $0 + 1 } ?? 1
                let name = badge?.name ?? "窗口"
                let label = siblings.count > 1 ? "\(name) · \(ordinal)" : name
                let target = DesktopWindowTarget(window, in: snapshot)
                let lifetime = target.flatMap { previews?.currentDesktop?.lifetime(of: $0.key) }
                let automatic = target.flatMap { gallery?.image(for: $0, permitted: permitted) }
                let selected = pictures && automatic == nil ? selectedPicture(for: target) : nil
                let pictureSize = thumbnailLayout.fittedSize(for: window, width: width,
                    heightLimit: settings.measures[.spaceRowHeight]?.points(in: width) ?? width * 0.5)
                let canLabelPrevious = width >= 24 + labelSize * 4
                let member = source.flatMap { NativeSidebarMember(window, source: $0) }
                let previous = automatic == nil && selected == nil && canLabelPrevious ? target.flatMap {
                    gallery?.previousImage(for: $0, permitted: permitted)
                } : nil
                let caption = previous == nil ? label : "上次画面 · " + label
                let picture = automatic ?? selected ?? previous
                let reason: String? = if !host.configuration.showsWindowThumbnails { "窗口画面已关闭" }
                    else if !pictures { "窗口画面暂不可用" }
                    else if !permitted { nil }
                    else if previous != nil { "上次画面，最长保留一分钟" }
                    else if target == nil || target.map({ gallery?.lacksPicture($0) == true }) == true { "暂无窗口画面" }
                    else { nil }
                Button {
                    if let target { selectWindow(target, snapshot: snapshot, lifetime: lifetime) }
                } label: {
                    DesktopWindowCard(label: caption, icon: badge?.icon, image: picture, pictureSize: pictureSize,
                                      borderWidth: settings.points(.borderWidth, in: width),
                                      labelSize: labelSize,
                                      currentImage: {
                        guard let target, display?.interactionVisible == true, display?.id == target.display,
                              !host.configuration.surfaceHidden, host.isRunning, host.configuration.showsWindowThumbnails,
                              WindowContentPreview.sessionAvailable(), target.present(in: overview),
                              previews?.currentDesktop == nil || (lifetime != nil && lifetime == previews?.currentDesktop?.lifetime(of: target.key)) else { return nil }
                        if previous != nil { return gallery?.previousImage(for: target, permitted: true) }
                        return gallery?.image(for: target, permitted: true) ?? selectedPicture(for: target)
                    })
                }
                .buttonStyle(.plain).disabled(target == nil)
                .modifier(NativeWindowDragSource(member: navigation.canMove ? member : nil, drag: drag, feed: previews?.currentDesktop))
                .accessibilityLabel(label).accessibilityHint("将这扇窗口切换到前台")
                .accessibilityIdentifier("current-desktop-window:\(window.metadata?.pid ?? 0):\(window.metadata?.number ?? 0)")
                .accessibilityValue(cardDescription(window, within: screen, size: pictureSize, index: index,
                    source: automatic != nil ? "窗口画面" : selected != nil ? "所选快照" : previous != nil ? "上次画面" : "窗口轮廓"))
                .help([target == nil ? "窗口身份或呈现状态尚未确认" : "切换到" + label, reason].compactMap { $0 }.joined(separator: " · "))
                .onAppear { if let target { gallery?.setCard(target.key, on: id, visible: true) } }
                .onDisappear { if let target { gallery?.setCard(target.key, on: id, visible: false) } }
                .onChange(of: target?.key) { previous, next in
                    if let previous { gallery?.setCard(previous, on: id, visible: false) }
                    if let next { gallery?.setCard(next, on: id, visible: true) }
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本屏窗口，\(windows.count) 扇")
        .task(id: host.bus.desktop?.revision) {
            if let previews, previews.binding?.display == screen.id { await previews.validate(host.bus.desktop) }
        }
        .task(id: run) {
            WindowOverviewAccess.shared.refresh()
            guard permitted, let gallery else { return }
            await gallery.run(on: id, snapshot: { overview }, allowed: {
                host.isRunning && !host.configuration.surfaceHidden && host.configuration.showsWindowThumbnails &&
                    display?.interactionVisible == true && previews?.visibleDisplays.contains(id) == true
            }, recheck: previews?.currentDesktop.map { feed in { await feed.readNow() } })
        }
    }

    private func selectedPicture(for target: DesktopWindowTarget?) -> CGImage? {
        guard let target, let previews = display?.pointer?.windowPreviews, let proof = previews.binding,
              let issued = host.bus.desktop, proof.matchesRosterTarget(target, issued: issued) else { return nil }
        return previews.image(in: issued)
    }

    private func cardDescription(_ window: WindowObservation, within screen: DisplayObservation, size: CGSize?,
                                 index: Int, source: String) -> String {
        guard let size else { return "窗口尺寸待核对" }
        let pixels = "\(source)，预览 \(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
        guard let m = window.metadata,
              m.hasCatalogGeometry == true || (m.axStandardWindowNumber == m.number && m.presentation == .confirmed) else {
            return pixels + "，窗口位置待核对"
        }
        let geometry = Self.windowDescription(index: index, frame: window.bounds,
                                             within: SurfaceRect(width: screen.frame.width, height: screen.frame.height))
        return pixels + "，" + geometry
    }

    private func selectWindow(_ target: DesktopWindowTarget, snapshot: DesktopSnapshot, lifetime: UUID?) {
        guard snapshot.native != nil, let previews = display?.pointer?.windowPreviews else { return }
        let generation = previews.gallery.generation
        let feed = previews.currentDesktop
        let userInput = NativeSelectionPermit.inputCounters()
        let visibility = previews.visibilityGeneration[target.display]
        func stillCurrent() -> Bool {
            host.isRunning && !host.configuration.surfaceHidden && display?.interactionVisible == true &&
                (feed == nil || (lifetime != nil && feed?.lifetime(of: target.key) == lifetime)) &&
                display?.id == target.display && generation == previews.gallery.generation &&
                visibility == previews.visibilityGeneration[target.display] && target.remainsSelection(in: overview) &&
                WindowContentPreview.sessionAvailable() && NativeSelectionPermit.inputCounters() == userInput
        }
        guard target.present(in: overview), stillCurrent() else { selectionIssue = "桌面已变化，请重新选择。"; return }
        selectionIssue = nil
        navigation.submit { token in
            let isLatest = { navigation.isCurrent(token) }
            let verifySpace: (() async -> Bool)? = previews.currentDesktop.map { feed in
                { target.remainsSelection(in: await feed.readNow()) }
            }
            do {
                if target.overviewSpace == nil, let verifySpace {
                    guard await verifySpace(), stillCurrent() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
                }
                let path = try await DesktopWindowSelection.select(target, deadline: ProcessInfo.processInfo.systemUptime + 5,
                    verifySpace: verifySpace, stillCurrent: { isLatest() && stillCurrent() })
                if isLatest() { selectionIssue = path.focusNotice }
            } catch {
                // An explicitly superseded choice must not clear the newer pending click.
                if isLatest() { throw error }
            }
        }
    }

    static func windowDescription(index: Int, frame: SurfaceRect, within desktop: SurfaceRect) -> String {
        func percent(_ extent: Double, of total: Double) -> Int { Int((extent / total * 100).rounded()) }
        let left = percent(frame.x - desktop.x, of: desktop.width)
        let top = percent(frame.y - desktop.y, of: desktop.height)
        return "窗口 \(index + 1)，左距 \(left)%，上距 \(top)%，宽 \(percent(frame.width, of: desktop.width))%，高 \(percent(frame.height, of: desktop.height))%"
    }

    private struct BadgeRefresh: Equatable {
        let session: UUID, members: [String], visible: Bool
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension PreviewWindowBinding {
    /// The selected still was issued by the full reader; the fast roster has an independent session.
    func matchesRosterTarget(_ target: DesktopWindowTarget, issued: DesktopSnapshot) -> Bool {
        if case .known(let a) = membership, case .known(let b) = target.membership, Set(a) != Set(b) { return false }
        return session == issued.sessionID && topology == issued.topologyFingerprint && topology == target.topology &&
            display == target.display && pid == target.key.pid && birth == target.key.birth && number == target.key.number &&
            bounds == target.frame && (currentRecord == nil || currentRecord?.id == target.current)
    }
}
