import AppKit
import NearpaneCore

/// All panels share one Host. Secondary controllers are deliberately constructed without domain modules.
@MainActor public final class DisplayPanels {
    private let host: HostSession, primary: EdgeWindowController
    private let pointer = WorkspacePointerRegistry()
    private var coordinator = MultiDisplayPresentationCoordinator()
    private var secondary = [String: EdgeWindowController]()
    private var suspended = false
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
    public convenience init(host: HostSession, primary: EdgeWindowController, domains: EmbeddedModules? = nil) {
        self.init(host: host, primary: primary, domains: domains, present: { $0.presentIfNeeded() })
    }
    init(host: HostSession, primary: EdgeWindowController, domains: EmbeddedModules? = nil, present: @escaping (EdgeWindowController) -> Void) {
        self.fullscreen = FullscreenPresentation(host: host, domains: domains)
        self.present = present
        self.host = host
        self.primary = primary
        pointer.windowPreviews = domains?.windowPreviews
        primary.usePointer(pointer)
        host.glassPreviewChanged = { [weak self] id in
            self?.primary.refreshGlass(on: id)
            self?.secondary[id]?.refreshGlass(on: id)
        }
    }
    public func request(_ display: String) {
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
        suspended = value
        if value { stopObservingClicks() }
        fullscreen.sessionBoundary(uptime: ProcessInfo.processInfo.systemUptime)
    }
    public func update(screens: [ScreenGeometry], presentingOnly displayID: String? = nil) {
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
        let ordinary = coordinator.resolve(
            screens: screens, preferred: host.configuration.preferredDisplayID,
            settings: host.configuration.displays, demand: demand, hidden: host.configuration.surfaceHidden || suspended,
            voice: prefs.contains { $0.id == BuiltinCatalog.voice && $0.enabled },
            tray: prefs.contains { $0.id == BuiltinCatalog.screenshots && $0.enabled },
            spacesEnabled: prefs.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }, uptime: uptime)
        let ids = Set(ordinary.map(\.id))
        let identified = screens.filter { ids.contains($0.id) }
        fullscreen.updateTopology(identified, uptime: uptime)
        let suppressed = Set(identified.compactMap { screen in
            let witness = fixtureFullscreen?(screen.id)
            return fullscreen.sample(screen: screen, override: witness, now: now, uptime: ProcessInfo.processInfo.systemUptime,
                                     suspended: suspended) ? screen.id : nil
        })
        let plans = ordinary.map { plan in
            suppressed.contains(plan.id) ? DisplaySurfacePlan(id: plan.id, primary: plan.primary, content: .hidden) : plan
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
            fullscreen.present(on: screen, allowed: !suspended && !primary.captureSuppressed)
        } else { fullscreen.hide() }

        func place(_ controller: EdgeWindowController, on screen: ScreenGeometry, plan: DisplaySurfacePlan) {
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
        pendingSpaceOpenings.removeAll()
        stopObservingClicks()
        fullscreen.hide()
        host.updatePanelContents([:])
        primary.removePlacement()
        for panel in secondary.values { panel.removePlacement(); panel.close() }
        secondary.removeAll()
    }
}
