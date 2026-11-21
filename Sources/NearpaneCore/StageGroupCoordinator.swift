import Foundation

/// Independent AX and WindowServer readback. An adapter must withhold a sample when the two
/// disagree or when it cannot enumerate the bystanders in this display's ordinary desktop.
public struct StageWindowState: Codable, Equatable, Sendable {
    public let window: NativeSpaceWindow
    public let lifetime: UUID
    public var frame: SurfaceRect
    public var visibility: Visibility
    /// Read from independent native membership when the window is in a backend-created Space.
    public var hiddenSpaceID: UInt64?
    public enum Visibility: String, Codable, Sendable { case visible, minimized, parked, orderedOut, stageSpace }

    public init(window: NativeSpaceWindow, lifetime: UUID, frame: SurfaceRect, visibility: Visibility, hiddenSpaceID: UInt64? = nil) {
        self.window = window; self.lifetime = lifetime; self.frame = frame; self.visibility = visibility; self.hiddenSpaceID = hiddenSpaceID
    }
}

public struct StageWindowSample: Sendable {
    public let scope: StageGroupScope, generation: UUID, sequence: UInt64
    public let workArea: SurfaceRect, windows: [NativeSpaceWindow: StageWindowState]
    /// Independently matched global AXFocusedWindow and CG ID. Nil if the match is unavailable.
    public let focus: NativeSpaceWindow?
    /// Set only when the exact focused window is independently visible on another physical display.
    public let foreignFocusScope: StageGroupScope?
    public let nativeID: UInt64?
    public init(scope: StageGroupScope, generation: UUID, sequence: UInt64, workArea: SurfaceRect,
                windows: [NativeSpaceWindow: StageWindowState], focus: NativeSpaceWindow?, nativeID: UInt64? = nil,
                foreignFocusScope: StageGroupScope? = nil) {
        self.scope = scope; self.generation = generation; self.sequence = sequence
        self.workArea = workArea; self.windows = windows; self.focus = focus; self.nativeID = nativeID
        self.foreignFocusScope = foreignFocusScope
    }
}

public enum StageWindowAction: Codable, Equatable, Sendable {
    case hide, show, place(SurfaceRect), focus
}

/// A qualified driver retains exact AX objects. It must compare the argument with the live
/// window and recheck the input/topology epoch immediately before each individual OS write.
@MainActor public protocol StageWindowSession: AnyObject {
    var qualifiedHiddenState: StageWindowState.Visibility? { get }
    var engineOwner: StageEngineOwner? { get }
    func mayManage(_ state: StageWindowState) -> Bool
    func dispatch(_ command: StageWindowCommand) async throws
    func didVerify(_ command: StageWindowCommand, after: StageWindowState) async throws
    func prepareBackend(_ sample: StageWindowSample) async throws
    func read(_ scope: StageGroupScope) async throws -> StageWindowSample
    func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws
}

public struct StageWindowCommand: Sendable {
    public let intent, group, member, generation: UUID
    public let scope: StageGroupScope, nativeID: UInt64?, action: StageWindowAction, before: StageWindowState
    public let restoring: Bool, restoreFrame: SurfaceRect?
}

public extension StageWindowSession {
    func mayManage(_ state: StageWindowState) -> Bool { true }
    func prepareBackend(_ sample: StageWindowSample) async throws {}
    func didVerify(_ command: StageWindowCommand, after: StageWindowState) async throws {}
    var engineOwner: StageEngineOwner? { nil }
    func dispatch(_ c: StageWindowCommand) async throws {
        try await apply(c.action, to: c.before, in: c.scope, generation: c.generation)
    }
}

public enum StageSwitchError: LocalizedError, Equatable {
    case busy, unavailable, interrupted, incomplete, ownership, recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .busy: return "已有窗口操作正在进行。"
        case .unavailable: return "当前环境暂不能切换整个窗口组。"
        case .interrupted: return "窗口或焦点已变化，本次切换已停止。"
        case .incomplete: return "尚未核对完整的窗口组状态。"
        case .ownership: return "窗口归属已变化，请重新选择。"
        case .recoveryRequired: return "上一次窗口操作仍有待确认的恢复记录。"
        }
    }
}

