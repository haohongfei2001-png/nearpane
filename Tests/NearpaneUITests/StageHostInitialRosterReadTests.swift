import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct StageHostInitialRosterReadTests {
    private let fixture = StageHostGroupProjectionTests()
    private let session = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var scope: StageGroupScope { .init(display: UUID(uuidString: fixture.display)!, nativeSpace: fixture.space) }
    private var authorized: Set<NativeSpaceWindow> {
        Set([53, 55, 56].map { .init(pid: 614, birth: 3400, number: $0) })
    }

    private func window(_ number: UInt32, rank: Int, pid: Int32 = 614, birth: UInt64 = 3400,
                        frame: SurfaceRect? = nil, membership: WindowMembership = .known(recordIDs: ["4"])) -> WindowObservation {
        let rect = frame ?? fixture.rect
        return .init(id: "\(pid)/\(birth)/\(number)", displayID: fixture.display, bounds: rect,
            membership: membership, confidence: .unknown,
            metadata: .init(number: number, pid: pid, launchMicroseconds: birth, element: nil,
                globalFrame: rect, frontToBack: rank, minimized: false, fullScreen: false,
                isOnscreen: true, onActiveDesktop: true, overviewSpaceID: "4", overviewOrdinaryRole: true))
    }

    private func snapshot(complete: Bool, revision: UInt64 = 5, windows: [WindowObservation]? = nil,
                          issues: [String]? = nil, began: Double = 10, ended: Double = 11) -> DesktopSnapshot {
        let rows = windows ?? [window(53, rank: 0), window(55, rank: 1), window(56, rank: 2)]
        var sample = fixture.snapshot(rows, request: .init(session: session, revision: revision,
            parentPID: 1, fixtureWindows: nil, anchors: [], experimentalSpaces: false), accessibility: .partial)
        sample.sampledFrom = date.addingTimeInterval(began)
        sample.sampledTo = date.addingTimeInterval(ended)
        sample.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [],
            windowLimitReached: false, beganUptime: began, endedUptime: ended,
            stageManagerEnabled: false, catalogComplete: complete)
        sample.native?.catalogIssues = issues ?? (complete ? nil : ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86"])
        return sample
    }

    private func fresh() -> DesktopSnapshot { snapshot(complete: true, revision: 6, began: 13, ended: 14) }

    private func opening(_ first: DesktopSnapshot,
                         state: @MainActor () -> StageWindowEngineWitness.InitialReadState = { .init() },
                         current: @MainActor () -> Bool = { true },
                         read: @MainActor () async -> DesktopSnapshot?) async throws -> DesktopSnapshot {
        var tick = 0
        let instants = [11.5, 12.0, 15.0]
        return try await StageWindowEngineWitness.initialOpeningDirectory(first, display: fixture.display, scope: scope,
            session: session, topology: "fixture", authorized: authorized, state: state, current: current, read: read,
            clock: {
                let now = instants[min(tick, instants.count - 1)]
                tick += 1
                return (date.addingTimeInterval(now), now)
            })
    }

    @Test func oneRosterChangeUsesOnlyTheLaterCompleteDirectoryWithoutRepairingTheFailedOne() async throws {
        let first = snapshot(complete: false)
        let later = snapshot(complete: true, revision: 6,
            windows: [window(53, rank: 0), window(55, rank: 1), window(56, rank: 2), window(86, rank: 3)], began: 13, ended: 14)
        var reads = 0
        let result = try await opening(first) { reads += 1; return later }
        #expect(reads == 1 && result == later)
        #expect(first.native?.catalogComplete == false && first.windows.count == 3)
        #expect(result.windows.count == 4 && result.revision > first.revision)
        #expect(result.sampledFrom > date.addingTimeInterval(12) && result.native!.beganUptime > 12)
    }

    @Test func aSecondIncompleteDirectoryFailsAfterExactlyOneFreshRead() async {
        var reads = 0
        await #expect(throws: StageSwitchError.incomplete) {
            try await opening(snapshot(complete: false)) {
                reads += 1
                return snapshot(complete: false, revision: 6, began: 13, ended: 14)
            }
        }
        #expect(reads == 1)
    }

    @Test(arguments: ["sequence", "bindings", "claims", "enrolled", "specialized"])
    func anExistingOrSpecializedWitnessNeverRetries(_ change: String) async throws {
        var state = StageWindowEngineWitness.InitialReadState()
        switch change {
        case "sequence": state.sequence = 1
        case "bindings": state.bindings = 1
        case "claims": state.claims = 1
        case "enrolled": state.enrolled = true
        default: state.specialized = true
        }
        let first = snapshot(complete: false)
        var reads = 0
        let result = try await opening(first, state: { state }) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: [[], ["windowIdentityOrBounds:pid=614,window=86"],
        ["windowRosterChanged", "backgroundRosterIncomplete"], ["windowRosterChanged", "nativeInventoryUnavailable"],
        ["windowRosterChanged", "membershipDisplayMismatch:pid=614,window=86"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=53"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86,extra=1"],
        ["windowRosterChanged", "windowIdentityOrBounds:pid=0,window=86"],
        ["windowRosterChanged", "windowRosterChanged"],
        ["windowRosterChanged"] + Array(repeating: "windowIdentityOrBounds:pid=614,window=86", count: 31)])
    func otherOrPotentiallyTruncatedIssuesCannotAuthorizeARetry(_ issues: [String]) async throws {
        let first = snapshot(complete: false, issues: issues)
        var reads = 0
        let result = try await opening(first) { reads += 1; return fresh() }
        #expect(result == first && reads == 0)
    }

    @Test(arguments: ["session", "topology", "space", "stale", "permission", "complete"])
    func aLostInitialContextCannotRequestAnotherDirectory(_ change: String) async throws {
        var first = snapshot(complete: change == "complete")
        switch change {
        case "session": first.sessionID = UUID()
        case "topology": first.topologyFingerprint = "changed"
        case "space": first.scopes = [.init(id: "scope", displayID: fixture.display,
            records: [.init(id: "4", isCurrent: true, ordinaryUUID: UUID())])]
        case "stale": first.freshness = .stale
        default: break
        }
        var reads = 0
        if change == "permission" {
            await #expect(throws: StageSwitchError.interrupted) {
                try await opening(first, current: { false }) { reads += 1; return fresh() }
            }
        } else {
            let result = try await opening(first) { reads += 1; return fresh() }
            #expect(result == first)
        }
        #expect(reads == 0)
    }

    @Test(arguments: ["session", "topology", "scope", "display", "identity", "targetFrame", "membership",
                      "missingAuthorized", "sameRevision", "wallBefore", "wallEqual", "nativeBefore", "nativeEqual"])
    func aFreshResponseCannotChangeIdentityScopeTargetOrTheSamplingBoundary(_ change: String) async {
        var later = fresh()
        switch change {
        case "session": later.sessionID = UUID()
        case "topology": later.topologyFingerprint = "changed"
        case "scope": later.scopes = [.init(id: "scope", displayID: fixture.display,
            records: [.init(id: "4", isCurrent: true, ordinaryUUID: UUID())])]
        case "display": later.displays[0].usable = .init(width: 800, height: 700)
        case "identity": later.windows[0] = window(53, rank: 0, birth: 3401)
        case "targetFrame": later.windows[0] = window(53, rank: 0, frame: .init(x: 25, y: 32, width: 320, height: 200))
        case "membership": later.windows[0] = window(53, rank: 0, membership: .unknown)
        case "missingAuthorized": later.windows.removeFirst()
        case "sameRevision": later.revision = 5
        case "wallBefore": later.sampledFrom = date.addingTimeInterval(11.9)
        case "wallEqual": later.sampledFrom = date.addingTimeInterval(12)
        default:
            later.native = .init(population: .workWindows, accessibility: .partial, spaces: .observed, rows: [],
                windowLimitReached: false, beganUptime: change == "nativeBefore" ? 11.9 : 12, endedUptime: 14,
                stageManagerEnabled: false, catalogComplete: true)
        }
        var reads = 0
        await #expect(throws: StageSwitchError.self) {
            try await opening(snapshot(complete: false)) { reads += 1; return later }
        }
        #expect(reads == 1)
    }

    @Test(arguments: ["intent", "sequence", "bindings", "claims", "enrolled", "specialized", "cancelled"])
    func theOriginalSelectionAndUnenrolledStateMustSurviveTheAwait(_ change: String) async {
        var state = StageWindowEngineWitness.InitialReadState(), current = true, reads = 0
        let job = Task {
            try await opening(snapshot(complete: false), state: { state }, current: { current }) {
                reads += 1
                switch change {
                case "sequence": state.sequence = 1
                case "bindings": state.bindings = 1
                case "claims": state.claims = 1
                case "enrolled": state.enrolled = true
                case "specialized": state.specialized = true
                case "cancelled": withUnsafeCurrentTask { $0?.cancel() }
                default: current = false
                }
                return fresh()
            }
        }
        await #expect(throws: StageSwitchError.interrupted) { try await job.value }
        #expect(reads == 1)
    }
}

