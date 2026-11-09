import Foundation
import Observation

public enum DesktopObservationPause: Hashable { case screensAsleep, inactiveSession }

@Observable @MainActor
public final class HostSession {
    public private(set) var workspaceMode = WorkspaceModeCoordinator()
    public private(set) var workspaceIssue: WorkspaceFailure?
    @ObservationIgnored private var workspaceGestures = WorkspaceGestureRouter()
    @ObservationIgnored public var presentationChanged: (() -> Void)?
    public let diagnostics: Diagnostics
    public let bus: SnapshotBus
    public let registry: ModuleRegistry
    public let permissions: MockPermissionBroker
    public let router: InteractionRouter
    public private(set) var configuration = HostConfiguration()
    public private(set) var isRunning = false
    public private(set) var configurationProtected = false
    public private(set) var configurationSaveFailed = false
    public private(set) var providerFailed = false
    public private(set) var lastAction: ActionResult?
    @ObservationIgnored private let store: any ConfigurationStore
    @ObservationIgnored private let provider: any DesktopObservationProvider
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var desktopTask: Task<Void, Never>?
    @ObservationIgnored private var desktopPauses = Set<DesktopObservationPause>()

    public init(store: any ConfigurationStore, provider: (any DesktopObservationProvider)? = nil,
                coreFactories: [String: @MainActor () -> any HostModule] = [:]) {
        let diagnostics = Diagnostics()
        let bus = SnapshotBus(diagnostics: diagnostics)
        let registry = ModuleRegistry(bus: bus, diagnostics: diagnostics)
        let permissions = MockPermissionBroker()
        self.diagnostics = diagnostics; self.bus = bus; self.registry = registry; self.permissions = permissions
        self.router = InteractionRouter(registry: registry, permissions: permissions, bus: bus, diagnostics: diagnostics)
        self.store = store
        self.provider = provider ?? MockDesktopObservationProvider()
        permissions.onRevocation = { [weak registry, weak diagnostics] key in
            registry?.permissionRevoked(key.moduleID)
            diagnostics?.record(.permissionChanged, moduleID: key.moduleID)
        }
        for manifest in BuiltinCatalog.manifests {
            // Static catalog registration failures are programmer errors caught by the catalog tests.
            do {
                try registry.register(manifest) {
                    if manifest.kind == .core, let factory = coreFactories[manifest.id] { return factory() }
                    return SampleModule(message: manifest.kind == .core ? "Domain adapter not connected." : "Synthetic module content. No account or data source is connected.")
                }
            } catch { diagnostics.record(.moduleFailed, moduleID: manifest.id) }
        }
    }