@MainActor public final class StageGroupCoordinator {
    struct Ownership: Codable, Equatable {
        let scope: StageGroupScope
        let original, hidden: StageWindowState
        var owner: StageEngineOwner? = nil
        var group: UUID? = nil
        var member: UUID? = nil
        var nativeID: UInt64? = nil
    }
    struct Entry: Codable {
        let action: StageWindowAction, before: StageWindowState
        var after: StageWindowState?
        var intent: UUID? = nil
        var undoIntent: UUID? = nil
        var guardianPending: Bool? = nil
    }
    struct Transaction: Codable {
        let scope: StageGroupScope, generation: UUID, target: UUID, preferred: NativeSpaceWindow
        let originalFocus: NativeSpaceWindow?, before: [StageWindowState], ownedBefore: [Ownership]
        var entries = [Entry]()
        var verifiedDirectoryCommit = false
        var owner: StageEngineOwner? = nil
        var intent: UUID? = nil
        var nativeID: UInt64? = nil
        var workArea: SurfaceRect? = nil
        var yieldedFocus: NativeSpaceWindow? = nil
    }
    struct Release: Codable {
        let intent: UUID, owned: Ownership
        var restored: Bool? = nil
    }
    struct InterruptedRelease: Codable {
        let transaction: UUID, owner: StageEngineOwner, scope: StageGroupScope, focus: NativeSpaceWindow
        let firstSequence, secondSequence: UInt64
    }
    struct Ledger: Codable {
        var version = 1
        var owned = [Ownership]()
        var pending: Transaction?
        var owner: StageEngineOwner?
        var releases: [Release]?
        var activeScopes: [StageGroupScope]?
        var lastInterruptedRelease: InterruptedRelease?
    }

    private let store: StageGroupStore, file: URL
    private var ledger = Ledger(), bytes: Data?
    private var busy = false
    private var epoch = UUID()

    /// Created within the Host's exclusively leased profile. No profile reads ever issue a window action.
    public init(store: StageGroupStore, profile: URL) throws {
        self.store = store; file = profile.appendingPathComponent("stage-visibility-v1.json")
        try ProfileLease.checkPath(file)
        bytes = try disk()
        if let bytes {
            ledger = try JSONDecoder().decode(Ledger.self, from: bytes)
            if let pending = ledger.pending {
                guard pending.owner == ledger.owner,
                      pending.owner == nil || (pending.intent != nil && (pending.nativeID ?? 0) > 0),
                      pending.owner == nil || (pending.entries.allSatisfy { $0.intent != nil } &&
                        Set(pending.entries.compactMap(\.intent)).count == pending.entries.count),
                      Set(pending.before.map(\.window)).count == pending.before.count,
                      pending.before.contains(where: { $0.window == pending.preferred }),
                      pending.entries.allSatisfy({ e in e.after.map { $0.window == e.before.window && $0.lifetime == e.before.lifetime } != false })
                else { throw StageSwitchError.recoveryRequired }
            }
            guard ledger.version == 1, Set(ledger.owned.map { $0.hidden.window }).count == ledger.owned.count,
                  ledger.owned.allSatisfy({ $0.original.window == $0.hidden.window && $0.original.lifetime == $0.hidden.lifetime &&
                      $0.original.visibility == .visible && [.minimized,.parked,.stageSpace].contains($0.hidden.visibility) &&
                      ($0.hidden.visibility != .stageSpace || ($0.hidden.hiddenSpaceID ?? 0) > 0) &&
                      ($0.owner == nil || $0.member != nil && $0.group != nil && ($0.nativeID ?? 0) > 0 &&
                        ($0.owner?.backend == .corner ? $0.hidden.visibility == .parked : $0.hidden.visibility == .stageSpace)) &&
                      $0.owner == ledger.owner }),
                  (ledger.releases ?? []).allSatisfy({ release in ledger.owner != nil && release.owned.owner == ledger.owner && ledger.owned.contains(release.owned) == (release.restored != true) }),
                  Set((ledger.releases ?? []).map(\.intent)).count == (ledger.releases ?? []).count,
                  Set((ledger.releases ?? []).map { $0.owned.hidden.window }).count == (ledger.releases ?? []).count else {
                throw StageSwitchError.recoveryRequired
            }
        }
    }