/// Each suspension is released by an observed request/publication, never a sleep.
@MainActor private final class InitialDirectoryLatch {
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var opened = false
    func wait() async {
        guard !opened else { return }
        var values = signal.stream.makeAsyncIterator()
        _ = await values.next()
    }
    func open() { opened = true; signal.continuation.yield(()); signal.continuation.finish() }
}

@MainActor private final class InitialDirectoryRace {
    let fixture = StageHostGroupProjectionTests()
    private let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var replies = [UInt64: AsyncStream<DesktopSnapshot>.Continuation]()
    private var requests = [UInt64: DesktopReadRequest]()
    private var actions = [Task<DesktopSnapshot?, Never>]()
    private var latches = [InitialDirectoryLatch]()
    private var closed = false
    var baseline: DesktopSnapshot?
    private var authorizedLifetimes = [DesktopWindowKey: UUID]()
    var current = true
    var state = StageWindowEngineWitness.InitialReadState()
    var eligibilityChecks = 0
    var duringEligibility: (() -> Void)?
    var joined = Set<UInt64>(), publishing = Set<UInt64>(), finishedPublishing = Set<UInt64>()
    var published = [UInt64]()
    var publicationHolds = [UInt64: InitialDirectoryLatch]()
    var first: DesktopSnapshot?, firstReturned = false, actionFinished = false
    var retries = 0
    var boundaries = [(revision: UInt64, date: Date)]()
    var failure: Error?
    lazy var feed = CurrentDesktopWindows(read: { [weak self] request in
        guard let self else { throw ReaderFailure.unavailable }
        return try await self.read(request)
    }, sessionAvailable: { true }, fingerprint: { nil })

