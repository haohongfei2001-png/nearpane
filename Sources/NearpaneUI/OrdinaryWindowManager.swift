import Foundation
import NearpaneCore
import Observation

@MainActor protocol OrdinaryWindowObserving: AnyObject {
    var id: ManagedWindowID { get }
    var bundle: String { get }
    var applicationName: String { get }
    func invalidate()
    var lastWriteSteps: [OrdinaryWindowStep] { get }
    func prepare() async throws -> AdmissionPair
    func verify(expected: SurfaceRect) async throws -> AdmissionPair
    func write(from: SurfaceRect, to: SurfaceRect) async throws -> AdmissionPair
}
extension OrdinaryWindowAX: OrdinaryWindowObserving {}

struct OrdinaryWindowReview {
    let token: UUID, display: String, validUntil: TimeInterval
    let current, proposed: [ManagedWindowID: SurfaceRect]
}

enum OrdinaryRefusal: LocalizedError {
    case busy, scope, stale, lost, noGrant, ownership, ambiguous, minimum, storage
    var errorDescription: String? {
        switch self {
        case .busy: "正在核对窗口，请等当前操作结束。"
        case .scope: "显示器、工作区域或排除规则已变化，请重新预演。"
        case .stale: "所选窗口或预演已过期，请重新选择。"
        case .lost: "窗口观测连续性已中断。已保留恢复记录，请核对当前位置。"
        case .noGrant: "尚未授权此窗口，或当前管理已暂停。"
        case .ownership: "窗口已被其他管理会话占用，或仍有未解决的恢复记录。"
        case .ambiguous: "无法确认窗口身份、可见性及 AX/CG 几何。"
        case .minimum: "预计位置超出该窗已证实可用的尺寸或显示范围。"
        case .storage: "无法安全保存或归档恢复记录，已停止布局写入。"
        }
    }
}

/// Owns only explicitly confirmed, continuously observed windows. Durable identities are evidence;
/// a new process cannot turn a journal back into an AX capability.
@MainActor @Observable public final class OrdinaryWindowManager {
    private struct Plan {
        let review: OrdinaryWindowReview, context: AdmissionContext
        let handles: [any OrdinaryWindowObserving]
        let layout: ManagedWindowTiler
    }

    private let session = UUID()
    private let journal: OrdinaryJournal
    private var journalLease: OrdinaryFileLease?
    private var leases = [ManagedWindowID: OrdinaryFileLease]()
    private var entries = [ManagedWindowID: OrdinaryJournal.Entry]()
    private var handles = [ManagedWindowID: any OrdinaryWindowObserving]()
    private var unsavedRevocation: ManagedWindowID?
    private var tiler = ManagedWindowTiler(workspace: nil)
    private var pending: Plan?
    private var previewRevision = 0
    private var monitoring: Task<Void, Never>?
    private var closing = false
    private var passiveRead = false
    private var userActionReserved = false
    @ObservationIgnored private var afterRead: CheckedContinuation<Void, Never>?
    var unavailableForUserAction: Bool { closing || userActionReserved || (busy && !passiveRead) }
    private var appliedArea: SurfaceRect?
    private var grantedGeometry: ScreenGeometry?
    private(set) var activeDisplay: String?
    private(set) var verifiedIDs = Set<ManagedWindowID>()
    private(set) var restoredIDs = Set<ManagedWindowID>()
    private(set) var activeIDs = [ManagedWindowID]()
    private(set) var blocked = false
    private(set) var paused = false
    private(set) var busy = false
    private(set) var message = "选择具体窗口后可预览布局；确认前不会调整窗口。"
    var liveContext: (@MainActor (String) -> AdmissionContext?)?
    var saveExclusion: (@MainActor (ManagedWindowID) throws -> Void)?

    public init(support: URL) {
        journal = OrdinaryJournal(support: support)
        if journal.exists {
            blocked = true
            message = "上次窗口管理没有正常结束，无法证明期间的编辑来源。已保留恢复记录和窗口现状。"
        }
    }

