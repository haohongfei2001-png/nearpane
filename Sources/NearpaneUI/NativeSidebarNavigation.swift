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

@MainActor private final class CrossSpaceFocusWatch {
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
    private var generation = UUID()
    private var activeSelection: NativeSelectionPermit?
    private(set) var dispatchAvailable = true
    private(set) var ownershipEpoch = UUID()

    func setDispatchAvailable(_ available: Bool) {
        guard dispatchAvailable != available else { return }
        dispatchAvailable = available
        ownershipEpoch = UUID()
        generation = UUID()
        activeSelection?.revoke()
        pending.removeAll()
        issue = nil
        canSwitch = false
        canMove = false
        recordedCapability = nil
    }
    @ObservationIgnored var confirmDispatch: (@MainActor () async -> Bool)?
    private var recordedCapability: String?
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "NativeSpaceActions")
    private struct Job { let token: UUID, epoch: UUID, selection: Bool, run: Work }
    private var pending: [Job] = []
    private var running = false
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

    func submit(selection: Bool = true, _ work: @escaping Work) {
        guard dispatchAvailable else { return }
        if selection && pending.last?.selection == true { pending.removeLast() }
        guard pending.count < 8 else { issue = "已有操作在等待，请稍后再试。"; return }
        activeSelection?.revoke()
        generation = UUID(); issue = nil
        pending.append(Job(token: generation, epoch: ownershipEpoch, selection: selection, run: work))
        guard !running else { return }
        running = true
        Task {
            while !pending.isEmpty {
                let job = pending.removeFirst()
                guard dispatchAvailable, job.epoch == ownershipEpoch else { continue }
                if let confirmDispatch {
                    guard await confirmDispatch(), dispatchAvailable, job.epoch == ownershipEpoch,
                          !job.selection || isCurrent(job.token) else { continue }
                }
                do { try await job.run(job.token) }
                catch where job.epoch == ownershipEpoch && (!job.selection || job.token == generation) { issue = error.localizedDescription }
                catch {}
            }
            running = false
        }
    }

    func isCurrent(_ token: UUID) -> Bool { dispatchAvailable && generation == token }

    func select(_ destination: NativeSidebarDestination, member: NativeSidebarMember?, feed: CurrentDesktopWindows,
                operation: UUID = UUID(), menuInventory: SpaceMenuInventory? = nil, finished: (@MainActor () -> Void)? = nil,
                allowed: @escaping @MainActor () -> Bool) {
        let userInput = NativeSelectionPermit.inputCounters()
        let menuSelectionUptime = menuInventory == nil ? nil : ProcessInfo.processInfo.systemUptime
        let originalFront = member == nil ? nil : SelectionForeground.read(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let lifetime = member.flatMap { feed.lifetime(of: $0.key) }
        submit { [weak self] token in
            defer { finished?() }
            var watch: CrossSpaceFocusWatch?
            defer { watch?.stop() }
            @MainActor func valid() -> Bool {
                guard self?.isCurrent(token) == true, allowed(), WindowContentPreview.sessionAvailable(),
                      watch?.current() != false,
                      NativeSelectionPermit.inputCounters() == userInput else { return false }
                if let member, let original = member.originalWindow, let location = member.location {
                    return feed.tracks(original, at: location)
                }
                return member.map { lifetime != nil && feed.lifetime(of: $0.key) == lifetime } ?? true
            }
            guard valid(), let before = await feed.readNow(), let map = destination.resolve(before),
                  menuInventory.map({ member == nil && self?.canSwitch == true && $0.stillOffers(destination, in: before) }) ?? true,
                  member == nil || member?.resolve(before) != nil, valid() else {
                if menuInventory != nil && !valid() { return }
                throw OrdinaryWindowFailure("桌面或窗口已变化，请重新选择。")
            }
            let original = map.current.id != destination.space ? member?.originalWindow : nil
            if map.current.id != destination.space, let member {
                guard let originalFront else { throw OrdinaryWindowFailure("无法确认原前台进程。") }
                watch = .init(source: originalFront, target: .init(pid: member.key.pid, birth: member.key.birth))
                guard valid() else { return }
            }
            var bound: OrdinaryWindowAX?
            if map.current.id != destination.space, let member, original == nil {
                // Retain the exact AX element across the switch and focus operation.
                // A rebuilt window with the same CG number cannot inherit the click.
                bound = try await DesktopWindowSelection.bind(member.key)
                guard valid(), let fresh = await feed.readNow(), member.resolve(fresh) != nil,
                      destination.resolve(fresh)?.current.id == map.current.id, valid() else {
                    throw OrdinaryWindowFailure("所选窗口或来源桌面已变化。")
                }
            }
            let beforeSwitch = bound
            let permit = NativeSelectionPermit(current: valid, requiredOriginal: original, checkOriginalWindow: {
                if let original, let member, let location = member.location {
                    guard feed.tracks(original, at: location), let surface = WindowSurfaceRecord(number: member.key.number)
                    else { return false }
                    return surface.pid == member.key.pid && surface.layer == 0 && surface.isDrawn
                }
                guard let beforeSwitch else { return member == nil }
                return await beforeSwitch.stillSelected()
            })
            self?.activeSelection = permit
            defer { if self?.activeSelection === permit { self?.activeSelection = nil } }
            var current = before
            if map.current.id != destination.space {
                guard let sourceUUID = map.current.nativeUUID, let sourceKind = map.current.nativeKind else { throw OrdinaryWindowFailure("当前空间无法执行此操作。") }
                let request = NativeSpaceCommand(id: operation, action: .select, display: destination.display,
                    source: map.current.id, target: destination.space, sourceUUID: sourceUUID, targetUUID: destination.uuid,
                    window: member.map { .init(pid: $0.key.pid, birth: $0.key.birth, number: $0.key.number) },
                    sourceKind: sourceKind, targetKind: destination.kind, originalWindow: original,
                    createdAtUptime: menuSelectionUptime ?? ProcessInfo.processInfo.systemUptime)
                let reply = await NativeSpaceActionClient.shared.run(request, permit: permit)
                feed.changed()
                guard reply.id == request.id, reply.state == .confirmed else { throw OrdinaryWindowFailure(reply.detail) }
                guard valid() else { return }
                // A coalesced overview read may have begun before the helper's final
                // WindowServer acknowledgement. Wait for an independent settled read.
                let end = ContinuousClock.now.advanced(by: .milliseconds(1100))
                var reached: DesktopSnapshot?
                repeat {
                    if let read = await feed.readNow(), destination.resolve(read)?.current.id == destination.space {
                        reached = read; break
                    }
                    guard valid() else { return }
                    try await Task.sleep(for: .milliseconds(70))
                } while ContinuousClock.now < end
                guard let reached else { throw OrdinaryWindowFailure("尚未确认目标桌面。") }
                current = reached
            }
            guard valid(), let member else { return }
            guard let window = member.resolve(current), let target = DesktopWindowTarget(window, in: current),
                  target.overviewSpace == destination.space else { throw OrdinaryWindowFailure("所选窗口已离开这个桌面。") }
            if let original, let location = member.location {
                // The destination is current again. The independent focus worker binds
                // its exact AX object first. Then the switch worker must still see the
                // unique CFEqual foreground object it retained before the desktop changed.
                let focus = try await DesktopWindowSelection.bind(member.key)
                let probe = NativeSidebarWindowProbe(location, current: true, original: original)
                guard valid(), await NativeSpaceActionClient.shared.observe([probe]).tokens == [original],
                      await focus.stillSelected(), valid() else {
                    throw OrdinaryWindowFailure("落地后原窗口身份已变化。")
                }
                bound = focus
            }
            let path = try await DesktopWindowSelection.select(target, deadline: ProcessInfo.processInfo.systemUptime + 4,
                verifySpace: {
                    guard valid(), let fresh = await feed.readNow() else { return false }
                    return destination.resolve(fresh)?.current.id == destination.space && target.remainsSelection(in: fresh)
                }, stillCurrent: valid, bound: bound, permit: bound == nil ? nil : permit)
            if valid() { self?.issue = path.focusNotice }
        }
    }

    func move(_ member: NativeSidebarMember, into dest: NativeSidebarDestination, lifetime: UUID, feed: CurrentDesktopWindows,
              allowed: @escaping @MainActor () -> Bool) {
        guard !member.selectionOnly, member.source != dest, member.source.kind == .ordinary, dest.kind == .ordinary else { return }
        let epoch = ownershipEpoch
        submit(selection: false) { [weak self] _ in
            @MainActor func currentIntent() -> Bool {
                self?.ownershipEpoch == epoch && self?.dispatchAvailable == true && allowed()
            }
            @MainActor func transfer() async throws {
                guard currentIntent(), let current = await feed.readNow(), let map = dest.resolve(current),
                      member.source.display == dest.display, let w = member.resolve(current),
                      w.sidebarOriginalWindow == nil || w.metadata?.overviewOrdinaryRole == true,
                      case .known(let ids) = w.membership, ids == [member.source.space],
                      feed.lifetime(of: member.key) == lifetime, map.rows.contains(where: { $0.id == member.source.space }), currentIntent() else {
                    throw OrdinaryWindowFailure("拖动的窗口或目标桌面已变化。")
                }
                let request = NativeSpaceCommand(id: UUID(), action: .move, display: dest.display,
                    source: member.source.space, target: dest.space, sourceUUID: member.source.uuid, targetUUID: dest.uuid,
                    window: .init(pid: member.key.pid, birth: member.key.birth, number: member.key.number),
                    confirmMoveBeforeSubmission: true)
                let permit = NativeSelectionPermit(current: currentIntent, confirmDispatch: { [weak self] in
                    guard currentIntent() else { return false }
                    if let check = self?.confirmDispatch { return await check() }
                    return true
                })
                let reply = await NativeSpaceActionClient.shared.run(request, permit: permit)
                feed.changed()
                guard reply.id == request.id, reply.state != .outcomeUnknown else {
                    throw UnconfirmedSpaceMove("窗口归属变化尚未确认，已保留原管理记录。")
                }
                guard reply.state == .confirmed else { throw OrdinaryWindowFailure(reply.detail) }
                guard reply.membershipBefore == [member.source.space], reply.membershipAfter == [dest.space] else {
                    throw UnconfirmedSpaceMove("窗口迁移的归属回读不完整。")
                }

                // A helper reply can precede the host reader. Verify the same lifetime
                // on the destination before granting a subsequent layout transaction.
                let until = ContinuousClock.now.advanced(by: .seconds(2))
                repeat {
                    if let fresh = await feed.readNow(), dest.resolve(fresh) != nil,
                       feed.lifetime(of: member.key) == lifetime,
                       fresh.windows.contains(where: {
                           $0.displayID == dest.display && $0.metadata?.pid == member.key.pid &&
                           $0.metadata?.launchMicroseconds == member.key.birth && $0.metadata?.number == member.key.number && $0.membership == .known(recordIDs: [dest.space])
                       }) { return }
                    try await Task.sleep(for: .milliseconds(70))
                } while ContinuousClock.now < until
                throw UnconfirmedSpaceMove("系统已报告迁移，但独立读数尚未确认窗口的新归属。")
            }
            if let tiling = feed.automaticTiling {
                let source = OrdinaryDesktopIdentity(display: member.source.display, record: member.source.space, uuid: member.source.uuid)
                let target = OrdinaryDesktopIdentity(display: dest.display, record: dest.space, uuid: dest.uuid)
                let result = try await tiling.transfer(member.key, lifetime: lifetime, from: source, to: target, perform: transfer)
                if currentIntent() { self?.issue = result }
            } else {
                try await transfer()
                if currentIntent() { self?.issue = "窗口已移入目标桌面。该桌面未授权自动分屏。" }
            }
        }
    }
}