    var scope: StageGroupScope { .init(display: UUID(uuidString: fixture.display)!, nativeSpace: fixture.space) }
    var authorized: Set<NativeSpaceWindow> {
        Set([UInt32(53), 55, 56].map { .init(pid: 614, birth: 3400, number: $0) })
    }
    func key(_ number: UInt32) -> DesktopWindowKey { .init(pid: 614, birth: 3400, number: number) }
    func signal() { changes.continuation.yield(()) }
    func latch() -> InitialDirectoryLatch {
        let result = InitialDirectoryLatch(); latches.append(result); return result
    }
    func until(_ predicate: () -> Bool) async throws {
        var events = changes.stream.makeAsyncIterator()
        while !predicate() {
            guard await events.next() != nil else { throw ReaderFailure.unavailable }
        }
    }
    private func read(_ request: DesktopReadRequest) async throws -> DesktopSnapshot {
        guard !closed else { throw ReaderFailure.unavailable }
        let response = AsyncStream<DesktopSnapshot>.makeStream()
        requests[request.revision] = request; replies[request.revision] = response.continuation
        signal()
        var values = response.stream.makeAsyncIterator()
        guard let value = await values.next() else { throw ReaderFailure.unavailable }
        return value
    }
    func nextRequest(after revision: UInt64) async throws -> DesktopReadRequest {
        try await until { replies.keys.contains { $0 > revision } }
        return try #require(replies.keys.filter { $0 > revision }.min().flatMap { requests[$0] })
    }
    func freshRequest(boundary index: Int) async throws -> DesktopReadRequest {
        try await until { boundaries.count > index }
        let boundary = boundaries[index]
        while true {
            let request = try await nextRequest(after: 0)
            if request.revision > boundary.revision { return request }
            // A periodic observation may already be queued on a loaded runner.
            // Explicitly drain it at the wall-clock boundary, which cannot
            // satisfy the action's strictly-later reuse rule, preserving its rows.
            var prior = sample(request, complete: true)
            prior.sampledFrom = boundary.date
            deliver(prior)
        }
    }
    func sample(_ request: DesktopReadRequest, complete: Bool, numbers: [UInt32]? = nil,
                issues: [String]? = nil) -> DesktopSnapshot {
        // 90 is an existing bystander; 88 appears only in the failed inventory.
        // An accidental producer-side mutation is visible even before publication.
        let numbers = numbers ?? (complete ? [53, 55, 56, 90] : [53, 55, 56, 88])
        let windows = numbers.enumerated().map { rank, number in
            var window = fixture.window(number, rank: rank)
            window.metadata?.minimized = false; window.metadata?.fullScreen = false
            window.metadata?.overviewOrdinaryRole = true
            return window
        }
        var sample = fixture.snapshot(windows, complete: complete, request: request, accessibility: .partial)
        sample.native?.catalogIssues = issues ?? (complete ? nil : ["windowRosterChanged", "windowIdentityOrBounds:pid=614,window=86"])
        return sample
    }
    func deliver(_ sample: DesktopSnapshot) {
        let reply = replies.removeValue(forKey: sample.revision)
        reply?.yield(sample); reply?.finish()
    }
    @discardableResult
    func answer(_ request: DesktopReadRequest, complete: Bool, numbers: [UInt32]? = nil,
                issues: [String]? = nil) -> DesktopSnapshot {
        let sample = self.sample(request, complete: complete, numbers: numbers, issues: issues)
        deliver(sample)
        return sample
    }
    func start() async throws {
        feed.didSample = { [weak self] in
            guard let self else { return }
            if let revision = feed.snapshot?.revision { published.append(revision) }
            signal()
        }
        feed.didBeginAfterActionRead = { [weak self] date, _ in
            guard let self else { return }
            boundaries.append((feed.revision, date)); signal()
        }
        feed.didJoinPendingRead = { [weak self] revision in self?.joined.insert(revision); self?.signal() }
        feed.beforePublishingRead = { [weak self] revision in
            guard let self, let revision else { return }
            publishing.insert(revision); signal()
            if let hold = publicationHolds[revision] { await hold.wait() }
        }
        feed.didFinishPublishingRead = { [weak self] revision in
            if let revision { self?.finishedPublishing.insert(revision) }
            self?.signal()
        }
        feed.observe(true)
        let seed = try await nextRequest(after: 0)
        answer(seed, complete: true)
        try await until { published.contains(seed.revision) }
        baseline = try #require(feed.snapshot)
        for window in authorized {
            let key = self.key(window.number)
            authorizedLifetimes[key] = try #require(feed.groupLifetime(of: key))
        }
    }
    private var selectionCurrent: Bool {
        current && authorizedLifetimes.allSatisfy { feed.groupLifetime(of: $0.key) == $0.value }
    }
    func staging() -> CurrentDesktopWindows.InitialDirectoryStaging {
        .init { [weak self] sample in
            guard let self, let baseline, selectionCurrent,
                  StageWindowEngineWitness.initialOpeningCandidate(sample, display: fixture.display, scope: scope,
                    session: baseline.sessionID, topology: baseline.topologyFingerprint, authorized: authorized,
                    state: state, clock: { (.now, ProcessInfo.processInfo.systemUptime) }) != nil else { return false }
            eligibilityChecks += 1
            duringEligibility?()
            return true
        }
    }
    func action(_ token: CurrentDesktopWindows.InitialDirectoryStaging, retry: Bool = false,
                afterFirst: InitialDirectoryLatch? = nil) -> Task<DesktopSnapshot?, Never> {
        first = nil; firstReturned = false; actionFinished = false; failure = nil
        let action = Task {
            let cancellation = token.cancellation
            let read = await withTaskCancellationHandler {
                await feed.readAfterAction(staging: token)
            } onCancel: { cancellation.cancel() }
            first = read; firstReturned = true; signal()
            if let afterFirst { await afterFirst.wait() }
            var result = read
            if retry, let read, let baseline {
                do {
                    result = try await StageWindowEngineWitness.initialOpeningDirectory(read, display: fixture.display,
                        scope: scope, session: baseline.sessionID, topology: baseline.topologyFingerprint,
                        authorized: authorized, state: { self.state }, current: { self.selectionCurrent },
                        read: { await self.feed.readAfterAction() }, retrying: { self.retries += 1 })
                } catch { failure = error; result = nil }
            }
            actionFinished = true; signal()
            return result
        }
        actions.append(action)
        return action
    }
    func close() {
        closed = true; duringEligibility = nil
        feed.beforeFreshAfterActionRead = nil
        for action in actions { action.cancel() }
        for latch in latches { latch.open() }
        for reply in replies.values { reply.finish() }
        feed.observe(false)
        changes.continuation.finish()
    }
}

