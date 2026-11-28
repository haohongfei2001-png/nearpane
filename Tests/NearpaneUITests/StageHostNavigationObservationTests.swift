import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

/// No detector poll can rescue a lost observation in these tests.
private final class NavigationObservationHint: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor private final class NavigationObservationLatch {
    private var opened = false
    private let signal = AsyncStream<Void>.makeStream()
    func wait() async {
        guard !opened else { return }
        var events = signal.stream.makeAsyncIterator()
        _ = await events.next()
    }
    func open() { opened = true; signal.continuation.yield(()); signal.continuation.finish() }
}

@MainActor private final class NavigationObservationRace {
    lazy var navigation = NativeSidebarNavigation(beginUserActivity: { [weak self] in
        { self?.signal() }
    })
    let confirmation = NavigationObservationLatch(), work = NavigationObservationLatch()
    private let fixture = StageHostGroupProjectionTests()
    private let hint = NavigationObservationHint()
    private let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var requests = [UInt64: DesktopReadRequest]()
    private var replies = [UInt64: AsyncStream<DesktopSnapshot>.Continuation]()
    private var closed = false
    var confirmationEntered = false, workEntered = false
    var workTokens = [UUID]()
    var waits = [String](), published = [UInt64]()
    var registeredWaits = [UUID]()
    var publishing = Set<UInt64>(), finishedPublishing = Set<UInt64>()
    var publicationHolds = [UInt64: NavigationObservationLatch]()
    var duringWait: ((String) -> Void)?
    var requestCount: Int { requests.count }
    var navigationWaitCount: Int { waits.filter { $0 == "observer-navigation" }.count }
    lazy var feed = CurrentDesktopWindows(read: { [weak self] request in
        guard let self else { throw ReaderFailure.unavailable }
        return try await self.read(request)
    }, sessionAvailable: { true }, fingerprint: { [hint] in
        hint.wait(); return nil
    }, navigation: navigation)

    init() {
        navigation.didRegisterObserverWait = { [weak self] id in
            self?.registeredWaits.append(id); self?.signal()
        }
        navigation.confirmDispatch = { [weak self] in
            guard let self else { return false }
            confirmationEntered = true; signal()
            await confirmation.wait()
            return true
        }
    }
    func signal() { changes.continuation.yield(()) }
    func until(_ predicate: () -> Bool) async throws {
        var events = changes.stream.makeAsyncIterator()
        while !predicate() {
            guard await events.next() != nil else { throw ReaderFailure.unavailable }
        }
    }
    @discardableResult
    func submit(needsInitialObservation: Bool = true, until supplied: NavigationObservationLatch? = nil) -> UUID {
        let completion = supplied ?? work
        navigation.submit(stage: true, needsInitialObservation: needsInitialObservation) { [weak self] token in
            guard let self else { return }
            workEntered = true; workTokens.append(token); signal()
            await completion.wait()
        }
        return navigation.generation
    }
    func observe() {
        feed.didWaitForMetadataRead = { [weak self] reason in
            guard let self else { return }
            waits.append(reason); signal(); duringWait?(reason)
        }
        feed.didSample = { [weak self] in
            guard let self else { return }
            if let revision = feed.snapshot?.revision { published.append(revision) }
            signal()
        }
        feed.beforePublishingRead = { [weak self] revision in
            guard let self, let revision else { return }
            publishing.insert(revision); signal()
            if let hold = publicationHolds[revision] { await hold.wait() }
        }
        feed.didFinishPublishingRead = { [weak self] revision in
            if let revision { self?.finishedPublishing.insert(revision) }
            self?.signal()
        }
        // Exercise the real observer loop without requesting presentation AX work.
        feed.observeManagement(true)
    }
    private func read(_ request: DesktopReadRequest) async throws -> DesktopSnapshot {
        guard !closed else { throw ReaderFailure.unavailable }
        let response = AsyncStream<DesktopSnapshot>.makeStream()
        requests[request.revision] = request; replies[request.revision] = response.continuation
        signal()
        var values = response.stream.makeAsyncIterator()
        guard let result = await values.next() else { throw ReaderFailure.unavailable }
        return result
    }
    func nextRequest(after revision: UInt64 = 0) async throws -> DesktopReadRequest {
        try await until { replies.keys.contains { $0 > revision } }
        return try #require(replies.keys.filter { $0 > revision }.min().flatMap { requests[$0] })
    }
    @discardableResult
    func answer(_ request: DesktopReadRequest, complete: Bool = true) -> DesktopSnapshot {
        var sample = fixture.snapshot([], complete: complete, request: request, accessibility: .partial)
        sample.native?.catalogIssues = complete ? nil : ["windowRosterChanged"]
        let reply = replies.removeValue(forKey: request.revision)
        reply?.yield(sample); reply?.finish()
        return sample
    }
    func seed() async throws -> DesktopSnapshot {
        observe()
        let request = try await nextRequest()
        let sample = answer(request)
        try await until { finishedPublishing.contains(request.revision) }
        return sample
    }
    func close() {
        closed = true; duringWait = nil
        feed.observeManagement(false)
        navigation.setDispatchAvailable(false)
        confirmation.open(); work.open()
        for hold in publicationHolds.values { hold.open() }
        for reply in replies.values { reply.finish() }
        hint.release()
        changes.continuation.finish()
    }
}

