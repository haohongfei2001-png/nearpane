import Foundation
import Observation

public enum ModuleKind: String, Sendable { case core, builtin }
public enum ModuleState: String, Sendable {
    case available, enabling, permissionRequired, resident, expanded, suspended, degraded, disabled
}
public enum ModuleAction: String, Hashable, Sendable { case refresh }
public enum HostPermission: String, CaseIterable, Hashable, Sendable { case calendarRead, location }

public struct ModuleManifest: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbol: String
    public let kind: ModuleKind
    public let version: Int
    public let minimumHostVersion: Int
    public let permissions: Set<HostPermission>
    public let actions: [ModuleAction: Set<HostPermission>]

    public init(id: String, name: String, symbol: String, kind: ModuleKind = .builtin,
                version: Int = 1, minimumHostVersion: Int = 1,
                permissions: Set<HostPermission> = [], actions: [ModuleAction: Set<HostPermission>] = [.refresh: []]) {
        self.id = id; self.name = name; self.symbol = symbol; self.kind = kind
        self.version = version; self.minimumHostVersion = minimumHostVersion
        self.permissions = permissions; self.actions = actions
    }
}

public enum BuiltinCatalog {
    public static let voice = "com.holdsnow.nearpane.saytile"
    public static let screenshots = "com.holdsnow.nearpane.riftlet"
    public static let desktop = "com.holdsnow.nearpane.desktop"
    public static let notes = "com.holdsnow.nearpane.notes-sample"
    public static let clock = "com.holdsnow.nearpane.clock-sample"
    public static let calendar = "com.holdsnow.nearpane.calendar-sample"
    public static let manifests: [ModuleManifest] = [
        .init(id: voice, name: "Saytile placeholder", symbol: "mic.slash", kind: .core, actions: [:]),
        .init(id: screenshots, name: "Riftlet placeholder", symbol: "photo", kind: .core, actions: [:]),
        .init(id: desktop, name: "Desktop mock", symbol: "rectangle.on.rectangle", kind: .core, actions: [:]),
        .init(id: notes, name: "Notes sample", symbol: "note.text"),
        .init(id: clock, name: "Clock sample", symbol: "clock"),
        .init(id: "com.holdsnow.nearpane.tasks-sample", name: "Tasks sample", symbol: "checklist"),
        .init(id: calendar, name: "Calendar sample", symbol: "calendar", permissions: [.calendarRead], actions: [.refresh: [.calendarRead]]),
        .init(id: "com.holdsnow.nearpane.weather-sample", name: "Weather sample", symbol: "cloud.sun")
    ]
}

/// Trusted, bundled adapters only. Throwing failures are isolated; process crashes require a future helper/XPC boundary.
@MainActor
public protocol HostModule: AnyObject {
    func start() throws
    func stop()
    func suspend()
    func resume() throws
    func perform(_ action: ModuleAction) throws
    func snapshot() throws -> ModuleProjection
}

@MainActor
public final class SampleModule: HostModule {
    private let message: String
    private var refreshCount = 0
    public init(message: String) { self.message = message }
    public func start() throws {}
    public func stop() {}
    public func suspend() {}
    public func resume() throws {}
    public func perform(_ action: ModuleAction) throws { refreshCount += 1 }
    public func snapshot() throws -> ModuleProjection { ModuleProjection(message: message, refreshCount: refreshCount) }
}

public enum RegistryError: Error, Equatable {
    case duplicateID, incompatibleManifest, unknownModule, coreOrderLocked, notRunning, unsupportedAction
}

@Observable @MainActor
public final class ModuleRegistry {
    public private(set) var manifests: [ModuleManifest] = []
    public private(set) var preferences: [ModulePreference] = []
    public private(set) var states: [String: ModuleState] = [:]
    public private(set) var expandedID: String?
    @ObservationIgnored private var factories: [String: () -> any HostModule] = [:]
    @ObservationIgnored private var runtimes: [String: any HostModule] = [:]
    @ObservationIgnored private var instances: [String: UUID] = [:]
    @ObservationIgnored private var revisions: [String: UInt64] = [:]
    private let bus: SnapshotBus
    private let diagnostics: Diagnostics

    public init(bus: SnapshotBus, diagnostics: Diagnostics) { self.bus = bus; self.diagnostics = diagnostics }

    public func register(_ manifest: ModuleManifest, factory: @escaping () -> any HostModule) throws {
        guard factories[manifest.id] == nil else { throw RegistryError.duplicateID }
        guard !manifest.id.isEmpty, manifest.version > 0, manifest.minimumHostVersion <= 1,
              manifest.actions.values.allSatisfy({ $0.isSubset(of: manifest.permissions) }) else {
            throw RegistryError.incompatibleManifest
        }
        manifests.append(manifest)
        factories[manifest.id] = factory
        preferences.append(ModulePreference(id: manifest.id, enabled: manifest.kind == .core))
        states[manifest.id] = .available
    }

