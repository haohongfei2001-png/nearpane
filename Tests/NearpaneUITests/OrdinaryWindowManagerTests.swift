import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class WindowDouble: OrdinaryWindowObserving {
    let id = ManagedWindowID(pid: getpid(), launch: UInt64.random(in: 2000...UInt64.max),
                             number: UInt32.random(in: 100...UInt32.max), element: UUID())
    var bundle = "test.sample.ordinary"
    var applicationName = "Sample"
    let token = UUID()
    let original = SurfaceRect(x: 20, y: 30, width: 100, height: 160)
    var frame = SurfaceRect(x: 20, y: 30, width: 100, height: 160)
    var reportedCGFrame: SurfaceRect?
    var valid = true
    var closedWitness: OrdinaryWindowClosure?
    var writes = 0
    var lastWriteSteps = [OrdinaryWindowStep]()
    var nextVerify: (() async -> Void)?
    var immediatelyBeforeWrite: (() throws -> Void)?
    func invalidate() { valid = false }

    func prepare() async throws -> AdmissionPair {
        guard valid else { throw WorkspaceFailure.identity }
        let time = ProcessInfo.processInfo.systemUptime
        func sample(_ at: Double) -> AdmissionSample {
            var s = AdmissionSample(pid: id.pid, launch: id.launch, number: id.number, bundle: bundle, uptime: at)
            s.element = id.element; s.axNumber = id.number; s.axFrame = frame; s.cgFrame = reportedCGFrame ?? frame
            s.minimized = false; s.fullscreen = false; s.onScreen = true; s.layer = 0; s.display = "side"
            s.minimum = .init(width: 100, height: 160); s.permission = true; s.positionSettable = true
            s.sizeSettable = true; s.selectionContinuity = true; s.role = .ordinary
            s.liveObservation = token
            return s
        }
        return .init(first: sample(time - 0.1), second: sample(time))
    }
    func verify(expected: SurfaceRect) async throws -> AdmissionPair {
        if let delay = nextVerify { nextVerify = nil; await delay() }
        if let closedWitness { throw closedWitness }
        guard frame == expected else { throw WorkspaceFailure.stale }
        return try await prepare()
    }
    func witnessClosure(of other: ManagedWindowID? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        closedWitness = .init(id: other ?? id, destroyed: now - 0.3, firstAbsent: now - 0.1, secondAbsent: now)
    }
    func write(from: SurfaceRect, to: SurfaceRect) async throws -> AdmissionPair {
        _ = try await verify(expected: from)
        try immediatelyBeforeWrite?()
        frame = to; writes += 1
        lastWriteSteps = [.init(from: from, to: to, ax: to, cg: to, notification: "test",
                                uptime: ProcessInfo.processInfo.systemUptime)]
        return try await prepare()
    }
}

@MainActor private final class OrdinaryScope {
    let support = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var context = AdmissionContext(display: "side", screen: .init(width: 1000, height: 800),
        usable: .init(width: 1000, height: 800), primary: false, settings: .init(),
        edge: .right, preferences: .init(), recoveryClear: true, exclusive: true)
    func manager() -> OrdinaryWindowManager {
        let m = OrdinaryWindowManager(support: support)
        m.liveContext = { [weak self] _ in self?.context }
        m.saveExclusion = { [weak self] id in self?.context.preferences.windows[id] = .exclude }
        return m
    }
    var journal: URL { support.appendingPathComponent("WorkRect/ordinary/journal.json") }
    deinit { try? FileManager.default.removeItem(at: support) }
}

@Suite @MainActor struct OrdinaryWindowManagerTests {
    @Test func managedLabelsUseOnlyGrantedOwnersAndDisambiguateEqualApplicationNames() async throws {
        let scope = OrdinaryScope(), manager = scope.manager(), first = WindowDouble(), second = WindowDouble()
        second.applicationName = "sample"
        second.bundle = "test.sample.palette"
        let preview = try await manager.prepare([first, second], context: scope.context)
        #expect(manager.managedWindowLabel(first.id) == "窗口 #\(first.id.number)")
        try await manager.confirm(preview, context: scope.context)
        let prior = (first.writes, second.writes)
        #expect(manager.managedWindowLabel(first.id) == "Sample（test.sample.ordinary） · 窗口 #\(first.id.number)")
        #expect(manager.managedWindowLabel(second.id) == "sample（test.sample.palette） · 窗口 #\(second.id.number)")
        #expect((first.writes,second.writes) == prior)
        try await manager.exclude(second.id, context: scope.context)
        #expect(manager.managedWindowLabel(first.id) == "Sample · 窗口 #\(first.id.number)")
        #expect(manager.managedWindowLabel(second.id) == "窗口 #\(second.id.number)")
        try await manager.stop()
        #expect(manager.managedWindowLabel(first.id) == "窗口 #\(first.id.number)")
    }