@MainActor struct StageHostInitialDirectoryStagingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func sharedPendingFailureCannotMutateOrReplayOverTheFreshDirectory(latePublisher: Bool) async throws {
        let race = InitialDirectoryRace()
        defer { race.close() }
        try await race.start()
        let originalDirectory = race.feed.groups.directory
        let bystander = try #require(race.feed.lifetime(of: race.key(90)))
        let foreground = race.latch(), publisher = race.latch()
        let action = race.action(race.staging(), retry: true, afterFirst: foreground)
        let first = try await race.freshRequest(boundary: 0)
        if latePublisher { race.publicationHolds[first.revision] = publisher }
        race.feed.changed()
        try await race.until { race.joined.contains(first.revision) }
        let beforeFailure = try #require(race.feed.snapshot)
        let failed = race.answer(first, complete: false)
        try await race.until { race.firstReturned && race.publishing.contains(first.revision) }
        if !latePublisher { try await race.until { race.finishedPublishing.contains(first.revision) } }
        #expect(race.first == failed && failed.native?.catalogComplete == false)
        #expect(race.feed.snapshot == beforeFailure && race.feed.lifetime(of: race.key(90)) == bystander)
        #expect(race.feed.lifetime(of: race.key(88)) == nil && race.feed.groups.directory == originalDirectory)
        #expect(!race.published.contains(first.revision) && race.eligibilityChecks == 1)

