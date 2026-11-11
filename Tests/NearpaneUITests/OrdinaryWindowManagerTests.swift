import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class WindowDouble: OrdinaryWindowObserving {
    let id = ManagedWindowID(pid: getpid(), launch: UInt64.random(in: 2000...UInt64.max),
                             number: UInt32.random(in: 100...UInt32.max), element: UUID())
    let bundle = "test.sample.ordinary"
    let token = UUID()
    let original = SurfaceRect(x: 20, y: 30, width: 100, height: 160)
    var frame = SurfaceRect(x: 20, y: 30, width: 100, height: 160)
    var valid = true
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
            s.element = id.element; s.axNumber = id.number; s.axFrame = frame; s.cgFrame = frame
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
        guard frame == expected else { throw WorkspaceFailure.stale }
        return try await prepare()
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
        return m
    }
    var journal: URL { support.appendingPathComponent("WorkRect/ordinary/journal.json") }
    deinit { try? FileManager.default.removeItem(at: support) }
}

@Suite @MainActor struct OrdinaryWindowManagerTests {
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
