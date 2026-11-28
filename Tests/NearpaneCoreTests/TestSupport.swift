import Foundation
@testable import NearpaneCore

enum SampleFailure: Error { case injected }

@MainActor
final class TrackingModule: HostModule {
    enum Failure { case start, action, snapshot, resume }
    var failure: Failure?
    var starts = 0
    var stops = 0
    var suspends = 0
    var resumes = 0
    var actions = 0
    init(failure: Failure? = nil) { self.failure = failure }
    func start() throws { starts += 1; if failure == .start { throw SampleFailure.injected } }
    func stop() { stops += 1 }
    func suspend() { suspends += 1 }
    func resume() throws { resumes += 1; if failure == .resume { throw SampleFailure.injected } }
    func perform(_ action: ModuleAction) throws { if failure == .action { throw SampleFailure.injected }; actions += 1 }
    func snapshot() throws -> ModuleProjection {
        if failure == .snapshot { throw SampleFailure.injected }
        return ModuleProjection(message: "synthetic", refreshCount: actions)
    }
}

@MainActor
struct RegistryHarness {
    let diagnostics = Diagnostics()
    let bus: SnapshotBus
    let registry: ModuleRegistry
    let broker = MockPermissionBroker()
    let router: InteractionRouter

    init() {
        bus = SnapshotBus(diagnostics: diagnostics)
        registry = ModuleRegistry(bus: bus, diagnostics: diagnostics)
        router = InteractionRouter(registry: registry, permissions: broker, bus: bus, diagnostics: diagnostics)
    }

    func add(_ id: String, module: TrackingModule = TrackingModule(), kind: ModuleKind = .builtin,
             permissions: Set<HostPermission> = []) throws {
        try registry.register(ModuleManifest(id: id, name: "Test sample", symbol: "circle", kind: kind,
                                              permissions: permissions, actions: [.refresh: permissions])) { module }
    }
}
