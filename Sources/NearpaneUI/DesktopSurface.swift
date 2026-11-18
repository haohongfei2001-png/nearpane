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
    @ViewState private var appBadges: [String: WindowAppBadges.Badge] = [:]
    @ViewState private var choices = WindowChoiceQueue()
    @ViewState private var selectionIssue: String?

    private var overview: DesktopSnapshot? {
        if let feed = display?.pointer?.windowPreviews?.currentDesktop {
            return WindowContentPreview.sessionAvailable() ? feed.snapshot : nil
        }
        return host.providerFailed ? nil : host.bus.desktop
    }

    var body: some View {
        Group {
            if enabled, let snapshot = overview, let native = snapshot.native,
               let screen = snapshot.displays.first(where: { $0.id == displayID }) {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let now = Date.now
                    let uptime = ProcessInfo.processInfo.systemUptime
                    if snapshot.nativeIsFresh(now: now, uptime: uptime), !native.windowLimitReached {
                        let windows = snapshot.currentDesktopWindows(on: screen.id, now: now, uptime: uptime)
                        GeometryReader { area in
                            let width = min(area.size.width, settings.points(.desktopWidth, in: area.size.width))
                            let viewport = min(area.size.height, settings.points(.scrollHeight, in: area.size.height))
                            let height = min(viewport, settings.points(.desktopHeight, in: viewport))
                            let inset = min(settings.points(.spacePadding, in: width) + 2, width / 3)
                            ScrollView(.vertical) {
                                if windows.isEmpty {
                                    status("当前屏幕没有可显示的窗口")
                                } else {
                                    windowList(windows, snapshot: snapshot, screen: screen, width: max(1, width - 2 * inset),
                                               spacing: settings.points(.spaceRowGap, in: height))
                                    if let selectionIssue {
                                        Text(selectionIssue).font(.caption2).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .contentMargins(.horizontal, inset, for: .scrollContent)
                            .contentMargins(.top, inset, for: .scrollContent)
                            .defaultScrollAnchor(.top)
                            .frame(width: width, height: height, alignment: .topLeading)
                        }
                    } else { status("正在更新本屏窗口") }
                }
            } else { status(enabled ? "正在读取本屏窗口" : "窗口预览已停用") }
        }
        .accessibilityHint("选择当前屏幕的一扇窗口可将它置前")
        .accessibilityIdentifier("desktop-reserved-region")
        .refreshWindowPermissions()
    }

    private struct GalleryRun: Equatable {
        let display: String, visible: Bool, permitted: Bool, generation: UInt64
    }

    private func windowList(_ windows: [WindowObservation], snapshot: DesktopSnapshot, screen: DisplayObservation,
                            width: CGFloat, spacing: CGFloat) -> some View {
        let previews = display?.pointer?.windowPreviews
        let gallery = previews?.gallery
        let id = screen.id
        let visible = display?.interactionVisible == true && !host.configuration.surfaceHidden
        let pictures = visible && host.configuration.showsWindowThumbnails && WindowContentPreview.sessionAvailable()
        let permitted = pictures && CGPreflightScreenCaptureAccess()
        let run = GalleryRun(display: id, visible: visible, permitted: permitted, generation: gallery?.generation ?? 0)
        var captured = gallery?.capturedSizes(for: windows, in: snapshot, permitted: permitted) ?? [:]
        if pictures, let proof = previews?.binding, captured[proof.number] == nil,
           let window = windows.first(where: { $0.metadata?.number == proof.number }),
           let target = DesktopWindowTarget(window, in: snapshot), selectedPicture(for: target) != nil {
            captured[proof.number] = CGSize(width: proof.bounds.width, height: proof.bounds.height)
        }
        let thumbnailLayout = DesktopWindowThumbnailLayout(windows: windows, display: screen, availableWidth: width, capturedSizes: captured)
        let groups = Dictionary(grouping: windows, by: { $0.metadata?.pid })
        return LazyVStack(alignment: .leading, spacing: spacing) {
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
                let picture = automatic ?? selected
                let pictureSize = thumbnailLayout.size(for: window)
                let reason: String? = if !host.configuration.showsWindowThumbnails { "窗口画面已关闭" }
                    else if !pictures { "窗口画面暂不可用" }
                    else if !permitted { nil }
                    else if target == nil || target.map({ gallery?.lacksPicture($0) == true }) == true { "暂无窗口画面" }
                    else { nil }
                Button {
                    if let target { selectWindow(target, snapshot: snapshot, lifetime: lifetime) }
                } label: {
                    DesktopWindowCard(label: label, icon: badge?.icon, image: picture, pictureSize: pictureSize,
                                      unavailableReason: reason, awaitingPicture: permitted,
                                      borderWidth: settings.points(.borderWidth, in: width),
                                      labelSize: settings.readableFontSize(.labelSize, in: display?.referenceHeight ?? 600) ?? 10,
                                      currentImage: {
                        guard let target, display?.interactionVisible == true, display?.id == target.display,
                              !host.configuration.surfaceHidden, host.isRunning, host.configuration.showsWindowThumbnails,
                              WindowContentPreview.sessionAvailable(), target.present(in: overview),
                              previews?.currentDesktop == nil || (lifetime != nil && lifetime == previews?.currentDesktop?.lifetime(of: target.key)) else { return nil }
                        return gallery?.image(for: target, permitted: true) ?? selectedPicture(for: target)
                    })
                }
                .buttonStyle(.plain).disabled(target == nil)
                .accessibilityLabel(label).accessibilityHint("将这扇窗口切换到前台")
                .accessibilityIdentifier("current-desktop-window:\(window.metadata?.pid ?? 0):\(window.metadata?.number ?? 0)")
                .accessibilityValue(cardDescription(window, within: screen, size: pictureSize, index: index,
                    source: automatic != nil ? "窗口画面" : selected != nil ? "所选快照" : "窗口轮廓"))
                .help(target == nil ? "窗口身份或呈现状态尚未确认" : "切换到" + label)
                .onAppear { if let target { gallery?.setCard(target.key, on: id, visible: true) } }
                .onDisappear { if let target { gallery?.setCard(target.key, on: id, visible: false) } }
                .onChange(of: target?.key) { previous, next in
                    if let previous { gallery?.setCard(previous, on: id, visible: false) }
                    if let next { gallery?.setCard(next, on: id, visible: true) }
                }
            }
            if pictures && !permitted {
                Text("显示实时画面需要屏幕录制权限")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本屏窗口，\(windows.count) 扇")
        .task(id: BadgeRefresh(session: snapshot.sessionID, members: windows.map(\.id), visible: visible)) {
            if visible { appBadges = WindowAppBadges.resolve(windows) }
        }
        .task(id: host.bus.desktop?.revision) {
            if let previews, previews.binding?.display == screen.id { await previews.validate(host.bus.desktop) }
        }
        .task(id: run) {
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
        guard let native = snapshot.native, let previews = display?.pointer?.windowPreviews else { return }
        let generation = previews.gallery.generation
        let feed = previews.currentDesktop
        let userInput = NativeSelectionPermit.inputCounters()
        let visibility = previews.visibilityGeneration[target.display]
        func stillCurrent() -> Bool {
            host.isRunning && !host.configuration.surfaceHidden && display?.interactionVisible == true &&
                (feed == nil || (lifetime != nil && feed?.lifetime(of: target.key) == lifetime)) &&
                display?.id == target.display && generation == previews.gallery.generation &&
                visibility == previews.visibilityGeneration[target.display] && target.present(in: overview) &&
                WindowContentPreview.sessionAvailable() && NativeSelectionPermit.inputCounters() == userInput
        }
        guard stillCurrent() else { selectionIssue = "桌面已变化，请重新选择。"; return }
        selectionIssue = nil
        choices.choose(target.key) {
            let verifySpace: (() async -> Bool)? = previews.currentDesktop.map { feed in
                { target.present(in: await feed.readNow()) }
            }
            do {
                if target.overviewSpace == nil, let verifySpace {
                    guard await verifySpace(), stillCurrent() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
                }
                try await DesktopWindowSelection.select(target, deadline: native.beganUptime + 12,
                    verifySpace: verifySpace, stillCurrent: { choices.isLatest(target.key) && stillCurrent() })
            } catch {
                // An explicitly superseded choice must not clear the newer pending click.
                if choices.isLatest(target.key) { throw error }
            }
        } failed: { selectionIssue = $0.localizedDescription }
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
