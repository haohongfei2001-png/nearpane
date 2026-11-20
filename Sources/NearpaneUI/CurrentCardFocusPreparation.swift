import Foundation
import NearpaneCore
import OSLog

/// The signed worker is unbound while idle. Selection consumes this entry exactly once;
/// another click must obtain its own process, window identities and per-write permission.
@MainActor final class FocusWorkerStandby<Worker: Sendable> {
    private struct Entry {
        let id: UUID
        let expires: ContinuousClock.Instant
        let worker: Task<Worker, Error>
    }
    private let lifetime: Duration
    private let now: () -> ContinuousClock.Instant
    private var entry: Entry?
    private var expiry: Task<Void, Never>?

    init(lifetime: Duration = .seconds(12), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.lifetime = lifetime
        self.now = now
    }

    @discardableResult
    func prepare(_ create: () -> Task<Worker, Error>) -> Bool {
        if let entry, now() < entry.expires { return true }
        discard()
        let id = UUID()
        entry = Entry(id:id, expires:now().advanced(by:lifetime), worker:create())
        let lifetime = lifetime
        expiry = Task { [weak self] in
            do { try await Task.sleep(for:lifetime) } catch { return }
            if self?.entry?.id == id { self?.discard() }
        }
        return false
    }

    func take(_ create: () -> Task<Worker, Error>) async throws -> Worker {
        prepare(create)
        guard let pending = entry else { throw CancellationError() }
        entry = nil
        expiry?.cancel(); expiry = nil
        return try await pending.worker.value
    }

    func discard() {
        entry?.worker.cancel(); entry = nil
        expiry?.cancel(); expiry = nil
    }

    deinit { entry?.worker.cancel(); expiry?.cancel() }
}

/// An ordering hint only. Every click still performs the preferred route's complete new
/// binding. If that read refuses, the caller can try the public Host binding before any write.
struct RecentWorkerFocus {
    let application: AdmissionApplication
    let session: UUID
    let completed: ContinuousClock.Instant

    func prefers(_ app: AdmissionApplication, session: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        application == app && self.session == session && now >= completed && now < completed.advanced(by:.seconds(12))
    }
}

/// Issue a real roster read for this click while its read-only AX binding is in progress.
/// Accept a result only if it *finished* after binding. An earlier positive result must
/// be read again; an independently observed refusal is never turned into permission.
@MainActor final class CurrentCardScopeRead {
    private let verify: () async -> Bool
    private let pending: Task<(valid: Bool, finished: ContinuousClock.Instant), Never>

    init(verify: @escaping () async -> Bool) {
        self.verify = verify
        pending = Task { @MainActor in
            let valid = await verify()
            return (valid,.now)
        }
    }

    func confirm(boundAt: ContinuousClock.Instant, current: () -> Bool) async throws {
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        let read = await pending.value
        guard read.valid, current() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
        if read.finished < boundAt {
            guard await verify(), current() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
        }
    }

    func cancel() { pending.cancel() }
}

extension WindowFocusTiming {
    private static let preparationLog = Logger(subsystem:"com.holdsnow.nearpane.alpha",category:"WindowFocusLatency")
    enum Preparation: String {
        case controllerCold, controllerStandby, controllerPreferred, controllerReady
        case publicBindingUnavailable, hostBindingFinished, workerBindingFinished, rosterReadFinished, rosterConfirmed
        case targetScopeConfirmed, targetScopeFallback, targetScopeChanged
    }
    func prepared(_ phase: Preparation) {
        Self.preparationLog.info("operation=\(id.uuidString, privacy: .public) phase=\(phase.rawValue, privacy: .public) route=sidebar action=none uptime=\(ProcessInfo.processInfo.systemUptime, format: .fixed(precision: 6), privacy: .public)")
    }
}
