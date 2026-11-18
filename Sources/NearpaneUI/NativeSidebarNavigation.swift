import AppKit
import NearpaneCore
import OSLog

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
    init?(_ window: WindowObservation, source: NativeSidebarDestination) {
        guard let m = window.metadata, m.pid > 1, m.number > 0, let birth = m.launchMicroseconds, birth > 0,
              case .known(let ids) = window.membership, ids.contains(source.space),
              window.displayID == source.display else { return nil }
        self.source = source
        key = .init(pid: m.pid, birth: birth, number: m.number)
    }

    func resolve(_ snapshot: DesktopSnapshot) -> WindowObservation? {
        guard let live = source.resolve(snapshot), let row = live.rows.first(where: { $0.id == source.space }) else { return nil }
        return row.windows.first(where: {
            $0.metadata?.number == key.number && $0.metadata?.pid == key.pid && $0.metadata?.launchMicroseconds == key.birth
        })
    }
}

@MainActor @Observable final class NativeSidebarNavigation {
    // All displays share the action lane. A superseded switch can finish, but cannot
    // subsequently focus a window after a newer explicit choice.
    static let shared = NativeSidebarNavigation()
    typealias Work = @MainActor (UUID) async throws -> Void
    private var generation = UUID()
    private var activeSelection: NativeSelectionPermit?
    private var recordedCapability: String?
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "NativeSpaceActions")
    private struct Job { let token: UUID, selection: Bool, run: Work }
    private var pending: [Job] = []
    private var running = false
    private(set) var issue: String?
    private(set) var canSwitch = false
    private(set) var canMove = false

    func probe(display: String) async {
        let request = NativeSpaceCommand(id: UUID(), action: .probe, display: display, source: "", target: "")
        let reply = await NativeSpaceActionClient.shared.run(request)
        guard !Task.isCancelled, reply.id == request.id else { return }
        canSwitch = reply.state == .ready && reply.canSwitch
        canMove = reply.state == .ready && reply.canMove
        let capability = "ready=\(reply.state == .ready) canSwitch=\(canSwitch) canMove=\(canMove)"
        if recordedCapability != capability {
            Self.log.notice("nativeSpaceCapabilities \(capability, privacy: .public)")
            recordedCapability = capability
        }
    }

    func submit(selection: Bool = true, _ work: @escaping Work) {
        if selection && pending.last?.selection == true { pending.removeLast() }
        guard pending.count < 8 else { issue = "已有操作在等待，请稍后再试。"; return }
        activeSelection?.revoke()
        generation = UUID(); issue = nil
        pending.append(Job(token: generation, selection: selection, run: work))
        guard !running else { return }
        running = true
        Task {
            while !pending.isEmpty {
                let job = pending.removeFirst()
                do { try await job.run(job.token) }
                catch where !job.selection || job.token == generation { issue = error.localizedDescription }
                catch {}
            }
            running = false
        }
    }

    func isCurrent(_ token: UUID) -> Bool { generation == token }

    func select(_ destination: NativeSidebarDestination, member: NativeSidebarMember?, feed: CurrentDesktopWindows,
                allowed: @escaping @MainActor () -> Bool) {
        let lifetime = member.flatMap { feed.lifetime(of: $0.key) }
        submit { [weak self] token in
            @MainActor func valid() -> Bool {
                guard self?.isCurrent(token) == true, allowed() else { return false }
                return member.map { lifetime != nil && feed.lifetime(of: $0.key) == lifetime } ?? true
            }
            guard valid(), let before = await feed.readNow(), let map = destination.resolve(before),
                  member == nil || member?.resolve(before) != nil, valid() else {
                throw OrdinaryWindowFailure("桌面或窗口已变化，请重新选择。")
            }
            var current = before
            if map.current.id != destination.space {
                guard let sourceUUID = map.current.nativeUUID, let sourceKind = map.current.nativeKind else { throw OrdinaryWindowFailure("当前空间无法执行此操作。") }
                let request = NativeSpaceCommand(id: UUID(), action: .select, display: destination.display,
                    source: map.current.id, target: destination.space, sourceUUID: sourceUUID, targetUUID: destination.uuid,
                    sourceKind: sourceKind, targetKind: destination.kind)
                let permit = NativeSelectionPermit()
                self?.activeSelection = permit
                defer { if self?.activeSelection === permit { self?.activeSelection = nil } }
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
            try await DesktopWindowSelection.select(target, deadline: ProcessInfo.processInfo.systemUptime + 4,
                hasAX: AXIsProcessTrusted() || current.native?.accessibility == .available || current.native?.accessibility == .partial,
                verifySpace: {
                    guard valid(), let fresh = await feed.readNow() else { return false }
                    return destination.resolve(fresh)?.current.id == destination.space && target.present(in: fresh)
                }, stillCurrent: valid)
        }
    }

    func move(_ member: NativeSidebarMember, into dest: NativeSidebarDestination, lifetime: UUID, feed: CurrentDesktopWindows,
              allowed: @escaping @MainActor () -> Bool) {
        guard member.source != dest, member.source.kind == .ordinary, dest.kind == .ordinary else { return }
        submit(selection: false) { _ in
            guard allowed(), let current = await feed.readNow(), let map = dest.resolve(current),
                  member.source.display == dest.display, let w = member.resolve(current),
                  case .known(let ids) = w.membership, ids == [member.source.space],
                  feed.lifetime(of: member.key) == lifetime, map.rows.contains(where: { $0.id == member.source.space }), allowed() else {
                throw OrdinaryWindowFailure("拖动的窗口或目标桌面已变化。")
            }
            let request = NativeSpaceCommand(id: UUID(), action: .move, display: dest.display,
                source: member.source.space, target: dest.space, sourceUUID: member.source.uuid, targetUUID: dest.uuid,
                window: .init(pid: member.key.pid, birth: member.key.birth, number: member.key.number))
            let reply = await NativeSpaceActionClient.shared.run(request)
            feed.changed()
            guard reply.id == request.id, reply.state == .confirmed else { throw OrdinaryWindowFailure(reply.detail) }
        }
    }
}
