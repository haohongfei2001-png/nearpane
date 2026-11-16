import Foundation
import NearpaneCore
import Observation

enum CreatedWindowResult {
    case none, skipped(String), window(any OrdinaryWindowObserving)
}

@MainActor protocol OrdinaryWindowObserving: AnyObject {
    var id: ManagedWindowID { get }
    var bundle: String { get }
    var applicationName: String { get }
    func invalidate()
    var lastWriteSteps: [OrdinaryWindowStep] { get }
    func prepare() async throws -> AdmissionPair
    func verify(expected: SurfaceRect) async throws -> AdmissionPair
    func write(from: SurfaceRect, to: SurfaceRect) async throws -> AdmissionPair
    func observeBoundary(expected: SurfaceRect) async throws -> OrdinaryBoundaryObservation
    func acknowledgeBoundary(_ observation: OrdinaryBoundaryObservation) async throws -> AdmissionPair
    func onBoundaryChange(_ wake: (@MainActor () -> Void)?)
    func setCreationWatch(_ token: UUID, enabled: Bool) async throws
    func nextCreatedWindow(_ token: UUID) async throws -> CreatedWindowResult
}
extension OrdinaryWindowObserving {
    func setCreationWatch(_ token: UUID, enabled: Bool) async throws { throw OrdinaryRefusal.scope }
    func nextCreatedWindow(_ token: UUID) async throws -> CreatedWindowResult { throw OrdinaryRefusal.scope }
    func onBoundaryChange(_ wake: (@MainActor () -> Void)?) {}
    // Older adapters cannot acquire this capability by merely returning a changed frame.
    func observeBoundary(expected: SurfaceRect) async throws -> OrdinaryBoundaryObservation {
        .init(pair: try await verify(expected: expected), previous: expected, revision: nil, settled: true)
    }
    func acknowledgeBoundary(_ observation: OrdinaryBoundaryObservation) async throws -> AdmissionPair {
        throw OrdinaryRefusal.lost
    }
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
    var pairSlots: (percent: Int, swapped: Bool)? {
        guard tiler.members.count == 2,
              case let .split(.columns, ratio, .slot(left), .slot(_)) = tiler.partition else { return nil }
        return (Int((ratio * 100).rounded()), left != 0)
    }
    var hasCustomLayout: Bool { tiler.userAdjusted }
    private var pending: Plan?
    private(set) var creationAnchor: ManagedWindowID?
    private var creationGrant: UUID?
    @ObservationIgnored private weak var creationWriter: (any OrdinaryWindowObserving)?
    private var checkingCreated = false
    private var previewRevision = 0
    private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var boundaryWake: Task<Void, Never>?
    private var closing = false
    private var passiveRead = false
    private var userActionReserved = false
    @ObservationIgnored private var afterRead: CheckedContinuation<Void, Never>?
    var unavailableForUserAction: Bool { closing || userActionReserved || (busy && !passiveRead) }
    private var appliedArea: SurfaceRect?
    private var lastCorrection = [ManagedWindowID: TimeInterval]()
    @ObservationIgnored var correctionUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    var presentationHeld: (@MainActor (String) -> Bool)?
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