    public func start() async {
        guard !isRunning else { return }
        do {
            configuration = try store.load()
            configurationProtected = false
        } catch {
            configuration = HostConfiguration()
            configurationProtected = true
            diagnostics.record(.configurationReadFailed)
        }
        registry.restore(configuration.modules)
        lastAction = nil
        configurationSaveFailed = false
        registry.startEnabled()
        isRunning = true
        providerFailed = false
        if let mock = provider as? MockDesktopObservationProvider { mock.fixture = configuration.fixture }
        diagnostics.record(.hostStarted)
        if provider is any LiveDesktopObservationProvider { restartDesktopUpdates() }
        else { await refreshDesktop() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        cancelWorkspaceGesture()
        refreshGeneration += 1
        desktopTask?.cancel()
        desktopPauses.removeAll()
        registry.stopAll()
        permissions.resetSession()
        bus.endSession()
        diagnostics.record(.hostStopped)
    }

    @discardableResult
    public func handle(_ action: HostAction, userInitiated: Bool = true) -> ActionResult {
        guard isRunning else { return .rejected(.hostStopped) }
        let result = router.route(action, userInitiated: userInitiated)
        lastAction = result
        if result == .accepted {
            switch action {
            case .setEnabled(let id, let enabled):
                if id == BuiltinCatalog.desktop {
                    refreshGeneration += 1
                    desktopTask?.cancel()
                    bus.resetDesktopSession()
                    if enabled { restartDesktopUpdates() }
                }
                persistModulePreferences()
                presentationChanged?()
            case .setPinned, .move: persistModulePreferences()
            default: break
            }
        }
        return result
    }

    public func setDisplaySettings(_ value: DisplaySettings, id: String) {
        guard isRunning, !configurationProtected, configuration.displays[id] != value else { return }
        var next = configuration
        next.displays[id] = value
        do {
            try store.save(next.validated())
            configuration = next
            configurationSaveFailed = false
            presentationChanged?()
        } catch {
            configurationSaveFailed = true
            diagnostics.record(.configurationWriteFailed)
        }
    }

    public func workspaceSnapshot(primary: String?, now: Date, uptime: Double) -> WorkspaceSnapshot? {
        guard isRunning, !configuration.surfaceHidden, !providerFailed, desktopPauses.isEmpty,
              let snapshot = bus.desktop, workspaceMode.mode == .native else { return nil }
        return NativeSpacesProvider().projection(snapshot, preferredDisplay: primary, settings: configuration.displays,
                                                 edge: configuration.edge, date: now, uptime: uptime)
    }
    public func pressWorkspace(_ row: WorkspaceID, window: ManagedWindowID?, x: Double, y: Double, snapshot: WorkspaceSnapshot) {
        workspaceIssue = nil
        workspaceGestures.down(row: row, window: window, x: x, y: y, snapshot: snapshot)
    }
    public func dragWorkspace(x: Double, y: Double) { workspaceGestures.moved(x: x, y: y) }
    public func cancelWorkspaceGesture() { workspaceGestures.cancel(); workspaceIssue = nil }
    public func releaseWorkspace(on row: WorkspaceID?, x: Double, y: Double, primary: String?, now: Date, uptime: Double) {
        guard let current = workspaceSnapshot(primary: primary, now: now, uptime: uptime) else {
            cancelWorkspaceGesture(); workspaceIssue = .stale; return
        }
        do {
            _ = try workspaceGestures.release(on: row, x: x, y: y, current: current, uptime: uptime,
                                              native: NativeSpacesProvider(), virtual: VirtualWorkspacesProvider())
            invalidateDesktop()
        } catch { workspaceIssue = error as? WorkspaceFailure ?? .unavailable }
    }

    public func setPlacement(edge: SurfaceEdge, displayID: String?) {
        guard isRunning else { return }
        configuration.edge = edge
        configuration.preferredDisplayID = displayID
        save()
    }

    public func setSurfaceHidden(_ hidden: Bool) {
        guard isRunning, configuration.surfaceHidden != hidden else { return }
        cancelWorkspaceGesture()
        configuration.surfaceHidden = hidden
        if provider is any LiveDesktopObservationProvider { invalidateDesktop() }
        save()
    }

    public func selectFixture(_ fixture: DesktopFixture) async {
        guard isRunning else { return }
        configuration.fixture = fixture
        save()
        guard let mock = provider as? MockDesktopObservationProvider else { return }
        mock.fixture = fixture
        await refreshDesktop()
    }

    public func setExperimentalSpaceObservation(_ enabled: Bool) {
        guard isRunning, configuration.experimentalSpaceObservation != enabled else { return }
        configuration.experimentalSpaceObservation = enabled
        save()
        invalidateDesktop()
    }

    /// Discard the prior topology before starting another read. No desktop actions are routed.
    public func invalidateDesktop() {
        guard isRunning, provider is any LiveDesktopObservationProvider else { return }
        refreshGeneration += 1
        desktopTask?.cancel()
        bus.resetDesktopSession()
        cancelWorkspaceGesture()
        presentationChanged?()
        restartDesktopUpdates()
    }

    public func setDesktopPause(_ reason: DesktopObservationPause, paused: Bool) {
        guard isRunning, provider is any LiveDesktopObservationProvider else { return }
        let changed = paused ? desktopPauses.insert(reason).inserted : desktopPauses.remove(reason) != nil
        if changed { invalidateDesktop() }
    }

    public func waitForDesktopStop() async {
        if !isRunning { await desktopTask?.value }
    }

    private func restartDesktopUpdates() {
        let previous = desktopTask
        previous?.cancel()
        let live = provider is any LiveDesktopObservationProvider
        guard isRunning, desktopPauses.isEmpty, !live || !configuration.surfaceHidden,
              registry.preferences.contains(where: { $0.id == BuiltinCatalog.desktop && $0.enabled }) else { return }
        desktopTask = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                await self?.refreshDesktop()
                guard live, self != nil else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    public func refreshDesktop() async {
        guard isRunning, provider.capabilities.observation != .unsupported,
              registry.preferences.contains(where: { $0.id == BuiltinCatalog.desktop && $0.enabled }) else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let snapshot: DesktopSnapshot
            if let live = provider as? any LiveDesktopObservationProvider {
                guard !configuration.surfaceHidden, desktopPauses.isEmpty else { return }
                snapshot = try await live.snapshot(experimentalSpaces: configuration.experimentalSpaceObservation)
            } else { snapshot = try await provider.snapshot() }
            guard isRunning, generation == refreshGeneration else { return }
            providerFailed = !bus.acceptDesktop(snapshot)
            if providerFailed && provider is any LiveDesktopObservationProvider { bus.resetDesktopSession() }
            presentationChanged?()
        } catch is CancellationError {
            // Cancellation is lifecycle control, not evidence of an empty desktop.
        } catch {
            guard isRunning, generation == refreshGeneration else { return }
            providerFailed = true
            if provider is any LiveDesktopObservationProvider { bus.resetDesktopSession() }
            diagnostics.record(.providerFailed)
            presentationChanged?()
        }
    }

    private func save() {
        guard !configurationProtected else { return }
        do { try store.save(configuration); configurationSaveFailed = false }
        catch { configurationSaveFailed = true; diagnostics.record(.configurationWriteFailed) }
    }

    private func persistModulePreferences() {
        configuration.modules = registry.preferences
        save()
    }
}
