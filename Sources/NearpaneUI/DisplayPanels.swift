import AppKit
import NearpaneCore

/// All panels share one Host. Secondary controllers are deliberately constructed without domain modules.
@MainActor public final class DisplayPanels {
    private let host: HostSession, primary: EdgeWindowController
    private let pointer = WorkspacePointerRegistry()
    private var coordinator = MultiDisplayPresentationCoordinator()
    private var secondary = [String: EdgeWindowController]()
    private var suspended = false
    public private(set) var systemManagesWindows = false
    private let navigation: NativeSidebarNavigation
    private weak var workRect: CandidateWorkRect?
    private weak var domains: EmbeddedModules?
    private var missionControl: MissionControlVisibility
    private let missionControlReader: MissionControlVisibilityReader?
    private var stageMonitor: Timer?
    private var wallpaperMonitor: WallpaperRevealMonitor?
    private var wallpaperHeld = false
    private var wallpaperAwaitingOrdinary = false
    enum StageDisposition: Equatable { case ordinary, wallpaper, system }
    private(set) var stageDisposition: StageDisposition = .ordinary
    private var occlusionMonitor: NSObjectProtocol?
    private var spaceMonitor: NSObjectProtocol?
    private var sampleGeneration = UUID()
    private var sampleBegan: TimeInterval?
    private var stopped = false

    /// Login/session and system overview ownership only. An explicit command can reopen a hidden sidebar.
    public var windowDispatchEligible: Bool {
        !stopped && !suspended && !systemManagesWindows && !wallpaperHeld && !wallpaperAwaitingOrdinary && missionControl == .ordinary
    }
    public var missionControlDispatchState: String { missionControl.rawValue }
    /// Fixed reason only, including incomplete reads on other macOS builds.
    public private(set) var missionControlDispatchEvidence = "waitingForDock"
    public private(set) var missionControlReadInterval: (start: TimeInterval, end: TimeInterval)?

    /// Read the same Dock witness used for dispatch, without publishing state or resuming any windows.
    public func observeMissionControl() async -> (mode: Int, evidence: String, start: TimeInterval, end: TimeInterval)? {
        guard !stopped, !suspended, let missionControlReader else { return nil }
        let generation = sampleGeneration
        let sample = await missionControlReader.read()
        guard !stopped, !suspended, generation == sampleGeneration else { return nil }
        let mode = sample.visibility == .ordinary ? 0 : sample.visibility == .exposed ? 1 : -1
        return (mode, sample.evidence, sample.startUptime, sample.endUptime)
    }