    @Test func appExclusionRetiresOnlyItsMembersAndRespectsSpecificWindowRuleWhilePaused() async throws {
        let scope = OrdinaryScope(), m = scope.manager(), a = WindowDouble(), b = WindowDouble(), c = WindowDouble()
        a.bundle = "test.sample.another"
        try await m.confirm(m.prepare([a,b,c], context: scope.context), context: scope.context)
        let writes = [a.writes, b.writes, c.writes]
        let excludedFrame = b.frame
        try m.pause()
        scope.context.preferences.excludedApps.insert(b.bundle)
        scope.context.preferences.windows[c.id] = .include
        await m.poll()
        #expect(m.activeIDs == [a.id,c.id] && m.paused && !m.blocked)
        #expect(writes == [a.writes,b.writes,c.writes])
        try await m.resume(context: scope.context)
        try await m.stop()
        #expect(a.frame == a.original && c.frame == c.original && b.frame == excludedFrame && b.writes == writes[1])
    }

    @Test func savedWindowExclusionCanBeClearedButOnlyFreshConsentCanWrite() async throws {
        let scope = OrdinaryScope(), m = scope.manager(), a = WindowDouble()
        try await m.confirm(m.prepare([a], context: scope.context), context: scope.context)
        try await m.exclude(a.id, context: scope.context)
        let prior = a.writes
        #expect(m.activeIDs.isEmpty && scope.context.preferences.windows[a.id] == .exclude)
        let restarted = scope.manager()
        await #expect(throws: (any Error).self) { _ = try await restarted.prepare([a], context: scope.context) }
        scope.context.preferences.windows[a.id] = nil
        await restarted.poll()
        #expect(restarted.activeIDs.isEmpty && a.writes == prior)
        let preview = try await restarted.prepare([a], context: scope.context)
        #expect(a.writes == prior)
        try await restarted.confirm(preview, context: scope.context)
        #expect(restarted.activeIDs == [a.id])
        try await restarted.stop()
    }

    @Test func failedExclusionPersistenceStopsWritesIncludingRestore() async throws {
        let scope = OrdinaryScope(), m = scope.manager(), a = WindowDouble()
        try await m.confirm(m.prepare([a], context: scope.context), context: scope.context)
        let frame = a.frame, writes = a.writes
        m.saveExclusion = { _ in throw OrdinaryRefusal.storage }
        await #expect(throws: (any Error).self) { try await m.exclude(a.id, context: scope.context) }
        #expect(m.blocked && m.paused && FileManager.default.fileExists(atPath: scope.journal.path))
        await m.poll()
        await #expect(throws: (any Error).self) { try await m.stop() }
        #expect(a.frame == frame && a.writes == writes)
        try m.keepCurrent()
    }

