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
    @ViewState private var appleStages = AppleNativeStages()
    @ViewState private var appleDrag = AppleNativeStageDrag()
    private let navigation = NativeSidebarNavigation.shared
    private var panelAvailable: Bool {
        navigation.dispatchAvailable && enabled && host.isRunning && !host.configuration.surfaceHidden &&
            display?.interactionVisible == true && display?.id == displayID && WindowContentPreview.sessionAvailable()
    }
    private var currentCardsAcceptInput: Bool {
        panelAvailable && display?.pointer?.windowPreviews?.currentDesktop?.departingPictures == nil
    }
    private var canNavigate: Bool { currentCardsAcceptInput && !displayingAppleStages }
    @ViewState private var selectionIssue: String?
    private struct NameEdit {
        let group: StageGroupDirectory.Group
        let member: NativeSidebarMember
        let lifetimes: [UUID]
    }
    @ViewState private var nameEdit: NameEdit?
    @ViewState private var groupName = ""

    private var rawOverview: DesktopSnapshot? {
        if let feed = display?.pointer?.windowPreviews?.currentDesktop {
            return WindowContentPreview.sessionAvailable() ? feed.snapshot : nil
        }
        return host.providerFailed ? nil : host.bus.desktop
    }

    private var overview: DesktopSnapshot? {
        rawOverview.map(project)
    }

    private var displayingAppleStages: Bool {
        let departing = display?.pointer?.windowPreviews?.currentDesktop?.departingPictures
        return (departing?.snapshot ?? rawOverview)?.native?.stageManagerEnabled == true
    }

    private func project(_ value: DesktopSnapshot) -> DesktopSnapshot {
        var snapshot = value
        if snapshot.native?.population == .workWindows && snapshot.native?.catalogComplete == nil {
            // The general desktop reader has no catalogue role field. Its exact AX
            // standard-window witness is the only usable fallback for actual users.
            snapshot.windows.removeAll { !$0.canWitnessCurrentSpace }
        }
        return display?.pointer?.windowPreviews?.currentDesktop?.stageEngine.snapshotForGroups(snapshot) ?? snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            roster
                .alert("窗口组名称", isPresented: Binding(get: { nameEdit != nil }, set: {
                    if !$0 { nameEdit = nil }
                }), presenting: nameEdit) { edit in
                    TextField("名称", text: $groupName)
                    Button("保存") { saveName(edit, text: groupName) }
                    Button("取消", role: .cancel) {}
                }
            let feed = display?.pointer?.windowPreviews?.currentDesktop
            if let selectionIssue = navigation.issue ?? selectionIssue ?? feed?.groups.loadIssue ?? feed?.groupIssue {
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
        .task(id: AppleObservation(display: displayID, visible: panelAvailable && displayingAppleStages)) {
            guard panelAvailable, let displayID, displayingAppleStages,
                  let feed = display?.pointer?.windowPreviews?.currentDesktop else { return }
            await appleStages.run(display: displayID, snapshot: { rawOverview }, refresh: { await feed.readNow() }, visible: {
                panelAvailable && displayingAppleStages
            })
        }
        .task(id: GalleryRun(display: displayID, visible: display?.interactionVisible == true,
                             permitted: picturesAllowed, generation: display?.pointer?.windowPreviews?.gallery.generation ?? 0)) {
            WindowOverviewAccess.shared.refresh()
            guard let displayID, picturesAllowed, let previews = display?.pointer?.windowPreviews else { return }
            let feed = previews.currentDesktop
            await previews.gallery.run(on: displayID, snapshot: { overview }, allowed: {
                picturesAllowed && previews.visibleDisplays.contains(displayID)
            }, recheck: feed.map { feed in { await feed.readNow() } }, groups: { sample in
                guard let screen = sample.displays.first(where: { $0.id == displayID }), let area = workArea(for: screen) else { return nil }
                return feed?.pictureGroups(in: sample, screen: screen, area: area)
            })
        }
        .alert("允许窗口组调度？", isPresented: Binding(get: {
            !displayingAppleStages && display?.pointer?.windowPreviews?.currentDesktop?.stageEngine.consentRequest?.scope.display.uuidString.caseInsensitiveCompare(displayID ?? "") == .orderedSame
        }, set: { _ in })) {
            Button("允许") { display?.pointer?.windowPreviews?.currentDesktop?.stageEngine.answerConsent(allow:true) }
            Button("取消",role:.cancel) { display?.pointer?.windowPreviews?.currentDesktop?.stageEngine.answerConsent(allow:false) }
        } message: {
            let n = display?.pointer?.windowPreviews?.currentDesktop?.stageEngine.consentRequest?.lifetimes.count ?? 0
            Text("允许在此屏当前桌面暂时移出、恢复和排列所选组的 \(n) 扇已登记窗口。授权后请再次选择窗口组。")
        }
        .onChange(of: canNavigate) { _, available in
            if !available { nameEdit = nil; navigation.windowSwitch.cancel(on: displayID) }
        }
        .onChange(of: appleStages.ready && currentCardsAcceptInput) { _, available in
            if !available { appleDrag.cancel() }
        }
        .onDisappear {
            appleDrag.cancel()
            navigation.windowSwitch.cancel(on: displayID)
        }
    }

    @ViewBuilder private var roster: some View {
        let departing = display?.pointer?.windowPreviews?.currentDesktop?.departingPictures
        if enabled, WindowContentPreview.sessionAvailable(),
           let snapshot = departing.map({ project($0.snapshot) }) ?? overview, let native = snapshot.native,
           let screen = snapshot.displays.first(where: { $0.id == displayID }) {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let now = departing == nil ? Date.now : snapshot.sampledTo
                let uptime = departing == nil ? ProcessInfo.processInfo.systemUptime : native.endedUptime
                if snapshot.nativeIsFresh(now: now, uptime: uptime), !native.windowLimitReached {
                    let feed = display?.pointer?.windowPreviews?.currentDesktop
                    let observed = native.population == .markedFixture
                        ? snapshot.currentDesktopWindows(on: screen.id, now: now, uptime: uptime)
                        : snapshot.activeSpaceWindows(on: screen.id, now: now, uptime: uptime)
                    let split = snapshot.currentSplitView(on: screen.id, now: now, uptime: uptime)
                    let windows = feed?.ordered(observed, on: screen.id) ?? observed
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
                                if native.stageManagerEnabled == true {
                                    if current?.kind == .ordinary, appleStages.matches(snapshot, display: screen.id) {
                                        appleWorksets(snapshot, screen: screen, width: innerWidth)
                                    } else if let split {
                                        DesktopSplitViewCard(layout: split, snapshot: snapshot, width: innerWidth,
                                            gallery: feed == nil ? nil : display?.pointer?.windowPreviews?.gallery,
                                            permitted: picturesAllowed, badges: appBadges, now: now, uptime: uptime)
                                    }
                                } else if let split {
                                    DesktopSplitViewCard(layout: split, snapshot: snapshot, width: innerWidth,
                                        gallery: feed == nil ? nil : display?.pointer?.windowPreviews?.gallery,
                                        permitted: picturesAllowed, badges: appBadges, now: now, uptime: uptime)
                                } else {
                                    if !windows.isEmpty { windowList(windows,snapshot:snapshot,screen:screen,width:innerWidth,source:current,now:now,uptime:uptime) }
                                    if let feed, let current {
                                        ForEach(feed.stageEngine.heldGroups.filter { $0.scope.display.uuidString.caseInsensitiveCompare(screen.id) == .orderedSame &&
                                            $0.scope.nativeSpace == current.uuid }) { held in
                                            heldCard(held, feed:feed, snapshot:snapshot)
                                        }
                                        if picturesAllowed, let gallery = feed.stageGallery, let displayID = UUID(uuidString:screen.id) {
                                            let scope = StageGroupScope(display:displayID,nativeSpace:current.uuid)
                                            let visible = Set(feed.visibleGroups(in:snapshot,on:screen).values.map(\.id))
                                            let held = Set(feed.stageEngine.heldGroups.map(\.id))
                                            ForEach(feed.groups.groups(in:scope).filter { !visible.contains($0.id) && !held.contains($0.id) }) { group in
                                                if let picture = gallery.observedGroups[group.id], picture.matches(snapshot),
                                                   group.needsReorganization != true, Set(group.members.map(\.id)) == Set(picture.members.map(\.id)) {
                                                    observedCard(group,picture:picture,gallery:gallery,snapshot:snapshot)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: innerWidth, alignment: .topLeading)
                            .padding(inset)
                        }
                        .frame(width: width, alignment: .leading)
                        .task(id: BadgeRefresh(session: snapshot.sessionID, members: badgeRows(windows, in: snapshot, on: screen).compactMap(DesktopWindowKey.init), visible: currentCardsAcceptInput)) {
                            if currentCardsAcceptInput {
                                let rows = badgeRows(windows, in: snapshot, on: screen)
                                let badges = WindowAppBadges.resolve(rows)
                                appBadges = Dictionary(uniqueKeysWithValues: DesktopWindowRow.rows(rows).compactMap { row in
                                    guard let badge = badges[row.window.id] else { return nil }
                                    return (row.id, badge)
                                })
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(departing == nil)
            .accessibilityHidden(departing != nil)
        }
    }

    private func heldCard(_ held: StageWindowEngineHost.HeldGroup, feed: CurrentDesktopWindows,
                          snapshot: DesktopSnapshot) -> some View {
        let title = feed.groups.groups(in:held.scope).first { $0.id == held.id }?.name ??
            (held.count == 1 ? "非活动窗口" : "非活动组合 · " + String(held.count))
        let departure = held.departure.flatMap { $0.matches(snapshot) ? $0 : nil }
        var pictures = [UUID:CGImage]()
        if let departure, picturesAllowed, let gallery = feed.stageGallery {
            for member in departure.members {
                pictures[member.id] = gallery.heldImage(member,departure:departure,snapshot:snapshot,permitted:true) {
                    feed.stageEngine.confirmsPicture(member, group:held)
                }
            }
        }
        let description = pictures.isEmpty ? "暂无历史画面" : "历史画面 " + String(pictures.count) + "/" + String(held.count)
        func restore(_ member: StageGroupDeparture.Stamp?) {
            guard canNavigate else { return }
            let input = NativeSelectionPermit.inputCounters()
            let epoch = navigation.ownershipEpoch
            navigation.submit(stage:true) { token in
                try await feed.stageEngine.chooseHeld(held, member: member, in:feed, selectionToken: token, current:{
                    canNavigate && navigation.isCurrent(token) && input == NativeSelectionPermit.inputCounters()
                }, successor: { canNavigate ? navigation.queuedGroupChoice(after: token, in: epoch) : nil })
            }
        }
        return VStack(spacing:0) {
            if let departure {
                StageGroupHistoryPicture(departure:departure, images:pictures, select:restore)
            }
            Button { restore(nil) } label: {
                HStack(spacing:3) {
                    Text(title).lineLimit(1)
                    Text(description).lineLimit(1).foregroundStyle(.secondary).fixedSize()
                }.font(.caption2).frame(maxWidth:.infinity).frame(height:18).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(description)
            .accessibilityIdentifier("native-held-group:" + held.id.uuidString)
        }.disabled(!canNavigate)
    }

    @ViewBuilder private func observedCard(_ group: StageGroupDirectory.Group, picture: StageGroupDeparture,
                                           gallery: DesktopWindowGallery, snapshot: DesktopSnapshot) -> some View {
        let pairs = picture.members.compactMap { member in
            gallery.observedImage(member.key,group:group.id,snapshot:snapshot,permitted:picturesAllowed).map { (member.id,$0) }
        }
        if !pairs.isEmpty {
            let title = group.name ?? (group.members.count == 1 ? "窗口" : "窗口组合")
            let status = "历史画面 " + String(pairs.count) + "/" + String(group.members.count)
            VStack(spacing:0) {
                StageGroupHistoryPicture(departure:picture,images:Dictionary(uniqueKeysWithValues:pairs))
                HStack(spacing:3) {
                    Text(title).lineLimit(1)
                    Text(status).lineLimit(1).foregroundStyle(.secondary).fixedSize()
                }.font(.caption2).frame(height:18)
            }.accessibilityElement(children:.ignore).accessibilityLabel(title).accessibilityValue(status)
                .accessibilityIdentifier("observed-window-group:" + group.id.uuidString)
        }
    }

    private var picturesAllowed: Bool {
        panelAvailable && host.configuration.showsWindowThumbnails && WindowPermissionProbe.screen.allowed()
    }

    private func workArea(for screen: DisplayObservation) -> SurfaceRect? {
        guard let usable = screen.usable else { return nil }
        let bounds = SurfaceRect(width: screen.frame.width, height: screen.frame.height)
        return try? DesktopWorkArea(display: screen.id, screen: bounds, usable: usable,
            primary: display?.secondary != true, settings: settings, fallbackEdge: host.configuration.edge).ordinary
    }

    private func choose(_ member: NativeSidebarMember, group: UUID, lifetime: UUID?, snapshot: DesktopSnapshot, feed: CurrentDesktopWindows,
                        intent: StageSidebarSelection = .member) {
        guard canNavigate else { return }
        guard let lifetime, let observed = member.resolve(snapshot), let target = DesktopWindowTarget(observed, in:snapshot),
              feed.stillGroups(member, in: group, appearance: lifetime) else {
            selectionIssue = StageGroupError.staleBinding.localizedDescription
            return
        }
        if !feed.stageEngine.routesGroupChoice && intent == .member {
            selectWindow(target,snapshot:snapshot,lifetime:lifetime,member:member,group:group)
            return
        }
        let input = NativeSelectionPermit.inputCounters()
        let epoch = navigation.ownershipEpoch
        navigation.submit(stage:true) { token in
            let valid: @MainActor () -> Bool = {
                canNavigate && navigation.isCurrent(token) && feed.stillGroups(member, in: group, appearance: lifetime) &&
                    NativeSelectionPermit.inputCounters() == input
            }
            guard valid() else { throw StageSwitchError.interrupted }
            guard feed.stageEngine.routesGroupChoice else { throw StageSwitchError.unavailable }
            guard let fresh = await feed.readNow(), valid() else { throw StageSwitchError.interrupted }
            let handled = try await feed.stageEngine.groupChoice(group,member:member,selection:intent,in:feed,snapshot:fresh,current:valid,
                successor: { canNavigate ? navigation.queuedGroupChoice(after: token, in: epoch) : nil })
            if !handled && valid() {
                try intent.withoutEngine { selectWindow(target,snapshot:fresh,lifetime:lifetime,member:member,group:group) }
            }
        }
    }

    private func nameLifetimes(_ group: StageGroupDirectory.Group, feed: CurrentDesktopWindows) -> [UUID] {
        group.members.compactMap { member in
            let key = member.windowHint
            return feed.groupLifetime(of: .init(pid: key.pid, birth: key.birth, number: key.number))
        }
    }

    private func openName(_ group: StageGroupDirectory.Group, member: NativeSidebarMember, feed: CurrentDesktopWindows) {
        guard canNavigate, navigation.idleGeneration != nil else { return }
        let lifetimes = nameLifetimes(group, feed: feed)
        guard lifetimes.count == group.members.count else { selectionIssue = StageGroupError.staleBinding.localizedDescription; return }
        groupName = group.name ?? ""
        nameEdit = .init(group: group, member: member, lifetimes: lifetimes)
    }

    private func saveName(_ edit: NameEdit, text: String) {
        guard canNavigate, let generation = navigation.idleGeneration, let feed = display?.pointer?.windowPreviews?.currentDesktop else { return }
        Task { @MainActor in
            do {
                guard let fresh = await feed.readNow(), canNavigate, navigation.idleGeneration == generation,
                      let catalog = edit.member.source.resolve(fresh), catalog.current.id == edit.member.source.space,
                      let w = feed.groupWindow(edit.member, in: fresh), let space = w.nativeSpace,
                      feed.visibleGroups(in: fresh, on: catalog.display)[w.identity] == edit.group,
                      nameLifetimes(edit.group, feed: feed) == edit.lifetimes else { throw StageGroupError.staleBinding }
                // Naming updates only the directory. It must not release parked windows or request a dispatch grant.
                try feed.groups.rename(edit.group, in: .init(display: w.display, nativeSpace: space), to: text)
                selectionIssue = nil
            } catch { selectionIssue = error.localizedDescription }
        }
    }

    private func editGroup(_ members: [NativeSidebarMember], change: @escaping @MainActor (DesktopSnapshot) throws -> Void) {
        guard canNavigate, let feed = display?.pointer?.windowPreviews?.currentDesktop else { return }
        selectionIssue = nil
        let lifetimes = members.compactMap { feed.lifetime(of: $0.key) }
        let input = NativeSelectionPermit.inputCounters()
        guard lifetimes.count == members.count else { selectionIssue = StageGroupError.staleBinding.localizedDescription; return }
        navigation.submit(selection: false, stage: true) { token in
            let current: @MainActor () -> Bool = {
                canNavigate && navigation.isCurrent(token) && input == NativeSelectionPermit.inputCounters() &&
                    zip(members, lifetimes).allSatisfy { feed.lifetime(of: $0.0.key) == $0.1 }
            }
            try await feed.stageEngine.prepareForGroupEdit(current: current)
            guard let fresh = await feed.readNow(), current(),
                  members.allSatisfy({ feed.groupWindow($0, in: fresh) != nil })
            else { throw StageGroupError.staleBinding }
            try change(fresh)
        }
    }

    private func place(_ pair: SidebarPairDrop, feed: CurrentDesktopWindows) {
        guard let tiling = feed.automaticTiling, canNavigate else { return }
        selectionIssue = nil
        let input = NativeSelectionPermit.inputCounters()
        navigation.submit(selection: false, stage: true) { token in
            let current: @MainActor () -> Bool = {
                canNavigate && navigation.isCurrent(token) && NativeSelectionPermit.inputCounters() == input
            }
            try await feed.stageEngine.prepareForGroupEdit(current: current)
            try await tiling.place(pair, allowed: current)
        }
    }

    private struct GalleryRun: Equatable {
        let display: String?, visible: Bool, permitted: Bool, generation: UInt64
    }

    private struct AppleObservation: Equatable { let display: String?, visible: Bool }
    private struct AppleCardIdentity: Hashable {
        let group: String, session: UUID, display: String, home: UUID?, topology: String
    }

    private func badgeRows(_ windows: [WindowObservation], in snapshot: DesktopSnapshot, on screen: DisplayObservation) -> [WindowObservation] {
        guard snapshot.native?.stageManagerEnabled == true else { return windows }
        let members = Set(appleStages.groups.flatMap(\.members))
        return snapshot.windows.filter { $0.displayID == screen.id && DesktopWindowKey($0).map(members.contains) == true }
    }

    private func appleWorksets(_ snapshot: DesktopSnapshot, screen: DisplayObservation, width: CGFloat) -> some View {
        let rows = Dictionary(uniqueKeysWithValues: DesktopWindowRow.rows(snapshot.windows.filter { $0.displayID == screen.id })
            .map { ($0.id, $0.window) })
        let feed = display?.pointer?.windowPreviews?.currentDesktop
        let live = currentCardsAcceptInput && appleStages.ready && !navigation.stageOwnsWindowDispatch()
        let home = snapshot.scopes.first { $0.displayID == screen.id }?.records.first(where: \.isCurrent)?.ordinaryUUID
        return ForEach(appleStages.groups) { group in
            AppleNativeStageCard(group: group, snapshot: snapshot, screen: screen, width: width,
                pictureHeight: settings.measures[.spaceRowHeight]?.points(in: width) ?? width * 0.5,
                border: settings.points(.borderWidth, in: width),
                fontSize: settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600) ?? 10, rows: rows,
                badges: appBadges, gallery: display?.pointer?.windowPreviews?.gallery, permitted: picturesAllowed,
                interactive: live, lifetime: { feed?.departingPictures?.appearances[$0] ?? feed?.lifetime(of: $0) }, choose: { window in
                    guard live, currentCardsAcceptInput else { return }
                    let input = NativeSelectionPermit.inputCounters()
                    navigation.submit { token in
                        try await appleStages.choose(group, window: window, current: {
                            currentCardsAcceptInput && displayingAppleStages && navigation.isCurrent(token) && !navigation.stageOwnsWindowDispatch() &&
                                input == NativeSelectionPermit.inputCounters()
                        })
                    }
                })
                .modifier(appleDropTarget(group, in: snapshot, displayID: screen.id, enabled: live && appleStages.mergeAvailable))
                .id(AppleCardIdentity(group: group.id, session: snapshot.sessionID, display: screen.id, home: home,
                                      topology: snapshot.topologyFingerprint))
        }
    }

    private func appleDropTarget(_ group: AppleNativeStages.Group, in snapshot: DesktopSnapshot, displayID: String,
                                 enabled: Bool) -> AppleStageDropTarget {
        let renderedHome = snapshot.scopes.first(where: { $0.displayID == displayID })?.records.first(where: \.isCurrent)
        let session = snapshot.sessionID, topology = snapshot.topologyFingerprint
        func scope() -> AppleNativeStageDrag.Scope? {
            guard currentCardsAcceptInput, displayingAppleStages, !navigation.stageOwnsWindowDispatch(),
                  let fresh = rawOverview, fresh.sessionID == session,
                  fresh.topologyFingerprint == topology, appleStages.matches(fresh, display: displayID),
                  let home = fresh.scopes.first(where: { $0.displayID == displayID })?.records.first(where: \.isCurrent),
                  let desktop = home.ordinaryUUID, desktop == renderedHome?.ordinaryUUID, home.id == renderedHome?.id else { return nil }
            return .init(session: fresh.sessionID, display: displayID, desktop: desktop, record: home.id, topology: fresh.topologyFingerprint)
        }
        func lifetime(_ key: DesktopWindowKey) -> UUID? {
            display?.pointer?.windowPreviews?.currentDesktop?.lifetime(of: key)
        }
        return AppleStageDropTarget(enabled: enabled, begin: {
            guard enabled, appleStages.mergeAvailable, let scope = scope(),
                  let ticket = appleDrag.begin(group, scope: scope, intent: navigation.generation,
                                               groups: appleStages.groups, lifetime: lifetime) else { return NSItemProvider() }
            return ticket.provider()
        }, drop: { ticket in
            guard enabled, appleStages.mergeAvailable, let home = scope(),
                  let source = appleDrag.consume(ticket, into: group, scope: home, intent: navigation.generation,
                                                 groups: appleStages.groups, lifetime: lifetime) else { return false }
            let members = source.members + group.members
            let appearances = members.compactMap(lifetime)
            guard appearances.count == members.count else { return false }
            let input = NativeSelectionPermit.inputCounters()
            navigation.submit { token in
                let current: @MainActor () -> Bool = {
                    navigation.isCurrent(token) && scope() == home && members.compactMap(lifetime) == appearances
                }
                guard current(), appleStages.mergeAvailable,
                      appleStages.groups.contains(source), appleStages.groups.contains(group),
                      input == NativeSelectionPermit.inputCounters() else { return }
                try await appleStages.merge(source, into: group, current: current)
            }
            return true
        })
    }

    private func windowList(_ windows: [WindowObservation], snapshot: DesktopSnapshot, screen: DisplayObservation,
                            width: CGFloat, source: NativeSidebarDestination?, now: Date, uptime: TimeInterval) -> some View {
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
        let visibleGroups = feed?.departingPictures?.groups[screen.id] ?? feed?.visibleGroups(in: snapshot, on: screen) ?? [:]
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(DesktopWindowRow.rows(windows)) { row in
                let window = row.window
                let badge = appBadges[row.id]
                let siblings = siblingsByApp[window.metadata?.pid] ?? []
                let ordinal = siblings.firstIndex(of: window).map { $0 + 1 } ?? 1
                let name = badge?.name ?? "窗口"
                let label = siblings.count > 1 ? "\(name) · \(ordinal)" : name
                let target = DesktopWindowTarget(window, in: snapshot)
                let liveTarget = DesktopWindowTarget.preview(window, in: snapshot, now: now, uptime: uptime)
                let lifetime = target.flatMap { previews?.currentDesktop?.lifetime(of: $0.key) }
                let pictureLimit = CGSize(width: width, height: settings.measures[.spaceRowHeight]?.points(in: width) ?? width * 0.5)
                let pictureSize = thumbnailLayout.fittedSize(for: window, width: width, heightLimit: pictureLimit.height)
                let member = target.flatMap { _ in source.flatMap { NativeSidebarMember(window, source: $0) } }
                let group = member?.location.flatMap { visibleGroups[$0.window] }
                let chooseCurrent: @MainActor () -> Void = {
                    if let feed, feed.stageEngine.routesGroupChoice, let member, let group, group.members.count == 1 {
                        choose(member, group:group.id, lifetime:lifetime, snapshot:snapshot, feed:feed)
                    } else if let target {
                        selectWindow(target, snapshot:snapshot, lifetime:lifetime)
                    }
                }
                if let member, let group, group.members.count > 1, let feed {
                    let keys = Set(group.members.map(\.windowHint))
                    if members.first(where: { $0.location.map { keys.contains($0.window) } == true })?.key == member.key {
                        let grouped = windows.filter { w in NativeSidebarMember(w, source: member.source)?.location.map { keys.contains($0.window) } == true }
                        let preferred = group.focusMember().flatMap { saved in
                            members.first(where: { $0.location?.window == saved.windowHint })
                        }
                        let preferredLifetime = preferred.flatMap { feed.lifetime(of: $0.key) }
                        NativeWindowGroupCard(destination: member.source, display: screen,
                            feed: feed, badges: Dictionary(uniqueKeysWithValues: grouped.compactMap { w in
                                DesktopWindowKey(w).flatMap { appBadges[$0] }.map { (w.id, $0) }
                            }), gallery: gallery,
                            permitted: permitted, workArea: workArea(for: screen),
                            select: { choose($0, group: group.id, lifetime: $1, snapshot: snapshot, feed: feed) },
                            selectGroup: canNavigate && feed.stageEngine.offersGroupSelection(on: member.source) ? {
                                guard let preferred, feed.stageEngine.offersGroupSelection(on: member.source) else { return }
                                choose(preferred, group: group.id, lifetime: preferredLifetime, snapshot: snapshot, feed: feed, intent: .group)
                            } : nil,
                            id: group.id, name: group.name, windows: grouped, snapshot: snapshot,
                            place: { place($0, feed: feed) }, remove: { chosen in
                                editGroup([chosen]) { fresh in
                                    guard let w = feed.groupWindow(chosen, in: fresh) else { throw StageGroupError.staleBinding }
                                    try feed.groups.detach(w, from: group.id)
                                }
                            }, rename: { openName(group, member: member, feed: feed) }, dissolve: {
                                let enrolled = members.filter { $0.location.map { keys.contains($0.window) } == true }
                                guard enrolled.count == group.members.count else { selectionIssue = StageGroupError.staleBinding.localizedDescription; return }
                                editGroup(enrolled) { fresh in
                                    guard let w = feed.groupWindow(member, in: fresh),
                                          let current = feed.visibleGroups(in: fresh, on: screen)[w.identity],
                                          current.id == group.id, current.members.map(\.id) == group.members.map(\.id) else { throw StageGroupError.staleBinding }
                                    try feed.groups.dissolve(group.id, on: w.display)
                                }
                            })
                            .id(group.id)
                    }
                } else {
                    CurrentWindowCard(label: group?.name ?? label, badge: badge, size: pictureSize, pictureLimit: pictureLimit, target: liveTarget, key: row.id,
                        gallery: gallery, permitted: permitted, border: settings.points(.borderWidth, in: width),
                        fontSize: labelSize, selected: { pictures && target?.present(in: overview) == true ? selectedPicture(for: target) : nil },
                        describe: { cardDescription(window, within: screen, size: pictureSize, index: row.index, source: $0) },
                        select: { chooseCurrent() },
                        selectable: target != nil, groupHistory:{
                            group.flatMap { gallery?.observedImage(row.id,group:$0.id,snapshot:snapshot,permitted:permitted) }
                        })
                    .modifier(SidebarWindowDragAndDrop(member: canNavigate ? member : nil, lifetime: lifetime,
                        width: width, feed: feed,
                        select: { chooseCurrent() },
                        place: { pair in if let feed { place(pair, feed: feed) } },
                        prepare: { if let target { prepareSwitch(target, in: snapshot) } }))
                    .contextMenu {
                        if let member, let feed, member.source.kind == .ordinary {
                            if let group {
                                Button("命名窗口组…") { openName(group, member: member, feed: feed) }
                            }
                            if let w = feed.groupWindow(member, in: snapshot), feed.groups.needsRebinding(w) {
                                Button("重新关联此窗口到已保存的调度组") {
                                    editGroup([member]) { fresh in
                                        guard let current = feed.groupWindow(member, in: fresh), current.lifetime == w.lifetime
                                        else { throw StageGroupError.staleBinding }
                                        try feed.groups.rebind(current)
                                    }
                                }
                            }
                            if let w = feed.groupWindow(member, in: snapshot), feed.groups.needsReassignment(w) {
                                Button("将此窗口归入当前屏幕和桌面") {
                                    editGroup([member]) { fresh in
                                        guard let current = feed.groupWindow(member, in: fresh) else { throw StageGroupError.staleBinding }
                                        try feed.groups.assignToObservedDisplay(current)
                                    }
                                }
                            }
                            ForEach(Array(windows.enumerated()), id: \.element.id) { i, other in
                                if let second = NativeSidebarMember(other, source: member.source), second.key != member.key {
                                    Button("与 \(DesktopWindowKey(other).flatMap { appBadges[$0]?.name } ?? "窗口") · \(i + 1) 组合") {
                                        editGroup([member, second]) { try feed.join(member, second, in: $0) }
                                    }
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

    private func prepareSwitch(_ target: DesktopWindowTarget, in snapshot: DesktopSnapshot, operation: UUID? = nil) {
        guard let previews = display?.pointer?.windowPreviews else { return }
        navigation.windowSwitch.prepare(target, snapshot: snapshot, previews: previews, operation: operation,
            allowed: { canNavigate && host.configuration.showsWindowThumbnails })
    }

    private func selectWindow(_ target: DesktopWindowTarget, snapshot: DesktopSnapshot, lifetime: UUID?,
                              member: NativeSidebarMember? = nil, group: UUID? = nil) {
        let timing = WindowFocusTiming.begin()
        guard canNavigate, snapshot.native != nil, let previews = display?.pointer?.windowPreviews else { return }
        let generation = previews.gallery.generation
        let feed = previews.currentDesktop
        let userInput = NativeSelectionPermit.inputCounters()
        let visibility = previews.visibilityGeneration[target.display]
        func stillCurrent() -> Bool {
            guard canNavigate, navigation.dispatchAvailable, host.isRunning, !host.configuration.surfaceHidden, display?.interactionVisible == true,
                  display?.id == target.display else { return DesktopWindowSelection.refusedCurrentCard("display or sidebar") }
            guard feed == nil || (lifetime != nil && feed?.lifetime(of: target.key) == lifetime) else {
                return DesktopWindowSelection.refusedCurrentCard("window lifetime")
            }
            if let group {
                guard let member, let lifetime, feed?.stillGroups(member, in: group, appearance: lifetime) == true,
                      feed?.stageEngine.holdsDispatch == false else {
                    return DesktopWindowSelection.refusedCurrentCard("group membership or window ownership")
                }
            }
            if let original = member?.originalWindow, let location = member?.location, feed?.tracks(original, at: location) != true {
                return DesktopWindowSelection.refusedCurrentCard("group window identity")
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
        navigation.submit(prepare: { prepareSwitch(target, in: snapshot, operation: timing.id) }) { token in
            let isLatest = { navigation.isCurrent(token) }
            let verifySpace: (() async -> Bool)? = previews.currentDesktop.map { feed in
                { target.remainsSelection(in: await feed.readNow()) }
            }
            do {
                let path = try await DesktopWindowSelection.select(target, deadline: ProcessInfo.processInfo.systemUptime + 5,
                    verifySpace: verifySpace, stillCurrent: { isLatest() && stillCurrent() }, timing: timing,
                    beforeFocus: { navigation.windowSwitch.beforeFocus(timing.id, current: { isLatest() && stillCurrent() }) })
                if isLatest() { selectionIssue = path.focusNotice }
            } catch {
                navigation.windowSwitch.cancel(timing.id)
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
