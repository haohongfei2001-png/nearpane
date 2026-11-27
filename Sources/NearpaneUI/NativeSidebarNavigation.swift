import AppKit
import NearpaneCore
import OSLog

struct UnconfirmedSpaceMove: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

struct NativeSidebarDestination: Equatable {
    let session: UUID
    let topology: String
    let display: String
    let space: String
    let uuid: UUID
    let kind: NativeSpaceKind

    init(session: UUID, topology: String, display: String, space: String, uuid: UUID, kind: NativeSpaceKind = .ordinary) {
        self.session = session; self.topology = topology; self.display = display; self.space = space; self.uuid = uuid; self.kind = kind
    }

    init?(_ row: NativeSpaceCatalog.Row, in catalog: NativeSpaceCatalog) {
        guard let uuid = row.record.nativeUUID, let kind = row.record.nativeKind else { return nil }
        self.kind = kind
        self.uuid = uuid; space = row.id; display = catalog.display.id
        topology = catalog.topology; session = catalog.session
    }

    func resolve(_ snapshot: DesktopSnapshot) -> NativeSpaceCatalog? {
        guard session == snapshot.sessionID, topology == snapshot.topologyFingerprint,
              let live = NativeSpaceCatalog(snapshot, displayID: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime),
              live.rows.contains(where: { $0.id == space && $0.record.nativeUUID == uuid && $0.record.nativeKind == kind }) else { return nil }
        return live
    }
}

struct NativeSidebarMember: Equatable {
    let source: NativeSidebarDestination
    let key: DesktopWindowKey
    let originalWindow: UUID?
    let selectionOnly: Bool
    var location: NativeSidebarWindowLocation? {
        guard source.kind == .ordinary, let display = UUID(uuidString: source.display) else { return nil }
        return .init(window: .init(pid: key.pid, birth: key.birth, number: key.number), display: display,
                     space: source.space, spaceUUID: source.uuid)
    }
    init?(_ window: WindowObservation, source: NativeSidebarDestination) {
        guard let m = window.metadata, m.pid > 1, m.number > 0, let birth = m.launchMicroseconds, birth > 0,
              case .known(let ids) = window.membership, ids.contains(source.space),
              window.displayID == source.display else { return nil }
        self.source = source
        originalWindow = window.sidebarOriginalWindow
        selectionOnly = originalWindow != nil && m.overviewOrdinaryRole != true
        key = .init(pid: m.pid, birth: birth, number: m.number)
    }

    func resolve(_ snapshot: DesktopSnapshot) -> WindowObservation? {
        guard let live = source.resolve(snapshot), let row = live.rows.first(where: { $0.id == source.space }) else { return nil }
        return row.windows.first(where: {
            $0.metadata?.number == key.number && $0.metadata?.pid == key.pid && $0.metadata?.launchMicroseconds == key.birth &&
                (originalWindow == nil || $0.sidebarOriginalWindow == originalWindow)
        })
    }
}

/// One presentation of each background window, with its actual Space retained for dispatch.
struct SidebarBackgroundWindows: Identifiable {
    let destination: NativeSidebarDestination
    let windows: [WindowObservation]
    var id: UUID { destination.uuid }

    static func sections(in catalog: NativeSpaceCatalog) -> [Self] {
        var seen = Set<DesktopWindowKey>()
        return catalog.rows.compactMap { row in
            guard !row.record.isCurrent, let destination = NativeSidebarDestination(row, in: catalog) else { return nil }
            let windows = row.windows.filter { window in
                guard let metadata = window.metadata, metadata.minimized != true,
                      (window.sidebarOriginalWindow != nil || (metadata.overviewOrdinaryRole ?? window.canWitnessCurrentSpace)),
                      case .known(let spaces) = window.membership, !spaces.contains(catalog.current.id),
                      let member = NativeSidebarMember(window, source: destination) else { return false }
                return seen.insert(member.key).inserted
            }
            return windows.isEmpty ? nil : Self(destination: destination, windows: windows)
        }
    }
}

struct SelectionForeground: Equatable {
    let pid: Int32
    let birth: UInt64

    static func read(_ pid: Int32?) -> Self? {
        guard let pid, let owner = AdmissionBirth.read(pid), owner.start > 0 else { return nil }
        return .init(pid: pid, birth: owner.start)
    }
}

struct CrossSpaceFocusContinuity {
    let source: SelectionForeground
    let target: SelectionForeground
    private(set) var reachedTarget = false
    private(set) var revoked = false

    mutating func observe(_ owner: SelectionForeground?) -> Bool {
        guard !revoked else { return false }
        if owner == target { reachedTarget = true }
        else if owner != source || reachedTarget { revoked = true }
        return !revoked
    }
}

@MainActor final class CrossSpaceFocusWatch {
    var continuity: CrossSpaceFocusContinuity
    private var observer: NSObjectProtocol?
    init(source: SelectionForeground, target: SelectionForeground) {
        continuity = .init(source: source, target: target)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { _ = self?.continuity.observe(.read(app?.processIdentifier)) }
        }
    }
    func current() -> Bool {
        continuity.observe(.read(NSWorkspace.shared.frontmostApplication?.processIdentifier))
    }
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

@MainActor @Observable final class NativeSidebarNavigation {
    // All displays share the action lane. A superseded switch can finish, but cannot
    // subsequently focus a window after a newer explicit choice.
    static let shared = NativeSidebarNavigation()
    typealias Work = @MainActor (UUID) async throws -> Void
    private(set) var generation = UUID()
    private var activeSelection: NativeSelectionPermit?
    private(set) var dispatchAvailable = true
    private(set) var ownershipEpoch = UUID()
    @ObservationIgnored let windowSwitch = WindowSwitchTransition()