@MainActor @Suite(.serialized) struct StageHostNavigationObservationTests {
    @Test(.timeLimit(.minutes(1)))
    func anInitialObservationGateOpensDuringItsJobWithoutBlockingForegroundReads() async throws {
        let race = NavigationObservationRace(), scope = StageMetadataReadScope()
        defer { race.feed.endMetadataReadScope(scope); race.close() }
        let epoch = race.navigation.ownershipEpoch, token = race.submit()
        #expect(race.navigation.isDispatching && race.navigation.blocksObserverAdmission && !race.confirmationEntered)
        race.observe()
        try await race.until { race.navigationWaitCount == 1 && race.registeredWaits.count == 1 && race.confirmationEntered }
        #expect(race.requestCount == 0 && race.feed.snapshot == nil)

        // Neither direct entry point can depend on the automatic publication token.
        let plain = Task { await race.feed.readNow() }
        defer { plain.cancel() }
        let first = try await race.nextRequest()
        let firstSample = race.answer(first, complete: false)
        #expect(await plain.value == firstSample)
        #expect(race.navigation.blocksObserverAdmission)
        let action = Task { await race.feed.readAfterAction() }
        defer { action.cancel() }
        let second = try await race.nextRequest(after: first.revision)
        let secondSample = race.answer(second)
        #expect(await action.value == secondSample)
        // Even a complete unrelated read cannot end a job's explicit preparation.
        #expect(race.navigation.blocksObserverAdmission)
        #expect(!race.navigation.completeInitialObservation(for: UUID(), in: epoch))
        #expect(!race.navigation.completeInitialObservation(for: token, in: UUID()))

        try await race.feed.acquireMetadataReadScope(scope, current: { true })
        #expect(race.feed.hasMetadataReadScope(scope))
        #expect(await race.feed.readAfterAction(within: StageMetadataReadScope()) == nil)
        var revision = second.revision
        for phase in 0..<2 {
            if phase == 1 {
                race.confirmation.open()
                try await race.until { race.workEntered }
            }
            let owner = Task { await race.feed.readAfterAction(within: scope) }
            defer { owner.cancel() }
            let request = try await race.nextRequest(after: revision)
            let sample = race.answer(request)
            #expect(await owner.value == sample)
            revision = request.revision
            #expect(race.navigation.isDispatching && race.feed.snapshot == nil && race.published.isEmpty)
        }
        #expect(race.navigation.completeInitialObservation(for: token, in: epoch))
        #expect(!race.navigation.completeInitialObservation(for: token, in: epoch))
        try await race.until { race.waits.contains("observer") }
        #expect(race.requestCount == 4 && race.navigationWaitCount == 1)
        // Admission opens, but an exact foreground metadata scope still owns its reads.
        race.feed.endMetadataReadScope(scope)
        let observer = try await race.nextRequest(after: revision)
        let observed = race.answer(observer)
        try await race.until { race.finishedPublishing.contains(observer.revision) }
        #expect(race.navigation.isDispatching && !race.navigation.blocksObserverAdmission && race.feed.snapshot == observed)
        #expect(race.requestCount == 5 && race.published == [observer.revision])
        #expect(observed.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anAlreadyAdmittedPublisherStillDrainsDuringNavigation(incomplete: Bool) async throws {
        let race = NavigationObservationRace(), scope = StageMetadataReadScope(), hold = NavigationObservationLatch()
        defer { hold.open(); race.feed.endMetadataReadScope(scope); race.close() }
        let seed = try await race.seed()
        race.feed.changed()
        let prior = try await race.nextRequest(after: seed.revision)
        race.publicationHolds[prior.revision] = hold
        race.submit()
        var acquired = false
        let acquire = Task {
            try await race.feed.acquireMetadataReadScope(scope, current: { race.feed.snapshot?.native?.catalogComplete == true })
            acquired = true; race.signal()
        }
        defer { acquire.cancel() }
        try await race.until { race.waits.contains("drain") && race.confirmationEntered }
        // Queue one later observer, but leave the already admitted one free to publish.
        race.feed.changed()
        let sample = race.answer(prior, complete: !incomplete)
        try await race.until { race.publishing.contains(prior.revision) }
        #expect(!acquired && race.feed.snapshot == seed && race.navigation.isDispatching)
        hold.open()
        if incomplete {
            await #expect(throws: StageSwitchError.interrupted) { try await acquire.value }
        } else { try await acquire.value }
        try await race.until { race.navigationWaitCount == 1 && race.registeredWaits.count == 1 }
        #expect(acquired == !incomplete && race.feed.hasMetadataReadScope(scope) == !incomplete)
        #expect(race.finishedPublishing.contains(prior.revision) && race.feed.snapshot == sample)
        #expect(race.feed.snapshot?.native?.catalogComplete == !incomplete)
        #expect(race.published == [seed.revision, prior.revision] && race.requestCount == 2)
        #expect(race.navigation.isDispatching && !race.workEntered)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aRevokedActualJobLeavesAdmissionOpenUntilTheNextJobDequeues(reenableWhileBusy: Bool) async throws {
        let race = NavigationObservationRace()
        defer { race.close() }
        let oldEpoch = race.navigation.ownershipEpoch, old = race.submit()
        race.observe()
        try await race.until { race.navigationWaitCount == 1 && race.registeredWaits.count == 1 && race.confirmationEntered }
        race.navigation.setDispatchAvailable(false)
        var next: UUID?
        if reenableWhileBusy {
            race.navigation.setDispatchAvailable(true)
            next = race.submit()
        }
        #expect(!race.navigation.blocksObserverAdmission && race.navigation.isDispatching)
        // This was the only coalesced event; the old actual job is still awaiting confirmation.
        let first = try await race.nextRequest()
        race.answer(first)
        try await race.until { race.finishedPublishing.contains(first.revision) }
        #expect(race.navigation.isDispatching && !race.workEntered && race.requestCount == 1)
        if !reenableWhileBusy {
            race.navigation.setDispatchAvailable(true)
            next = race.submit()
        }
        let token = try #require(next), epoch = race.navigation.ownershipEpoch
        #expect(!race.navigation.blocksObserverAdmission)
        #expect(!race.navigation.completeInitialObservation(for: old, in: oldEpoch))
        #expect(!race.navigation.completeInitialObservation(for: old, in: epoch))
        race.confirmation.open()
        try await race.until { race.workTokens.contains(token) }
        #expect(race.navigation.blocksObserverAdmission)
        race.feed.changed()
        try await race.until { race.navigationWaitCount == 2 && race.registeredWaits.count == 2 }
        #expect(!race.navigation.completeInitialObservation(for: token, in: oldEpoch))
        let action = Task { await race.feed.readAfterAction() }
        defer { action.cancel() }
        let second = try await race.nextRequest(after: first.revision)
        let fresh = race.answer(second)
        #expect(await action.value == fresh)
        #expect(race.navigation.completeInitialObservation(for: token, in: epoch))
        let observer = try await race.nextRequest(after: second.revision)
        race.answer(observer)
        try await race.until { race.finishedPublishing.contains(observer.revision) }
        #expect(race.published == [first.revision, observer.revision] && race.navigation.isDispatching)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["stop", "epoch", "before-registration"])
    func revokedObserverWaitsCannotBlockANewFeedEpoch(_ change: String) async throws {
        let race = NavigationObservationRace(), scope = StageMetadataReadScope()
        defer { race.feed.endMetadataReadScope(scope); race.close() }
        if change == "before-registration" {
            race.duringWait = { reason in
                guard reason == "observer-navigation" else { return }
                race.duringWait = nil
                race.feed.invalidate(reason: "test-before-navigation-wait-registration")
            }
        }
        race.submit(); race.observe()
        try await race.until { !race.registeredWaits.isEmpty && race.confirmationEntered }
        if change == "stop" {
            race.feed.observeManagement(false)
            race.observe()
        } else if change == "epoch" {
            race.feed.invalidate(reason: "test-navigation-observer-epoch")
        }
        try await race.until {
            race.navigationWaitCount == 2 && race.registeredWaits.count == (change == "before-registration" ? 1 : 2)
        }
        #expect(race.requestCount == 0 && race.feed.snapshot == nil)
        try await race.feed.acquireMetadataReadScope(scope, current: { true })
        let owner = Task { await race.feed.readAfterAction(within: scope) }
        defer { owner.cancel() }
        let direct = try await race.nextRequest()
        let sample = race.answer(direct)
        #expect(await owner.value == sample)
        race.feed.endMetadataReadScope(scope)
        #expect(race.navigation.isDispatching && race.feed.snapshot == nil)
        race.work.open(); race.confirmation.open()
        let observer = try await race.nextRequest(after: direct.revision)
        race.answer(observer)
        try await race.until { race.finishedPublishing.contains(observer.revision) }
        #expect(race.published == [observer.revision] && race.requestCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func eachActualQueuedJobOwnsItsGateAndAReadyJobKeepsPublishing() async throws {
        let race = NavigationObservationRace(), firstWork = NavigationObservationLatch(), secondWork = NavigationObservationLatch()
        defer { firstWork.open(); secondWork.open(); race.close() }
        let epoch = race.navigation.ownershipEpoch, first = race.submit(until: firstWork)
        race.observe()
        try await race.until { race.registeredWaits.count == 1 && race.confirmationEntered }
        race.confirmation.open()
        try await race.until { race.workTokens == [first] }
        let firstRead = Task { await race.feed.readAfterAction() }
        defer { firstRead.cancel() }
        let request = try await race.nextRequest()
        let fresh = race.answer(request)
        #expect(await firstRead.value == fresh)
        let second = race.submit(until: secondWork)
        // Scheduling is bound to the actual job, not the newest selection generation.
        #expect(!race.navigation.isCurrent(first) && race.navigation.isCurrent(second))
        #expect(race.navigation.completeInitialObservation(for: first, in: epoch))
        #expect(!race.navigation.blocksObserverAdmission && race.workTokens == [first])
        let observed = try await race.nextRequest(after: request.revision)
        race.answer(observed)
        try await race.until { race.finishedPublishing.contains(observed.revision) }
        race.feed.changed()
        let whilePending = try await race.nextRequest(after: observed.revision)
        race.answer(whilePending)
        try await race.until { race.finishedPublishing.contains(whilePending.revision) }
        #expect(race.navigation.isDispatching && race.workTokens == [first])

        firstWork.open()
        try await race.until { race.workTokens == [first, second] }
        #expect(race.navigation.blocksObserverAdmission)
        #expect(!race.navigation.completeInitialObservation(for: first, in: epoch))
        #expect(!race.navigation.completeInitialObservation(for: second, in: UUID()))
        race.feed.changed()
        try await race.until { race.registeredWaits.count == 2 }
        let secondRead = Task { await race.feed.readAfterAction() }
        defer { secondRead.cancel() }
        let next = try await race.nextRequest(after: whilePending.revision)
        let nextFresh = race.answer(next)
        #expect(await secondRead.value == nextFresh)
        #expect(race.navigation.completeInitialObservation(for: second, in: epoch))
        let final = try await race.nextRequest(after: next.revision)
        race.answer(final)
        try await race.until { race.finishedPublishing.contains(final.revision) }
        #expect(race.navigation.isDispatching && !race.navigation.blocksObserverAdmission)
        #expect(race.published == [observed.revision, whilePending.revision, final.revision])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anOptOutJobCanPublishEvenWhenItReplacesAnOptedInPendingChoice(replacesPending: Bool) async throws {
        let race = NavigationObservationRace()
        defer { race.close() }
        let epoch = race.navigation.ownershipEpoch
        var discarded: UUID?
        if replacesPending {
            discarded = race.submit()
            #expect(race.navigation.blocksObserverAdmission)
        }
        // Both submits run in the same actor turn, before any dequeue can start.
        let token = race.submit(needsInitialObservation: false)
        #expect(!race.navigation.blocksObserverAdmission && race.navigation.isDispatching)
        race.observe()
        let request = try await race.nextRequest()
        race.answer(request)
        try await race.until { race.finishedPublishing.contains(request.revision) && race.confirmationEntered }
        #expect(race.registeredWaits.isEmpty && race.navigationWaitCount == 0 && !race.workEntered)
        if let discarded { #expect(!race.navigation.completeInitialObservation(for: discarded, in: epoch)) }
        #expect(!race.navigation.completeInitialObservation(for: token, in: epoch))
        #expect(race.published == [request.revision] && race.navigation.isDispatching)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aJobThatEndsWithoutACompleteInitialReadReleasesItsGate(fails: Bool) async throws {
        let race = NavigationObservationRace(), finish = NavigationObservationLatch()
        defer { finish.open(); race.close() }
        let epoch = race.navigation.ownershipEpoch
        race.navigation.submit(stage: true, needsInitialObservation: true) { _ in
            await finish.wait()
            if fails { throw StageSwitchError.interrupted }
        }
        let token = race.navigation.generation
        race.observe()
        try await race.until { race.registeredWaits.count == 1 && race.confirmationEntered }
        race.confirmation.open()
        #expect(race.navigation.blocksObserverAdmission && race.requestCount == 0)
        finish.open()
        let request = try await race.nextRequest()
        race.answer(request)
        try await race.until { race.finishedPublishing.contains(request.revision) }
        #expect(!race.navigation.isDispatching && !race.navigation.blocksObserverAdmission)
        #expect((race.navigation.issue != nil) == fails)
        #expect(!race.navigation.completeInitialObservation(for: token, in: epoch))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anObserverWaitCancellationUnregistersItsContinuation(cancelBeforeRegistration: Bool) async throws {
        let race = NavigationObservationRace(), id = UUID()
        defer { race.close() }
        race.submit()
        var registrations = 0
        let wait = Task {
            await race.navigation.waitForObserverAdmission(id) {
                registrations += 1; race.signal(); return true
            }
        }
        defer { wait.cancel() }
        if !cancelBeforeRegistration { try await race.until { registrations == 1 } }
        wait.cancel()
        #expect(await wait.value == false)
        #expect(registrations == (cancelBeforeRegistration ? 0 : 1))
        let before = registrations
        // A pre-cancelled call may return before its queued cleanup actor turn.
        // Production always creates a new UUID; reuse proves removal only for a
        // registered continuation whose completion required that cleanup.
        let replacementID = cancelBeforeRegistration ? UUID() : id
        var replacementFinished = false
        let replacement = Task {
            defer { replacementFinished = true; race.signal() }
            return await race.navigation.waitForObserverAdmission(replacementID) {
                registrations += 1; race.signal(); return true
            }
        }
        defer { replacement.cancel() }
        try await race.until { registrations > before }
        #expect(!replacementFinished && race.navigation.isDispatching)
        race.work.open(); race.confirmation.open()
        #expect(await replacement.value == true)
        #expect(!race.navigation.isDispatching)
    }
}
