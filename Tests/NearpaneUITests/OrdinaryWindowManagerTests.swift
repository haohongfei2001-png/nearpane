import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class WindowDouble: OrdinaryWindowObserving {
    let id: ManagedWindowID
    var desktopBinding: OrdinaryDesktopIdentity?
    init(launch: UInt64 = UInt64.random(in: 2000...UInt64.max), pid: Int32 = getpid(),
         number: UInt32 = UInt32.random(in: 100...UInt32.max)) {
        id = .init(pid: pid, launch: launch, number: number, element: UUID())
    }
    var nextCreation: WindowDouble?
    var watching: UUID?
    func setCreationWatch(_ token: UUID, enabled: Bool) async throws {
        if enabled { watching = token; nextCreation = nil }
        else if watching == token { watching = nil }
    }
    func nextCreatedWindow(_ token: UUID) async throws -> CreatedWindowResult {
        guard watching == token else { throw OrdinaryRefusal.scope }
        defer { nextCreation = nil }
        return nextCreation.map { .window($0) } ?? .none
    }
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
    var boundaryRevision: UUID?
    var boundaryPrevious: SurfaceRect?
    var boundarySettled = true
    var beforeBoundaryAcknowledgement: (() throws -> Void)?
    var boundaryAcknowledgements = 0
    var boundaryAlert: (@MainActor () -> Void)?
    func onBoundaryChange(_ wake: (@MainActor () -> Void)?) { boundaryAlert = wake }
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
    func externalChange(to next: SurfaceRect) {
        boundaryPrevious = frame
        frame = next
        boundaryRevision = UUID()
    }
    func observeBoundary(expected: SurfaceRect) async throws -> OrdinaryBoundaryObservation {
        guard let revision = boundaryRevision, let previous = boundaryPrevious else {
            return .init(pair: try await verify(expected: expected), previous: expected, revision: nil, settled: true)
        }
        return .init(pair: boundarySettled ? try await prepare() : nil, previous: previous,
                     revision: revision, settled: boundarySettled)
    }
    func acknowledgeBoundary(_ observation: OrdinaryBoundaryObservation) async throws -> AdmissionPair {
        try beforeBoundaryAcknowledgement?()
        guard valid, boundarySettled, observation.revision == boundaryRevision,
              observation.previous == boundaryPrevious, observation.pair?.second.cgFrame == frame else {
            throw WorkspaceFailure.stale
        }
        boundaryRevision = nil; boundaryPrevious = nil; boundaryAcknowledgements += 1
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
    @MainActor private final class DesktopFixture {
        let space = OrdinaryDesktopIdentity(display: "side", record: "91", uuid: UUID())
        var current: OrdinaryDesktopIdentity
        var windows = [WindowDouble]()
        var offStage = Set<UInt32>()
        var sticky = Set<UInt32>()
        init() { current = space }
        func snapshot(_ request: DesktopReadRequest) -> DesktopSnapshot {
            let now = Date(), time = ProcessInfo.processInfo.systemUptime
            let f = SurfaceRect(width: 1000, height: 800)
            let members = windows.enumerated().map { index, h in
                let id = h.id, visible = !offStage.contains(id.number)
                return WindowObservation(id: String(id.number), displayID: "side", bounds: h.frame,
                    membership: .known(recordIDs: sticky.contains(id.number) ? [current.record, "900"] : [current.record]),
                    confidence: .unknown, metadata: .init(number: id.number, pid: id.pid, launchMicroseconds: id.launch,
                        element: nil, globalFrame: h.frame, frontToBack: index, minimized: nil, fullScreen: nil,
                        isOnscreen: visible, onActiveDesktop: visible, overviewSpaceID: current.record, overviewIsPresented: true))
            }
            return .observed(request, from: now, to: now, build: "test", topology: "one-display", consistent: true, separateSpaces: true,
                displays: [.init(id: "side", frame: f, rotationDegrees: 0, backingScale: 2, usable: f)],
                scopes: [.init(id: "scope", displayID: "side", records: [.init(id: current.record, isCurrent: true, ordinaryUUID: current.uuid),
                    .init(id: "900", isCurrent: false)])], windows: members,
                evidence: .init(population: .workWindows, accessibility: .available, spaces: .observed, rows: [],
                    windowLimitReached: false, beganUptime: time, endedUptime: time))
        }
        func feed() -> CurrentDesktopWindows {
            CurrentDesktopWindows(read: { request in await self.snapshot(request) }, sessionAvailable: { true }, fingerprint: { 0 })
        }
        func until(_ predicate: () -> Bool) async throws {
            let limit = ContinuousClock.now.advanced(by: .seconds(4))
            while !predicate() && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
            try #require(predicate())
        }
        func automation(_ manager: OrdinaryWindowManager, _ feed: CurrentDesktopWindows) -> DesktopAutomaticTiling {
            let result = DesktopAutomaticTiling(manager: manager) { keys, scope, prefs in
                self.windows.filter { h in
                    guard keys.contains(.init(pid: h.id.pid, birth: h.id.launch, number: h.id.number)),
                          (try? prefs.excluded(h.id, bundle: h.bundle)) == false else { return false }
                    h.desktopBinding = scope
                    return true
                }
            }
            result.connect(feed); return result
        }
    }

    @Test func currentDeskGrantAutomaticallyTilesTwoDifferentOwnersAndRestoresThem() async throws {
        let s = OrdinaryScope(), manager = s.manager(), world = DesktopFixture()
        s.context.settings.measures[.reservedWidth] = .init(160)
        let a = WindowDouble(pid: 101, number: 101), b = WindowDouble(pid: 102, number: 102)
        b.bundle = "test.second.app"
        let feed = world.feed(), automation = world.automation(manager, feed)
        world.windows = [a]
        let choice = try #require(await automation.proposed(on: "side"))
        #expect(a.writes == 0 && manager.activeIDs.isEmpty)
        await automation.start(choice)
        try await world.until { manager.verifiedIDs.contains(a.id) && !manager.busy }
        #expect(a.frame == .init(width: 840, height: 800))
        world.windows.append(b); feed.changed()
        try await world.until { manager.verifiedIDs.contains(b.id) && !manager.busy }
        try await world.until { automation.notice.contains("新窗口已在本桌面分屏") }
        #expect(a.frame == .init(width: 420, height: 800))
        #expect(b.frame == .init(x: 420, width: 420, height: 800))
        let writes = [a.writes,b.writes]
        feed.observe(false); feed.changed()
        try await Task.sleep(for: .milliseconds(260))
        #expect([a.writes,b.writes] == writes)
        try await manager.performUserAction { try await manager.stop() }
        #expect(automation.scope == nil && a.frame == a.original && b.frame == b.original)
    }

    @Test func confirmedDragReleasesOnlyItsOldGrantAndKeepsTheDestinationUnmanaged() async throws {
        let env = OrdinaryScope(), manager = env.manager(), world = DesktopFixture()
        env.context.settings.measures[.reservedWidth] = .init(160)
        let moved = WindowDouble(number: 101), sibling = WindowDouble(number: 102)
        let feed = world.feed(), tiling = world.automation(manager, feed)
        world.windows = [moved, sibling]
        await tiling.start(world.space)
        try await world.until { manager.activeIDs.count == 2 && !manager.busy }
        let key = DesktopWindowKey(pid: moved.id.pid, birth: moved.id.launch, number: moved.id.number)
        let life = try #require(feed.lifetime(of: key))
        let oldWrites = moved.writes
        let other = OrdinaryDesktopIdentity(display: world.space.display, record: "900", uuid: UUID())
        let status = try await tiling.transfer(key, lifetime: life, from: world.space, to: other) {
            world.windows = [sibling]
        }
        #expect(status.contains("未授权") && manager.activeIDs == [sibling.id] && !manager.blocked)
        await manager.poll()
        #expect(moved.writes == oldWrites)
        #expect(sibling.frame == .init(width: 840, height: 800))
        try await manager.performUserAction { try await manager.stop() }
        #expect(moved.writes == oldWrites && sibling.frame == sibling.original)
    }

    @Test func explicitDropIntoGrantedDesktopSchedulesTheExistingLayoutOnce() async throws {
        let env = OrdinaryScope(), manager = env.manager(), world = DesktopFixture()
        env.context.settings.measures[.reservedWidth] = .init(160)
        let old = WindowDouble(number: 120), arrival = WindowDouble(number: 121)
        let feed = world.feed(), auto = world.automation(manager, feed)
        world.windows = [old, arrival]; world.offStage = [arrival.id.number]
        await auto.start(world.space)
        try await world.until { manager.activeIDs == [old.id] && !manager.busy }
        let key = DesktopWindowKey(pid: arrival.id.pid, birth: arrival.id.launch, number: arrival.id.number)
        let lifetime = try #require(feed.lifetime(of: key))
        let source = OrdinaryDesktopIdentity(display: world.space.display, record: "900", uuid: UUID())
        let notice = try await auto.transfer(key, lifetime: lifetime, from: source, to: world.space) {
            world.offStage.remove(arrival.id.number)
        }
        #expect(notice.contains("等待核对"))
        try await world.until { manager.verifiedIDs.contains(arrival.id) && !manager.busy }
        #expect(old.frame == .init(width: 420, height: 800))
        #expect(arrival.frame == .init(x: 420, width: 420, height: 800))
        #expect(!auto.notice.contains("创建"))
        try await manager.performUserAction { try await manager.stop() }
    }

    @Test func unconfirmedSpaceMoveRetainsTheWindowAndPausesFrameWrites() async throws {
        let env = OrdinaryScope(), manager = env.manager(), world = DesktopFixture()
        let window = WindowDouble(), feed = world.feed(), tiling = world.automation(manager, feed)
        world.windows = [window]
        await tiling.start(world.space)
        try await world.until { manager.activeIDs == [window.id] && !manager.busy }
        let before = window.writes
        let key = DesktopWindowKey(pid: window.id.pid, birth: window.id.launch, number: window.id.number)
        let life = try #require(feed.lifetime(of: key))
        let other = OrdinaryDesktopIdentity(display: world.space.display, record: "900", uuid: UUID())
        await #expect(throws: UnconfirmedSpaceMove.self) {
            try await tiling.transfer(key, lifetime: life, from: world.space, to: other) {
                throw UnconfirmedSpaceMove("indeterminate membership")
            }
        }
        await manager.poll()
        #expect(manager.blocked && manager.paused && manager.activeIDs == [window.id])
        #expect(window.writes == before && FileManager.default.fileExists(atPath: env.journal.path))
        try manager.keepCurrent()
    }

    @Test func desktopGrantExcludesAllDesktopWindowsInactiveStagesAndExcludedApps() async throws {
        let s = OrdinaryScope(), manager = s.manager(), world = DesktopFixture()
        let a = WindowDouble(number: 101), b = WindowDouble(number: 102), c = WindowDouble(number: 103), d = WindowDouble(number: 104)
        s.context.preferences.excludedApps = ["test.excluded"]; d.bundle = "test.excluded"
        world.windows = [a,b,c,d]; world.sticky = [102]; world.offStage = [103]
        let feed = world.feed(), auto = world.automation(manager, feed)
        await auto.start(world.space)
        try await world.until { manager.verifiedIDs == [a.id] && !manager.busy }
        #expect(b.writes == 0 && c.writes == 0 && d.writes == 0 && auto.unpresented == 1)
        try await manager.performUserAction { try await manager.stop() }
    }

    @Test func virtualModeCannotInheritTheNativeDesktopGrant() async throws {
        let s = OrdinaryScope(), manager = s.manager(), world = DesktopFixture()
        let a = WindowDouble(); world.windows = [a]
        let feed = world.feed(), auto = world.automation(manager, feed)
        let proposed = try #require(await auto.proposed(on: "side"))
        auto.nativeModeAvailable = { false }
        await auto.start(proposed)
        #expect(auto.scope == nil && a.writes == 0)
        #expect(await auto.proposed(on: "side") == nil)
    }

    @Test func onlyTheOriginalProfileCanConsumeACleanDesktopHandoffOnce() throws {
        let original = OrdinaryScope(), copy = OrdinaryScope()
        let journal = OrdinaryJournal(support: original.support), world = DesktopFixture()
        #expect(try journal.takeCleanDesktop() == nil)
        try journal.rememberCleanDesktop(world.space)
        try FileManager.default.copyItem(at: original.support, to: copy.support)
        #expect(try OrdinaryJournal(support: copy.support).takeCleanDesktop() == nil)
        #expect(try journal.takeCleanDesktop() == world.space)
        #expect(try journal.takeCleanDesktop() == nil)
        try journal.rememberCleanDesktop(world.space)
        try Data("unresolved".utf8).write(to: journal.file)
        #expect(try journal.takeCleanDesktop() == nil)
    }

    @Test func normalQuitReadsFreshEvidenceAndRelaunchReenrollsOnlyOnTheSavedDesktop() async throws {
        let s = OrdinaryScope(), manager = s.manager(), world = DesktopFixture()
        let a = WindowDouble(), original = a.frame
        world.windows = [a]
        let feed = world.feed(), auto = world.automation(manager, feed)
        await auto.start(world.space)
        try await world.until { manager.verifiedIDs.contains(a.id) && !manager.busy }
        feed.invalidate()
        let saved = try #require(await auto.prepareForExit())
        await manager.finish()
        #expect(a.frame == original && manager.activeIDs.isEmpty && !manager.blocked)
        auto.end()
        let nextManager = s.manager(), nextFeed = world.feed(), next = world.automation(nextManager, nextFeed)
        let b = WindowDouble(number: 333)
        world.current = .init(display: "side", record: saved.record, uuid: UUID())
        world.windows = [b]
        next.awaitCleanDesktop(saved)
        try await world.until { nextFeed.snapshot != nil }
        #expect(next.scope == nil && b.writes == 0 && next.waitingForDesktop == saved)
        world.current = saved; nextFeed.changed()
        try await world.until { nextManager.verifiedIDs.contains(b.id) && !nextManager.busy }
        #expect(!nextManager.activeIDs.contains(a.id))
        try nextManager.pause()
        #expect(await next.prepareForExit() == nil)
        await nextManager.finish()
        #expect(nextManager.activeIDs.isEmpty)
    }

    @Test func movingToAnotherDesktopBetweenConsentAndAdmissionCannotMoveAWindow() async throws {
        let s = OrdinaryScope(), manager = s.manager(), world = DesktopFixture()
        let a = WindowDouble(); world.windows = [a]
        let feed = world.feed(), auto = world.automation(manager, feed)
        let old = try #require(await auto.proposed(on: "side"))
        world.current = .init(display: "side", record: old.record, uuid: UUID())
        await auto.start(old)
        #expect(auto.scope == nil && a.writes == 0 && manager.activeIDs.isEmpty)
        await auto.start(world.current)
        try await world.until { manager.verifiedIDs.contains(a.id) && !manager.busy }
        let other = WindowDouble()
        let original = world.current
        world.current = old; world.windows.append(other); feed.changed()
        try await world.until { auto.notice.contains("等待回到") }
        #expect(other.writes == 0 && !manager.blocked)
        world.current = original; feed.changed()
        try await world.until { manager.verifiedIDs.contains(other.id) && !manager.busy }
        try await manager.performUserAction { try await manager.stop() }
    }

    @Test func residentFractionalReservationUsesExactSystemPointsForPreviewPlacementAndDragRelease() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), c = WindowDouble(), manager = s.manager()
        s.context.primary = true
        s.context.screen = .init(width: 1470, height: 956)
        s.context.usable = .init(y: 25, width: 1470, height: 923)
        s.context.settings.measures[.panelWidth] = .init(183.75)
        let review = try await manager.prepare([a, b, c], context: s.context)
        #expect(review.proposed[c.id] == SurfaceRect(x: 0, y: 25, width: 643, height: 923))
        #expect(review.proposed[a.id] == SurfaceRect(x: 643, y: 25, width: 643, height: 462))
        #expect(review.proposed[b.id] == SurfaceRect(x: 643, y: 487, width: 643, height: 461))
        try await manager.confirm(review, context: s.context)
        let tile = a.frame
        var dragged = tile
        dragged.x += 25
        a.externalChange(to: dragged)
        await manager.poll()
        #expect(!manager.blocked && a.frame == tile && a.writes == 2 && b.writes == 1 && c.writes == 1)
        try await manager.stop()
        #expect(a.frame == tile && b.frame == b.original && c.frame == c.original)
    }

    @Test func updateCannotTerminateAWindowGrantIncludingWhilePausedOrOrphaned() async throws {
        let fixture = OrdinaryScope(), window = WindowDouble(), manager = fixture.manager()
        #expect(!manager.blocksUpdateRelaunch)
        try await manager.confirm(manager.prepare([window], context: fixture.context), context: fixture.context)
        #expect(manager.blocksUpdateRelaunch)
        try manager.pause()
        #expect(manager.blocksUpdateRelaunch)
        let orphan = fixture.manager()
        #expect(orphan.blocked && orphan.blocksUpdateRelaunch)
        try await manager.stop()
        #expect(!manager.blocksUpdateRelaunch)
    }
    @Test func cancellingCreationScopeDuringConfirmationCannotPublishGrantOrWrite() async throws {
        let fixture = OrdinaryScope(), anchor = WindowDouble(), manager = fixture.manager()
        let created = WindowDouble(launch: anchor.id.launch)
        try await manager.confirm(manager.prepare([anchor], context: fixture.context), context: fixture.context)
        try await manager.enableNewWindows(from: anchor.id)
        let writes = anchor.writes
        anchor.nextCreation = created
        created.nextVerify = { manager.disableNewWindows() }
        await manager.checkNewWindows()
        #expect(manager.creationAnchor == nil && manager.activeIDs == [anchor.id])
        #expect(!manager.blocked && anchor.writes == writes && created.writes == 0)
        let record = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: fixture.journal))
        #expect(record.entries.map(\.id) == [anchor.id])
        try await manager.stop()
    }
    @Test func exchangingSlotsSurvivesThirdMemberAndNormalQuitProjectsThePair() async throws {
        let fixture = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), c = WindowDouble()
        let manager = fixture.manager()
        try await manager.confirm(manager.prepare([a,b], context: fixture.context), context: fixture.context)
        try await manager.editPair(leftPercent: 60, swap: true, context: fixture.context)
        #expect(b.frame.x < a.frame.x && b.frame.width > a.frame.width)
        try await manager.editPair(leftPercent: 65, swap: false, context: fixture.context)
        let ordered = [a.frame, b.frame]
        #expect(manager.pairSlots?.swapped == true && manager.pairSlots?.percent == 65)
        try await manager.confirm(manager.prepare([c], context: fixture.context), context: fixture.context)
        #expect(c.frame.x < a.frame.x && a.frame.x == b.frame.x)
        c.witnessClosure()
        await manager.poll()
        #expect([a.frame,b.frame] == ordered && manager.pairSlots?.swapped == true)
        let durable = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: fixture.journal))
        #expect(durable.layout?.userAdjusted == true)
        let untouched = c.writes
        try manager.pause()
        await manager.finish()
        #expect(b.frame == SurfaceRect(x: 0, y: 0, width: 650, height: 800))
        #expect(a.frame == SurfaceRect(x: 650, y: 0, width: 350, height: 800))
        #expect(c.writes == untouched && manager.activeIDs.isEmpty && !manager.blocked)
    }

    @Test func changedSiblingPreventsPairExitWritesAndPersistedLayoutCannotReplay() async throws {
        let fixture = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), manager = fixture.manager()
        try await manager.confirm(manager.prepare([a,b], context: fixture.context), context: fixture.context)
        try await manager.editPair(leftPercent: 60, swap: true, context: fixture.context)
        let writes = [a.writes,b.writes]
        b.frame.x += 1
        await manager.finish()
        #expect(manager.blocked && [a.writes,b.writes] == writes)
        let restarted = fixture.manager()
        #expect(restarted.blocked && restarted.activeIDs.isEmpty)
        await #expect(throws: OrdinaryRefusal.self) { try await restarted.prepare([b], context: fixture.context) }
        await restarted.finish()
        #expect([a.writes,b.writes] == writes && FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func witnessedLaterDragOverridesOlderPairOnNormalQuit() async throws {
        let fixture = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), manager = fixture.manager()
        try await manager.confirm(manager.prepare([a,b], context: fixture.context), context: fixture.context)
        try await manager.editPair(leftPercent: 60, swap: true, context: fixture.context)
        var edited = a.frame
        edited.width -= 20
        a.externalChange(to: edited)
        await manager.poll()
        let writes = [a.writes,b.writes], other = b.frame
        await manager.finish()
        #expect(!manager.blocked && manager.activeIDs.isEmpty)
        #expect([a.writes,b.writes] == writes && a.frame == edited && b.frame == other)
    }

    @Test func creationScopeAdmitsOnlySubsequentSameIncarnationWindowsAndRestores() async throws {
        let m = OrdinaryScope(), anchor = WindowDouble(), manager = m.manager()
        let existing = WindowDouble(launch: anchor.id.launch), born = WindowDouble(launch: anchor.id.launch)
        anchor.nextCreation = existing
        await #expect(throws: OrdinaryRefusal.self) { try await manager.enableNewWindows(from: anchor.id) }
        try await manager.confirm(manager.prepare([anchor], context: m.context), context: m.context)
        try await manager.enableNewWindows(from: anchor.id)
        await manager.checkNewWindows()
        #expect(manager.activeIDs == [anchor.id] && existing.writes == 0)
        let other = WindowDouble()
        anchor.nextCreation = other
        await manager.checkNewWindows()
        #expect(other.writes == 0 && manager.activeIDs == [anchor.id])
        m.context.preferences.windows[existing.id] = .exclude
        anchor.nextCreation = existing
        await manager.checkNewWindows()
        #expect(existing.writes == 0 && manager.activeIDs == [anchor.id])
        born.reportedCGFrame = .init(width: 16, height: 22)
        anchor.nextCreation = born
        await manager.checkNewWindows()
        #expect(born.writes == 0 && !manager.blocked && manager.creationAnchor == anchor.id)
        let eligible = WindowDouble(launch: anchor.id.launch)
        anchor.nextCreation = eligible
        await manager.checkNewWindows()
        #expect(manager.activeIDs == [anchor.id, eligible.id] && eligible.writes == 1)
        #expect(anchor.frame == SurfaceRect(width: 438, height: 800))
        #expect(eligible.frame == SurfaceRect(x: 438, width: 437, height: 800))
        await manager.checkNewWindows()
        #expect(eligible.writes == 1)
        try manager.pause()
        #expect(manager.creationAnchor == nil)
        try await manager.resume(context: m.context)
        anchor.nextCreation = existing
        await manager.checkNewWindows()
        #expect(manager.activeIDs.count == 2 && existing.writes == 0)
        try await manager.stop()
        #expect(eligible.frame == eligible.original && anchor.frame == anchor.original && manager.creationAnchor == nil)
    }

    @Test func excludingEnrollmentAnchorRetiresCreationGrantWithoutAdoptingSiblings() async throws {
        let scope = OrdinaryScope(), anchor = WindowDouble(), manager = scope.manager()
        let sibling = WindowDouble(launch: anchor.id.launch)
        try await manager.confirm(manager.prepare([anchor], context: scope.context), context: scope.context)
        try await manager.enableNewWindows(from: anchor.id)
        anchor.nextCreation = sibling
        try await manager.exclude(anchor.id, context: scope.context)
        await manager.checkNewWindows()
        #expect(manager.activeIDs.isEmpty && manager.creationAnchor == nil && sibling.writes == 0)
    }

    @Test func primaryWindowNeedsTheSelectedDisplayAndNeverInheritsASecondaryAcceptanceScope() {
        let frame = SurfaceRect(width: 1470, height: 956)
        let primary = ScreenGeometry(id: "main", frame: frame, visibleFrame: frame)
        let side = ScreenGeometry(id: "side", frame: frame, visibleFrame: frame)
        #expect(CandidateWorkRect.selectedDisplay("main", on: [primary], restrictedTo: nil) == primary)
        #expect(CandidateWorkRect.selectedDisplay("main", on: [primary], restrictedTo: "side") == nil)
        #expect(CandidateWorkRect.selectedDisplay("side", on: [primary], restrictedTo: "side") == nil)
        #expect(CandidateWorkRect.selectedDisplay("side", on: [primary, side], restrictedTo: "side") == side)
        #expect(CandidateWorkRect.selectedDisplay("main", on: [primary, primary], restrictedTo: nil) == nil)
    }

    @Test func laterIndependentGesturesCanBeCorrectedWithoutRegrantingTheWindow() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        var time: TimeInterval = 100
        manager.correctionUptime = { time }
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        let work = a.frame
        for offset in [10.0, 20, -30] {
            var beyond = work; beyond.x += offset
            a.externalChange(to: beyond)
            await manager.poll()
            #expect(!manager.blocked && a.frame == work)
            time += 10
        }
        #expect(a.writes == 4 && a.boundaryAcknowledgements == 3)
        try await manager.stop()
        #expect(a.writes == 4)
    }

    @Test func stoppingAfterAutomaticReflowRestoresTheLastObservedUserLayout() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        let chosen = SurfaceRect(x: 100, y: 100, width: 400, height: 320)
        a.externalChange(to: chosen)
        await manager.poll()
        #expect(a.writes == 1)
        s.context.settings.placement = .docked
        try await manager.update(context: s.context)
        #expect(a.frame != chosen && a.writes == 2)
        try await manager.stop()
        #expect(a.frame == chosen && a.writes == 3 && manager.restoredIDs == [a.id])
    }

    @Test func lateUnchangedNotificationCannotDiscardExitRecovery() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        a.externalChange(to: a.frame)
        await manager.poll()
        #expect(!manager.blocked && a.writes == 1 && a.boundaryAcknowledgements == 1)
        try await manager.stop()
        #expect(a.frame == a.original && a.writes == 2)
    }

    @Test func boundaryCorrectionIsJournaledOnceAndNeverRestoresOverExternalLayout() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        let work = a.frame, initialWrites = a.writes
        var beyond = work; beyond.x = 100
        a.externalChange(to: beyond)
        a.beforeBoundaryAcknowledgement = {
            let record = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: Data(contentsOf: s.journal))
            #expect(record.entries.first?.retainsExternalLayout == true)
            #expect(record.entries.first?.original == a.original)
        }
        await manager.poll()
        #expect(!manager.blocked && a.frame == work && a.writes == initialWrites + 1)
        #expect(a.boundaryAcknowledgements == 1)
        await manager.poll()
        #expect(a.writes == initialWrites + 1)
        try await manager.stop()
        #expect(a.frame == work && a.writes == initialWrites + 1 && manager.activeIDs.isEmpty)
    }

    @Test func boundaryWaitsForSettledObservationAndPausedManagementNeverCorrects() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        var next = a.frame; next.y = -20
        a.externalChange(to: next); a.boundarySettled = false
        await manager.poll()
        #expect(!manager.blocked && a.writes == 1 && a.boundaryAcknowledgements == 0)
        a.boundarySettled = true
        await manager.poll()
        #expect(!manager.blocked && a.frame.y == 0 && a.writes == 2)
        try manager.pause()
        next = a.frame; next.x = 50
        a.externalChange(to: next)
        await manager.poll()
        #expect(manager.blocked && a.writes == 2 && a.boundaryAcknowledgements == 1)
        try manager.keepCurrent()
    }

    @Test func repeatedBoundaryViolationStopsWithoutAFrameWarOrOldRestore() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        var next = a.frame; next.x = 10
        a.externalChange(to: next); await manager.poll()
        #expect(a.writes == 2 && !manager.blocked)
        next = a.frame; next.x = 30
        a.externalChange(to: next); await manager.poll(); await manager.poll()
        #expect(manager.blocked && a.writes == 2)
        await #expect(throws: (any Error).self) { try await manager.stop() }
        #expect(a.frame == next && a.writes == 2)
        try manager.keepCurrent()
    }

    @Test func changedInBoundsLayoutIsRetainedWithoutAnyWindowWrite() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        let changed = SurfaceRect(x: 100, y: 100, width: 300, height: 300)
        a.externalChange(to: changed); await manager.poll()
        #expect(!manager.blocked && a.writes == 1 && a.frame == changed)
        try await manager.stop()
        #expect(a.writes == 1 && a.frame == changed)
    }

    @Test func changedObservationBetweenDurableRecordAndAcknowledgementCannotWrite() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        var next = a.frame; next.x = 20
        a.externalChange(to: next)
        a.beforeBoundaryAcknowledgement = { a.frame.x += 1; a.boundaryRevision = UUID() }
        await manager.poll()
        #expect(manager.blocked && a.writes == 1 && a.boundaryAcknowledgements == 0)
        let restarted = s.manager()
        #expect(restarted.blocked)
        await restarted.poll()
        #expect(a.writes == 1)
        try manager.keepCurrent()
    }

    @Test func correctionCannotMoveAnUnauthorizedSiblingOrOverlapManagedSibling() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), b = WindowDouble(), manager = s.manager(), untouched = WindowDouble()
        try await manager.confirm(manager.prepare([a,b], context: s.context), context: s.context)
        let other = b.frame, original = untouched.frame
        var next = a.frame; next.x = 700
        a.externalChange(to: next); await manager.poll()
        #expect(manager.blocked && a.writes == 1 && b.writes == 1 && b.frame == other)
        #expect(untouched.writes == 0 && untouched.frame == original)
        try manager.keepCurrent()
    }

    @Test func aCompletedDragWakesTheManagerAndUsesOnlyTheTargetsFreeSlot() async throws {
        let scope = OrdinaryScope(), manager = scope.manager(), a = WindowDouble(), b = WindowDouble()
        try await manager.confirm(manager.prepare([a,b], context: scope.context), context: scope.context)
        let safe = a.frame, sibling = b.frame
        var beyond = safe
        beyond.x += safe.x < sibling.x ? 10 : -10
        beyond.y -= 25
        a.externalChange(to: beyond)
        let signal = try #require(a.boundaryAlert)
        signal()
        signal()
        // The private completion signal wakes the normal transaction before the idle scan.
        let deadline = ContinuousClock.now + .milliseconds(850)
        while a.writes == 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!manager.blocked && a.writes == 2 && a.frame == safe)
        #expect(b.writes == 1 && b.frame == sibling)
        try await manager.stop()
        #expect(a.boundaryAlert == nil && b.boundaryAlert == nil)
    }

    @Test func unobservedDriftStillCannotAcquireBoundaryCorrectionAuthority() async throws {
        let s = OrdinaryScope(), a = WindowDouble(), manager = s.manager()
        try await manager.confirm(manager.prepare([a], context: s.context), context: s.context)
        a.frame.x = 50 // No retained native-event witness.
        await manager.poll()
        #expect(manager.blocked && a.writes == 1 && a.boundaryAcknowledgements == 0)
        try manager.keepCurrent()
    }
    @Test func anExpiredOrWithdrawnDesktopWitnessStopsOrdinaryWindowWrites() {
        let scope = OrdinaryScope(), candidate = CandidateWorkRect(support: scope.support)
        let now = ProcessInfo.processInfo.systemUptime
        candidate.ordinaryPresentation("unknown", display: "isolated", deadline: nil)
        #expect(candidate.permitsOrdinaryPresentation(on: "isolated", uptime: now))
        candidate.ordinaryPresentation("ordinary", display: "side", deadline: now + 3)
        #expect(candidate.permitsOrdinaryPresentation(on: "side", uptime: now))
        #expect(!candidate.permitsOrdinaryPresentation(on: "side", uptime: now + 3))
        candidate.ordinaryPresentation("unknown", display: "side", deadline: nil)
        #expect(!candidate.permitsOrdinaryPresentation(on: "side", uptime: now))
        for deadline in [nil, .nan, .infinity, now - 1, now + 100] as [Double?] {
            candidate.ordinaryPresentation("ordinary", display: "side", deadline: deadline)
            #expect(!candidate.permitsOrdinaryPresentation(on: "side", uptime: now))
        }
        candidate.ordinaryPresentation("ordinary", display: "other", deadline: nil)
        #expect(!candidate.permitsOrdinaryPresentation(on: "other", uptime: now))
    }

    @Test func managedWindowOnAnotherOrdinarySpaceCannotUseAFullscreenReturn() async throws {
        let scope = OrdinaryScope(), candidate = CandidateWorkRect(support: scope.support), window = WindowDouble()
        let manager = candidate.ordinary
        scope.context.settings.placement = .docked
        func send(_ state: String) {
            candidate.ordinaryPresentation(state, display: "side", deadline: ProcessInfo.processInfo.systemUptime + 8)
        }
        manager.liveContext = { [weak candidate] display in
            candidate?.permitsOrdinaryPresentation(on: display, uptime: ProcessInfo.processInfo.systemUptime) == true ? scope.context : nil
        }
        send("ordinary")
        let plan = try await manager.prepare([window], context: scope.context)
        try await manager.confirm(plan, context: scope.context)
        let before = window.writes
        send("hold")
        scope.context.settings.placement = .floating
        await manager.poll()
        #expect(!manager.blocked && window.writes == before)
        send("unknown")
        send("ordinary")
        #expect(!candidate.permitsOrdinaryPresentation(on: "side", uptime: ProcessInfo.processInfo.systemUptime))
        await #expect(throws: OrdinaryRefusal.scope) { try await manager.update(context: scope.context) }
        await manager.poll()
        #expect(!manager.blocked && window.writes == before)
        #expect(FileManager.default.fileExists(atPath: scope.journal.path))
        send("returned")
        #expect(candidate.permitsOrdinaryPresentation(on: "side", uptime: ProcessInfo.processInfo.systemUptime))
        try await manager.stop()
        #expect(window.frame == window.original && window.writes == before + 1)
    }

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