    func setDispatchAvailable(_ available: Bool) {
        guard dispatchAvailable != available else { return }
        dispatchAvailable = available
        windowSwitch.cancel()
        ownershipEpoch = UUID()
        generation = UUID()
        activeSelection?.revoke()
        pending.removeAll()
        issue = nil
        canSwitch = false
        canMove = false
        recordedCapability = nil
    }
    @ObservationIgnored var stageOwnsWindowDispatch: @MainActor () -> Bool = { false }
    @ObservationIgnored var confirmDispatch: (@MainActor () async -> Bool)?
    private var recordedCapability: String?
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "NativeSpaceActions")
    private struct Job { let token: UUID, epoch: UUID, selection: Bool, stage: Bool, run: Work }
    private var pending: [Job] = []
    private var running = false
    /// Capture refreshes yield while an explicit window action owns this lane.
    /// Include queued work so they cannot slip between two rapid choices.
    var isDispatching: Bool { running || !pending.isEmpty }
    var idleGeneration: UUID? { dispatchAvailable && !isDispatching ? generation : nil }
    /// Starting an idle observation and checking the action lane are one actor turn.
    /// A caller still owns completion of a read that began before the next action.
    func whenIdle(_ observe: @MainActor () -> Void) {
        guard !isDispatching else { return }
        observe()
    }
    private(set) var issue: String?
    private(set) var canSwitch = false
    private(set) var canMove = false

    @discardableResult func probe(display: String) async -> Bool {
        guard dispatchAvailable else { return false }
        let epoch = ownershipEpoch
        let request = NativeSpaceCommand(id: UUID(), action: .probe, display: display, source: "", target: "")
        let reply = await NativeSpaceActionClient.shared.run(request)
        guard dispatchAvailable, ownershipEpoch == epoch, !Task.isCancelled, reply.id == request.id else { return false }
        canSwitch = reply.state == .ready && reply.canSwitch
        canMove = reply.state == .ready && reply.canMove
        let capability = "ready=\(reply.state == .ready) canSwitch=\(canSwitch) canMove=\(canMove)"
        if recordedCapability != capability {
            Self.log.notice("nativeSpaceCapabilities \(capability, privacy: .public)")
            recordedCapability = capability
        }
        return canSwitch
    }

    func submit(selection: Bool = true, stage: Bool = false, prepare: (() -> Void)? = nil, _ work: @escaping Work) {
        IndependentStageTrace.record("navigation-submit", ["stage": stage, "selection": selection,
            "dispatchAvailable": dispatchAvailable, "stageOwnsDispatch": stageOwnsWindowDispatch(),
            "pending": pending.count, "running": running])
        guard dispatchAvailable, stage || !stageOwnsWindowDispatch() else { return }
        if selection && pending.last?.selection == true { pending.removeLast() }
        guard pending.count < 8 else { issue = "已有操作在等待，请稍后再试。"; return }
        activeSelection?.revoke()
        generation = UUID(); issue = nil
        if let prepare { prepare() } else { windowSwitch.cancel() }
        pending.append(Job(token: generation, epoch: ownershipEpoch, selection: selection, stage: stage, run: work))
        guard !running else { return }
        running = true
        Task(priority: .userInitiated) {
            while !pending.isEmpty {
                let job = pending.removeFirst()
                IndependentStageTrace.record("navigation-dequeue", ["stage": job.stage,
                    "taskPriority": Task.currentPriority.rawValue,
                    "dispatchAvailable": dispatchAvailable, "sameEpoch": job.epoch == ownershipEpoch,
                    "currentSelection": !job.selection || isCurrent(job.token), "stageOwnsDispatch": stageOwnsWindowDispatch()])
                guard dispatchAvailable, job.epoch == ownershipEpoch, !job.selection || isCurrent(job.token),
                      job.stage || !stageOwnsWindowDispatch() else { continue }
                if let confirmDispatch {
                    let confirmed = await confirmDispatch()
                    IndependentStageTrace.record("navigation-system-confirmation", ["confirmed": confirmed,
                        "dispatchAvailable": dispatchAvailable, "sameEpoch": job.epoch == ownershipEpoch,
                        "currentSelection": !job.selection || isCurrent(job.token)])
                    guard confirmed, dispatchAvailable, job.epoch == ownershipEpoch,
                          !job.selection || isCurrent(job.token), job.stage || !stageOwnsWindowDispatch() else { continue }
                }
                do { try await job.run(job.token) }
                catch where job.epoch == ownershipEpoch && (!job.selection || job.token == generation) {
                    IndependentStageTrace.record("navigation-job-failed", ["reason": error.localizedDescription])
                    issue = error.localizedDescription
                }
                catch { IndependentStageTrace.record("navigation-job-superseded", ["reason": error.localizedDescription]) }
            }
            running = false
        }
    }

    func isCurrent(_ token: UUID) -> Bool { dispatchAvailable && generation == token }

    func queuedGroupChoice(after token: UUID, in epoch: UUID) -> UUID? {
        guard dispatchAvailable, ownershipEpoch == epoch, generation != token, let latest = pending.last,
              latest.token == generation, latest.epoch == epoch, latest.stage, latest.selection else { return nil }
        return latest.token
    }
}