    @Test func evenSubpointGeometryDisagreementCannotObtainOrRetainAWriteGrant() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        var different = a.frame
        different.x += 0.25
        a.reportedCGFrame = different
        await #expect(throws: (any Error).self) { _ = try await manager.prepare([a], context: s.context) }
        #expect(a.writes == 0 && manager.activeIDs.isEmpty)
        a.reportedCGFrame = nil
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        different = a.frame
        different.width -= 0.25
        a.reportedCGFrame = different
        await manager.poll()
        #expect(manager.blocked && a.writes == 1)
        let journal = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: s.journal))
        #expect(journal.entries.first?.original == a.original && journal.entries.first?.confirmed == a.frame)
        await #expect(throws: (any Error).self) { try await manager.stop() }
        let retained = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: s.journal))
        #expect(retained.entries.first?.refusal == OrdinaryRefusal.ambiguous.localizedDescription)
        try manager.keepCurrent()
    }
    @Test func displayScaleAndRotationChangesInvalidateReviewAndActiveWriteAuthority() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        func geometry(rotation: Double, scale: Double) -> ScreenGeometry {
            .init(id: s.context.display, frame: s.context.screen, visibleFrame: s.context.usable,
                  rotationDegrees: rotation, backingScale: scale)
        }
        s.context.displayGeometry = geometry(rotation: 0, scale: 1)
        let before = s.context
        let review = try await manager.prepare([a], context: before)
        s.context.displayGeometry = geometry(rotation: 0, scale: 2)
        await #expect(throws: (any Error).self) { try await manager.confirm(review, context: before) }
        #expect(a.writes == 0 && manager.activeIDs.isEmpty)
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        s.context.displayGeometry = geometry(rotation: 180, scale: 2)
        await manager.poll()
        #expect(manager.blocked && a.writes == 1)
        await #expect(throws: (any Error).self) { try await manager.stop() }
        #expect(a.writes == 1 && FileManager.default.fileExists(atPath:s.journal.path))
        try manager.keepCurrent()
    }
    @Test func confirmedClosureRetiresOnlyThatGrantAndRestoresSavedPair() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), c = WindowDouble()
        let manager = s.manager()
        var pairContext = s.context
        pairContext.pairCustomized = true; pairContext.ratio = 0.6
        try await manager.confirm(manager.prepare([a,b], context: pairContext), context: pairContext)
        let pair = [a.frame, b.frame]
        try await manager.confirm(manager.prepare([c], context: s.context), context: s.context)
        let prior = c.writes
        c.witnessClosure()
        await manager.poll()
        #expect(!manager.blocked && manager.activeIDs == [a.id,b.id])
        #expect([a.frame,b.frame] == pair && c.writes == prior)
        let files = try FileManager.default.contentsOfDirectory(at: s.journal.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil)
        let url = try #require(files.first { $0.lastPathComponent.hasPrefix("closure-") })
        let receipt = try JSONDecoder().decode(OrdinaryJournal.ClosedMember.self, from: Data(contentsOf: url))
        #expect(receipt.entry.id == c.id && receipt.witness.id == c.id && receipt.entry.original == c.original)
        try await manager.stop()
        #expect(c.writes == prior)
    }

    @Test func pausedMembershipChangeDelaysWritesAndLastClosureEndsSession() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a,b], context: s.context), context: s.context)
        try manager.pause()
        let writes = a.writes
        b.witnessClosure()
        await manager.poll()
        #expect(manager.paused && !manager.blocked && manager.activeIDs == [a.id] && a.writes == writes)
        try await manager.resume(context: s.context)
        #expect(a.writes == writes + 1)
        a.witnessClosure()
        await manager.poll()
        #expect(manager.activeIDs.isEmpty && !manager.blocked && !FileManager.default.fileExists(atPath:s.journal.path))
    }

    @Test func ambiguousDisappearanceAndWrongClosureProofNeverRetireOrReflow() async throws {
        for mismatch in [false, true] {
            let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), manager = s.manager()
            try await manager.confirm(manager.prepare([a,b], context: s.context), context: s.context)
            if mismatch { a.witnessClosure(of:b.id) } else { a.valid = false }
            let writes = b.writes
            await manager.poll()
            #expect(manager.blocked && manager.activeIDs == [a.id,b.id] && b.writes == writes)
            #expect(FileManager.default.fileExists(atPath:s.journal.path))
            try manager.keepCurrent()
        }
    }

    @Test func reviewedObjectsOnlyWithJournalBeforeLayoutAndConditionalReturn() async throws {
        let scope = OrdinaryScope(), a = WindowDouble(), b = WindowDouble()
        let m = scope.manager()
        a.immediatelyBeforeWrite = {
            let pending = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: scope.journal))
            #expect(pending.status == "pending" && pending.entries.first?.intended != nil)
            #expect(pending.entries.first?.operation != nil && pending.entries.first?.id == a.id)
        }
        let review = try await m.prepare([a], context: scope.context)
        #expect(a.writes == 0 && b.writes == 0)
        try await m.confirm(review, context: scope.context)
        #expect(a.writes == 1 && a.frame == review.proposed[a.id])
        await #expect(throws: (any Error).self) { try await m.confirm(review, context: scope.context) }
        try m.pause()
        let before = a.frame
        scope.context.settings.placement = .floating
        await m.poll()
        #expect(a.frame == before)
        try await m.resume(context: scope.context)
        try await m.stop()
        #expect(a.frame == a.original && b.frame == b.original && b.writes == 0)
        #expect(m.restoredIDs == [a.id] && !FileManager.default.fileExists(atPath: scope.journal.path))
    }

    @Test func externalEditBlocksOnlyUnprovableRestoreAndRestartCannotReplayIdentity() async throws {
        let scope = OrdinaryScope(), a = WindowDouble(), b = WindowDouble()
        let m = scope.manager()
        let r = try await m.prepare([a,b], context: scope.context)
        try await m.confirm(r, context: scope.context)
        a.frame.x += 9
        let changed = a.frame
        await m.poll()
        #expect(m.blocked)
        await #expect(throws: (any Error).self) { try await m.exclude(a.id, context: scope.context) }
        #expect(FileManager.default.fileExists(atPath: scope.journal.path))
        await #expect(throws: (any Error).self) { try await m.stop() }
        #expect(a.frame == changed && b.frame == b.original && m.blocked)
        let reopened = scope.manager()
        #expect(reopened.blocked && reopened.activeIDs.isEmpty)
        await #expect(throws: (any Error).self) { try await reopened.stop() }
        #expect(throws: (any Error).self) { try reopened.keepCurrent() }
        try m.keepCurrent()
        #expect(a.frame == changed && a.writes == 1)
    }

    @Test func previewInvalidationAndScopeChangeRevokeConsent() async throws {
        let scope = OrdinaryScope(), a = WindowDouble()
        let m = scope.manager()
        let first = try await m.prepare([a], context: scope.context)
        m.cancelPreview()
        await #expect(throws: (any Error).self) { try await m.confirm(first, context: scope.context) }
        let oldContext = scope.context
        let second = try await m.prepare([a], context: oldContext)
        scope.context.preferences.excludedApps = [a.bundle]
        await #expect(throws: (any Error).self) { try await m.confirm(second, context: oldContext) }
        #expect(a.writes == 0 && !FileManager.default.fileExists(atPath: scope.journal.path))
    }

    @Test func secondProfileCannotAcquireTheSameWindowEvenWithAnotherSession() async throws {
        let s = OrdinaryScope(), t = OrdinaryScope(), a = WindowDouble()
        let m = s.manager(), n = t.manager()
        let r = try await m.prepare([a], context: s.context)
        try await m.confirm(r, context: s.context)
        let another = try await n.prepare([a], context: t.context)
        await #expect(throws: (any Error).self) { try await n.confirm(another, context: t.context) }
        #expect(a.writes == 1 && n.activeIDs.isEmpty)
        try await m.stop()
    }

    @Test func oneExplicitActionWaitsForDelayedPassiveReadAndDuplicateCannotWrite() async throws {
        let s = OrdinaryScope(), a = WindowDouble()
        s.context.settings.placement = .docked
        let m = s.manager()
        let r = try await m.prepare([a], context: s.context)
        try await m.confirm(r, context: s.context)
        var release: CheckedContinuation<Void, Never>?
        a.nextVerify = { await withCheckedContinuation { release = $0 } }
        let polling = Task { await m.poll() }
        while release == nil { await Task.yield() }
        #expect(!m.unavailableForUserAction)
        let stop = Task { try await m.performUserAction { try await m.stop() } }
        while !m.unavailableForUserAction { await Task.yield() }
        var redundantCall = false
        await #expect(throws: (any Error).self) { try await m.performUserAction { redundantCall = true } }
        #expect(!redundantCall && a.writes == 1)
        release?.resume()
        await polling.value
        try await stop.value
        #expect(a.writes == 2 && a.frame == a.original && m.activeIDs.isEmpty)
    }

    @Test func invalidationWhileWaitingCancelsExplicitAction() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), m = s.manager()
        let r = try await m.prepare([a], context: s.context)
        try await m.confirm(r, context: s.context)
        var release: CheckedContinuation<Void, Never>?
        a.nextVerify = { await withCheckedContinuation { release = $0 } }
        let polling = Task { await m.poll() }
        while release == nil { await Task.yield() }
        let intent = Task { try await m.performUserAction { try await m.stop() } }
        while !m.unavailableForUserAction { await Task.yield() }
        m.cancelPreview()
        release?.resume()
        await polling.value
        await #expect(throws: (any Error).self) { try await intent.value }
        #expect(a.writes == 1)
        try await m.stop()
    }

    @Test func exclusionsLeaveCurrentFrameAndRestoreSavedPairRatio() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), c = WindowDouble()
        let m = s.manager()
        var ctx = s.context
        ctx.pairCustomized = true; ctx.ratio = 0.6
        let pair = try await m.prepare([a,b], context: ctx)
        try await m.confirm(pair, context: ctx)
        let first = a.frame, second = b.frame
        let next = try await m.prepare([c], context: s.context)
        try await m.confirm(next, context: s.context)
        let excludedFrame = c.frame, count = c.writes
        try await m.exclude(c.id, context: s.context)
        #expect(a.frame == first && b.frame == second)
        #expect(c.frame == excludedFrame && c.writes == count)
        await #expect(throws: (any Error).self) { _ = try await m.prepare([c], context: s.context) }
        try await m.stop()
        #expect(c.frame == excludedFrame && c.writes == count)
    }
}
