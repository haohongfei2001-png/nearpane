import Foundation

/// Independent AX and WindowServer readback. An adapter must withhold a sample when the two
/// disagree or when it cannot enumerate the bystanders in this display's ordinary desktop.
public struct StageWindowState: Codable, Equatable, Sendable {
    public let window: NativeSpaceWindow
    public let lifetime: UUID
    public var frame: SurfaceRect
    public var visibility: Visibility
    public enum Visibility: String, Codable, Sendable { case visible, minimized, parked, orderedOut }

    public init(window: NativeSpaceWindow, lifetime: UUID, frame: SurfaceRect, visibility: Visibility) {
        self.window = window; self.lifetime = lifetime; self.frame = frame; self.visibility = visibility
    }
}

public struct StageWindowSample: Sendable {
    public let scope: StageGroupScope, generation: UUID, sequence: UInt64
    public let workArea: SurfaceRect, windows: [NativeSpaceWindow: StageWindowState]
    /// Independently matched global AXFocusedWindow and CG ID. Nil if the match is unavailable.
    public let focus: NativeSpaceWindow?
    public init(scope: StageGroupScope, generation: UUID, sequence: UInt64, workArea: SurfaceRect,
                windows: [NativeSpaceWindow: StageWindowState], focus: NativeSpaceWindow?) {
        self.scope = scope; self.generation = generation; self.sequence = sequence
        self.workArea = workArea; self.windows = windows; self.focus = focus
    }
}

public enum StageWindowAction: Codable, Equatable, Sendable {
    case hide, show, place(SurfaceRect), focus
}

/// A qualified driver retains exact AX objects. It must compare the argument with the live
/// window and recheck the input/topology epoch immediately before each individual OS write.
@MainActor public protocol StageWindowSession: AnyObject {
    var qualifiedHiddenState: StageWindowState.Visibility? { get }
    func read(_ scope: StageGroupScope) async throws -> StageWindowSample
    func apply(_ action: StageWindowAction, to before: StageWindowState, in scope: StageGroupScope, generation: UUID) async throws
}

public enum StageSwitchError: Error, Equatable { case busy, unavailable, interrupted, incomplete, ownership, recoveryRequired }