        foreground.open()
        let second = try await race.freshRequest(boundary: 1)
        let fresh = race.answer(second, complete: true, numbers: [53, 55, 56, 90, 99])
        let result = try #require(await action.value)
        #expect(result == fresh && result.revision > failed.revision && race.retries == 1 && race.failure == nil)
        let newestLifetime = try #require(race.feed.lifetime(of: race.key(99)))
        let newestDirectory = race.feed.groups.directory
        #expect(newestDirectory != originalDirectory)
        // This late consumer holds the immutable failed outcome after the
        // action token ended and a newer producer has updated groups/lifetimes.
        publisher.open()
        try await race.until { race.finishedPublishing.contains(first.revision) }
        #expect(!race.published.contains(first.revision) && race.feed.snapshot?.revision != first.revision)
        #expect(race.feed.lifetime(of: race.key(99)) == newestLifetime && race.feed.groups.directory == newestDirectory)
        #expect(race.feed.lifetime(of: race.key(90)) == bystander && race.feed.lifetime(of: race.key(88)) == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aTokenCannotProtectAnotherFailureAfterItsFirstCompleteOrStagedRead(firstComplete: Bool) async throws {
        let race = InitialDirectoryRace()
        defer { race.close() }
        try await race.start()
        let token = race.staging()
        let firstAction = race.action(token)
        let first = try await race.freshRequest(boundary: 0)
        race.feed.changed()
        try await race.until { race.joined.contains(first.revision) }
        let beforeFirst = try #require(race.feed.snapshot)
        race.answer(first, complete: firstComplete)
        _ = await firstAction.value
        try await race.until { race.finishedPublishing.contains(first.revision) }
        #expect(race.feed.snapshot?.revision == (firstComplete ? first.revision : beforeFirst.revision))
        #expect(race.feed.lifetime(of: race.key(90)) != nil && race.feed.lifetime(of: race.key(88)) == nil)