    private var localMouse: Any?, externalMouse: Any?
    private var clickLease: UUID?
    private var pendingSpaceOpenings = Set<String>()
    private var observedTransientWindows = Set<ObjectIdentifier>()
    private let fullscreen: FullscreenPresentation
    public var refresh: (() -> Void)? {
        didSet { fullscreen.refresh = refresh; primary.exposureDidChange = refresh }
    }
    /// Set only by the executable-bound secondary acceptance Host.
    public var fixtureFullscreen: ((String) -> FullscreenDisplaySample?)?
    public var managementChanged: ((String, String, Double?) -> Void)? {
        didSet { fullscreen.management = managementChanged }
    }
    public var topologyChanged: ((Set<String>) -> Void)? {
        didSet { fullscreen.topologyChanged = topologyChanged }
    }
    private let present: (EdgeWindowController) -> Void
    var secondaryIDs: Set<String> { Set(secondary.keys) }
    isolated deinit {
        if let spaceMonitor { NSWorkspace.shared.notificationCenter.removeObserver(spaceMonitor) }
    }
    public convenience init(host: HostSession, primary: EdgeWindowController, domains: EmbeddedModules? = nil) {
        self.init(host: host, primary: primary, domains: domains, navigation: .shared, missionControlReader: .init(), present: { $0.presentIfNeeded() })
        wallpaperMonitor = WallpaperRevealMonitor { [weak self] held in
            self?.setWallpaperHeld(held)
        }
        pollSystemOwnership()
        occlusionMonitor = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let source = note.object as? NSWindow else { return }
            let id = ObjectIdentifier(source)
            MainActor.assumeIsolated { self?.panelOcclusionChanged(id) }
        }
        spaceMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.nativeDesktopChanged() } }
        // The panel may be entirely withdrawn when Stage Manager owns the display.
        // Observe the preference independently of the gallery, without prompting or writing it.
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSystemOwnership() }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        stageMonitor = timer
    }
    init(host: HostSession, primary: EdgeWindowController, domains: EmbeddedModules? = nil,
         navigation: NativeSidebarNavigation = .init(), missionControlReader: MissionControlVisibilityReader? = nil,
         present: @escaping (EdgeWindowController) -> Void) {
        self.navigation = navigation
        self.workRect = domains?.workRect
        self.domains = domains
        self.missionControlReader = missionControlReader
        missionControl = missionControlReader == nil ? .ordinary : .unknown
        self.fullscreen = FullscreenPresentation(host: host, domains: domains)
        self.present = present
        self.host = host
        self.primary = primary
        pointer.navigation = navigation
        pointer.windowPreviews = domains?.windowPreviews
        navigation.stageOwnsWindowDispatch = { [weak feed = domains?.windowPreviews.currentDesktop] in
            feed?.stageEngine.holdsDispatch == true
        }
        pointer.windowPreviews?.currentDesktop?.splitPresentationChanged = { [weak self] in self?.refresh?() }
        primary.usePointer(pointer)
        #if canImport(NearpaneLyricsModule)
        domains?.lyrics?.heightDidChange = { [weak self] in self?.refresh?() }
        #endif
        if missionControlReader != nil {
            navigation.confirmDispatch = { [weak self] in await self?.confirmWindowDispatch() == true }
            workRect?.desktopTiling.confirmDispatch = { [weak self] in await self?.confirmWindowDispatch() == true }
        }
        navigation.setDispatchAvailable(windowDispatchEligible)
        workRect?.setOrdinaryHold("systemWindowDispatch", active: !windowDispatchEligible)
        host.glassPreviewChanged = { [weak self] id in
            self?.primary.refreshGlass(on: id)
            self?.secondary[id]?.refreshGlass(on: id)
        }
    }
    private func panelOcclusionChanged(_ id: ObjectIdentifier) {
        guard !suspended, !stopped else { return }
        let windows = [primary.window] + secondary.values.map(\.window)
        guard let window = windows.compactMap({ $0 }).first(where: { ObjectIdentifier($0) == id }),
              window.isVisible, !window.occlusionState.contains(.visible) else { return }
        // Ordinary occlusion also causes this notification. Re-read the Dock;
        // occlusion by itself never identifies Mission Control.
        invalidateObservation()
        pollSystemOwnership()
    }

    func setSystemManagesWindows(_ value: Bool) {
        guard value != systemManagesWindows else { return }
        let previous = windowDispatchEligible
        systemManagesWindows = value
        if value { clearWallpaperTracking() }
        sampleGeneration = UUID()
        missionControl = .unknown
        missionControlDispatchEvidence = "waitingForDock"
        missionControlReadInterval = nil
        publishOwnership(previous: previous)
    }

    /// Shared with the observational wallpaper monitor; this never sends input or
    /// changes the native desktop preference. An unknown Dock read cannot create it.
    func setWallpaperHeld(_ held: Bool) {
        guard !stopped, wallpaperHeld != held else { return }
        let previous = windowDispatchEligible
        wallpaperHeld = held
        wallpaperAwaitingOrdinary = !held
        sampleGeneration = UUID()
        if !held {
            missionControl = .unknown
            missionControlDispatchEvidence = "wallpaperRestoredAwaitingOrdinaryRead"
            missionControlReadInterval = nil
            pointer.windowPreviews?.currentDesktop?.changed()
        }
        publishOwnership(previous: previous)
    }

    private func clearWallpaperTracking() {
        wallpaperHeld = false
        wallpaperAwaitingOrdinary = false
        wallpaperMonitor?.reset()
    }

    func nativeDesktopChanged() {
        guard !stopped else { return }
        let previous = windowDispatchEligible
        clearWallpaperTracking()
        sampleGeneration = UUID()
        missionControl = .unknown
        missionControlDispatchEvidence = "desktopChangedAwaitingOrdinaryRead"
        missionControlReadInterval = nil
        publishOwnership(previous: previous)
    }

    func setMissionControl(_ value: MissionControlVisibility, evidence: String? = nil,
                           interval: (TimeInterval, TimeInterval)? = nil) {
        guard !stopped, !suspended else { return }
        missionControlReadInterval = interval
        if let evidence { missionControlDispatchEvidence = evidence }
        guard missionControl != value else { return }
        let previous = windowDispatchEligible
        missionControl = value
        if value == .exposed { clearWallpaperTracking() }
        if value == .ordinary { wallpaperAwaitingOrdinary = false }
        sampleGeneration = UUID()
        publishOwnership(previous: previous)
    }

    /// Recheck the signed Dock at the point an explicit window command or automatic layout is admitted.
    /// The monitor alone may still describe the last ordinary desktop just as an overview opens.
    public func confirmWindowDispatch() async -> Bool {
        guard let missionControlReader else { return windowDispatchEligible }
        setSystemManagesWindows(StageManagerPreference.ownsWindowDispatch)
        guard windowDispatchEligible else { return false }
        let generation = sampleGeneration
        let requestUptime = ProcessInfo.processInfo.systemUptime
        let value = await missionControlReader.read()
        IndependentStageTrace.record("dispatch-dock-confirmation-read", [
            "visibility": value.visibility.rawValue, "evidence": value.evidence,
            "readStart": value.startUptime, "readEnd": value.endUptime,
            "requestMilliseconds": (ProcessInfo.processInfo.systemUptime - requestUptime) * 1000,
            "sameGeneration": generation == sampleGeneration,
            "eligibleBeforeAccept": windowDispatchEligible])
        guard generation == sampleGeneration, windowDispatchEligible else { return false }
        setSystemManagesWindows(StageManagerPreference.ownsWindowDispatch)
        acceptMissionControl(value, requestedAt: requestUptime)
        return windowDispatchEligible && generation == sampleGeneration
    }

    static func missionControlReadIsFresh(start: TimeInterval, end: TimeInterval, now: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && now.isFinite && start <= end && end <= now && now - start <= 0.75
    }

    func acceptMissionControl(_ sample: MissionControlVisibilityReader.Reading, requestedAt: TimeInterval,
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Actor/main-queue wait is not the age of a later physical observation.
        // The entire interval from actual sampling start to acceptance stays bounded.
        if Self.missionControlReadIsFresh(start: sample.startUptime, end: sample.endUptime, now: now) {
            if now - requestedAt > 0.75 {
                IndependentStageTrace.record("dispatch-dock-read-accepted-after-queue", [
                    "requestStart": requestedAt, "requestMilliseconds": (now - requestedAt) * 1000,
                    "readStart": sample.startUptime, "readEnd": sample.endUptime,
                    "readAgeMilliseconds": (now - sample.endUptime) * 1000,
                    "readTotalMilliseconds": (now - sample.startUptime) * 1000])
            }
            setMissionControl(sample.visibility, evidence: sample.evidence, interval: (sample.startUptime, sample.endUptime))
        } else {
            IndependentStageTrace.record("dispatch-dock-read-expired", [
                "visibility": sample.visibility.rawValue, "evidence": sample.evidence,
                "requestStart": requestedAt, "requestMilliseconds": (now - requestedAt) * 1000,
                "readStart": sample.startUptime, "readEnd": sample.endUptime,
                "readDurationMilliseconds": (sample.endUptime - sample.startUptime) * 1000,
                "readAgeMilliseconds": (now - sample.endUptime) * 1000])
            setMissionControl(.unknown, evidence: "sampleExpired")
        }
    }

    private func invalidateObservation() {
        sampleGeneration = UUID()
        setMissionControl(.unknown, evidence: "panelOcclusionChanged")
    }

    private func pollSystemOwnership() {
        guard !stopped, let missionControlReader else { return }
        setSystemManagesWindows(StageManagerPreference.ownsWindowDispatch)
        guard !suspended else { return }
        wallpaperMonitor?.poll()
        if let sampleBegan {
            let now = ProcessInfo.processInfo.systemUptime
            if let interval = missionControlReadInterval,
               !Self.missionControlReadIsFresh(start: interval.start, end: interval.end, now: now) {
                IndependentStageTrace.record("dispatch-dock-observation-expired", [
                    "pendingRequestStart": sampleBegan, "readStart": interval.start, "readEnd": interval.end,
                    "readTotalMilliseconds": (now - interval.start) * 1000])
                setMissionControl(.unknown, evidence: "sampleExpired")
            }
            return
        }
        let generation = sampleGeneration
        sampleBegan = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let value = await missionControlReader.read()
            guard let self else { return }
            let started = sampleBegan
            sampleBegan = nil
            guard generation == sampleGeneration, !stopped else { return }
            setSystemManagesWindows(StageManagerPreference.ownsWindowDispatch)
            if let started { acceptMissionControl(value, requestedAt: started) }
        }
    }

    private func publishOwnership(previous: Bool) {
        let eligible = windowDispatchEligible
        let disposition: StageDisposition
        if stopped || suspended || systemManagesWindows || missionControl == .exposed { disposition = .system }
        else if wallpaperHeld || wallpaperAwaitingOrdinary { disposition = .wallpaper }
        else if missionControl == .ordinary { disposition = .ordinary }
        else { disposition = .system }
        let dispositionChanged = stageDisposition != disposition
        stageDisposition = disposition
        if previous != eligible || dispositionChanged {
            IndependentStageTrace.record("system-window-ownership", ["previousEligible": previous,
                "eligible": eligible, "disposition": String(describing: disposition),
                "missionControl": missionControl.rawValue, "evidence": missionControlDispatchEvidence,
                "stopped": stopped, "suspended": suspended, "systemManagesWindows": systemManagesWindows,
                "wallpaperHeld": wallpaperHeld, "wallpaperAwaitingOrdinary": wallpaperAwaitingOrdinary,
                "readStart": missionControlReadInterval?.start as Any? ?? NSNull(),
                "readEnd": missionControlReadInterval?.end as Any? ?? NSNull()])
        }
        let stage = pointer.windowPreviews?.currentDesktop?.stageEngine
        if dispositionChanged {
            switch disposition {
            case .wallpaper: stage?.setWallpaperHeld(true)
            case .system: stage?.systemTakesOver()
            case .ordinary: break
            }
        }
        if previous != eligible {
            navigation.setDispatchAvailable(eligible)
            workRect?.setOrdinaryHold("systemWindowDispatch", active: !eligible)
            if !eligible {
                for id in pendingSpaceOpenings.union(host.panelContents.keys) { coordinator.finishRequest(id) }
                pendingSpaceOpenings.removeAll()
                primary.cancelWindowDispatchGesture()
                for controller in secondary.values { controller.cancelWindowDispatchGesture() }
                host.cancelWorkspaceGesture()
                if let previews = pointer.windowPreviews {
                    if !stopped && !suspended && !systemManagesWindows && !host.configuration.surfaceHidden &&
                        host.configuration.showsWindowThumbnails {
                        let screens = Set(host.panelContents.keys).union(previews.visibleDisplays)
                        previews.setSystemCoverage(screens, eligible: screens)
                    } else { previews.setSystemCoverage([], eligible: []) }
                    for id in previews.visibleDisplays { previews.setVisible(false, on: id) }
                }
                stopObservingClicks()
            }
        }
        if eligible {
            if dispositionChanged { stage?.setWallpaperHeld(false) }
            stage?.ordinaryContextObserved()
        }
        if !stopped { refresh?() }
    }

    public func request(_ display: String) {
        guard windowDispatchEligible else { return }
        pendingSpaceOpenings.insert(display)
        coordinator.request(display)
        setDismissed(false, on: display)
    }
    public func dismiss(_ display: String) {
        pendingSpaceOpenings.remove(display)
        coordinator.dismiss(display)
        setDismissed(true, on: display)
    }
    private func setDismissed(_ value: Bool, on display: String) {
        var settings = host.configuration.displays[display] ?? .init()
        guard settings.spacesDismissed != value else { return }
        settings.spacesDismissed = value
        host.setDisplaySettings(settings, id: display)
    }
    public func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        let previous = windowDispatchEligible
        suspended = value
        if value { clearWallpaperTracking() }
        if missionControlReader != nil {
            sampleGeneration = UUID(); missionControl = .unknown
            missionControlDispatchEvidence = value ? "sessionSuspended" : "waitingForDock"
            missionControlReadInterval = nil
        }
        fullscreen.sessionBoundary(uptime: ProcessInfo.processInfo.systemUptime)
        publishOwnership(previous: previous)
    }
    public func update(screens: [ScreenGeometry], presentingOnly displayID: String? = nil) {
        guard !stopped else { return }
        // A click may unfold the panel once. Later observation ticks must leave it
        // folded if the user subsequently closes the temporary expansion.
        let explicitOpenings = pendingSpaceOpenings
        pendingSpaceOpenings.removeAll()
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let prefs = host.registry.preferences
        var demand = [String: DisplayDemand]()
        for screen in screens {
            demand[screen.id] = host.bus.desktop?.presentationDemand(for: screen.id, now: now, uptime: uptime) ?? .init()
        }
        let canDispatch = windowDispatchEligible && !host.configuration.surfaceHidden &&
            prefs.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }
        let feed = pointer.windowPreviews?.currentDesktop
        let fullscreenHint = demand.values.contains { $0.blocked }
        feed?.configureSplitObservation(allowed: canDispatch, fullscreenHint: canDispatch && fullscreenHint)
        let paired = canDispatch ? feed?.pairedDisplays ?? [] : []
        for id in paired {
            // The fullscreen management hold still applies. Only the read-only surface
            // may be presented for two positively identified, system-managed panes.
            demand[id] = DisplayDemand(spaces: 1, windows: 2, blocked: false, complete: true)
            demand[id]?.hasCurrentDesktopWindows = true
        }
        let lyricsActive = (domains?.lyricsHeight ?? 0) > 0 && prefs.contains { $0.id == BuiltinCatalog.lyrics && $0.enabled }
        let auxiliaryTools = prefs.contains { $0.enabled && ($0.id == BuiltinCatalog.memo || $0.id == BuiltinCatalog.tasks || $0.id == BuiltinCatalog.clock) }
            || !host.registry.pinnedModules.isEmpty
        let ordinary = coordinator.resolve(
            screens: screens, preferred: host.configuration.preferredDisplayID,
            settings: host.configuration.displays, demand: demand, hidden: host.configuration.surfaceHidden || suspended,
            voice: prefs.contains { $0.id == BuiltinCatalog.voice && $0.enabled },
            tray: prefs.contains { $0.id == BuiltinCatalog.screenshots && $0.enabled }, lyrics: lyricsActive,
            auxiliaryTools: auxiliaryTools,
            spacesEnabled: prefs.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }, uptime: uptime)
        let ids = Set(ordinary.map(\.id))
        let identified = screens.filter { ids.contains($0.id) }
        fullscreen.updateTopology(identified, uptime: uptime)
        let suppressed = Set(identified.compactMap { screen in
            let witness = fixtureFullscreen?(screen.id)
            return fullscreen.sample(screen: screen, override: witness, now: now, uptime: ProcessInfo.processInfo.systemUptime,
                                     suspended: suspended) ? screen.id : nil
        })
        let hasTools = prefs.contains { $0.enabled && BuiltinCatalog.sidebarTools.contains($0.id) && ($0.id != BuiltinCatalog.lyrics || lyricsActive) } || !host.registry.pinnedModules.isEmpty
        let plans = ordinary.map { plan -> DisplaySurfacePlan in
            let content: PanelContent
            if paired.contains(plan.id) {
                content = plan.content == .full || plan.content == .spacesOnly ? .spacesOnly : .hidden
            } else if suppressed.contains(plan.id) || suspended || host.configuration.surfaceHidden { content = .hidden }
            else if missionControl == .exposed { content = .hidden }
            else if !windowDispatchEligible {
                content = plan.primary && hasTools && demand[plan.id]?.blocked != true ? .toolsOnly : .hidden
            } else { return plan }
            return DisplaySurfacePlan(id: plan.id, primary: plan.primary, content: content)
        }
        if let previews = pointer.windowPreviews {
            let allowsPictures = !stopped && !suspended && !systemManagesWindows && !host.configuration.surfaceHidden &&
                host.configuration.showsWindowThumbnails && !primary.captureSuppressed &&
                prefs.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }
            let eligible = Set(plans.filter {
                allowsPictures && host.configuration.displays[$0.id]?.spacesDismissed != true
            }.map(\.id))
            let covered = Set(plans.filter {
                suppressed.contains($0.id) || demand[$0.id]?.blocked == true || !windowDispatchEligible ||
                    (!$0.primary && $0.content == .hidden)
            }.map(\.id))
            previews.setSystemCoverage(covered, eligible: eligible)
        }
        host.updatePanelContents(Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0.content) }))
        // Resolve roles in the real topology even when an isolated trial may present on only one display.
        let visiblePlans = plans.filter { displayID == nil || $0.id == displayID }
        let spacesPlans = visiblePlans.filter { !$0.primary && $0.content != .hidden }
        let spaceIDs = Set(spacesPlans.map(\.id))
        for id in Array(secondary.keys) where !spaceIDs.contains(id) {
            let panel = secondary.removeValue(forKey: id)
            panel?.removePlacement()
            panel?.close()
        }
        guard let main = plans.first(where: \.primary) else {
            stopObservingClicks()
            primary.removePlacement(); fullscreen.hide()
            return
        }
        // Withdraw or move the unique domain panel before its old display presents a Space-only panel.
        if visiblePlans.contains(main), main.content != .hidden,
           let screen = identified.first(where: { $0.id == main.id }) {
            place(primary, on: screen, plan: main)
        } else { primary.removePlacement() }
        for plan in spacesPlans {
            guard let screen = identified.first(where: { $0.id == plan.id }) else { continue }
            let controller: EdgeWindowController
            if let panel = secondary[plan.id] {
                controller = panel
            } else {
                controller = EdgeWindowController(host: host)
                if displayID != nil { controller.window?.ignoresMouseEvents = true }
                controller.usePointer(pointer)
                secondary[plan.id] = controller
            }
            place(controller, on: screen, plan: plan)
        }
        observeClicksIfNeeded()
        if let screen = screens.first(where: { $0.id == main.id }),
           displayID == nil || main.id == displayID {
            fullscreen.present(on: screen, allowed: !suspended && missionControl != .exposed && !paired.contains(screen.id) && !primary.captureSuppressed)
        } else { fullscreen.hide() }

        func place(_ controller: EdgeWindowController, on screen: ScreenGeometry, plan: DisplaySurfacePlan) {
            controller.presentInSplitView(paired.contains(screen.id))
            controller.place(on: screen, primary: main.id, content: plan.content)
            if explicitOpenings.contains(screen.id), plan.content == .full || plan.content == .spacesOnly,
               !controller.temporarilyExpanded {
                controller.toggleTemporaryExpansion()
            }
            present(controller)
        }
    }
    // Observe mouse-down only while an on-demand destination is actually shown.
    // The external handler never reads a click location, window name or owning app.
    private var transientPanels: [String: EdgeWindowController] {
        secondary.filter { (host.configuration.displays[$0.key]?.policy ?? .onDemand) == .onDemand }
    }

    private func observeClicksIfNeeded() {
        let shown = Set(transientPanels.values.compactMap { panel in
            panel.window.flatMap { $0.isVisible && !$0.ignoresMouseEvents ? ObjectIdentifier($0) : nil }
        })
        guard shown != observedTransientWindows else { return }
        stopObservingClicks()
        guard !shown.isEmpty else { return }
        observedTransientWindows = shown
        let lease = UUID()
        clickLease = lease
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
            if self?.clickLease == lease { self?.finishRequests(outside: event.window) }
            return event
        }
        externalMouse = NSEvent.addGlobalMonitorForEvents(matching: presses) { [weak self] _ in
            if self?.clickLease == lease { self?.finishRequests(outside: nil) }
        }
    }

    func finishRequests(outside clicked: NSWindow?) {
        var changed = false
        for (id, panel) in transientPanels where clicked == nil || panel.window !== clicked {
            if coordinator.finishRequest(id) { changed = true }
        }
        if changed { refresh?() }
    }

    private func stopObservingClicks() {
        clickLease = nil
        observedTransientWindows.removeAll()
        if let localMouse { NSEvent.removeMonitor(localMouse); self.localMouse = nil }
        if let externalMouse { NSEvent.removeMonitor(externalMouse); self.externalMouse = nil }
    }

    public func stop() {
        guard !stopped else { return }
        let previous = windowDispatchEligible
        stopped = true
        publishOwnership(previous: previous)
        if let occlusionMonitor { NotificationCenter.default.removeObserver(occlusionMonitor); self.occlusionMonitor = nil }
        if let spaceMonitor { NSWorkspace.shared.notificationCenter.removeObserver(spaceMonitor); self.spaceMonitor = nil }
        stageMonitor?.invalidate(); stageMonitor = nil
        wallpaperMonitor?.stop(); wallpaperMonitor = nil
        pointer.windowPreviews?.currentDesktop?.configureSplitObservation(allowed: false, fullscreenHint: false)
        pendingSpaceOpenings.removeAll()
        stopObservingClicks()
        fullscreen.hide()
        host.updatePanelContents([:])
        primary.removePlacement()
        for panel in secondary.values { panel.removePlacement(); panel.close() }
        secondary.removeAll()
    }
}