@MainActor public final class StageGroupCoordinator {
    struct Ownership: Codable, Equatable {
        let scope: StageGroupScope
        let original, hidden: StageWindowState
    }
    struct Entry: Codable {
        let action: StageWindowAction, before: StageWindowState
        var after: StageWindowState?
    }
    struct Transaction: Codable {
        let scope: StageGroupScope, generation: UUID, target: UUID, preferred: NativeSpaceWindow
        let originalFocus: NativeSpaceWindow?, before: [StageWindowState], ownedBefore: [Ownership]
        var entries = [Entry]()
        var verifiedDirectoryCommit = false
    }
    struct Ledger: Codable {
        var version = 1
        var owned = [Ownership]()
        var pending: Transaction?
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
                guard Set(pending.before.map(\.window)).count == pending.before.count,
                      pending.before.contains(where: { $0.window == pending.preferred }),
                      pending.entries.allSatisfy({ e in e.after.map { $0.window == e.before.window && $0.lifetime == e.before.lifetime } != false })
                else { throw StageSwitchError.recoveryRequired }
            }
            guard ledger.version == 1, Set(ledger.owned.map { $0.hidden.window }).count == ledger.owned.count,
                  ledger.owned.allSatisfy({ $0.original.window == $0.hidden.window && $0.original.lifetime == $0.hidden.lifetime &&
                      $0.original.visibility == .visible && [.minimized,.parked].contains($0.hidden.visibility) }) else {
                throw StageSwitchError.recoveryRequired
            }
        }
    }

    public var requiresRecovery: Bool { ledger.pending != nil }
    public func invalidate() { epoch = UUID() }

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
    /// first enrollment the initial group must contain the actual focused window.
    public func activate(_ group: UUID, member: UUID?, in scope: StageGroupScope,
                         consent: Bool, session: StageWindowSession) async throws {
        guard !busy else { throw StageSwitchError.busy }
        guard ledger.pending == nil else { throw StageSwitchError.recoveryRequired }
        guard consent, let mechanism = session.qualifiedHiddenState, [.parked,.minimized].contains(mechanism) else {
            throw StageSwitchError.unavailable
        }
        busy = true
        defer { busy = false }
        let token = epoch, directory = store.directory, groups = store.groups(in: scope)
        guard let target = groups.first(where: { $0.id == group }), !groups.contains(where: { $0.needsReorganization == true }),
              let preferred = target.members.first(where: { $0.id == (member ?? target.selectedMember ?? target.members.first?.id) })
        else { throw StageSwitchError.incomplete }
        let first = try await session.read(scope)
        let members = groups.flatMap(\.members), ids = Set(members.map(\.windowHint)), targets = Set(target.members.map(\.windowHint))
        guard epoch == token, first.scope == scope, first.workArea.width > 0, first.workArea.height > 0,
              ids.count == members.count, ids.isSubset(of: Set(first.windows.keys)),
              first.windows.allSatisfy({ $0.key == $0.value.window }),
              members.allSatisfy({ m in first.windows[m.windowHint].map { state in store.isBound(m, to: state.lifetime) } == true }),
              store.activeGroup(in: scope) != nil || first.focus.map(targets.contains) == true
        else { throw StageSwitchError.incomplete }
        let originalHeld = ledger.owned.filter { $0.scope == scope }
        let held = Dictionary(uniqueKeysWithValues: originalHeld.map { ($0.hidden.window,$0) })
        guard originalHeld.allSatisfy({ ids.contains($0.hidden.window) && first.windows[$0.hidden.window] == $0.hidden }),
              ids.allSatisfy({ held[$0] != nil || first.windows[$0]?.visibility == .visible }) else { throw StageSwitchError.ownership }
        let otherIDs = first.windows.keys.filter { !ids.contains($0) }
        try update { $0.pending = .init(scope: scope, generation: first.generation, target: group, preferred: preferred.windowHint,
            originalFocus: first.focus, before: Array(first.windows.values), ownedBefore: originalHeld) }
        var last = first
        func read() async throws -> StageWindowSample {
            let next = try await session.read(scope)
            guard epoch == token, directory == store.directory, session.qualifiedHiddenState == mechanism,
                  next.scope == scope, next.generation == first.generation, next.workArea == first.workArea,
                  next.sequence > last.sequence, next.windows.keys == first.windows.keys,
                  next.windows.allSatisfy({ $0.key == $0.value.window && $0.value.lifetime == first.windows[$0.key]?.lifetime }),
                  otherIDs.allSatisfy({ next.windows[$0] == first.windows[$0] }) else { throw StageSwitchError.interrupted }
            return next
        }
        func perform(_ action: StageWindowAction, id: NativeSpaceWindow,
                     check: (StageWindowState, StageWindowSample) -> Bool) async throws {
            let pre = try await read()
            guard pre.windows == last.windows, let before = pre.windows[id] else { throw StageSwitchError.interrupted }
            last = pre
            try update { $0.pending?.entries.append(.init(action: action, before: before)) }
            guard epoch == token else { throw StageSwitchError.interrupted }
            try await session.apply(action, to: before, in: scope, generation: first.generation)
            for _ in 0..<2 {
                let post = try await read()
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
                if action == .hide { $0.owned.append(.init(scope: scope, original: before, hidden: confirmed)) }
                if action == .show { $0.owned.removeAll { $0.scope == scope && $0.hidden.window == id } }
            }
        }
        do {
            for m in members where !targets.contains(m.windowHint) && held[m.windowHint] == nil {
                try await perform(.hide, id: m.windowHint) { value, _ in value.visibility == mechanism }
            }
            for m in target.members {
                let id = m.windowHint
                if let previous = held[id] {
                    try await perform(.show, id: id) { value, _ in value.visibility == .visible && self.matches(value.frame, previous.original.frame) }
                }
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
            last = try await read()
            guard complete(last) else { throw StageSwitchError.incomplete }
            if last.focus != preferred.windowHint {
                try await perform(.focus, id: preferred.windowHint) { state, sample in state.visibility == .visible && sample.focus == preferred.windowHint }
            }
            for _ in 0..<2 {
                last = try await read()
                guard complete(last), last.focus == preferred.windowHint else { throw StageSwitchError.incomplete }
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
        guard let hidden = session.qualifiedHiddenState, t.entries.allSatisfy({ $0.after != nil })
        else { throw StageSwitchError.recoveryRequired }
        let initial = Dictionary(uniqueKeysWithValues: t.before.map { ($0.window,$0) })
        var expected = initial
        for e in t.entries { expected[e.before.window] = e.after }
        var previousSequence: UInt64?
        func verified(_ expected: [NativeSpaceWindow: StageWindowState]) async throws -> StageWindowSample {
            let s = try await session.read(t.scope)
            guard token == epoch, s.generation == t.generation, s.scope == t.scope,
                  session.qualifiedHiddenState == hidden, previousSequence.map({ s.sequence > $0 }) != false,
                  s.windows == expected else { throw StageSwitchError.recoveryRequired }
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
            if let inverse {
                // Mark the ambiguous interval of the inverse as well. A crash never replays it.
                try update { $0.pending!.entries[$0.pending!.entries.count-1].after = nil }
                try await session.apply(inverse, to: after, in: t.scope, generation: t.generation)
            }
            expected[e.before.window] = e.before
            _ = try await verified(expected); _ = try await verified(expected)
            try update { _ = $0.pending?.entries.popLast() }
        }
        let restored = try await verified(initial)
        if restored.focus != t.originalFocus {
            guard let old = t.originalFocus, let window = initial[old],
                  t.before.contains(where: { $0.window == old }), store.groups(in: t.scope).contains(where: { $0.members.contains { $0.windowHint == old } })
            else { throw StageSwitchError.recoveryRequired }
            try update { $0.pending?.entries.append(.init(action: .focus, before: window)) }
            try await session.apply(.focus, to: window, in: t.scope, generation: t.generation)
            for _ in 0..<2 { guard try await verified(initial).focus == old else { throw StageSwitchError.recoveryRequired } }
        }
        try update { state in
            state.owned.removeAll { $0.scope == t.scope }; state.owned.append(contentsOf: t.ownedBefore); state.pending = nil
        }
    }
}