    public var requiresRecovery: Bool { ledger.pending != nil || !(ledger.releases ?? []).isEmpty }
    public var retainedOwner: StageEngineOwner? { ledger.owner }
    /// An idle check never tries to regain focus. An external takeover withdraws the active claim.
    public func observesActiveGroup(_ sample: StageWindowSample, owner: StageEngineOwner) -> Bool {
        guard !busy, !requiresRecovery, ledger.owner == owner, sample.generation == owner.generation,
              let focus = sample.focus, let group = store.groups(in: sample.scope).first(where: { $0.verifiedActive == true }) else { return false }
        if let other = sample.foreignFocusScope {
            guard other.display != sample.scope.display, sample.windows[focus] == nil else { return false }
        } else if !group.members.contains(where: { $0.windowHint == focus }) { return false }
        return group.members.allSatisfy { member in
            guard let state = sample.windows[member.windowHint] else { return false }
            return state.visibility == .visible && store.isBound(member, to: state.lifetime)
        } && ledger.owned.filter { $0.scope == sample.scope }.allSatisfy { sample.windows[$0.hidden.window] == $0.hidden }
    }
    public func confirmsHidden(group: UUID, member: UUID, state: StageWindowState, scope: StageGroupScope, owner: StageEngineOwner) -> Bool {
        !busy && !requiresRecovery && ledger.owner == owner &&
            ledger.owned.contains { $0.scope == scope && $0.group == group && $0.member == member && $0.hidden == state && $0.owner == owner }
    }
    public var hasWindowAuthority: Bool { busy || !ledger.owned.isEmpty || requiresRecovery || ledger.owner != nil }
    public func permitsRetirement(of key: NativeSpaceWindow) -> Bool {
        !busy && !requiresRecovery && !ledger.owned.contains { $0.hidden.window == key }
    }
    public func invalidate() { epoch = UUID() }
    public func withdrawVerifiedActivity() throws {
        guard ledger.owner != nil else { return }
        let scopes = Set((ledger.activeScopes ?? []) + ledger.owned.map(\.scope) + [ledger.pending?.scope].compactMap { $0 })
        try store.withdrawActivity(in: scopes)
    }