    func report(_ error: Error) { message = error.localizedDescription }
    /// Labels use the application metadata captured when the user selected this exact window.
    func managedWindowLabel(_ id: ManagedWindowID) -> String {
        let number = "窗口 #\(id.number)"
        guard let owner = handles[id], let entry = entries[id], entry.bundle == owner.bundle else { return number }
        let name = owner.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "\(entry.bundle) · \(number)" }
        let ambiguous = handles.values.contains { other in
            other.bundle != entry.bundle && other.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let label = ambiguous && name != entry.bundle ? "\(name)（\(entry.bundle)）" : name
        return "\(label) · \(number)"
    }
    func cancelPreview() { previewRevision += 1; pending = nil }

    /// Accept at most one explicit request during a passive read. A changed selection, lost
    /// observation, cancelled caller or closing Host invalidates it before dispatch.
    func performUserAction<T>(_ action: @MainActor () async throws -> T) async throws -> T {
        guard !unavailableForUserAction else { throw OrdinaryRefusal.busy }
        let revision = previewRevision
        userActionReserved = true
        defer { userActionReserved = false }
        if passiveRead {
            await withCheckedContinuation { afterRead = $0 }
        }
        try Task.checkCancellation()
        guard !busy, !closing, previewRevision == revision else { throw OrdinaryRefusal.stale }
        return try await action()
    }

    private func enter(allowBlocked: Bool = false) throws {
        guard !busy else { throw OrdinaryRefusal.busy }
        guard allowBlocked || (!blocked && !closing) else { throw OrdinaryRefusal.lost }
        busy = true
    }

    private func area(_ context: AdmissionContext) throws -> SurfaceRect {
        try DesktopWorkArea(display: context.display, screen: context.screen, usable: context.usable,
                            primary: context.primary, settings: context.settings, fallbackEdge: context.edge).ordinary
    }

    private func checkedScope(_ ctx: AdmissionContext, grant: (any OrdinaryWindowObserving)? = nil) throws {
        guard ctx.recoveryClear, ctx.exclusive != false, !ctx.hypothetical, !ctx.display.isEmpty,
              let live = liveContext?(ctx.display), live.recoveryClear, live.exclusive != false, !live.hypothetical,
              ctx.display == live.display, ctx.screen == live.screen, ctx.usable == live.usable, ctx.primary == live.primary,
              ctx.displayGeometry == live.displayGeometry,
              activeDisplay == nil || grantedGeometry == live.displayGeometry,
              try area(ctx) == area(live) else { throw OrdinaryRefusal.scope }
        if let grant {
            guard unsavedRevocation != grant.id, try !live.preferences.excluded(grant.id, bundle: grant.bundle),
                  try !ctx.preferences.excluded(grant.id, bundle: grant.bundle) else { throw WorkspaceFailure.excluded }
        }
    }

    private func sample(_ pair: AdmissionPair, for handle: any OrdinaryWindowObserving, in ctx: AdmissionContext) throws -> SurfaceRect {
        let a = pair.first, b = pair.second
        guard a.liveObservation != nil, a.liveObservation == b.liveObservation,
              a.minimum == b.minimum, a.stageManager == b.stageManager else { throw OrdinaryRefusal.lost }
        guard let f = b.cgFrame, f.geometry.isValid, a.cgFrame == f, a.axFrame == f, b.axFrame == f,
              ctx.usable.geometry.intersection(f.geometry) == f.geometry else { throw OrdinaryRefusal.ambiguous }
        let now = ProcessInfo.processInfo.systemUptime
        guard b.uptime - a.uptime >= 0.075, now >= b.uptime, now - b.uptime <= 3 else { throw OrdinaryRefusal.stale }
        for item in [a, b] {
            guard item.id == handle.id, item.bundle == handle.bundle, item.display == ctx.display,
                  item.permission, item.selectionContinuity else { throw OrdinaryRefusal.ambiguous }
            guard item.positionSettable == true, item.sizeSettable == true, item.role == .ordinary,
                  item.fullscreen == false, item.minimized == false, item.layer == 0, item.onScreen == true
            else { throw OrdinaryRefusal.ambiguous }
        }
        return f
    }

