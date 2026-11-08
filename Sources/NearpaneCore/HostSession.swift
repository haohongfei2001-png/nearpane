import Foundation
import Observation

@Observable @MainActor
public final class HostSession {
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
        await refreshDesktop()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        refreshGeneration += 1
        desktopTask?.cancel()
        desktopTask = nil
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
                    desktopTask = nil
                    if enabled {
                        desktopTask = Task { [weak self] in await self?.refreshDesktop() }
                    } else {
                        bus.resetDesktopSession()
                    }
                }
                persistModulePreferences()
            case .setPinned, .move: persistModulePreferences()
            default: break
            }
        }
        return result
    }

    public func setPlacement(edge: SurfaceEdge, displayID: String?) {
        guard isRunning else { return }
        configuration.edge = edge
        configuration.preferredDisplayID = displayID
        save()
    }

    public func setSurfaceHidden(_ hidden: Bool) {
        guard isRunning, configuration.surfaceHidden != hidden else { return }
        configuration.surfaceHidden = hidden
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

    public func refreshDesktop() async {
        guard isRunning, provider.capabilities.observation != .unsupported,
              registry.preferences.contains(where: { $0.id == BuiltinCatalog.desktop && $0.enabled }) else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let snapshot = try await provider.snapshot()
            guard isRunning, generation == refreshGeneration else { return }
            providerFailed = !bus.acceptDesktop(snapshot)
        } catch is CancellationError {
            // Cancellation is lifecycle control, not evidence of an empty desktop.
        } catch {
            guard isRunning, generation == refreshGeneration else { return }
            providerFailed = true
            diagnostics.record(.providerFailed)
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
