import AppKit
import NearpaneCore

/// All panels share one Host. Secondary controllers are deliberately constructed without domain modules.
@MainActor public final class DisplayPanels {
    private let host: HostSession, primary: EdgeWindowController
    private let pointer = WorkspacePointerRegistry()
    private var coordinator = MultiDisplayPresentationCoordinator()
    private var secondary = [String: EdgeWindowController]()
    private var suspended = false
    private let fullscreen: FullscreenPresentation
    public var refresh: (() -> Void)? {
        didSet { fullscreen.refresh = refresh; primary.exposureDidChange = refresh }
    }
    /// Set only by the executable-bound secondary acceptance Host.
    public var fixtureFullscreen: ((String) -> FullscreenDisplaySample?)?
    public var managementChanged: ((String, String, Double?) -> Void)? {
        didSet { fullscreen.management = managementChanged }
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
        primary.usePointer(pointer)
    }
    public func request(_ display: String) {
        coordinator.request(display)
        setDismissed(false, on: display)
    }
    public func dismiss(_ display: String) {
        coordinator.dismiss(display)
        setDismissed(true, on: display)
    }
    private func setDismissed(_ value: Bool, on display: String) {
        var settings = host.configuration.displays[display] ?? .init()
        guard settings.spacesDismissed != value else { return }
        settings.spacesDismissed = value
        host.setDisplaySettings(settings, id: display)
    }
    public func setSuspended(_ value: Bool) { suspended = value; if value { fullscreen.hide() } }
    public func update(screens: [ScreenGeometry], presentingOnly displayID: String? = nil) {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let prefs = host.registry.preferences
        var demand = [String: DisplayDemand]()
        for screen in screens {
            demand[screen.id] = host.bus.desktop?.presentationDemand(for: screen.id, now: now, uptime: uptime) ?? .init()
        }
        fullscreen.retain(displays: Set(screens.map(\.id)))
        let suppressed = Set(screens.compactMap { screen in
            fullscreen.sample(screen: screen, override: fixtureFullscreen?(screen.id), now: now, uptime: uptime,
                              suspended: suspended) ? screen.id : nil
        })
        let ordinary = coordinator.resolve(
            screens: screens, preferred: host.configuration.preferredDisplayID,
            settings: host.configuration.displays, demand: demand, hidden: host.configuration.surfaceHidden || suspended,
            voice: prefs.contains { $0.id == BuiltinCatalog.voice && $0.enabled },
            tray: prefs.contains { $0.id == BuiltinCatalog.screenshots && $0.enabled },
            spacesEnabled: prefs.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }, uptime: uptime)
        let plans = ordinary.map { plan in
            suppressed.contains(plan.id) ? DisplaySurfacePlan(id: plan.id, primary: plan.primary, content: .hidden) : plan
        }
        host.updatePanelContents(Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0.content) }))
        // Resolve roles in the real topology even when an isolated trial may present on only one display.
        let visiblePlans = plans.filter { displayID == nil || $0.id == displayID }
        let ids = Set(visiblePlans.filter { !$0.primary && $0.content != .hidden }.map(\.id))
        for id in Array(secondary.keys) where !ids.contains(id) { secondary.removeValue(forKey: id)?.close() }
        guard let main = plans.first(where: \.primary) else {
            primary.place(screens: []); fullscreen.hide()
            return
        }
        if let displayID, main.id != displayID { primary.place(screens: []) }
        for plan in visiblePlans where plan.primary || ids.contains(plan.id) {
            guard let screen = screens.first(where: { $0.id == plan.id }) else { continue }
            let controller: EdgeWindowController
            if plan.primary {
                controller = primary
            } else if let panel = secondary[plan.id] {
                controller = panel
            } else {
                controller = EdgeWindowController(host: host)
                if displayID != nil { controller.window?.ignoresMouseEvents = true }
                controller.usePointer(pointer)
                secondary[plan.id] = controller
            }
            controller.place(on: screen, primary: main.id, content: plan.content)
            present(controller)
        }
        if let screen = screens.first(where: { $0.id == main.id }),
           displayID == nil || main.id == displayID {
            fullscreen.present(on: screen, allowed: !suspended && !primary.captureSuppressed)
        } else { fullscreen.hide() }
    }
    public func stop() {
        fullscreen.hide()
        host.updatePanelContents([:])
        primary.hide()
        for panel in secondary.values { panel.close() }
        secondary.removeAll()
    }
}