    func prepare(_ selected: [any OrdinaryWindowObserving], context: AdmissionContext) async throws -> OrdinaryWindowReview {
        try enter()
        defer { busy = false }
        cancelPreview()
        let revision = previewRevision
        guard !paused, !selected.isEmpty, activeDisplay == nil || activeDisplay == context.display else { throw OrdinaryRefusal.scope }
        try checkedScope(context)
        let work = try area(context)
        var list = activeIDs.compactMap { handles[$0] }
        for h in selected {
            if let prior = list.first(where: { $0.id.number == h.id.number }) {
                guard prior === h else { throw OrdinaryRefusal.stale }
            } else { list.append(h) }
        }
        var frames = [ManagedWindowID: SurfaceRect]()
        var next = tiler
        var requirements = [ManagedMember]()
        for h in list {
            try checkedScope(context, grant: h)
            let pair: AdmissionPair
            if let existing = entries[h.id] {
                pair = try await h.verify(expected: existing.confirmed)
            } else {
                pair = try await h.prepare()
            }
            let frame = try sample(pair, for: h, in: context)
            frames[h.id] = frame
            // With no published AX minimum the initial witnessed size is a conservative floor.
            let min = pair.second.minimum ?? (entries[h.id]?.original ?? frame)
            guard min.geometry.isValid, frame.width >= min.width, frame.height >= min.height else { throw OrdinaryRefusal.minimum }
            let m = ManagedMember(h.id, minimumWidth: min.width, minimumHeight: min.height, canResize: true)
            if !next.members.contains(where: { $0.id == m.id }) { next = try next.adding(m, in: work) }
            requirements.append(m)
        }
        next = try next.refreshingRequirements(requirements, in: work)
        next = try preferences(next, context, in: work)
        try checkedScope(context)
        guard revision == previewRevision, !closing else { throw OrdinaryRefusal.stale }
        let review = OrdinaryWindowReview(token: UUID(), display: context.display,
            validUntil: ProcessInfo.processInfo.systemUptime + 45, current: frames, proposed: try next.frames(in: work))
        pending = .init(review: review, context: context, handles: list, layout: next)
        return review
    }

    private func preferences(_ layout: ManagedWindowTiler, _ context: AdmissionContext, in work: SurfaceRect) throws -> ManagedWindowTiler {
        guard context.pairCustomized, layout.members.count == 2 else { return layout }
        guard (0.2...0.8).contains(context.ratio) else { throw OrdinaryRefusal.minimum }
        // Interpret swap as an absolute slot preference on each explicit application.
        let members = layout.members
        var next = try layout.adjusting(path: [], axis: .columns, ratio: context.ratio, in: work)
        guard let first = try next.frames(in: work)[members[0].id] else { throw OrdinaryRefusal.stale }
        if (first.x > work.x) != context.swapped { next = try next.swapping(members[0].id, members[1].id, in: work) }
        return next
    }

    func confirm(_ review: OrdinaryWindowReview, context: AdmissionContext) async throws {
        try enter()
        defer { busy = false }
        let revision = previewRevision
        let plan = pending
        pending = nil
        guard !paused, let plan, plan.review.token == review.token, plan.context == context,
              ProcessInfo.processInfo.systemUptime <= plan.review.validUntil else { throw OrdinaryRefusal.stale }
        try checkedScope(context)
        let disk = try journalLease ?? journal.lock()
        guard journalLease != nil || !journal.exists else { throw OrdinaryRefusal.ownership }
        var extra = [ManagedWindowID: OrdinaryFileLease]()
        for h in plan.handles {
            try checkedScope(context, grant: h)
            if leases[h.id] == nil { extra[h.id] = try OrdinaryFileLease.forWindow(h.id) }
            guard let before = plan.review.current[h.id],
                  try sample(await h.verify(expected: before), for: h, in: context) == before else { throw OrdinaryRefusal.stale }
        }
        guard !closing, previewRevision == revision,
              ProcessInfo.processInfo.systemUptime <= plan.review.validUntil else { throw OrdinaryRefusal.stale }
        journalLease = disk
        leases.merge(extra) { first, _ in first }
        for h in plan.handles where entries[h.id] == nil {
            guard let before = plan.review.current[h.id] else { throw OrdinaryRefusal.stale }
            entries[h.id] = .init(id: h.id, bundle: h.bundle, original: before, confirmed: before)
            handles[h.id] = h
            activeIDs.append(h.id)
        }
        activeDisplay = context.display
        grantedGeometry = context.displayGeometry
        tiler = plan.layout
        do {
            try save()
            try await apply(plan.review.proposed, in: context)
            appliedArea = try area(context)
            message = "已管理 \(activeIDs.count) 扇经授权窗口，布局已由 AX 和 CG 核对。"
            startMonitoring()
        } catch { fail(error); throw error }
    }