    public func restore(_ saved: [ModulePreference]) {
        let catalog = manifests.map { ModulePreference(id: $0.id, enabled: $0.kind == .core) }
        let known = Set(catalog.map(\.id))
        var seen: Set<String> = []
        let restored = saved.filter { known.contains($0.id) && seen.insert($0.id).inserted }
        let coreIDs = manifests.filter { $0.kind == .core }.map(\.id)
        let merged = restored + catalog.filter { !seen.contains($0.id) }
        preferences = coreIDs.compactMap { id in merged.first { $0.id == id } }
            + merged.filter { !coreIDs.contains($0.id) }
        for pref in preferences { states[pref.id] = pref.enabled ? .available : .disabled }
    }

    public var pinnedModules: [ModuleManifest] {
        preferences.filter { $0.enabled && $0.pinned }.compactMap { pref in
            manifests.first { $0.id == pref.id && $0.kind == .builtin }
        }
    }

    public func startEnabled() {
        for pref in preferences where pref.enabled { start(pref.id) }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let index = preferences.firstIndex(where: { $0.id == id }) else { throw RegistryError.unknownModule }
        preferences[index].enabled = enabled
        if enabled {
            if runtimes[id] == nil { start(id) }
        } else {
            stop(id)
        }
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws {
        guard let index = preferences.firstIndex(where: { $0.id == id }) else { throw RegistryError.unknownModule }
        preferences[index].pinned = pinned
        if !pinned && expandedID == id { collapse() }
    }

    public func move(_ id: String, by offset: Int) throws {
        guard let manifest = manifests.first(where: { $0.id == id }) else { throw RegistryError.unknownModule }
        guard manifest.kind == .builtin else { throw RegistryError.coreOrderLocked }
        let core = preferences.filter { pref in manifests.contains { $0.id == pref.id && $0.kind == .core } }
        var optional = preferences.filter { pref in !core.contains { $0.id == pref.id } }
        guard let index = optional.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(optional.count - 1, max(0, index + max(-1, min(1, offset))))
        let item = optional.remove(at: index)
        optional.insert(item, at: destination)
        preferences = core + optional
    }

    public func expand(_ id: String) throws {
        guard manifests.contains(where: { $0.id == id && $0.kind == .builtin }),
              preferences.contains(where: { $0.id == id && $0.enabled && $0.pinned }),
              states[id] == .resident || states[id] == .expanded else { throw RegistryError.notRunning }
        collapse()
        expandedID = id
        states[id] = .expanded
    }

    public func collapse() {
        if let id = expandedID, states[id] == .expanded { states[id] = .resident }
        expandedID = nil
    }

    public func suspend(_ id: String) {
        guard let runtime = runtimes[id], states[id] == .resident || states[id] == .expanded else { return }
        if expandedID == id { collapse() }
        runtime.suspend()
        bus.deactivate(moduleID: id)
        states[id] = .suspended
    }

    public func resume(_ id: String) {
        guard let runtime = runtimes[id], states[id] == .suspended else { return }
        do {
            try runtime.resume()
            // New publication epoch prevents late pre-suspension events from overwriting resumed state.
            activate(id)
            states[id] = .resident
            try publish(id)
        } catch { fail(id) }
    }

    public func perform(_ action: ModuleAction, on id: String) throws {
        guard manifests.first(where: { $0.id == id })?.actions[action] != nil else { throw RegistryError.unsupportedAction }
        guard let runtime = runtimes[id], states[id] == .resident || states[id] == .expanded || states[id] == .permissionRequired else {
            throw RegistryError.notRunning
        }
        do {
            try runtime.perform(action)
            states[id] = expandedID == id ? .expanded : .resident
            try publish(id)
        } catch { fail(id); throw error }
    }

    public func permissionRequired(_ id: String) {
        guard runtimes[id] != nil else { return }
        if expandedID == id { collapse() }
        states[id] = .permissionRequired
    }

    public func permissionRevoked(_ id: String) { if runtimes[id] != nil { fail(id) } }

    public func stopAll() {
        collapse()
        for id in Array(runtimes.keys) { stop(id) }
    }

    private func activate(_ id: String) {
        let instance = UUID()
        instances[id] = instance
        revisions[id] = 0
        bus.activate(moduleID: id, instanceID: instance)
    }

    private func start(_ id: String) {
        guard let factory = factories[id] else { return }
        states[id] = .enabling
        let runtime = factory()
        runtimes[id] = runtime
        activate(id)
        do {
            try runtime.start()
            states[id] = .resident
            try publish(id)
            diagnostics.record(.moduleStarted, moduleID: id)
        } catch { fail(id) }
    }

    private func publish(_ id: String) throws {
        guard let runtime = runtimes[id], let instance = instances[id] else { return }
        let projection = try runtime.snapshot()
        let revision = (revisions[id] ?? 0) + 1
        revisions[id] = revision
        bus.publish(ModuleEvent(moduleID: id, instanceID: instance, revision: revision, snapshot: projection))
    }

    private func stop(_ id: String) {
        if expandedID == id { collapse() }
        runtimes.removeValue(forKey: id)?.stop()
        instances[id] = nil
        revisions[id] = nil
        bus.deactivate(moduleID: id)
        states[id] = .disabled
        diagnostics.record(.moduleStopped, moduleID: id)
    }

    private func fail(_ id: String) {
        stop(id)
        states[id] = .degraded
        diagnostics.record(.moduleFailed, moduleID: id)
    }
}
