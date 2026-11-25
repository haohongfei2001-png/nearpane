import Darwin
import Foundation

/// Independent AX and WindowServer readback. An adapter must withhold a sample when the two
/// disagree or when it cannot enumerate the bystanders in this display's ordinary desktop.
public struct StageWindowState: Codable, Equatable, Sendable {
    public static let maximumParkedExtent = 256.0
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
    /// Public WindowServer stacking order for the independently visible, retained windows.
    public let frontToBack: [NativeSpaceWindow]
    public init(scope: StageGroupScope, generation: UUID, sequence: UInt64, workArea: SurfaceRect,
                windows: [NativeSpaceWindow: StageWindowState], focus: NativeSpaceWindow?, nativeID: UInt64? = nil,
                foreignFocusScope: StageGroupScope? = nil, frontToBack: [NativeSpaceWindow] = []) {
        self.scope = scope; self.generation = generation; self.sequence = sequence
        self.workArea = workArea; self.windows = windows; self.focus = focus; self.nativeID = nativeID
        self.foreignFocusScope = foreignFocusScope
        self.frontToBack = frontToBack
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
    /// Read an already-issued Guardian release. This path must never issue a window or Guardian command.
    func readsFinalRelease(_ command: StageWindowCommand) async -> Bool
    func prepareBackend(_ sample: StageWindowSample) async throws
    func checkHealth() async throws
    func checkRetirementSurface(_ sample: StageWindowSample, bottomOnly: Bool) async throws
    func read(_ scope: StageGroupScope) async throws -> StageWindowSample
    func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws
}

public struct StageWindowCommand: Equatable, Sendable {
    public let intent, group, member, generation: UUID
    public let scope: StageGroupScope, nativeID: UInt64?, action: StageWindowAction, before: StageWindowState
    public let restoring: Bool, restoreFrame: SurfaceRect?
}

public extension StageWindowSession {
    func mayManage(_ state: StageWindowState) -> Bool { true }
    func prepareBackend(_ sample: StageWindowSample) async throws {}
    func checkRetirementSurface(_ sample: StageWindowSample, bottomOnly: Bool) async throws { throw StageSwitchError.unavailable }
    func didVerify(_ command: StageWindowCommand, after: StageWindowState) async throws {}
    func readsFinalRelease(_ command: StageWindowCommand) async -> Bool { false }
    var engineOwner: StageEngineOwner? { nil }
    func dispatch(_ c: StageWindowCommand) async throws {
        try await apply(c.action, to: c.before, in: c.scope, generation: c.generation)
    }
}

public enum StageSwitchError: LocalizedError, Equatable {
    case busy, unavailable, interrupted, workAreaObstructed, incomplete, ownership, recoveryRequired, superseded