    private func save() throws {
        guard journalLease != nil, let display = activeDisplay else { throw OrdinaryRefusal.storage }
        try journal.publish(.init(version: 1, session: session, status: "pending", display: display,
                                  entries: activeIDs.compactMap { entries[$0] }))
    }

    private func move(_ id: ManagedWindowID, to target: SurfaceRect, context: AdmissionContext, kind: String) async throws {
        guard let h = handles[id], leases[id] != nil, var e = entries[id],
              e.refusal == nil, e.intended == nil else { throw OrdinaryRefusal.lost }
        try checkedScope(context, grant: h)
        guard target.geometry.isValid,
              context.usable.geometry.intersection(target.geometry) == target.geometry else { throw OrdinaryRefusal.minimum }
        guard try sample(await h.verify(expected: e.confirmed), for: h, in: context) == e.confirmed else { throw OrdinaryRefusal.lost }
        if target == e.confirmed { return }
        guard kind == "restore" || !closing else { throw OrdinaryRefusal.stale }
        try checkedScope(context, grant: h)
        let op = UUID()
        let before = e.confirmed
        e.operation = op; e.intended = target
        entries[id] = e
        try save()
        // The worker checks identity, focus and geometry at each AX primitive. Revoke its live
        // channel too if the Host changes scope while awaiting the result.
        let guardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { h.invalidate(); return }
                do {
                    guard !self.closing || kind == "restore" else { throw OrdinaryRefusal.stale }
                    try self.checkedScope(context, grant: h)
                } catch { h.invalidate(); return }
            }
        }
        defer { guardTask.cancel() }
        let pair = try await h.write(from: before, to: target)
        guard try sample(pair, for: h, in: context) == target else { throw OrdinaryRefusal.lost }
        // A receipt follows independent readback and never confers fresh authority after a crash.
        try journal.record(.init(operation: op, session: session, id: id, kind: kind, previous: before,
                                 requested: target, readback: pair, steps: h.lastWriteSteps))
        if kind == "layout" { verifiedIDs.insert(id) }
        e.confirmed = target; e.intended = nil
        entries[id] = e
        try save()
    }

    private func apply(_ targets: [ManagedWindowID: SurfaceRect], in context: AdmissionContext) async throws {
        for id in activeIDs {
            guard !closing, let frame = targets[id] else { throw OrdinaryRefusal.stale }
            do { try await move(id, to: frame, context: context, kind: "layout") }
            catch { entries[id]?.refusal = error.localizedDescription; throw error }
        }
    }

    private func fail(_ error: Error) {
        blocked = true; paused = true; cancelPreview()
        message = "已暂停窗口管理并保留恢复记录。\(error.localizedDescription)"
        if journalLease != nil { try? save() }
    }

    func pause() throws {
        try enter()
        defer { busy = false }
        guard !activeIDs.isEmpty else { throw OrdinaryRefusal.noGrant }
        cancelPreview(); paused = true
        message = "已暂停写入，窗口保持当前布局，仍在观察外部变化。"
    }

    func update(context: AdmissionContext) async throws {
        try enter()
        defer { busy = false }
        guard !paused, !activeIDs.isEmpty, context.display == activeDisplay else { throw OrdinaryRefusal.noGrant }
        cancelPreview()
        try await reflow(context)
    }

    private func reflow(_ context: AdmissionContext) async throws {
        try checkedScope(context)
        try revokeExcluded(in: context)
        guard !activeIDs.isEmpty else { return }
        let work = try area(context)
        let next = try preferences(tiler, context, in: work)
        let frames = try next.frames(in: work)
        do {
            try await apply(frames, in: context)
            tiler = next; appliedArea = work
            message = "已核对 \(activeIDs.count) 扇授权窗口的工作区域和布局。"
        } catch { fail(error); throw error }
    }

    func resume(context: AdmissionContext) async throws {
        try enter()
        defer { busy = false }
        guard paused, !activeIDs.isEmpty, context.display == activeDisplay else { throw OrdinaryRefusal.noGrant }
        try await reflow(context)
        paused = false
    }

    /// Exclusion revokes permission immediately and keeps this window where it is.
    func exclude(_ id: ManagedWindowID, context: AdmissionContext) async throws {
        try enter()
        defer { busy = false }
        guard !closing, entries[id] != nil, activeDisplay == context.display else { throw OrdinaryRefusal.noGrant }
        cancelPreview()
        // Deny writes even if saving this explicit user decision fails.
        unsavedRevocation = id
        do {
            guard let saveExclusion else { throw OrdinaryRefusal.storage }
            try saveExclusion(id)
            guard let live = liveContext?(context.display), live.preferences.windows[id] == .exclude else {
                throw OrdinaryRefusal.storage
            }
            unsavedRevocation = nil
            try revokeExcluded(in: live)
            if !activeIDs.isEmpty && !paused { try await reflow(live) }
        } catch { fail(error); throw error }
    }

    /// An explicit, proven exclusion ends this grant in place. Do not resolve an interrupted
    /// move or an ambiguous identity merely because a user changed the policy.
    private func revokeExcluded(in context: AdmissionContext) throws {
        guard unsavedRevocation == nil else { throw OrdinaryRefusal.storage }
        guard let current = liveContext?(context.display) else { throw OrdinaryRefusal.scope }
        let revoked = try activeIDs.filter { id in
            guard let entry = entries[id] else { throw OrdinaryRefusal.lost }
            guard try current.preferences.excluded(id, bundle: entry.bundle) else { return false }
            guard entry.intended == nil, entry.refusal == nil else { throw OrdinaryRefusal.lost }
            return true
        }
        guard !revoked.isEmpty else { return }
        cancelPreview()
        if revoked.count == activeIDs.count {
            try finishRecord("excluded")
            message = "已排除全部授权窗口，保留当前位置。"
            return
        }
        let work = try area(context)
        var next = tiler
        for id in revoked { next = try next.removing(id, in: work) }
        for id in revoked { detach(id) }
        tiler = next
        appliedArea = nil
        try save()
    }

    private func detach(_ id: ManagedWindowID) {
        entries.removeValue(forKey: id); handles.removeValue(forKey: id); leases.removeValue(forKey: id)
        activeIDs.removeAll { $0 == id }
    }

    private func closedMember(_ witness: OrdinaryWindowClosure, entry: OrdinaryJournal.Entry) throws -> OrdinaryJournal.ClosedMember {
        let now = ProcessInfo.processInfo.systemUptime
        guard entry.id == witness.id, entry.refusal == nil, entry.intended == nil,
              witness.destroyed >= 0, witness.destroyed <= witness.firstAbsent,
              witness.secondAbsent - witness.firstAbsent >= 0.075,
              witness.secondAbsent <= now, now - witness.secondAbsent <= 3 else { throw OrdinaryRefusal.lost }
        return .init(session: session, entry: entry, witness: witness)
    }

    private func retire(_ closed: [OrdinaryJournal.ClosedMember], in context: AdmissionContext) throws {
        let work = try area(context)
        var next = tiler
        for member in closed {
            next = try next.removing(member.entry.id, in: work)
            try journal.record(member)
        }
        cancelPreview()
        for member in closed { detach(member.entry.id) }
        tiler = next
        appliedArea = nil
        try save()
        if activeIDs.isEmpty {
            try finishRecord("closed")
            message = "已确认全部授权窗口关闭，管理已结束。"
        }
    }

    func stop() async throws {
        try enter(allowBlocked: true)
        defer { busy = false }
        cancelPreview()
        guard !activeIDs.isEmpty else {
            if blocked { throw OrdinaryRefusal.lost }
            return
        }
        guard let display = activeDisplay, let ctx = liveContext?(display) else { fail(OrdinaryRefusal.scope); throw OrdinaryRefusal.scope }
        do { try revokeExcluded(in: ctx) } catch { fail(error); throw error }
        guard !activeIDs.isEmpty else { return }
        var failed: Error?
        var closed = [OrdinaryJournal.ClosedMember]()
        // Independent targets can still be restored when another grant has lost continuity.
        for id in activeIDs {
            guard let e = entries[id] else { continue }
            do {
                try await move(id, to: e.original, context: ctx, kind: "restore")
                if e.confirmed != e.original { restoredIDs.insert(id) }
            } catch let witness as OrdinaryWindowClosure {
                do { closed.append(try closedMember(witness, entry: e)) }
                catch { entries[id]?.refusal = error.localizedDescription; failed = error }
            } catch {
                if entries[id]?.refusal == nil { entries[id]?.refusal = error.localizedDescription }
                failed = error
            }
        }
        if !closed.isEmpty {
            do { try retire(closed, in: ctx) }
            catch { fail(error); throw error }
        }
        if let failed { fail(failed); throw failed }
        guard !activeIDs.isEmpty else { return }
        try finishRecord("restored")
    }

    private func finishRecord(_ outcome: String) throws {
        do { try journal.archive(as: outcome) } catch { fail(OrdinaryRefusal.storage); throw error }
        reset()
        message = outcome == "restored" ? "已停止并核对原窗口位置。" : "已保留窗口当前布局，授权已解除。"
    }

    /// UI calls only after explicit confirmation to retain current frames. Never opens an AX handle.
    func keepCurrent() throws {
        try enter(allowBlocked: true)
        defer { busy = false }
        guard blocked, journal.exists else { throw OrdinaryRefusal.noGrant }
        let lock = try journalLease ?? journal.lock()
        try withExtendedLifetime(lock) { try journal.archive(as: "kept-current") }
        reset()
        message = "已保留当前位置并归档恢复记录。再次管理需要重新选择和授权。"
    }

    private func reset() {
        monitoring?.cancel(); monitoring = nil
        cancelPreview(); activeIDs.removeAll(); handles.removeAll(); entries.removeAll(); leases.removeAll()
        tiler = .init(workspace: nil); activeDisplay = nil; appliedArea = nil; grantedGeometry = nil
        journalLease = nil; blocked = false; paused = false; unsavedRevocation = nil
    }

    func poll() async {
        guard !busy, !userActionReserved, !blocked, !closing, !activeIDs.isEmpty, let display = activeDisplay else { return }
        busy = true
        passiveRead = true
        defer {
            busy = false
            passiveRead = false
            let waiter = afterRead
            afterRead = nil
            waiter?.resume()
        }
        guard let ctx = liveContext?(display) else { fail(OrdinaryRefusal.scope); return }
        do {
            try revokeExcluded(in: ctx)
            guard !activeIDs.isEmpty else { return }
            var closed = [OrdinaryJournal.ClosedMember]()
            for id in activeIDs {
                guard let h = handles[id], let e = entries[id] else { throw OrdinaryRefusal.lost }
                do {
                    try checkedScope(ctx, grant: h)
                    guard try sample(await h.verify(expected: e.confirmed), for: h, in: ctx) == e.confirmed else {
                        throw OrdinaryRefusal.lost
                    }
                } catch let witness as OrdinaryWindowClosure {
                    closed.append(try closedMember(witness, entry: e))
                } catch { entries[id]?.refusal = error.localizedDescription; throw error }
            }
            if !closed.isEmpty {
                try checkedScope(ctx)
                // Let a waiting explicit action run its own checks before automatic membership writes.
                guard !userActionReserved, !closing else { return }
                try retire(closed, in: ctx)
                if activeIDs.isEmpty { return }
            }
            if !paused, !closing, !userActionReserved, try area(ctx) != appliedArea {
                passiveRead = false
                try await reflow(ctx)
            }
        } catch { fail(error) }
    }

    private func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    public func finish() async {
        closing = true
        cancelPreview()
        monitoring?.cancel()
        while busy { try? await Task.sleep(for: .milliseconds(25)) }
        if !activeIDs.isEmpty { try? await stop() }
    }
}