    private func sample(_ pair: AdmissionPair, for handle: any OrdinaryWindowObserving, in ctx: AdmissionContext,
                        boundaryOverflow: Bool = false) throws -> SurfaceRect {
        let a = pair.first, b = pair.second
        guard a.liveObservation != nil, a.liveObservation == b.liveObservation,
              a.minimum == b.minimum, a.stageManager == b.stageManager else { throw OrdinaryRefusal.lost }
        guard let f = b.cgFrame, f.geometry.isValid, a.cgFrame == f, a.axFrame == f, b.axFrame == f else {
            throw OrdinaryRefusal.ambiguous
        }
        if boundaryOverflow {
            // Only a retained, already-authorized monitor may supply this read. Its native
            // observer separately excludes crossings into another display and invisible windows.
            guard ctx.screen.geometry.intersection(f.geometry) != nil else { throw OrdinaryRefusal.ambiguous }
        } else {
            guard ctx.usable.geometry.intersection(f.geometry) == f.geometry else { throw OrdinaryRefusal.ambiguous }
        }
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

    private func checkCreationGrant(_ token: UUID?) throws {
        if let token, token != creationGrant { throw OrdinaryRefusal.noGrant }
    }

    func confirm(_ review: OrdinaryWindowReview, context: AdmissionContext, creationToken: UUID? = nil) async throws {
        try enter()
        defer { busy = false }
        let revision = previewRevision
        let plan = pending
        pending = nil
        guard !paused, let plan, plan.review.token == review.token, plan.context == context,
              ProcessInfo.processInfo.systemUptime <= plan.review.validUntil else { throw OrdinaryRefusal.stale }
        try checkCreationGrant(creationToken)
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
        try checkCreationGrant(creationToken)
        journalLease = disk
        leases.merge(extra) { first, _ in first }
        for h in plan.handles where entries[h.id] == nil {
            guard let before = plan.review.current[h.id] else { throw OrdinaryRefusal.stale }
            entries[h.id] = .init(id: h.id, bundle: h.bundle, original: before, confirmed: before)
            handles[h.id] = h
            activeIDs.append(h.id)
            h.onBoundaryChange { [weak self] in self?.scheduleBoundaryCheck() }
        }
        activeDisplay = context.display
        grantedGeometry = context.displayGeometry
        tiler = plan.layout
        do {
            try save()
            try await apply(plan.review.proposed, in: context, creationToken: creationToken)
            try checkCreationGrant(creationToken)
            appliedArea = try area(context)
            message = "已管理 \(activeIDs.count) 扇经授权窗口，布局已由 AX 和 CG 核对。"
            startMonitoring()
        } catch { fail(error); throw error }
    }

    private func save() throws {
        guard journalLease != nil, let display = activeDisplay else { throw OrdinaryRefusal.storage }
        try journal.publish(.init(version: 1, session: session, status: "pending", display: display,
                                  entries: activeIDs.compactMap { entries[$0] }, layout: tiler))
    }

    private func move(_ id: ManagedWindowID, to target: SurfaceRect, context: AdmissionContext, kind: String,
                      creationToken: UUID? = nil) async throws {
        guard let h = handles[id], leases[id] != nil, var e = entries[id],
              e.refusal == nil, e.intended == nil else { throw OrdinaryRefusal.lost }
        try checkedScope(context, grant: h)
        guard target.geometry.isValid,
              context.usable.geometry.intersection(target.geometry) == target.geometry else { throw OrdinaryRefusal.minimum }
        if kind != "restore" {
            let work = try area(context)
            guard work.geometry.intersection(target.geometry) == target.geometry else { throw OrdinaryRefusal.minimum }
        }
        guard try sample(await h.verify(expected: e.confirmed), for: h, in: context,
                         boundaryOverflow: kind == "boundary" && e.retainsExternalLayout == true) == e.confirmed
        else { throw OrdinaryRefusal.lost }
        try checkCreationGrant(creationToken)
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
                    try self.checkCreationGrant(creationToken)
                    try self.checkedScope(context, grant: h)
                } catch { h.invalidate(); return }
            }
        }
        if creationToken != nil { creationWriter = h }
        defer { creationWriter = nil; guardTask.cancel() }
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

    private func apply(_ targets: [ManagedWindowID: SurfaceRect], in context: AdmissionContext, creationToken: UUID? = nil) async throws {
        for id in activeIDs {
            guard !closing, let frame = targets[id] else { throw OrdinaryRefusal.stale }
            try checkCreationGrant(creationToken)
            do { try await move(id, to: frame, context: context, kind: "layout", creationToken: creationToken) }
            catch { entries[id]?.refusal = error.localizedDescription; throw error }
        }
    }

    private func fail(_ error: Error) {
        disableNewWindows()
        blocked = true; paused = true; cancelPreview()
        message = "已暂停窗口管理并保留恢复记录。\(error.localizedDescription)"
        if journalLease != nil { try? save() }
    }

    func pause() throws {
        try enter()
        defer { busy = false }
        guard !activeIDs.isEmpty else { throw OrdinaryRefusal.noGrant }
        disableNewWindows()
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

    func editPair(leftPercent: Int, swap: Bool, context: AdmissionContext) async throws {
        guard let slots = pairSlots, (20...80).contains(leftPercent) else { throw OrdinaryRefusal.noGrant }
        var choice = context
        choice.pairCustomized = true
        choice.swapped = swap ? !slots.swapped : slots.swapped
        choice.ratio = Double(leftPercent) / 100
        try await update(context: choice)
    }

    /// Check the whole group before changing its first member. Each write then revalidates
    /// its own retained observer again, so this check cannot authorize a stale target.
    private func verifyGroup(_ targets: [ManagedWindowID: SurfaceRect], in context: AdmissionContext) async throws {
        guard Set(activeIDs) == Set(targets.keys), presentationHeld?(context.display) != true else { throw OrdinaryRefusal.scope }
        for id in activeIDs {
            guard let target = targets[id], let handle = handles[id], let entry = entries[id],
                  entry.refusal == nil, entry.intended == nil else { throw OrdinaryRefusal.lost }
            try checkedScope(context, grant: handle)
            let pair = try await handle.verify(expected: entry.confirmed)
            guard try sample(pair, for: handle, in: context) == entry.confirmed else { throw OrdinaryRefusal.lost }
            let minimum = pair.second.minimum ?? entry.original
            guard target.width >= minimum.width, target.height >= minimum.height,
                  context.usable.geometry.intersection(target.geometry) == target.geometry else { throw OrdinaryRefusal.minimum }
        }
    }

    private func reflow(_ context: AdmissionContext) async throws {
        try checkedScope(context)
        try revokeExcluded(in: context)
        guard !activeIDs.isEmpty else { return }
        let work = try area(context)
        let next = try preferences(tiler, context, in: work)
        let frames = try next.frames(in: work)
        do {
            if context.pairCustomized {
                try await verifyGroup(frames, in: context)
                guard !closing else { throw OrdinaryRefusal.stale }
                // Persist the exact chosen members and partition before the first AX action.
                tiler = next
                try save()
            }
            try await apply(frames, in: context)
            tiler = next; appliedArea = work
            if context.pairCustomized {
                // This confirmed explicit choice supersedes any earlier observed drag.
                for id in activeIDs {
                    entries[id]?.retainsExternalLayout = nil
                    entries[id]?.externalLayout = nil
                }
                try save()
            }
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
        if creationAnchor == id { disableNewWindows() }
        handles[id]?.onBoundaryChange(nil)
        lastCorrection.removeValue(forKey: id)
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

    func stop(preservingCustomLayout: Bool = false) async throws {
        try enter(allowBlocked: true)
        disableNewWindows()
        defer { busy = false }
        cancelPreview()
        guard !activeIDs.isEmpty else {
            if blocked { throw OrdinaryRefusal.lost }
            return
        }
        guard let display = activeDisplay, let ctx = liveContext?(display) else { fail(OrdinaryRefusal.scope); throw OrdinaryRefusal.scope }
        do { try revokeExcluded(in: ctx) } catch { fail(error); throw error }
        guard !activeIDs.isEmpty else { return }
        if preservingCustomLayout && tiler.userAdjusted {
            do {
                guard !blocked else { throw OrdinaryRefusal.lost }
                let hasLaterChange = entries.values.contains { $0.retainsExternalLayout == true }
                // A later external drag invalidates the relative arrangement. Leave the whole
                // group at its witnessed frames rather than project a stale sibling across it.
                let targets = try hasLaterChange ? entries.mapValues(\.confirmed) : tiler.frames(in: ctx.usable)
                try await verifyGroup(targets, in: ctx)
                if !hasLaterChange {
                    for id in activeIDs {
                        guard let target = targets[id], let before = entries[id]?.confirmed else { throw OrdinaryRefusal.lost }
                        try await move(id, to: target, context: ctx, kind: "restore")
                        if target != before { restoredIDs.insert(id) }
                    }
                }
                try finishRecord(hasLaterChange ? "stopped-retaining-external" : "restored-user-layout")
                return
            } catch { fail(error); throw error }
        }
        var failed: Error?
        var closed = [OrdinaryJournal.ClosedMember]()
        var retainedExternal = false
        // Independent targets can still be restored when another grant has lost continuity.
        for id in activeIDs {
            guard let e = entries[id] else { continue }
            do {
                if e.retainsExternalLayout == true {
                    guard let saved = e.externalLayout else {
                        throw OrdinaryRefusal.lost
                    }
                    try await move(id, to: saved, context: ctx, kind: "restore")
                    if e.confirmed != saved { restoredIDs.insert(id) }
                    retainedExternal = true
                    continue
                }
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
        try finishRecord(retainedExternal ? "stopped-retaining-external" : "restored")
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
        disableNewWindows()
        monitoring?.cancel(); monitoring = nil
        boundaryWake?.cancel(); boundaryWake = nil
        for h in handles.values { h.onBoundaryChange(nil) }
        lastCorrection.removeAll()
        cancelPreview(); activeIDs.removeAll(); handles.removeAll(); entries.removeAll(); leases.removeAll()
        tiler = .init(workspace: nil); activeDisplay = nil; appliedArea = nil; grantedGeometry = nil
        journalLease = nil; blocked = false; paused = false; unsavedRevocation = nil
    }

    func poll() async {
        guard !busy, !userActionReserved, !blocked, !closing, !activeIDs.isEmpty,
              let display = activeDisplay, presentationHeld?(display) != true else { return }
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
                    if !paused {
                        guard try await maintainBoundary(id, in: ctx) else { return }
                        continue
                    }
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

    /// A bounded correction after a witnessed drag/resize, never an unbounded frame war.
    /// This consumes a fresh native observation, not a synthetic editing-generation counter.
    private func maintainBoundary(_ id: ManagedWindowID, in context: AdmissionContext) async throws -> Bool {
        guard let h = handles[id], var entry = entries[id], entry.intended == nil, entry.refusal == nil else {
            throw OrdinaryRefusal.lost
        }
        let observation = try await h.observeBoundary(expected: entry.confirmed)
        guard observation.previous == entry.confirmed else { throw OrdinaryRefusal.stale }
        guard observation.settled else {
            message = "等待窗口拖动结束，暂不调整位置。"
            if observation.revision != nil { scheduleBoundaryCheck() }
            return false
        }
        guard let pair = observation.pair else { throw OrdinaryRefusal.lost }
        guard let revision = observation.revision else {
            guard try sample(pair, for: h, in: context) == entry.confirmed else { throw OrdinaryRefusal.lost }
            return true
        }
        guard !paused, !closing, !userActionReserved else { return false }
        try checkedScope(context, grant: h)
        let observed = try sample(pair, for: h, in: context, boundaryOverflow: true)
        if observed == entry.confirmed {
            // Some apps deliver another notification after their frame has already
            // settled. A notification alone cannot replace the exit recovery frame.
            let verified = try await h.acknowledgeBoundary(observation)
            guard try sample(verified, for: h, in: context) == observed,
                  verified.second.liveObservation == pair.second.liveObservation else { throw OrdinaryRefusal.lost }
            return true
        }
        // Retire restoration authority before acknowledging any external geometry, including
        // a geometry that later cannot be corrected. The old baseline remains evidence only.
        entry.retainsExternalLayout = true
        entry.externalLayout = nil
        entries[id] = entry
        try save()
        try journal.record(.init(session: session, id: id, revision: revision, previous: entry.confirmed, observed: pair))
        var others = [SurfaceRect]()
        for other in activeIDs where other != id {
            guard let handle = handles[other], let sibling = entries[other], sibling.refusal == nil,
                  sibling.intended == nil else { throw OrdinaryRefusal.lost }
            try checkedScope(context, grant: handle)
            others.append(try sample(await handle.verify(expected: sibling.confirmed), for: handle, in: context))
        }
        guard let minimum = pair.second.minimum else { throw OrdinaryRefusal.minimum }
        let correction = try ManagedWindowBoundary.correction(frame: observed, in: area(context), minimum: minimum,
                                                            others: others, lastConfirmed: entry.confirmed)
        if correction != nil, let previous = lastCorrection[id], correctionUptime() - previous < 5 {
            throw OrdinaryWindowFailure("窗口在纠正后五秒内再次越界，可能有其他程序正在调整它。已暂停，请核对位置。")
        }
        guard !paused, !closing, !userActionReserved else { return false }
        try checkedScope(context, grant: h)
        let acknowledged = try await h.acknowledgeBoundary(observation)
        guard try sample(acknowledged, for: h, in: context, boundaryOverflow: true) == observed,
              acknowledged.second.liveObservation == pair.second.liveObservation else { throw OrdinaryRefusal.lost }
        entry.confirmed = observed
        if correction == nil { entry.externalLayout = observed }
        if correction != nil { entry.boundaryCorrections = (entry.boundaryCorrections ?? 0) + 1 }
        entries[id] = entry
        try save()
        if let correction {
            guard !closing, !userActionReserved, !paused else { throw OrdinaryRefusal.stale }
            passiveRead = false
            try await move(id, to: correction, context: context, kind: "boundary")
            entries[id]?.externalLayout = correction
            try save()
            lastCorrection[id] = correctionUptime()
            message = "已在拖动结束后将授权窗口约束回工作区域；退出时保留这次新布局。"
        } else {
            message = "已保留工作区内的新布局；旧的自动恢复位置不再覆盖它。"
        }
        return true
    }

    /// The grant lives only while its original authorized window, process and display are witnessed.
    /// Activating it takes an initial inventory in the helper; none of those siblings are eligible.
    func enableNewWindows(from id: ManagedWindowID) async throws {
        try enter()
        defer { busy = false }
        guard creationAnchor == nil, !paused, let anchor = handles[id], verifiedIDs.contains(id),
              let display = activeDisplay, let context = liveContext?(display), let entry = entries[id]
        else { throw OrdinaryRefusal.noGrant }
        try checkedScope(context, grant: anchor)
        _ = try sample(await anchor.verify(expected: entry.confirmed), for: anchor, in: context)
        let token = UUID()
        try await anchor.setCreationWatch(token, enabled: true)
        do {
            guard !closing, !paused, !blocked, handles[id] === anchor else { throw OrdinaryRefusal.lost }
            try checkedScope(context, grant: anchor)
        } catch {
            try? await anchor.setCreationWatch(token, enabled: false)
            throw error
        }
        creationGrant = token
        creationAnchor = id
        message = "将自动管理此应用本次运行在当前显示器新建的合格窗口。已有其他窗口保持原样。"
    }

    func disableNewWindows() {
        if creationGrant != nil { cancelPreview() }
        creationWriter?.invalidate()
        if let id = creationAnchor, let token = creationGrant, let anchor = handles[id] {
            Task { try? await anchor.setCreationWatch(token, enabled: false) }
        }
        creationAnchor = nil
        creationGrant = nil
    }

    func checkNewWindows() async {
        guard !checkingCreated, !busy, !paused, !blocked, !closing, !userActionReserved,
              let token = creationGrant, let id = creationAnchor, let anchor = handles[id],
              let display = activeDisplay, let context = liveContext?(display),
              presentationHeld?(display) != true else { return }
        if let pending, pending.review.validUntil >= ProcessInfo.processInfo.systemUptime { return }
        let revision = previewRevision
        checkingCreated = true
        defer { checkingCreated = false }
        let event: CreatedWindowResult
        do {
            try checkedScope(context, grant: anchor)
            event = try await anchor.nextCreatedWindow(token)
        } catch {
            if creationGrant == token {
                disableNewWindows()
                message = "已结束新窗授权。\(error.localizedDescription)"
            }
            return
        }
        guard creationGrant == token, handles[id] === anchor, !busy, !userActionReserved,
              !paused, !closing, !blocked, previewRevision == revision else { return }
        switch event {
        case .none: return
        case .skipped(let reason): message = "新窗口未加入。\(reason)"
        case .window(let fresh):
            do {
                guard fresh.id.pid == id.pid, fresh.id.launch == id.launch, fresh.bundle == anchor.bundle,
                      !activeIDs.contains(where: { $0.number == fresh.id.number }) else { throw OrdinaryRefusal.ambiguous }
                try checkedScope(context, grant: fresh)
                let requestCreation = WorkspaceAdmissionPlanner.requestsCreation(existingCount: activeIDs.count,
                                                        source: .application, preferences: context.preferences)
                let plan = try await prepare([fresh], context: context)
                guard creationGrant == token, !paused, !closing else { cancelPreview(); throw OrdinaryRefusal.noGrant }
                try await confirm(plan, context: context, creationToken: token)
                if requestCreation { message = "当前无法新建系统空间，已在本屏现有工作区核对并平铺新窗口。" }
            } catch {
                if !blocked { message = "新窗口未加入。\(error.localizedDescription)" }
            }
        }
    }

    private func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.poll()
                await self.checkNewWindows()
            }
        }
    }

    /// AX move/resize notifications arrive on the helper's run loop at the end of the
    /// gesture. Wake the existing read/verify/journal path after its quiet interval.
    /// The private pipe is only a scheduling hint and confers no authority to write.
    private func scheduleBoundaryCheck() {
        guard boundaryWake == nil, !activeIDs.isEmpty, !blocked, !closing, !paused else { return }
        boundaryWake = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.boundaryWake = nil
            await self.poll()
        }
    }

    public func finish() async {
        disableNewWindows()
        closing = true
        cancelPreview()
        monitoring?.cancel()
        while busy { try? await Task.sleep(for: .milliseconds(25)) }
        if !activeIDs.isEmpty { try? await stop(preservingCustomLayout: true) }
    }
}