    public var errorDescription: String? {
        switch self {
        case .busy: return "已有窗口操作正在进行。"
        case .unavailable: return "当前环境暂不能切换整个窗口组。"
        case .interrupted: return "窗口或焦点已变化，本次切换已停止。"
        case .workAreaObstructed: return "系统界面占用了窗口退场区域，本次切换已停止。"
        case .incomplete: return "尚未核对完整的窗口组状态。"
        case .ownership: return "窗口归属已变化，请重新选择。"
        case .recoveryRequired: return "上一次窗口操作仍有待确认的恢复记录。"
        case .superseded: return "已收到新的工作集合选择。"
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
        var undoBefore: StageWindowState? = nil
        var measuredReturnIntent: UUID? = nil
        var guardianPending: Bool? = nil
        var group: UUID? = nil
        var member: UUID? = nil
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
        var focusAtSurfaceInterruption: NativeSpaceWindow? = nil
    }
    struct Release: Codable {
        let intent: UUID, owned: Ownership
        var restored: Bool? = nil
    }
    struct InterruptedRelease: Codable {
        let transaction: UUID, owner: StageEngineOwner, scope: StageGroupScope, focus: NativeSpaceWindow
        let firstSequence, secondSequence: UInt64
    }
    package struct HidePrimitive: Codable, Equatable {
        package let transaction, intent, group, member: UUID
        package let owner: StageEngineOwner, scope: StageGroupScope, nativeID: UInt64, before: StageWindowState
        package var measuredReturnIntent: UUID? = nil
    }
    struct Ledger: Codable {
        var version = 1
        var owned = [Ownership]()
        var pending: Transaction?
        var owner: StageEngineOwner?
        var releases: [Release]?
        var activeScopes: [StageGroupScope]?
        var lastInterruptedRelease: InterruptedRelease?
        var lastWithdrawnHide, lastGuardianReturn: HidePrimitive?
        var lastLiveCornerReturn: HidePrimitive?
    }

    private let store: StageGroupStore, file: URL
    private var ledger = Ledger(), bytes: Data?
    private var journalCommitUnconfirmed = false
    private var busy = false
    private var epoch = UUID()
    private var groupStacking = [UUID: [NativeSpaceWindow]]()

    // A queued card may outlive its parked representation. Only this executor's most
    // recent, fully read-back show prefix can admit that card on its next activation.
    private struct YieldedRestore {
        let group: UUID, owner: StageEngineOwner, sample: StageWindowSample
        let formerLeases: [Ownership], shown: Set<UUID>

        func matches(_ next: StageWindowSample) -> Bool {
            next.scope == sample.scope && next.nativeID == sample.nativeID && next.generation == sample.generation &&
                next.sequence > sample.sequence && next.windows == sample.windows && next.workArea == sample.workArea &&
                next.focus == sample.focus && next.foreignFocusScope == sample.foreignFocusScope
        }
    }
    private var yieldedRestore: YieldedRestore?

    package func confirmsYieldedHeldMember(group: UUID, member: UUID, window: NativeSpaceWindow, lifetime: UUID,
                                           owner: StageEngineOwner, observed: StageWindowSample) -> Bool {
        guard !busy, !requiresRecovery, ledger.owner == owner, let proof = yieldedRestore, proof.group == group,
              proof.owner == owner, proof.matches(observed),
              let prior = proof.formerLeases.first(where: { $0.member == member }), prior.hidden.window == window,
              prior.hidden.lifetime == lifetime, let state = observed.windows[window], state.lifetime == lifetime,
              let bound = store.groups(in: observed.scope).first(where: { $0.id == group })?.members.first(where: { $0.id == member }),
              bound.windowHint == window, store.isBound(bound, to: lifetime) else { return false }
        if proof.shown.contains(member) { return state.visibility == .visible && state.hiddenSpaceID == nil }
        return state == prior.hidden && confirmsHidden(group: group, member: member, state: state, scope: observed.scope, owner: owner)
    }

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

    public var requiresRecovery: Bool { journalCommitUnconfirmed || ledger.pending != nil || !(ledger.releases ?? []).isEmpty }
    public func awaitsFinalRelease(_ intent: UUID, from owner: StageEngineOwner) -> Bool {
        guard !journalCommitUnconfirmed, ledger.owner == owner, owner.backend == .corner,
              ledger.pending == nil, ledger.owned.isEmpty, let releases = ledger.releases,
              releases.allSatisfy({ $0.restored == true && $0.owned.owner == owner }) else { return false }
        return releases.contains { $0.intent == intent }
    }
    public var retainedOwner: StageEngineOwner? { ledger.owner }

    /// A frozen read plan for a former Host. It is not a replacement window
    /// session: the caller must prove that the old worker cannot issue anything
    /// further, then independently read the original windows and private Spaces.
    package struct ColdSpacesReturn: Equatable, Sendable {
        package let owner: StageEngineOwner
        package let windows: [StageWindowReturn]
        package let hiddenSpaces: [UInt64]
        fileprivate let journal: Data
    }

    package func coldSpacesReturn() throws -> ColdSpacesReturn? {
        guard let owner = ledger.owner, owner.backend == .spaces else { return nil }
        guard !busy, !journalCommitUnconfirmed, let bytes else { throw StageSwitchError.recoveryRequired }
        let windows = try systemReturnRequirements(for: owner)
        let prior = ledger.owned + (ledger.releases ?? []).map(\.owned) + (ledger.pending?.ownedBefore ?? [])
        var states = prior.map(\.hidden)
        if let pending = ledger.pending {
            states += pending.before
            states += pending.entries.flatMap { [$0.before, $0.after, $0.undoBefore].compactMap { $0 } }
        }
        let hidden = states.filter { $0.visibility == .stageSpace }
        guard hidden.allSatisfy({ ($0.hiddenSpaceID ?? 0) > 0 }) else { throw StageSwitchError.recoveryRequired }
        return .init(owner: owner, windows: windows, hiddenSpaces: Set(hidden.compactMap(\.hiddenSpaceID)).sorted(), journal: bytes)
    }

    /// Both empty and nonempty WALs require explicit worker completion. An empty
    /// window list can still belong to an unresolved controller-owned launch canary.
    package func finishColdSpacesReturn(_ expected: ColdSpacesReturn, workerFinished: Bool,
                                        physicalReturnConfirmed: Bool) throws {
        guard workerFinished, physicalReturnConfirmed, try coldSpacesReturn() == expected else {
            throw StageSwitchError.recoveryRequired
        }
        try confirmSystemReturn(expected.windows, owner: expected.owner)
    }

    /// Cold startup holds the profile writer lock. Consume only the last failed HIDE
    /// whose original Guardian proved a physical return. No window or focus is written.
    package func finishExitedGuardianReturn(confirmed: (HidePrimitive) -> Bool) throws {
        guard !busy, !journalCommitUnconfirmed, (ledger.releases ?? []).isEmpty, var pending = ledger.pending,
              !pending.verifiedDirectoryCommit, let owner = ledger.owner, owner.backend == .corner,
              pending.owner == owner, pending.generation == owner.generation, let transaction = pending.intent,
              let nativeID = pending.nativeID, nativeID > 0, let entry = pending.entries.last, entry.action == .hide,
              let intent = entry.intent, let group = entry.group, let member = entry.member,
              entry.after == nil, entry.undoIntent == nil, entry.guardianPending == nil,
              entry.before.visibility == .visible, entry.before.hiddenSpaceID == nil,
              pending.before.contains(entry.before), !ledger.owned.contains(where: { $0.hidden.window == entry.before.window }),
              pending.entries.count > 1 || pending.ownedBefore == ledger.owned.filter({ $0.scope == pending.scope })
        else { return }
        let returned = HidePrimitive(transaction: transaction, intent: intent, group: group, member: member,
                                     owner: owner, scope: pending.scope, nativeID: nativeID, before: entry.before,
                                     measuredReturnIntent: entry.measuredReturnIntent)
        guard confirmed(returned) else { return }
        try verifyJournal()
        pending.entries.removeLast()
        let finished = pending.entries.isEmpty && ledger.owned.isEmpty
        if finished { try withdrawVerifiedActivity() }
        try update {
            $0.lastGuardianReturn = returned
            $0.pending = pending.entries.isEmpty ? nil : pending
            if finished { $0.owner = nil; $0.activeScopes = nil }
        }
    }
    /// An idle check never tries to regain focus. An external takeover withdraws the active claim.
    public func observesActiveGroup(_ sample: StageWindowSample, owner: StageEngineOwner,
                                    mayManage: (StageWindowState) -> Bool = { _ in true },
                                    requiringActiveFocus: Bool = true) -> Bool {
        guard !busy, !requiresRecovery, ledger.owner == owner, sample.generation == owner.generation else { return false }
        let groups = store.participatingGroups(in: sample.scope) { key in
            guard let state = sample.windows[key], mayManage(state) else { return nil }
            return state.lifetime
        }
        guard let group = groups.first(where: { $0.verifiedActive == true }) else { return false }
        if requiringActiveFocus {
            guard let focus = sample.focus else { return false }
            if let other = sample.foreignFocusScope {
                guard other.display != sample.scope.display, sample.windows[focus] == nil else { return false }
            } else if sample.windows[focus]?.visibility != .visible || !group.members.contains(where: { $0.windowHint == focus }) {
                return false
            }
        }
        return matchesActiveSet(group, groups: groups, sample: sample)
    }

    private func matchesActiveSet(_ active: StageGroupDirectory.Group, groups: [StageGroupDirectory.Group],
                                  sample: StageWindowSample) -> Bool {
        let leases = ledger.owned.filter { $0.scope == sample.scope }
        let held = Dictionary(uniqueKeysWithValues: leases.map { ($0.hidden.window, $0) })
        guard active.members.contains(where: { sample.windows[$0.windowHint]?.visibility == .visible }),
              Set(held.keys).isSubset(of: groups.flatMap { $0.members.map(\.windowHint) }),
              leases.allSatisfy({ sample.windows[$0.hidden.window] == $0.hidden }) else { return false }
        return groups.allSatisfy { group in
            group.members.allSatisfy { member in
                guard let state = sample.windows[member.windowHint], store.isBound(member, to: state.lifetime) else { return false }
                if let lease = held[state.window] {
                    return group.id != active.id && lease.group == group.id && lease.member == member.id && lease.hidden == state
                }
                return (state.visibility == .minimized && state.hiddenSpaceID == nil) ||
                    (group.id == active.id && state.visibility == .visible)
            }
        }
    }
    public func confirmsHidden(group: UUID, member: UUID, state: StageWindowState, scope: StageGroupScope, owner: StageEngineOwner) -> Bool {
        !busy && !requiresRecovery && ledger.owner == owner &&
            ledger.owned.contains { $0.scope == scope && $0.group == group && $0.member == member && $0.hidden == state && $0.owner == owner }
    }
    public var hasWindowAuthority: Bool { busy || !ledger.owned.isEmpty || requiresRecovery || ledger.owner != nil }
    public func permitsRetirement(of key: NativeSpaceWindow) -> Bool {
        !busy && !requiresRecovery && !ledger.owned.contains { $0.hidden.window == key }
    }
    public func invalidate() { epoch = UUID(); yieldedRestore = nil }
    public func withdrawVerifiedActivity() throws {
        guard ledger.owner != nil else { return }
        let scopes = Set((ledger.activeScopes ?? []) + ledger.owned.map(\.scope) + [ledger.pending?.scope].compactMap { $0 })
        try store.withdrawActivity(in: scopes)
    }

    private func disk() throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }

    private func verifyJournal() throws {
        guard !journalCommitUnconfirmed else { throw StageSwitchError.recoveryRequired }
        try ProfileLease.checkPath(file)
        guard try disk() == bytes else { throw StageSwitchError.recoveryRequired }
    }

    private func save(_ next: Ledger) throws {
        try verifyJournal()
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        let temporary = directory.appendingPathComponent(".stage-visibility-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); unlink(temporary.path) }
        try output.write(contentsOf: data)
        try output.synchronize()
        guard try disk() == bytes else { throw StageSwitchError.recoveryRequired }
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // No new window action may depend on this journal until its directory entry is durable.
        journalCommitUnconfirmed = true
        try ProfileLease.syncDirectory(directory)
        if bytes == nil { try ProfileLease.syncDirectory(directory.deletingLastPathComponent()) }
        guard try disk() == data else { throw StageSwitchError.recoveryRequired }
        bytes = data; ledger = next
        journalCommitUnconfirmed = false
    }

    private func update(_ edit: (inout Ledger) -> Void) throws {
        var next = ledger; edit(&next); try save(next)
    }

    private func recordWithdrawal(_ proof: UnsubmittedCornerHide, command: StageWindowCommand, transaction: UUID,
                                  target: UUID, owner: StageEngineOwner?, yieldingToChoice: Bool) throws {
        // A failed admission yields the current switch. Earlier actions stay recorded for their
        // original owner; no focus or geometry compensation runs against a possible new user intent.
        if !yieldingToChoice { invalidate() }
        guard proof.command == command, owner == proof.owner, proof.owner.backend == .corner,
              command.generation == proof.owner.generation, command.action == .hide, !command.restoring,
              command.before.visibility == .visible, command.restoreFrame == nil, let nativeID = command.nativeID,
              ledger.owner == owner, var pending = ledger.pending, pending.owner == owner,
              pending.intent == transaction, pending.target == target, pending.scope == command.scope,
              pending.nativeID == nativeID, pending.generation == command.generation, !pending.verifiedDirectoryCommit,
              let entry = pending.entries.last, entry.action == .hide, entry.intent == command.intent,
              entry.group == command.group, entry.member == command.member, entry.before == command.before,
              entry.after == nil, entry.undoIntent == nil, entry.guardianPending == nil,
              !ledger.owned.contains(where: { $0.hidden.window == command.before.window })
        else { throw StageSwitchError.recoveryRequired }
        pending.entries.removeLast()
        if let focus = proof.yieldedFocus { pending.yieldedFocus = focus }
        try update {
            $0.pending = pending.entries.isEmpty ? nil : pending
            $0.lastWithdrawnHide = .init(transaction: transaction, intent: command.intent, group: command.group,
                member: command.member, owner: proof.owner, scope: command.scope, nativeID: nativeID, before: command.before)
        }
    }

    private func absolute(_ relative: SurfaceRect, work: SurfaceRect) -> SurfaceRect {
        .init(x: work.x + relative.x * work.width, y: work.y + relative.y * work.height,
              width: relative.width * work.width, height: relative.height * work.height)
    }
    private func matches(_ a: SurfaceRect, _ b: SurfaceRect) -> Bool {
        abs(a.x-b.x) <= 1 && abs(a.y-b.y) <= 1 && abs(a.width-b.width) <= 1 && abs(a.height-b.height) <= 1
    }

    /// A trusted AX miniaturization event retires one previously enrolled window.
    /// The engine first moves the minimized window into its hidden Space and only then
    /// clears AXMinimized. Previously minimized Dock windows never enter this method.
    public func retireMinimized(_ window: NativeSpaceWindow, in scope: StageGroupScope,
                                session: StageWindowSession, current: @escaping @MainActor () -> Bool) async throws {
        guard !busy, !requiresRecovery, let owner = session.engineOwner, owner.backend == .spaces,
              session.qualifiedHiddenState == .stageSpace, ledger.owner == owner,
              !ledger.owned.contains(where: { $0.hidden.window == window }), current() else {
            throw StageSwitchError.unavailable
        }
        busy = true
        defer { busy = false }
        let token = epoch
        let first = try await session.read(scope)
        guard current(), token == epoch, first.generation == owner.generation,
              let before = first.windows[window], before.visibility == .minimized, before.hiddenSpaceID == nil,
              session.mayManage(before), let native = first.nativeID, native > 0,
              let existing = store.groups(in: scope).first(where: { $0.members.contains { $0.windowHint == window } }),
              let oldMember = existing.members.first(where: { $0.windowHint == window }), store.isBound(oldMember, to: before.lifetime),
              let layout = StageGroupWindow.relativeFrame(before.frame, in: first.workArea) else { throw StageSwitchError.ownership }
        if existing.members.count > 1 {
            guard !ledger.owned.contains(where: { $0.group == existing.id }) else { throw StageSwitchError.ownership }
            try store.detach(.init(display:scope.display, identity:window, lifetime:before.lifetime,
                layout:layout, nativeSpace:scope.nativeSpace), from:existing.id)
        }
        guard let group = store.groups(in:scope).first(where: { $0.members.contains { $0.windowHint == window } }),
              let member = group.members.first(where: { $0.windowHint == window }) else { throw StageSwitchError.ownership }
        let directory = store.directory, intent = UUID(), primitive = UUID()
        var original = before
        original.visibility = .visible
        try update {
            $0.pending = .init(scope:scope, generation:first.generation, target:group.id, preferred:window,
                originalFocus:first.focus, before:Array(first.windows.values), ownedBefore:$0.owned.filter { $0.scope == scope },
                entries:[.init(action:.hide, before:before, intent:primitive, group:group.id, member:member.id)],
                owner:owner, intent:intent, nativeID:native, workArea:first.workArea)
        }
        let command = StageWindowCommand(intent:primitive, group:group.id, member:member.id, generation:first.generation,
            scope:scope, nativeID:native, action:.hide, before:before, restoring:false, restoreFrame:nil)
        try await session.dispatch(command)
        var last = first, hidden: StageWindowState?
        for _ in 0..<2 {
            let sample = try await session.read(scope)
            guard current(), token == epoch, sample.generation == first.generation, sample.nativeID == native,
                  sample.sequence > last.sequence, sample.windows.keys == first.windows.keys,
                  let after = sample.windows[window], after.lifetime == before.lifetime,
                  after.visibility == .stageSpace, let hiddenID = after.hiddenSpaceID, hiddenID > 0, hiddenID != native,
                  matches(after.frame, original.frame), sample.focus != window,
                  hidden == nil || hidden == after,
                  first.windows.keys.filter({ $0 != window }).allSatisfy({ first.windows[$0] == sample.windows[$0] })
            else { throw StageSwitchError.incomplete }
            hidden = after; last = sample
        }
        guard let hidden else { throw StageSwitchError.incomplete }
        try await session.didVerify(command, after:hidden)
        try update {
            $0.pending?.entries[0].after = hidden
            $0.owned.append(.init(scope:scope, original:original, hidden:hidden, owner:owner,
                group:group.id, member:member.id, nativeID:native))
        }
        let focused = last.focus.flatMap { focus in
            store.groups(in:scope).first { group in group.members.contains { $0.windowHint == focus } }
                .flatMap { group in group.members.first { $0.windowHint == focus }.map { (group.id, $0.id) } }
        }
        try store.saveObservedActivity(focused, in:scope, expected:directory, verifiedLayouts:[member.id:layout])
        try update { $0.pending = nil }
    }

    /// The caller supplies the current explicit selection and its enrolled window identities.
    /// Spaces may start from a known desktop focus or restore an entirely retired workset.
    public func activate(_ group: UUID, member: UUID?, in scope: StageGroupScope,
                         consent: Bool, session: StageWindowSession,
                         resumingFrom: StageWindowSample? = nil,
                         current: @MainActor () -> Bool = { true },
                         newerChoice: @MainActor () -> Bool = { false }) async throws {
        guard !busy else { throw StageSwitchError.busy }
        let previous = yieldedRestore
        if resumingFrom == nil { yieldedRestore = nil }
        guard !requiresRecovery, ledger.owner == nil || ledger.owner == session.engineOwner,
              ledger.owned.allSatisfy({ $0.owner == session.engineOwner }) else { throw StageSwitchError.recoveryRequired }
        guard consent, let mechanism = session.qualifiedHiddenState,
              (mechanism == .stageSpace && session.engineOwner?.backend == .spaces) ||
              (mechanism == .parked && session.engineOwner?.backend == .corner) else {
            throw StageSwitchError.unavailable
        }
        busy = true
        defer {
            busy = false
            if Task.isCancelled || !newerChoice() || requiresRecovery { yieldedRestore = nil }
        }
        let token = epoch, directory = store.directory
        func requireCurrentIntent() throws {
            guard epoch == token, !Task.isCancelled else { throw StageSwitchError.interrupted }
            if !current() { throw newerChoice() ? StageSwitchError.superseded : .interrupted }
        }
        try requireCurrentIntent()
        var first = try await session.read(scope)
        try requireCurrentIntent()
        if let resumingFrom {
            guard let previous, previous.group == group, previous.owner == session.engineOwner,
                  previous.matches(resumingFrom), previous.matches(first), first.sequence > resumingFrom.sequence
            else { throw StageSwitchError.interrupted }
        }
        let groups = store.participatingGroups(in: scope) { key in
            guard let state = first.windows[key], session.mayManage(state) else { return nil }
            return state.lifetime
        }
        guard let target = groups.first(where: { $0.id == group }) else { throw StageSwitchError.incomplete }
        let enrolled = groups.flatMap(\.members), enrolledIDs = Set(enrolled.map(\.windowHint))
        guard epoch == token, first.scope == scope, first.workArea.width > 0, first.workArea.height > 0,
              enrolledIDs.count == enrolled.count, enrolledIDs.isSubset(of: Set(first.windows.keys)),
              first.windows.allSatisfy({ $0.key == $0.value.window }),
              enrolled.allSatisfy({ m in first.windows[m.windowHint].map { state in store.isBound(m, to: state.lifetime) } == true }),
              mechanism == .stageSpace || groups.contains(where: { $0.verifiedActive == true }) ||
                  first.focus.map(enrolledIDs.contains) == true
        else { throw StageSwitchError.incomplete }
        // A Spaces click can restore the last yellow-minimized group or start from
        // Finder's desktop. Consent, the selected retained window and all bystanders
        // were verified above; restore/focus the incoming group before retiring any
        // other window. The historical Corner first-focus requirement stays local.
        let originalHeld = ledger.owned.filter { $0.scope == scope }
        let held = Dictionary(uniqueKeysWithValues: originalHeld.map { ($0.hidden.window,$0) })
        guard originalHeld.allSatisfy({ enrolledIDs.contains($0.hidden.window) && first.windows[$0.hidden.window] == $0.hidden }) else {
            throw StageSwitchError.ownership
        }
        // An independently observed user-minimized window remains in its workset. It has no engine lease.
        let members = enrolled.filter { m in
            guard let state = first.windows[m.windowHint] else { return false }
            return held[m.windowHint] != nil || state.visibility != .minimized || state.hiddenSpaceID != nil
        }
        let ids = Set(members.map(\.windowHint))
        guard ids.allSatisfy({ held[$0] != nil || first.windows[$0]?.visibility == .visible }) else { throw StageSwitchError.ownership }
        guard let preferred = target.focusMember(requested: member, including: { ids.contains($0.windowHint) }) else {
            throw StageSwitchError.incomplete
        }
        if ledger.owner != nil, let active = groups.first(where: { $0.verifiedActive == true }),
           !matchesActiveSet(active, groups: groups, sample: first) { throw StageSwitchError.interrupted }
        let activeMembers = target.members.filter { ids.contains($0.windowHint) }, targets = Set(activeMembers.map(\.windowHint))
        // Capture the actual order before retirement. Hidden windows have no meaningful
        // onscreen rank; their last visible order survives in this coordinator instead.
        for visibleGroup in groups {
            let keys = Set(visibleGroup.members.filter { ids.contains($0.windowHint) }.map(\.windowHint))
            let order = first.frontToBack.filter(keys.contains)
            if !keys.isEmpty, order.count == keys.count, Set(order) == keys,
               keys.allSatisfy({ first.windows[$0]?.visibility == .visible }) {
                groupStacking[visibleGroup.id] = order
            }
        }
        let expectedStack = groupStacking[group].flatMap { order -> [NativeSpaceWindow]? in
            guard order.count == targets.count, Set(order) == targets else { return nil }
            return [preferred.windowHint] + order.filter { $0 != preferred.windowHint }
        }
        let alreadyVisible = target.verifiedActive == true && first.focus.map(targets.contains) == true &&
            Set(held.keys) == ids.subtracting(targets)
        var targetLayouts = [UUID: SurfaceRect]()
        for m in activeMembers {
            if alreadyVisible {
                guard let current = first.windows[m.windowHint],
                      let layout = StageGroupWindow.relativeFrame(current.frame, in: first.workArea) else { throw StageSwitchError.incomplete }
                targetLayouts[m.id] = layout
            } else { targetLayouts[m.id] = m.layout }
        }
        let otherIDs = first.windows.keys.filter { !ids.contains($0) }
        let intent = UUID(), owner = session.engineOwner
        let ownsScope = ledger.owner == owner && (ledger.activeScopes ?? []).contains(scope)
        guard owner == nil || (first.nativeID ?? 0) > 0 else { throw StageSwitchError.unavailable }
        if let owner {
            // An unavailable corner is known before showing another member or transferring the keyboard.
            let outgoing = first.windows.values.filter { ids.contains($0.window) && !targets.contains($0.window) && held[$0.window] == nil }
            if !outgoing.isEmpty && mechanism == .parked {
                guard outgoing.allSatisfy({ $0.frame.height.isFinite && $0.frame.height > 0 }) else { throw StageSwitchError.incomplete }
                let bottomOnly = outgoing.contains { $0.frame.height > StageWindowState.maximumParkedExtent }
                try await session.checkRetirementSurface(first, bottomOnly: bottomOnly)
                try requireCurrentIntent()
            }
            // Record the worker before preparing it. A failed health check cannot imply a window was hidden.
            if ownsScope { try verifyJournal() }
            else {
                try update {
                    $0.owner = owner
                    if !($0.activeScopes ?? []).contains(scope) { $0.activeScopes = ($0.activeScopes ?? []) + [scope] }
                }
            }
            try await session.prepareBackend(first)
            try requireCurrentIntent()
            let postLaunch = try await session.read(scope)
            try requireCurrentIntent()
            guard epoch == token, session.qualifiedHiddenState == mechanism, session.engineOwner == owner,
                  postLaunch.scope == scope, postLaunch.generation == first.generation, postLaunch.sequence > first.sequence,
                  postLaunch.nativeID == first.nativeID, postLaunch.workArea == first.workArea,
                  postLaunch.windows == first.windows, postLaunch.focus == first.focus,
                  postLaunch.foreignFocusScope == first.foreignFocusScope else { throw StageSwitchError.interrupted }
            first = postLaunch
        }
        var last = first
        func requireFocus(_ sample: StageWindowSample, _ expected: NativeSpaceWindow?) throws {
            guard sample.focus == expected else {
                invalidate()
                if let focus = sample.focus, ledger.pending != nil { try update { $0.pending?.yieldedFocus = focus } }
                throw StageSwitchError.interrupted
            }
        }
        func read() async throws -> StageWindowSample {
            let next = try await session.read(scope)
            guard epoch == token, directory.hasSameWindowGroups(as: store.directory, in: scope), session.qualifiedHiddenState == mechanism, session.engineOwner == owner,
                  next.nativeID == first.nativeID,
                  next.scope == scope, next.generation == first.generation, next.workArea == first.workArea,
                  next.sequence > last.sequence, next.windows.keys == first.windows.keys,
                  next.windows.allSatisfy({ $0.key == $0.value.window && $0.value.lifetime == first.windows[$0.key]?.lifetime }),
                  enrolled.allSatisfy({ member in
                      guard let state = next.windows[member.windowHint] else { return false }
                      return session.mayManage(state) && store.isBound(member, to: state.lifetime)
                  }),
                  otherIDs.allSatisfy({ next.windows[$0] == first.windows[$0] }) else { throw StageSwitchError.interrupted }
            return next
        }
        func verifySelection() async throws {
            let parked = ledger.owned.filter { $0.scope == scope }
            guard Set(parked.map { $0.hidden.window }) == ids.subtracting(targets) else { throw StageSwitchError.incomplete }
            for _ in 0..<3 {
                try requireCurrentIntent()
                let next = try await read()
                try requireCurrentIntent()
                try requireFocus(next, preferred.windowHint)
                guard next.foreignFocusScope == nil, next.windows == last.windows,
                      expectedStack.map({ next.frontToBack.filter(targets.contains) == $0 }) != false,
                      parked.allSatisfy({ next.windows[$0.hidden.window] == $0.hidden }),
                      activeMembers.allSatisfy({ m in
                          guard let value = next.windows[m.windowHint], value.visibility == .visible else { return false }
                          return targetLayouts[m.id].map { matches(value.frame, absolute($0, work: first.workArea)) } ?? true
                      }) else { throw StageSwitchError.incomplete }
                last = next
            }
            if !parked.isEmpty {
                // The independent AX reads can still show the correct geometry after the
                // compositor or pointer shield has yielded. Ask the owning worker last.
                do {
                    try await session.checkHealth()
                } catch StageSwitchError.workAreaObstructed {
                    // Keep the user's last verified focus when releasing this fully observed
                    // prefix. A new click, an unknown primitive or a different focus cannot use it.
                    if epoch == token, !Task.isCancelled, current(), ledger.pending?.intent == intent {
                        try update { $0.pending?.focusAtSurfaceInterruption = last.focus }
                    }
                    throw StageSwitchError.workAreaObstructed
                }
                try requireCurrentIntent()
                guard session.engineOwner == owner, session.qualifiedHiddenState == mechanism,
                      directory.hasSameWindowGroups(as: store.directory, in: scope) else { throw StageSwitchError.interrupted }
            }
        }
        // Reselecting an intact, focused workset only observes. Its previously committed leases remain authoritative.
        if ownsScope, alreadyVisible, first.focus == preferred.windowHint, first.foreignFocusScope == nil,
           target.selectedMember == preferred.id, activeMembers.allSatisfy({ targetLayouts[$0.id] == $0.layout }) {
            try await verifySelection()
            try verifyJournal()
            try store.verifyPersistedDirectory()
            return
        }
        try update {
            $0.pending = .init(scope: scope, generation: first.generation, target: group, preferred: preferred.windowHint,
                originalFocus: first.focus, before: Array(first.windows.values), ownedBefore: originalHeld,
                owner: owner, intent: intent, nativeID: first.nativeID, workArea: first.workArea)
        }
        func perform(_ action: StageWindowAction, id: NativeSpaceWindow,
                     check: (StageWindowState, StageWindowSample) -> Bool) async throws {
            try requireCurrentIntent()
            let pre = try await read()
            try requireCurrentIntent()
            try requireFocus(pre, last.focus)
            guard pre.foreignFocusScope == last.foreignFocusScope, pre.windows == last.windows,
                  let before = pre.windows[id] else { throw StageSwitchError.interrupted }
            last = pre
            let primitive = UUID()
            guard let member = members.first(where: { $0.windowHint == id }),
                  let owningGroup = groups.first(where: { $0.members.contains(where: { $0.id == member.id }) }) else { throw StageSwitchError.interrupted }
            try update { $0.pending?.entries.append(.init(action: action, before: before, intent: primitive, group: owningGroup.id, member: member.id)) }
            guard epoch == token else { throw StageSwitchError.interrupted }
            let command = StageWindowCommand(intent:primitive,group:owningGroup.id,member:member.id,generation:first.generation,
                scope:scope,nativeID:first.nativeID,action:action,before:before,restoring:false,restoreFrame:held[id]?.original.frame)
            do { try await session.dispatch(command) }
            catch let proof as SupersededBeforeStageWrite {
                func canWithdraw() -> Bool {
                    guard session is StageEngineSession, proof.owner == owner, proof.command == command,
                          !Task.isCancelled, epoch == token, !current(), newerChoice(),
                          session.engineOwner == owner, session.qualifiedHiddenState == mechanism,
                          let pending = ledger.pending, pending.intent == intent, pending.target == group,
                          pending.owner == owner, !pending.verifiedDirectoryCommit, let last = pending.entries.last
                    else { return false }
                    return last.intent == primitive && last.group == command.group && last.member == command.member &&
                        last.action == action && last.before == before && last.after == nil && last.undoIntent == nil &&
                        last.measuredReturnIntent == nil && last.guardianPending == nil
                }
                guard canWithdraw() else { throw StageSwitchError.recoveryRequired }
                for _ in 0..<2 {
                    let next = try await read()
                    guard canWithdraw(), next.focus == pre.focus, next.foreignFocusScope == pre.foreignFocusScope,
                          next.windows == pre.windows else { throw StageSwitchError.recoveryRequired }
                    last = next
                }
                try update { _ = $0.pending?.entries.popLast() }
                throw StageSwitchError.superseded
            }
            catch let proof as MeasuredCornerHide {
                guard let engine = session as? StageEngineSession, proof.owner == owner, proof.command == command,
                      epoch == token, current(), !Task.isCancelled, action == .hide, before.visibility == .visible,
                      let native = command.nativeID, var pending = ledger.pending, pending.intent == intent,
                      pending.owner == owner, !pending.verifiedDirectoryCommit, let index = pending.entries.indices.last,
                      pending.entries[index].intent == primitive, pending.entries[index].after == nil,
                      pending.entries[index].undoIntent == nil, pending.entries[index].measuredReturnIntent == nil
                else { throw StageSwitchError.recoveryRequired }
                let undo = UUID()
                pending.entries[index].measuredReturnIntent = undo
                try update { $0.pending = pending }
                defer { engine.freeze(); invalidate() }
                try await engine.returnMeasured(proof, intent: undo, baseline: pre)
                try verifyJournal()
                guard ledger.pending?.intent == intent, ledger.pending?.entries.last?.measuredReturnIntent == undo
                else { throw StageSwitchError.recoveryRequired }
                pending.entries.removeLast()
                // The other entries still belong to the failed switch. A complete
                // physical return never commits its target group or replays focus.
                try update {
                    $0.pending = pending.entries.isEmpty ? nil : pending
                    $0.lastLiveCornerReturn = .init(transaction: intent, intent: primitive, group: command.group,
                        member: command.member, owner: proof.owner, scope: scope, nativeID: native, before: before,
                        measuredReturnIntent: undo)
                }
                throw StageSwitchError.incomplete
            }
            catch let proof as UnsubmittedCornerHide {
                let yielding = epoch == token && !Task.isCancelled && proof.yieldedFocus == nil &&
                    !current() && newerChoice() && session.qualifiedHiddenState == mechanism
                try recordWithdrawal(proof, command: command, transaction: intent, target: group,
                                     owner: session.engineOwner, yieldingToChoice: yielding)
                throw yielding ? StageSwitchError.superseded : .interrupted
            }
            var firstAfter: StageWindowState?
            for _ in 0..<2 {
                let post = try await read()
                try requireFocus(post, action == .focus ? id : pre.focus)
                guard post.foreignFocusScope == (action == .focus ? nil : pre.foreignFocusScope),
                      let value = post.windows[id], check(value, post),
                      firstAfter == nil || firstAfter == value,
                      action != .focus || value == before,
                      pre.windows.keys.filter({ $0 != id }).allSatisfy({ post.windows[$0] == pre.windows[$0] }) else {
                    throw StageSwitchError.incomplete
                }
                firstAfter = value
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
            for member in activeMembers {
                if let previous = held[member.windowHint] {
                    try await perform(.show, id:member.windowHint) { value, _ in
                        value.visibility == .visible && self.matches(value.frame,previous.original.frame)
                    }
                }
            }
            if let expectedStack, last.frontToBack.filter(targets.contains) != expectedStack {
                // AX focus/raise is already the exact-window production primitive. Only
                // repair stacking when the compositor did not preserve it on return.
                for id in expectedStack.reversed() where last.focus != id {
                    try await perform(.focus, id: id) { state, sample in
                        state.visibility == .visible && sample.focus == id
                    }
                }
            }
            if last.focus != preferred.windowHint {
                try await perform(.focus, id: preferred.windowHint) { state, sample in
                    state.visibility == .visible && sample.focus == preferred.windowHint
                }
            }
            var verifiedLayouts = alreadyVisible ? targetLayouts : [:]
            for m in members where !targets.contains(m.windowHint) && held[m.windowHint] == nil {
                guard let observed = last.windows[m.windowHint], observed.visibility == .visible,
                      let layout = StageGroupWindow.relativeFrame(observed.frame, in: first.workArea) else { throw StageSwitchError.incomplete }
                try await perform(.hide, id: m.windowHint) { value, _ in value.visibility == mechanism &&
                    (mechanism == .stageSpace ? (value.hiddenSpaceID ?? 0) > 0 && value.hiddenSpaceID != first.nativeID : value.hiddenSpaceID == nil) }
                verifiedLayouts[m.id] = layout
            }
            for m in activeMembers {
                let id = m.windowHint
                if let relative = targetLayouts[m.id] {
                    let frame = absolute(relative, work: first.workArea)
                    if let f = last.windows[id]?.frame, !matches(f, frame) {
                        try await perform(.place(frame), id: id) { value, _ in value.visibility == .visible && self.matches(value.frame, frame) }
                    }
                }
            }
            try await verifySelection()
            try update { $0.pending?.verifiedDirectoryCommit = true }
            try store.commitActivity(group, preferred: preferred.id, in: scope, expected: directory, verifiedLayouts: verifiedLayouts)
            try update { $0.pending = nil }
        } catch {
            guard !journalCommitUnconfirmed else { throw StageSwitchError.recoveryRequired }
            if ledger.pending?.entries.isEmpty == true { try update { $0.pending = nil } }
            else if (error as? StageSwitchError) == .superseded, let pending = ledger.pending {
                // Keep the same executor and its sealed leases. Only retire a fully observed prefix.
                guard pending.intent == intent, !pending.verifiedDirectoryCommit,
                      pending.entries.allSatisfy({ $0.after != nil && $0.guardianPending != true && $0.undoIntent == nil }),
                      (ledger.releases ?? []).isEmpty else { throw StageSwitchError.recoveryRequired }
                let expected = last
                for _ in 0..<2 {
                    let next = try await read()
                    guard newerChoice(), !Task.isCancelled, next.focus == expected.focus, next.foreignFocusScope == expected.foreignFocusScope,
                          next.windows == expected.windows else { throw StageSwitchError.recoveryRequired }
                    last = next
                }
                if !ledger.owned.isEmpty {
                    try await session.checkHealth()
                    guard newerChoice(), !Task.isCancelled, epoch == token, session.engineOwner == owner,
                          session.qualifiedHiddenState == mechanism else { throw StageSwitchError.recoveryRequired }
                }
                var layouts = [UUID: SurfaceRect]()
                for entry in pending.entries where entry.action == .hide {
                    guard let member = entry.member, let frame = StageGroupWindow.relativeFrame(entry.before.frame, in: first.workArea),
                          ledger.owned.contains(where: { $0.owner == owner && $0.scope == scope && $0.member == member &&
                              $0.original == entry.before && $0.hidden == entry.after }) else { throw StageSwitchError.recoveryRequired }
                    layouts[member] = frame
                }
                try store.saveObservedActivity(nil, in: scope, expected: directory, verifiedLayouts: layouts)
                try update { $0.pending = nil }
                let resumed = resumingFrom == nil ? nil : previous
                let shown = Set(pending.entries.filter { $0.action == .show && $0.group == group }.compactMap(\.member))
                    .union(resumed?.shown ?? [])
                if let owner, !shown.isEmpty {
                    yieldedRestore = .init(group: group, owner: owner, sample: last,
                        formerLeases: resumed?.formerLeases ?? originalHeld.filter { $0.group == group && $0.owner == owner }, shown: shown)
                }
            } else if epoch == token, current(), !Task.isCancelled, ledger.pending?.verifiedDirectoryCommit == false {
                // A revoked generation or a may-have-issued entry cannot be rolled back by inference.
                _ = try? await compensate(session, token: token, current: current)
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

    private func compensate(_ session: StageWindowSession, token: UUID, current: @MainActor () -> Bool = { true }) async throws {
        guard !journalCommitUnconfirmed else { throw StageSwitchError.recoveryRequired }
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
            guard token == epoch, current(), !Task.isCancelled, s.generation == t.generation, s.scope == t.scope, s.nativeID == t.nativeID, session.engineOwner == t.owner,
                  session.qualifiedHiddenState == hidden, previousSequence.map({ s.sequence > $0 }) != false,
                  t.workArea.map({ $0 == s.workArea }) != false, s.foreignFocusScope == nil,
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
        for index in t.entries.indices.reversed() {
            let e = t.entries[index]
            guard let after = e.after else { throw StageSwitchError.recoveryRequired }
            _ = try await verified(expected)
            let inverse: StageWindowAction?
            var inverseBefore = after
            switch e.action {
            case .hide: inverse = .show
            case .show:
                guard let focus = expectedFocus, focus == t.originalFocus, focus != after.window,
                      expected[focus]?.visibility == .visible else { throw StageSwitchError.recoveryRequired }
                if t.owner?.backend == .corner {
                    guard t.ownedBefore.contains(where: {
                        $0.owner == t.owner && $0.scope == t.scope && $0.nativeID == t.nativeID &&
                        $0.member == e.member && $0.group == e.group && $0.hidden == e.before && $0.original == after
                    }) else { throw StageSwitchError.recoveryRequired }
                }
                inverse = .hide
            case .place: inverse = .place(e.before.frame)
            case .focus:
                // An incoming window can be parked again only after the previous responder has the keyboard.
                let previous = t.entries[..<index].last(where: { $0.action == .focus })?.before.window ?? t.originalFocus
                if previous == expectedFocus {
                    inverse = nil
                } else {
                    guard let previous, let state = expected[previous], state.visibility == .visible,
                          initial[previous]?.lifetime == state.lifetime, session.mayManage(state),
                          store.groups(in: t.scope).contains(where: { group in group.members.contains {
                              $0.windowHint == previous && store.isBound($0, to: state.lifetime)
                          } }) else { throw StageSwitchError.recoveryRequired }
                    inverseBefore = state
                    inverse = .focus
                }
            }
            var undoCommand: StageWindowCommand?
            if let inverse {
                // Mark the ambiguous interval of the inverse as well. A crash never replays it.
                let inverseIntent = UUID()
                try update {
                    let last = $0.pending!.entries.count - 1
                    $0.pending!.entries[last].after = nil
                    $0.pending!.entries[last].undoIntent = inverseIntent
                    $0.pending!.entries[last].undoBefore = inverseBefore
                }
                undoCommand = try await undo(inverse, intent: inverseIntent, before: inverseBefore, original: e.before, t: t, session: session)
                if inverse == .focus { expectedFocus = inverseBefore.window }
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
        guard restored.focus == t.originalFocus else { throw StageSwitchError.recoveryRequired }
        try update { state in
            state.owned.removeAll { $0.scope == t.scope }; state.owned.append(contentsOf: t.ownedBefore); state.pending = nil
        }
    }
    private func undo(_ action: StageWindowAction, intent: UUID, before: StageWindowState, original: StageWindowState,
                      t: Transaction, session: StageWindowSession) async throws -> StageWindowCommand? {
        if t.intent != nil, let group = store.groups(in: t.scope).first(where: { $0.members.contains { $0.windowHint == before.window } }),
           let member = group.members.first(where: { $0.windowHint == before.window }) {
            let command = StageWindowCommand(intent:intent,group:group.id,member:member.id,generation:t.generation,
                scope:t.scope,nativeID:t.nativeID,action:action,before:before,restoring:action == .show,
                restoreFrame:action == .show || action == .hide ? original.frame : nil)
            try await session.dispatch(command)
            return command
        } else {
            guard t.owner == nil else { throw StageSwitchError.recoveryRequired }
            try await session.apply(action, to: before, in: t.scope, generation: t.generation)
            return nil
        }
    }

    private func readReleaseState(_ expected: StageWindowState, of entry: Ownership, owner: StageEngineOwner,
                                  token: UUID, session: StageWindowSession) async throws -> StageWindowSample {
        guard epoch == token, session.engineOwner == owner, entry.owner == owner, let native = entry.nativeID
        else { throw StageSwitchError.interrupted }
        let one = try await session.read(entry.scope)
        let two = try await session.read(entry.scope)
        guard epoch == token, session.engineOwner == owner, one.scope == entry.scope, two.scope == one.scope,
              one.generation == owner.generation, two.generation == owner.generation,
              one.nativeID == native, two.nativeID == native, one.sequence < two.sequence,
              one.windows == two.windows, two.windows[expected.window] == expected,
              one.workArea == two.workArea, one.focus == two.focus, one.foreignFocusScope == two.foreignFocusScope
        else { throw StageSwitchError.recoveryRequired }
        return two
    }

    func systemReturnRequirements(for owner: StageEngineOwner) throws -> [StageWindowReturn] {
        guard !busy, !journalCommitUnconfirmed, owner.backend == .spaces,
              ledger.owner == nil || ledger.owner == owner else { throw StageSwitchError.recoveryRequired }
        try verifyJournal()
        var returns = [NativeSpaceWindow: StageWindowReturn]()
        for entry in ledger.owned {
            guard entry.owner == owner, let home = entry.nativeID else { throw StageSwitchError.ownership }
            returns[entry.original.window] = .init(original:entry.original, scope:entry.scope, nativeID:home)
        }
        for release in ledger.releases ?? [] {
            let entry = release.owned
            guard entry.owner == owner, let home = entry.nativeID else { throw StageSwitchError.ownership }
            returns[entry.original.window] = .init(original:entry.original, scope:entry.scope, nativeID:home)
        }
        if let pending = ledger.pending {
            guard pending.owner == owner, let home = pending.nativeID else { throw StageSwitchError.ownership }
            // Include uncertain issued hides as well; a callback error is not proof
            // that no move happened. The engine's release settles its retained lease.
            for entry in pending.entries where entry.action == .hide || entry.action == .show {
                let original = returns[entry.before.window]?.original ??
                    pending.ownedBefore.first(where: { $0.original.window == entry.before.window })?.original ?? entry.before
                returns[entry.before.window] = .init(original:original, scope:pending.scope, nativeID:home)
            }
        }
        return returns.values.sorted { $0.original.window.number < $1.original.window.number }
    }

    func confirmSystemReturn(_ returned: [StageWindowReturn], owner: StageEngineOwner) throws {
        guard try systemReturnRequirements(for:owner) == returned else { throw StageSwitchError.ownership }
        try withdrawVerifiedActivity()
        try update {
            $0.owned.removeAll(); $0.pending = nil; $0.releases = nil
            $0.owner = nil; $0.activeScopes = nil
        }
    }

    /// Freeze first. An old owner may release independently confirmed hides. Neither an ambiguous write nor
    /// a modified/reused window becomes an instruction to the replacement backend.
    public func releaseOwned(_ session: StageWindowSession) async throws {
        guard !busy else { throw StageSwitchError.busy }
        guard !journalCommitUnconfirmed else { throw StageSwitchError.recoveryRequired }
        guard let owner = session.engineOwner, ledger.owner == owner else { throw StageSwitchError.ownership }
        busy = true; defer { busy = false }
        let token = epoch, touched = Set(ledger.pending?.entries.filter { $0.after == nil }.map { $0.before.window } ?? [])
        try withdrawVerifiedActivity()
        // A previous pass can finish the actual restore before the Guardian's terminal record
        // becomes readable. Only these previously verified restores may settle without a write.
        for release in ledger.releases ?? [] where release.restored == true && owner.backend == .corner {
            let entry = release.owned
            guard !touched.contains(entry.original.window), let group = entry.group,
                  let member = entry.member, let native = entry.nativeID,
                  (try? await readReleaseState(entry.original, of: entry, owner: owner, token: token, session: session)) != nil
            else { continue }
            let command = StageWindowCommand(intent: release.intent, group: group, member: member, generation: owner.generation,
                scope: entry.scope, nativeID: native, action: .show, before: entry.hidden, restoring: true, restoreFrame: entry.original.frame)
            try verifyJournal()
            guard await session.readsFinalRelease(command) else { continue }
            try update { $0.releases?.removeAll { $0.intent == release.intent } }
        }
        for entry in ledger.owned where entry.owner == owner && !touched.contains(entry.hidden.window) &&
                !(ledger.releases ?? []).contains(where: { $0.owned.hidden.window == entry.hidden.window }) {
            guard token == epoch, session.engineOwner == owner,
                  let group = entry.group, let member = entry.member, let native = entry.nativeID else { break }
            do {
                let two = try await readReleaseState(entry.hidden, of: entry, owner: owner, token: token, session: session)
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
              let focus = pending.yieldedFocus ?? pending.focusAtSurfaceInterruption,
              pending.focusAtSurfaceInterruption.map({ $0 == pending.preferred && pending.yieldedFocus == nil }) != false,
              let area = pending.workArea, !pending.verifiedDirectoryCommit,
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
                  (pending.focusAtSurfaceInterruption == nil || sample.foreignFocusScope == nil),
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
        guard !busy, !requiresRecovery, ledger.owned.isEmpty else {
            throw StageSwitchError.recoveryRequired
        }
        guard let stamped = ledger.owner else { return }
        guard stamped == owner else { throw StageSwitchError.ownership }
        try update { $0.owner = nil; $0.releases = nil; $0.activeScopes = nil }
    }

}
