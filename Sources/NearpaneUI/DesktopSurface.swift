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
    @ViewState private var appBadges: [DesktopWindowKey: WindowAppBadges.Badge] = [:]
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
                Text(selectionIssue).font(.caption2).foregroundStyle(Color(nsColor: SidebarTextColor.secondary)).lineLimit(2)
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
        #if NEARPANE_P0_DIAGNOSTIC
        .task(id: canNavigate ? displayID : nil) {
            guard canNavigate, let id = displayID, let feed = display?.pointer?.windowPreviews?.currentDesktop,
                  let lease = P0DiagnosticLease.installed() else { return }
            await P0HostDiagnostic().listen(lease, display:id, feed:feed, navigation:navigation, allowed:{ canNavigate })
        }
        #endif
    }

    @ViewBuilder private var roster: some View {
        if enabled, let snapshot = overview, let native = snapshot.native,
           let screen = snapshot.displays.first(where: { $0.id == displayID }) {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let now = Date.now
                let uptime = ProcessInfo.processInfo.systemUptime
                if snapshot.nativeIsFresh(now: now, uptime: uptime), !native.windowLimitReached {
                    let feed = display?.pointer?.windowPreviews?.currentDesktop
                    let observed = native.population == .markedFixture
                        ? snapshot.currentDesktopWindows(on: screen.id, now: now, uptime: uptime)
                        : snapshot.activeSpaceWindows(on: screen.id, now: now, uptime: uptime)
                    let split = snapshot.currentSplitView(on: screen.id, now: now, uptime: uptime)
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
                                if let split {
                                    DesktopSplitViewCard(layout: split, snapshot: snapshot, width: innerWidth,
                                        gallery: feed == nil ? nil : display?.pointer?.windowPreviews?.gallery,
                                        permitted: picturesAllowed, badges: appBadges)
                                } else if !windows.isEmpty {
                                    windowList(windows, snapshot: snapshot, screen: screen, width: innerWidth, source: current)
                                }
                            }
                            .task(id: GalleryRun(display: screen.id, visible: display?.interactionVisible == true,
                                permitted: picturesAllowed, generation: display?.pointer?.windowPreviews?.gallery.generation ?? 0)) {
                                WindowOverviewAccess.shared.refresh()
                                guard picturesAllowed, let previews = display?.pointer?.windowPreviews else { return }
                                await previews.gallery.run(on: screen.id, snapshot: { overview }, allowed: {
                                    picturesAllowed && previews.visibleDisplays.contains(screen.id)
                                }, recheck: feed.map { feed in { await feed.readNow() } })
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
                        .task(id: BadgeRefresh(session: snapshot.sessionID, members: windows.compactMap(DesktopWindowKey.init), visible: canNavigate)) {
                            if canNavigate {
                                let badges = WindowAppBadges.resolve(windows)
                                appBadges = Dictionary(uniqueKeysWithValues: DesktopWindowRow.rows(windows).compactMap { row in
                                    guard let badge = badges[row.window.id] else { return nil }
                                    return (row.id, badge)
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    private struct ProbeKey: Equatable {
        let session: UUID, topology: String, available: Bool
        let grants: Set<WindowOverviewAccess.Permission>, accessibility: AXReadStatus?, post: Bool
    }

    private var picturesAllowed: Bool {
        canNavigate && host.configuration.showsWindowThumbnails && WindowPermissionProbe.screen.allowed()
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

    private struct GalleryRun: Equatable {
        let display: String, visible: Bool, permitted: Bool, generation: UInt64
    }

    private func windowList(_ windows: [WindowObservation], snapshot: DesktopSnapshot, screen: DisplayObservation,
                            width: CGFloat, source: NativeSidebarDestination?) -> some View {
        let previews = display?.pointer?.windowPreviews
        let gallery = previews?.gallery
        let visible = display?.interactionVisible == true && !host.configuration.surfaceHidden
        let pictures = visible && host.configuration.showsWindowThumbnails && WindowContentPreview.sessionAvailable()
        let permitted = pictures && WindowPermissionProbe.screen.allowed()
        var captured = gallery?.capturedSizes(for: windows, in: snapshot, permitted: permitted) ?? [:]
        if pictures, let proof = previews?.binding, captured[proof.number] == nil,
           let window = windows.first(where: { $0.metadata?.number == proof.number }),
           let target = DesktopWindowTarget(window, in: snapshot), selectedPicture(for: target) != nil {
            captured[proof.number] = CGSize(width: proof.bounds.width, height: proof.bounds.height)
        }
        let thumbnailLayout = DesktopWindowThumbnailLayout(display: screen, capturedSizes: captured)
        let labelSize = settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600) ?? 10
        let spacing = settings.points(.spaceRowGap, in: display?.referenceHeight ?? 600)
        let siblingsByApp = Dictionary(grouping: windows, by: { $0.metadata?.pid })
        let feed = previews?.currentDesktop
        let members = source.map { dest in windows.compactMap { NativeSidebarMember($0, source: dest) } } ?? []
        let visibleGroups = source.flatMap { feed?.groups.visible(space: $0.uuid, members: Set(members.map(\.key))) } ?? [:]
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(DesktopWindowRow.rows(windows)) { row in
                let window = row.window
                let badge = appBadges[row.id]
                let siblings = siblingsByApp[window.metadata?.pid] ?? []
                let ordinal = siblings.firstIndex(of: window).map { $0 + 1 } ?? 1
                let name = badge?.name ?? "窗口"
                let label = siblings.count > 1 ? "\(name) · \(ordinal)" : name
                let target = DesktopWindowTarget(window, in: snapshot)
                let liveTarget = DesktopWindowTarget.preview(window, in: snapshot)
                let lifetime = target.flatMap { previews?.currentDesktop?.lifetime(of: $0.key) }
                let pictureSize = thumbnailLayout.fittedSize(for: window, width: width,
                    heightLimit: settings.measures[.spaceRowHeight]?.points(in: width) ?? width * 0.5)
                let member = target.flatMap { _ in source.flatMap { NativeSidebarMember(window, source: $0) } }
                if let member, let group = visibleGroups[member.key], let feed {
                    if members.first(where: { group.members[$0.key] != nil })?.key == member.key {
                        let grouped = windows.filter { w in NativeSidebarMember(w, source: member.source).map { group.members[$0.key] != nil } == true }
                        NativeWindowGroupCard(destination: member.source, display: screen, isCurrent: true,
                            drag: drag, feed: feed, badges: Dictionary(uniqueKeysWithValues: grouped.compactMap { w in
                                DesktopWindowKey(w).flatMap { appBadges[$0] }.map { (w.id, $0) }
                            }), gallery: gallery,
                            permitted: permitted, canSwitch: canNavigate && navigation.canSwitch,
                            canMove: canNavigate && navigation.canMove, workArea: workArea(for: screen),
                            select: { navigation.select(member.source, member: $0, feed: feed, allowed: { canNavigate }) },
                            id: group.id, windows: grouped, snapshot: snapshot, dissolve: { feed.groups.dissolve(group.id) })
                            .id(group.members)
                    }
                } else {
                    CurrentWindowCard(label: label, badge: badge, size: pictureSize, target: liveTarget, key: row.id,
                        gallery: gallery, permitted: permitted, border: settings.points(.borderWidth, in: width),
                        fontSize: labelSize, selected: { pictures && target?.present(in: overview) == true ? selectedPicture(for: target) : nil },
                        describe: { cardDescription(window, within: screen, size: pictureSize, index: row.index, source: $0) },
                        select: { if let target { selectWindow(target, snapshot: snapshot, lifetime: lifetime) } },
                        selectable: target != nil)
                    .modifier(NativeWindowDragSource(member: navigation.canMove ? member : nil, drag: drag, feed: feed))
                    .contextMenu {
                        if let member, let feed, member.source.kind == .ordinary {
                            ForEach(Array(windows.enumerated()), id: \.element.id) { i, other in
                                if let second = NativeSidebarMember(other, source: member.source), second.key != member.key {
                                    Button("与 \(DesktopWindowKey(other).flatMap { appBadges[$0]?.name } ?? "窗口") · \(i + 1) 组合") { feed.join(member, second) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本屏窗口，\(windows.count) 扇")
        .modifier(NativeWindowDropTarget(destination: source, canMove: canNavigate && navigation.canMove, drag: drag) { member, dest, lifetime in
            if let feed { move(member, to: dest, lifetime: lifetime, feed: feed) }
        })
        .task(id: host.bus.desktop?.revision) {
            if let previews, previews.binding?.display == screen.id { await previews.validate(host.bus.desktop) }
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
            guard host.isRunning, !host.configuration.surfaceHidden, display?.interactionVisible == true,
                  display?.id == target.display else { return DesktopWindowSelection.refusedCurrentCard("display or sidebar") }
            guard feed == nil || (lifetime != nil && feed?.lifetime(of: target.key) == lifetime) else {
                return DesktopWindowSelection.refusedCurrentCard("window lifetime")
            }
            guard generation == previews.gallery.generation, visibility == previews.visibilityGeneration[target.display] else {
                return DesktopWindowSelection.refusedCurrentCard("visibility generation")
            }
            guard target.remainsSelection(in: overview) else { return DesktopWindowSelection.refusedCurrentCard("roster target") }
            guard WindowContentPreview.sessionAvailable() else { return DesktopWindowSelection.refusedCurrentCard("console session") }
            guard NativeSelectionPermit.inputCounters() == userInput else { return DesktopWindowSelection.refusedCurrentCard("new input") }
            return true
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
        let session: UUID, members: [DesktopWindowKey], visible: Bool
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