    private func disk() throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }

    private func save(_ next: Ledger) throws {
        try ProfileLease.checkPath(file)
        guard try disk() == bytes else { throw StageSwitchError.recoveryRequired }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        bytes = data; ledger = next
    }

    private func update(_ edit: (inout Ledger) -> Void) throws {
        var next = ledger; edit(&next); try save(next)
    }

    private func absolute(_ relative: SurfaceRect, work: SurfaceRect) -> SurfaceRect {
        .init(x: work.x + relative.x * work.width, y: work.y + relative.y * work.height,
              width: relative.width * work.width, height: relative.height * work.height)
    }
    private func matches(_ a: SurfaceRect, _ b: SurfaceRect) -> Bool {
        abs(a.x-b.x) <= 1 && abs(a.y-b.y) <= 1 && abs(a.width-b.width) <= 1 && abs(a.height-b.height) <= 1
    }

    /// The caller obtains consent from an explicit first-use confirmation before entering. On
    /// first enrollment the actual focused window must belong to a participating group.
    public func activate(_ group: UUID, member: UUID?, in scope: StageGroupScope,
                         consent: Bool, session: StageWindowSession) async throws {
        guard !busy else { throw StageSwitchError.busy }
        guard !requiresRecovery, ledger.owner == nil || ledger.owner == session.engineOwner,
              ledger.owned.allSatisfy({ $0.owner == session.engineOwner }) else { throw StageSwitchError.recoveryRequired }
        guard consent, let mechanism = session.qualifiedHiddenState, [.parked,.minimized,.stageSpace].contains(mechanism),
              session.engineOwner.map({ $0.backend == .corner ? mechanism == .parked : mechanism == .stageSpace }) != false else {
            throw StageSwitchError.unavailable
        }
        busy = true
        defer { busy = false }
        let token = epoch, directory = store.directory
        var first = try await session.read(scope)
        let groups = store.participatingGroups(in: scope) { key in
            guard let state = first.windows[key], session.mayManage(state) else { return nil }
            return state.lifetime
        }
        guard let target = groups.first(where: { $0.id == group }),
              let preferred = target.focusMember(requested: member)
        else { throw StageSwitchError.incomplete }
        let members = groups.flatMap(\.members), ids = Set(members.map(\.windowHint)), targets = Set(target.members.map(\.windowHint))
        guard epoch == token, first.scope == scope, first.workArea.width > 0, first.workArea.height > 0,
              ids.count == members.count, ids.isSubset(of: Set(first.windows.keys)),
              first.windows.allSatisfy({ $0.key == $0.value.window }),
              members.allSatisfy({ m in first.windows[m.windowHint].map { state in store.isBound(m, to: state.lifetime) } == true }),
              groups.contains(where: { $0.verifiedActive == true }) || first.focus.map(ids.contains) == true
        else { throw StageSwitchError.incomplete }
        let originalHeld = ledger.owned.filter { $0.scope == scope }
        let held = Dictionary(uniqueKeysWithValues: originalHeld.map { ($0.hidden.window,$0) })
        guard originalHeld.allSatisfy({ ids.contains($0.hidden.window) && first.windows[$0.hidden.window] == $0.hidden }),
              ids.allSatisfy({ held[$0] != nil || first.windows[$0]?.visibility == .visible }) else { throw StageSwitchError.ownership }
        let otherIDs = first.windows.keys.filter { !ids.contains($0) }
        let intent = UUID(), owner = session.engineOwner
        guard owner == nil || (first.nativeID ?? 0) > 0 else { throw StageSwitchError.unavailable }
        if let owner {
            // A launch probe can own its own temporary window/Space before any business-window action exists.
            // Persist the worker authority first; a failed probe is not a may-have-issued hide of a user window.
            try update {
                $0.owner = owner
                if !($0.activeScopes ?? []).contains(scope) { $0.activeScopes = ($0.activeScopes ?? []) + [scope] }
            }
            try await session.prepareBackend(first)
            let postLaunch = try await session.read(scope)
            guard epoch == token, session.qualifiedHiddenState == mechanism, session.engineOwner == owner,
                  postLaunch.scope == scope, postLaunch.generation == first.generation, postLaunch.sequence > first.sequence,
                  postLaunch.nativeID == first.nativeID, postLaunch.workArea == first.workArea,
                  postLaunch.windows == first.windows, postLaunch.focus == first.focus else { throw StageSwitchError.interrupted }
            first = postLaunch
        }
        try update {
            $0.pending = .init(scope: scope, generation: first.generation, target: group, preferred: preferred.windowHint,
                originalFocus: first.focus, before: Array(first.windows.values), ownedBefore: originalHeld,
                owner: owner, intent: intent, nativeID: first.nativeID, workArea: first.workArea)
        }
        var last = first
        func requireFocus(_ sample: StageWindowSample, _ expected: NativeSpaceWindow?) throws {
            guard sample.focus == expected else {
                invalidate()
                if let focus = sample.focus { try update { $0.pending?.yieldedFocus = focus } }
                throw StageSwitchError.interrupted
            }
        }
        func read() async throws -> StageWindowSample {
            let next = try await session.read(scope)
            guard epoch == token, directory.groups(in: scope) == store.groups(in: scope), session.qualifiedHiddenState == mechanism, session.engineOwner == owner,
                  next.nativeID == first.nativeID,
                  next.scope == scope, next.generation == first.generation, next.workArea == first.workArea,
                  next.sequence > last.sequence, next.windows.keys == first.windows.keys,
                  next.windows.allSatisfy({ $0.key == $0.value.window && $0.value.lifetime == first.windows[$0.key]?.lifetime }),
                  otherIDs.allSatisfy({ next.windows[$0] == first.windows[$0] }) else { throw StageSwitchError.interrupted }
            return next
        }
        func perform(_ action: StageWindowAction, id: NativeSpaceWindow,
                     check: (StageWindowState, StageWindowSample) -> Bool) async throws {
            let pre = try await read()
            try requireFocus(pre, last.focus)
            guard pre.windows == last.windows, let before = pre.windows[id] else { throw StageSwitchError.interrupted }
            last = pre
            let primitive = UUID()
            try update { $0.pending?.entries.append(.init(action: action, before: before, intent: primitive)) }
            guard epoch == token else { throw StageSwitchError.interrupted }
            guard let member = members.first(where: { $0.windowHint == id }),
                  let owningGroup = groups.first(where: { $0.members.contains(where: { $0.id == member.id }) }) else { throw StageSwitchError.interrupted }
            let command = StageWindowCommand(intent:primitive,group:owningGroup.id,member:member.id,generation:first.generation,
                scope:scope,nativeID:first.nativeID,action:action,before:before,restoring:false,restoreFrame:held[id]?.original.frame)
            try await session.dispatch(command)
            for _ in 0..<2 {
                let post = try await read()
                try requireFocus(post, action == .focus ? id : pre.focus)
                guard let value = post.windows[id], check(value, post),
                      pre.windows.keys.filter({ $0 != id }).allSatisfy({ post.windows[$0] == pre.windows[$0] }) else {
                    throw StageSwitchError.incomplete
                }
                last = post
            }
            let confirmed = last.windows[id]!
            try update {
                let i = $0.pending!.entries.count-1
                $0.pending!.entries[i].after = confirmed
                if owner?.backend == .corner, action == .hide || action == .show { $0.pending!.entries[i].guardianPending = true }
                if action == .hide { $0.owned.append(.init(scope: scope, original: before, hidden: confirmed, owner: owner,
                    group: owningGroup.id, member: member.id, nativeID: first.nativeID)) }
                if action == .show { $0.owned.removeAll { $0.scope == scope && $0.hidden.window == id } }
            }
            if owner?.backend == .corner, action == .hide || action == .show {
                try await session.didVerify(command,after:confirmed)
                try update { $0.pending!.entries[$0.pending!.entries.count-1].guardianPending = nil }
            }
        }
        do {
            // A desktop with only the outgoing group must keep a real work window visible. Reveal
            // verified incoming members first, while the outgoing group can still receive the keyboard.
            for member in target.members {
                if let previous = held[member.windowHint] {
                    try await perform(.show, id:member.windowHint) { value, _ in
                        value.visibility == .visible && self.matches(value.frame,previous.original.frame)
                    }
                }
            }
            if last.focus != preferred.windowHint {
                try await perform(.focus, id: preferred.windowHint) { state, sample in
                    state.visibility == .visible && sample.focus == preferred.windowHint
                }
            }
            for m in members where !targets.contains(m.windowHint) && held[m.windowHint] == nil {
                try await perform(.hide, id: m.windowHint) { value, _ in value.visibility == mechanism &&
                    (mechanism != .stageSpace || (value.hiddenSpaceID ?? 0) > 0 && value.hiddenSpaceID != first.nativeID) }
            }
            for m in target.members {
                let id = m.windowHint
                if let relative = m.layout {
                    let frame = absolute(relative, work: first.workArea)
                    if let f = last.windows[id]?.frame, !matches(f, frame) {
                        try await perform(.place(frame), id: id) { value, _ in value.visibility == .visible && self.matches(value.frame, frame) }
                    }
                }
            }
            func complete(_ s: StageWindowSample) -> Bool {
                let parked = ledger.owned.filter { $0.scope == scope }
                return Set(parked.map { $0.hidden.window }) == ids.subtracting(targets) &&
                    parked.allSatisfy { s.windows[$0.hidden.window] == $0.hidden } &&
                    target.members.allSatisfy { m in
                        guard let value = s.windows[m.windowHint], value.visibility == .visible else { return false }
                        return m.layout.map { matches(value.frame, absolute($0, work: first.workArea)) } ?? true
                    }
            }
            for _ in 0..<3 {
                last = try await read()
                try requireFocus(last, preferred.windowHint)
                guard complete(last) else { throw StageSwitchError.incomplete }
            }
            try update { $0.pending?.verifiedDirectoryCommit = true }
            try store.commitActivity(group, preferred: preferred.id, in: scope, expected: directory)
            try update { $0.pending = nil }
        } catch {
            if ledger.pending?.entries.isEmpty == true { try update { $0.pending = nil } }
            else if epoch == token, ledger.pending?.verifiedDirectoryCommit == false {
                // A revoked generation or a may-have-issued entry cannot be rolled back by inference.
                _ = try? await compensate(session, token: token)
            }
            throw error
        }
    }

    /// Explicit recovery for a failed or interrupted transaction. A fresh driver must prove
    /// the retained lifetimes, original generation, unaffected windows and each exact after-image.
    public func recover(_ session: StageWindowSession) async throws {
        guard !busy else { throw StageSwitchError.busy }
        busy = true; defer { busy = false }
        try await compensate(session, token: epoch)
    }

    private func compensate(_ session: StageWindowSession, token: UUID) async throws {
        guard let t = ledger.pending else { return }
        guard t.owner == session.engineOwner, ledger.owner == session.engineOwner, (ledger.releases ?? []).isEmpty,
              let hidden = session.qualifiedHiddenState, t.entries.allSatisfy({ $0.after != nil && $0.guardianPending != true })
        else { throw StageSwitchError.recoveryRequired }
        let initial = Dictionary(uniqueKeysWithValues: t.before.map { ($0.window,$0) })
        var expected = initial
        for e in t.entries { expected[e.before.window] = e.after }
        var previousSequence: UInt64?
        var expectedFocus = t.entries.last(where: { $0.action == .focus })?.before.window ?? t.originalFocus
        func verified(_ expected: [NativeSpaceWindow: StageWindowState]) async throws -> StageWindowSample {
            let s = try await session.read(t.scope)
            guard token == epoch, s.generation == t.generation, s.scope == t.scope, s.nativeID == t.nativeID, session.engineOwner == t.owner,
                  session.qualifiedHiddenState == hidden, previousSequence.map({ s.sequence > $0 }) != false,
                  s.windows == expected, s.focus == expectedFocus else { throw StageSwitchError.recoveryRequired }
            previousSequence = s.sequence
            return s
        }
        let start = try await verified(expected)
        let committed = store.groups(in: t.scope).first { $0.id == t.target && $0.verifiedActive == true }
        if t.verifiedDirectoryCommit, let committed,
           committed.members.contains(where: { $0.id == committed.selectedMember && $0.windowHint == t.preferred }),
           start.focus == t.preferred {
            let second = try await verified(expected)
            guard second.focus == t.preferred else { throw StageSwitchError.recoveryRequired }
            try update { $0.pending = nil }; return
        }
        for e in t.entries.reversed() {
            guard let after = e.after else { throw StageSwitchError.recoveryRequired }
            _ = try await verified(expected)
            let inverse: StageWindowAction?
            switch e.action {
            case .hide: inverse = .show
            case .show: inverse = .hide
            case .place: inverse = .place(e.before.frame)
            case .focus: inverse = nil
            }
            var undoCommand: StageWindowCommand?
            if let inverse {
                // Mark the ambiguous interval of the inverse as well. A crash never replays it.
                let inverseIntent = UUID()
                try update {
                    let last = $0.pending!.entries.count - 1
                    $0.pending!.entries[last].after = nil
                    $0.pending!.entries[last].undoIntent = inverseIntent
                }
                undoCommand = try await undo(inverse, intent: inverseIntent, before: after, original: e.before, t: t, session: session)
            }
            expected[e.before.window] = e.before
            _ = try await verified(expected); _ = try await verified(expected)
            if let command = undoCommand, t.owner?.backend == .corner, command.action == .hide || command.action == .show {
                try update { s in
                    s.owned.removeAll { $0.scope == t.scope && $0.hidden.window == command.before.window }
                    if command.action == .hide {
                        s.owned.append(.init(scope:t.scope,original:command.before,hidden:e.before,owner:t.owner,
                            group:command.group,member:command.member,nativeID:t.nativeID))
                    }
                    s.pending!.entries[s.pending!.entries.count-1].guardianPending = true
                }
                try await session.didVerify(command,after:e.before)
            }
            try update { _ = $0.pending?.entries.popLast() }
        }
        let restored = try await verified(initial)
        if restored.focus != t.originalFocus {
            guard let old = t.originalFocus, let window = initial[old],
                  t.before.contains(where: { $0.window == old }), store.groups(in: t.scope).contains(where: { $0.members.contains { $0.windowHint == old } })
            else { throw StageSwitchError.recoveryRequired }
            let focusIntent = UUID()
            try update { $0.pending?.entries.append(.init(action: .focus, before: window, intent: focusIntent)) }
            _ = try await undo(.focus, intent: focusIntent, before: window, original: window, t: t, session: session)
            expectedFocus = old
            for _ in 0..<2 { guard try await verified(initial).focus == old else { throw StageSwitchError.recoveryRequired } }
        }
        try update { state in
            state.owned.removeAll { $0.scope == t.scope }; state.owned.append(contentsOf: t.ownedBefore); state.pending = nil
        }
    }
    private func undo(_ action: StageWindowAction, intent: UUID, before: StageWindowState, original: StageWindowState,
                      t: Transaction, session: StageWindowSession) async throws -> StageWindowCommand? {
        if t.intent != nil, let group = store.groups(in: t.scope).first(where: { $0.members.contains { $0.windowHint == before.window } }),
           let member = group.members.first(where: { $0.windowHint == before.window }) {
            let command = StageWindowCommand(intent:intent,group:group.id,member:member.id,generation:t.generation,
                scope:t.scope,nativeID:t.nativeID,action:action,before:before,restoring:action == .show,restoreFrame:original.frame)
            try await session.dispatch(command)
            return command
        } else {
            guard t.owner == nil else { throw StageSwitchError.recoveryRequired }
            try await session.apply(action, to: before, in: t.scope, generation: t.generation)
            return nil
        }
    }

    /// Freeze first. An old owner may release independently confirmed hides. Neither an ambiguous write nor
    /// a modified/reused window becomes an instruction to the replacement backend.
    public func releaseOwned(_ session: StageWindowSession) async throws {
        guard !busy else { throw StageSwitchError.busy }
        guard let owner = session.engineOwner, ledger.owner == owner else { throw StageSwitchError.ownership }
        busy = true; defer { busy = false }
        let token = epoch, touched = Set(ledger.pending?.entries.filter { $0.after == nil }.map { $0.before.window } ?? [])
        try withdrawVerifiedActivity()
        for entry in ledger.owned where entry.owner == owner && !touched.contains(entry.hidden.window) &&
                !(ledger.releases ?? []).contains(where: { $0.owned.hidden.window == entry.hidden.window }) {
            guard token == epoch, session.engineOwner == owner,
                  let group = entry.group, let member = entry.member, let native = entry.nativeID else { break }
            do {
                let one = try await session.read(entry.scope)
                let two = try await session.read(entry.scope)
                guard token == epoch, one.scope == entry.scope, two.scope == one.scope, two.nativeID == native, one.nativeID == native,
                      one.windows == two.windows, one.focus == two.focus, one.generation == two.generation,
                      one.sequence < two.sequence, two.windows[entry.hidden.window] == entry.hidden else { continue }
                let intent = UUID()
                try update { $0.releases = ($0.releases ?? []) + [.init(intent: intent, owned: entry)] }
                let command = StageWindowCommand(intent:intent,group:group,member:member,generation:two.generation,
                    scope:entry.scope,nativeID:native,action:.show,before:entry.hidden,restoring:true,restoreFrame:entry.original.frame)
                try await session.dispatch(command)
                var expected = two.windows; expected[entry.hidden.window] = entry.original
                var sequence = two.sequence
                for _ in 0..<2 {
                    let after = try await session.read(entry.scope)
                    guard token == epoch, session.engineOwner == owner, after.scope == two.scope, after.generation == two.generation,
                          after.nativeID == native, after.windows == expected, after.focus == two.focus,
                          after.workArea == two.workArea, after.sequence > sequence else { throw StageSwitchError.recoveryRequired }
                    sequence = after.sequence
                }
                try update { s in
                    s.owned.removeAll { $0 == entry }
                    if let i = s.releases?.firstIndex(where:{ $0.intent == intent }) { s.releases?[i].restored = true }
                }
                if owner.backend == .corner { try await session.didVerify(command,after:entry.original) }
                try update { $0.releases?.removeAll { $0.intent == intent } }
            } catch {
                guard token == epoch else { throw StageSwitchError.interrupted }
                // Proceed only after independent re-admission of the other window and its bystanders.
                continue
            }
        }
        if let pending = ledger.pending, ledger.owned.isEmpty, (ledger.releases ?? []).isEmpty {
            try await confirmInterruptedRelease(pending, owner: owner, session: session, token: token)
        }
        guard token == epoch, ledger.owned.isEmpty, ledger.pending == nil, (ledger.releases ?? []).isEmpty else {
            throw StageSwitchError.recoveryRequired
        }
        // Retain the durable owner until the prior worker has also positively confirmed zero leases and closed.
    }

    /// Closing a yielded Stage transaction is read-only. An uncertain primitive, layout change
    /// or incomplete Guardian exchange remains the former worker's responsibility.
    private func confirmInterruptedRelease(_ pending: Transaction, owner: StageEngineOwner,
                                           session: StageWindowSession, token: UUID) async throws {
        guard pending.owner == owner, pending.generation == owner.generation, let transaction = pending.intent,
              let focus = pending.yieldedFocus, let area = pending.workArea, !pending.verifiedDirectoryCommit,
              !pending.entries.isEmpty, pending.entries.allSatisfy({ entry in
                  guard entry.intent != nil, entry.after != nil, entry.undoIntent == nil, entry.guardianPending != true else { return false }
                  switch entry.action { case .hide, .show, .focus: return true; case .place: return false }
              }) else { throw StageSwitchError.recoveryRequired }
        var expected = Dictionary(uniqueKeysWithValues: pending.before.map { ($0.window, $0) })
        for held in pending.ownedBefore {
            guard held.owner == owner, held.scope == pending.scope, expected[held.hidden.window] == held.hidden else {
                throw StageSwitchError.recoveryRequired
            }
            expected[held.hidden.window] = held.original
        }
        func read() async throws -> UInt64 {
            let sample = try await session.read(pending.scope)
            guard epoch == token, session.engineOwner == owner, sample.generation == owner.generation, sample.scope == pending.scope,
                  sample.nativeID == pending.nativeID, sample.workArea == area, sample.focus == focus,
                  sample.windows == expected else { throw StageSwitchError.recoveryRequired }
            return sample.sequence
        }
        let first = try await read(), second = try await read()
        guard first < second else { throw StageSwitchError.recoveryRequired }
        try update {
            $0.lastInterruptedRelease = .init(transaction: transaction, owner: owner, scope: pending.scope, focus: focus,
                                              firstSequence: first, secondSequence: second)
            $0.pending = nil
        }
    }

    func confirmReleased(_ owner: StageEngineOwner) throws {
        guard !busy, ledger.pending == nil, ledger.owned.isEmpty, (ledger.releases ?? []).isEmpty else {
            throw StageSwitchError.recoveryRequired
        }
        guard let stamped = ledger.owner else { return }
        guard stamped == owner else { throw StageSwitchError.ownership }
        try update { $0.owner = nil; $0.releases = nil; $0.activeScopes = nil }
    }

}
