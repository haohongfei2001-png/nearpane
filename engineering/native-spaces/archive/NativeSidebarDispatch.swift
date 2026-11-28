import AppKit
import NearpaneCore

extension NativeSidebarNavigation {
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