        let secondAction = race.action(token)
        let second = try await race.freshRequest(boundary: 1)
        race.feed.changed()
        try await race.until { race.joined.contains(second.revision) }
        let bad = race.answer(second, complete: false)
        #expect(await secondAction.value == bad)
        try await race.until { race.finishedPublishing.contains(second.revision) }
        #expect(race.feed.snapshot == bad && race.feed.lifetime(of: race.key(90)) == nil)
        #expect(race.feed.lifetime(of: race.key(88)) != nil)
        #expect(race.feed.groups.directory.displays.flatMap(\.groups).flatMap(\.members).contains { $0.windowHint.number == 88 })
        #expect(race.eligibilityChecks == (firstComplete ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func aBackgroundRequestWhileTheActionDrainsItsPriorReadCannotClaimTheActionToken() async throws {
        let race = InitialDirectoryRace()
        defer { race.close() }
        try await race.start()
        let baseline = try #require(race.baseline)
        race.feed.changed()
        let prior = try await race.nextRequest(after: baseline.revision)
        // This genuine sample precedes the input, so the action must drain the
        // prior task and enter its own fresh-read path instead of reusing it.
        let beforeInput = race.sample(prior, complete: true)
        let freshEntry = race.latch()
        var reachedFreshEntry = false
        race.feed.beforeFreshAfterActionRead = {
            reachedFreshEntry = true; race.signal(); await freshEntry.wait()
        }
        let action = race.action(race.staging())
        try await race.until { race.boundaries.count == 1 }
        race.deliver(beforeInput)
        try await race.until { reachedFreshEntry && race.finishedPublishing.contains(prior.revision) }

        // The observation loop completes a different request while the action
        // has an active registration but has not bound its actual fresh task.
        race.feed.changed()
        let unrelated = try await race.nextRequest(after: prior.revision)
        let bad = race.answer(unrelated, complete: false)
        try await race.until { race.finishedPublishing.contains(unrelated.revision) }
        #expect(race.feed.snapshot == bad && race.eligibilityChecks == 0)
        #expect(race.feed.lifetime(of: race.key(90)) == nil && race.feed.lifetime(of: race.key(88)) != nil)

        freshEntry.open()
        let own = try await race.freshRequest(boundary: 0)
        let complete = race.answer(own, complete: true)
        #expect(await action.value == complete && own.revision > unrelated.revision)
        #expect(race.first?.revision == own.revision && race.eligibilityChecks == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancelledBeforeReply", "cancelledDuringEligibility", "intent", "bindings"])
    func cancellationOrLostInitialAuthorityPublishesTheFailureNormally(_ change: String) async throws {
        let race = InitialDirectoryRace()
        defer { race.close() }
        try await race.start()
        let token = race.staging()
        let action = race.action(token)
        let request = try await race.freshRequest(boundary: 0)
        race.feed.changed()
        try await race.until { race.joined.contains(request.revision) }
        switch change {
        case "cancelledBeforeReply": action.cancel()
        case "cancelledDuringEligibility": race.duringEligibility = { action.cancel() }
        case "intent": race.current = false
        default: race.state.bindings = 1
        }
        let bad = race.answer(request, complete: false)
        _ = await action.value
        try await race.until { race.finishedPublishing.contains(request.revision) }
        // Cancellation does not rewrite the existing API's raw return value;
        // the original action's later current/permit guards remain mandatory.
        #expect(race.feed.snapshot == bad && race.feed.lifetime(of: race.key(90)) == nil)
        #expect(race.feed.lifetime(of: race.key(88)) != nil)
        #expect(race.eligibilityChecks == (change == "cancelledDuringEligibility" ? 1 : 0))
        if change.hasPrefix("cancelled") { #expect(token.cancellation.isCancelled) }
    }

    @Test(.timeLimit(.minutes(1)))
    func theActualSingleRetryPublishesAndRejectsASecondIncompleteDirectory() async throws {
        let race = InitialDirectoryRace()
        defer { race.close() }
        try await race.start()
        let foreground = race.latch()
        let action = race.action(race.staging(), retry: true, afterFirst: foreground)
        let first = try await race.freshRequest(boundary: 0)
        race.feed.changed()
        try await race.until { race.joined.contains(first.revision) }
        let beforeFailure = try #require(race.feed.snapshot)
        race.answer(first, complete: false)
        try await race.until { race.firstReturned && race.finishedPublishing.contains(first.revision) }
        #expect(race.feed.snapshot == beforeFailure)
        foreground.open()
        let retry = try await race.freshRequest(boundary: 1)
        race.feed.changed()
        try await race.until { race.joined.contains(retry.revision) }
        let stillBad = race.answer(retry, complete: false)
        #expect(await action.value == nil)
        try await race.until { race.finishedPublishing.contains(retry.revision) }
        #expect(race.retries == 1 && race.failure as? StageSwitchError == .incomplete)
        #expect(race.feed.snapshot == stillBad && race.feed.lifetime(of: race.key(90)) == nil)
        #expect(!race.published.contains(first.revision) && race.published.contains(retry.revision))
    }
}
