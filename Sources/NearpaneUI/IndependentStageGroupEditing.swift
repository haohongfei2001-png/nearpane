import SwiftUI
import NearpaneCore

/// The R4 context menu uses the same release, directory and activation paths as a visible
/// window edit. Hidden membership is never converted into a synthetic visible sidebar row.
@MainActor enum IndependentStageGroupEditing {
    enum Change { case joinCurrent, detach(UUID) }

    struct Result {
        let group: UUID
        let window: NativeSpaceWindow
    }

    @MainActor struct Plan {
        let scope: StageGroupScope
        let source: StageGroupDirectory.Group
        let target: StageGroupDirectory.Group?
        let detached: UUID?

        init(scope: StageGroupScope, source: StageGroupDirectory.Group,
             target: StageGroupDirectory.Group? = nil, detached: UUID? = nil) throws {
            guard source.nativeSpace == scope.nativeSpace, source.needsReorganization != true,
                  !source.members.isEmpty, (target != nil) != (detached != nil) else { throw StageGroupError.staleBinding }
            if let target {
                guard target.id != source.id, target.nativeSpace == scope.nativeSpace,
                      target.needsReorganization != true, !target.members.isEmpty else { throw StageGroupError.staleBinding }
            }
            if let detached {
                guard source.members.count > 1, source.members.contains(where: { $0.id == detached }) else {
                    throw StageGroupError.staleBinding
                }
            }
            self.scope = scope; self.source = source; self.target = target; self.detached = detached
        }

        var members: [StageGroupDirectory.Member] { source.members + (target?.members ?? []) }

        private func unchanged(_ expected: StageGroupDirectory.Group, in store: StageGroupStore) -> Bool {
            guard let now = store.groups(in: scope).first(where: { $0.id == expected.id }),
                  now.needsReorganization != true, now.members.count == expected.members.count else { return false }
            return zip(now.members, expected.members).allSatisfy { current, original in
                current.id == original.id && current.windowHint == original.windowHint
            }
        }

        /// The caller has already physically returned and independently re-read every member.
        /// Check all identities before the first directory write, including unselected siblings.
        func apply(to store: StageGroupStore, observed: [NativeSpaceWindow: StageGroupWindow]) throws -> Result {
            guard unchanged(source, in: store), target.map({ unchanged($0, in: store) }) != false,
                  members.allSatisfy({ member in
                      guard let window = observed[member.windowHint] else { return false }
                      return window.identity == member.windowHint && window.display == scope.display &&
                          window.nativeSpace == scope.nativeSpace && store.isBound(member, to: window.lifetime)
                  }) else { throw StageGroupError.staleBinding }
            let focus: NativeSpaceWindow
            if let target, let anchor = target.focusMember(), let destination = observed[anchor.windowHint] {
                for member in source.members {
                    guard let moving = observed[member.windowHint] else { throw StageGroupError.staleBinding }
                    try store.join(moving, to: destination)
                }
                focus = anchor.windowHint
            } else if let detached, let member = source.members.first(where: { $0.id == detached }),
                      let window = observed[member.windowHint] {
                try store.detach(window, from: source.id)
                focus = window.identity
            } else { throw StageGroupError.staleBinding }
            guard let group = store.groups(in: scope).first(where: { $0.members.contains { $0.windowHint == focus } }) else {
                throw StageGroupError.staleBinding
            }
            return .init(group: group.id, window: focus)
        }
    }

    static func perform(_ change: Change, held: StageWindowEngineHost.HeldGroup, in feed: CurrentDesktopWindows,
                        current: @escaping @MainActor () -> Bool) async throws {
        guard current(), feed.stageEngine.heldGroups.contains(held),
              let source = feed.groups.groups(in: held.scope).first(where: { $0.id == held.id }) else {
            throw StageGroupError.staleBinding
        }
        let plan: Plan
        switch change {
        case .joinCurrent:
            guard let active = feed.groups.activeGroup(in: held.scope),
                  let target = feed.groups.groups(in: held.scope).first(where: { $0.id == active }) else {
                throw StageGroupError.staleBinding
            }
            plan = try .init(scope: held.scope, source: source, target: target)
        case .detach(let member):
            plan = try .init(scope: held.scope, source: source, detached: member)
        }
        let fresh = try await feed.stageEngine.prepareHeldGroupEdit(held, in: feed, current: current)
        guard current(), fresh.native?.stageManagerEnabled == false,
              let catalog = NativeSpaceCatalog(fresh, displayID: held.scope.display.uuidString,
                  now: .now, uptime: ProcessInfo.processInfo.systemUptime),
              catalog.current.ordinaryUUID == held.scope.nativeSpace,
              let row = catalog.rows.first(where: { $0.record.isCurrent }),
              let destination = NativeSidebarDestination(row, in: catalog) else { throw StageSwitchError.interrupted }
        var observed = [NativeSpaceWindow: StageGroupWindow](), selections = [NativeSpaceWindow: NativeSidebarMember]()
        for member in plan.members {
            let identity = member.windowHint
            let key = DesktopWindowKey(pid: identity.pid, birth: identity.birth, number: identity.number)
            let rows = fresh.windows.filter { DesktopWindowKey($0) == key }
            guard rows.count == 1, let window = rows.first, let selection = NativeSidebarMember(window, source: destination),
                  let physical = feed.groupWindow(selection, in: fresh) else { throw StageGroupError.staleBinding }
            observed[identity] = physical; selections[identity] = selection
        }
        guard current() else { throw StageSwitchError.interrupted }
        let result = try plan.apply(to: feed.groups, observed: observed)
        guard let selection = selections[result.window], current() else { throw StageSwitchError.interrupted }
        guard try await feed.stageEngine.groupChoice(result.group, member: selection, selection: .member,
            in: feed, snapshot: fresh, current: current) else { throw StageSwitchError.unavailable }
        feed.changed()
    }
}
