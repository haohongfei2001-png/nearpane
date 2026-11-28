import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class EditQueueSignal {
    private let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func changed() { stream.continuation.yield(()) }
    func until(_ predicate: () -> Bool) async throws {
        var iterator = stream.stream.makeAsyncIterator()
        while !predicate() {
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }
}

@MainActor private final class EditQueueLatch {
    private var opened = false
    private let stream = AsyncStream<Void>.makeStream()
    func wait() async {
        guard !opened else { return }
        var iterator = stream.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func open() { opened = true; stream.continuation.yield(()); stream.continuation.finish() }
}

@MainActor private final class EditQueueActivity {
    let signal = EditQueueSignal()
    var begun = 0, ended = 0
    lazy var navigation = NativeSidebarNavigation(beginUserActivity: { [self] in
        begun += 1
        return { self.ended += 1; self.signal.changed() }
    })
}

@MainActor @Suite(.serialized) struct StageHostGroupEditQueueTests {
    private nonisolated func failed(_ outcome: Result<Void, Error>) -> Bool {
        if case .failure = outcome { return true }
        return false
    }

    @Test(arguments: [false, true])
    func rejectedSubmissionHasExactlyOneOutcome(systemOwnsLane: Bool) {
        let activity = EditQueueActivity(), navigation = activity.navigation
        defer { navigation.setDispatchAvailable(false) }
        if systemOwnsLane { navigation.stageOwnsWindowDispatch = { true } }
        else { navigation.setDispatchAvailable(false) }
        var outcomes = [NativeSidebarNavigation.Outcome](), ran = false
        let token = navigation.submit(stage: false, outcome: { outcomes.append($0) }) { _ in ran = true }
        #expect(token == nil && !ran && !navigation.isDispatching)
        #expect(outcomes.count == 1 && outcomes.allSatisfy(failed))
        #expect(activity.begun == 0 && activity.ended == 0)
        navigation.setDispatchAvailable(true)
        #expect(outcomes.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func queueCapacityAndEpochDiscardFinishEachSubmissionOnce() async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation, hold = EditQueueLatch()
        defer { hold.open(); navigation.setDispatchAvailable(false) }
        var started = false, executed = 0, outcomes = [Int: [NativeSidebarNavigation.Outcome]]()
        func report(_ index: Int, _ outcome: NativeSidebarNavigation.Outcome) {
            outcomes[index, default: []].append(outcome); activity.signal.changed()
        }
        navigation.submit(selection: false, stage: true, outcome: { report(0, $0) }) { _ in
            started = true; executed += 1; activity.signal.changed(); await hold.wait()
        }
        try await activity.signal.until { started }
        for index in 1...8 {
            let token = navigation.submit(selection: false, stage: true, outcome: { report(index, $0) }) { _ in executed += 1 }
            #expect(token != nil)
        }
        let rejected = navigation.submit(selection: false, stage: true, outcome: { report(9, $0) }) { _ in executed += 1 }
        #expect(rejected == nil && outcomes[9]?.count == 1 && outcomes[9]?.allSatisfy(failed) == true)
        #expect(activity.begun == 9 && activity.ended == 0)
        navigation.setDispatchAvailable(false)
        for index in 1...8 { #expect(outcomes[index]?.count == 1 && outcomes[index]?.allSatisfy(failed) == true) }
        #expect(outcomes[0] == nil && activity.ended == 8 && executed == 1)
        hold.open()
        try await activity.signal.until { outcomes[0]?.count == 1 }
        #expect(outcomes.values.allSatisfy { $0.count == 1 } && activity.ended == 9 && executed == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func coalescingReportsOnlyTheDiscardedSelection() async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation, hold = EditQueueLatch()
        defer { hold.open(); navigation.setDispatchAvailable(false) }
        var started = false, first = [NativeSidebarNavigation.Outcome](), discarded = [NativeSidebarNavigation.Outcome]()
        var latest = [NativeSidebarNavigation.Outcome](), discardedRan = false, latestRan = false
        navigation.submit(selection: false, stage: true, outcome: { first.append($0); activity.signal.changed() }) { _ in
            started = true; activity.signal.changed(); await hold.wait()
        }
        try await activity.signal.until { started }
        navigation.submit(stage: true, outcome: { discarded.append($0); activity.signal.changed() }) { _ in discardedRan = true }
        navigation.submit(stage: true, outcome: { latest.append($0); activity.signal.changed() }) { _ in latestRan = true }
        #expect(discarded.count == 1 && discarded.allSatisfy(failed) && !discardedRan)
        #expect(first.isEmpty && latest.isEmpty && !latestRan)
        hold.open()
        try await activity.signal.until { first.count == 1 && latest.count == 1 }
        #expect(discarded.count == 1 && latestRan && !latest.allSatisfy(failed) && activity.ended == 3)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func skippedConfirmationCompletesWithoutRunningWork(changeEpoch: Bool) async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation, confirmation = EditQueueLatch()
        defer { confirmation.open(); navigation.setDispatchAvailable(false) }
        var entered = false, ran = false, outcomes = [NativeSidebarNavigation.Outcome]()
        navigation.confirmDispatch = {
            entered = true; activity.signal.changed(); await confirmation.wait(); return changeEpoch
        }
        navigation.submit(stage: true, outcome: { outcomes.append($0); activity.signal.changed() }) { _ in ran = true }
        try await activity.signal.until { entered }
        if changeEpoch { navigation.setDispatchAvailable(false) }
        #expect(outcomes.isEmpty && !ran)
        confirmation.open()
        try await activity.signal.until { outcomes.count == 1 }
        #expect(outcomes.allSatisfy(failed) && !ran && activity.ended == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func sharedEditUsesProductionSchedulingUntilItsActualOutcome(fails: Bool) async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation
        let confirmation = EditQueueLatch(), work = EditQueueLatch()
        defer { confirmation.open(); work.open(); navigation.setDispatchAvailable(false) }
        var confirming = false, entered = false, returned = false, outcomeObservedAfterActivity = false
        navigation.stageOwnsWindowDispatch = { true }
        navigation.confirmDispatch = {
            confirming = true; activity.signal.changed(); await confirmation.wait(); return true
        }
        let ticket = IndependentStageGroupEditing.enqueue(navigation: navigation, current: { true }, input: { [1, 2] }) { current in
            #expect(current() && navigation.isDispatching && !navigation.blocksObserverAdmission)
            #expect(Task.currentPriority.rawValue >= TaskPriority.userInitiated.rawValue)
            #expect(activity.begun == 1 && activity.ended == 0)
            entered = true; activity.signal.changed(); await work.wait()
            #expect(current())
            if fails { throw StageSwitchError.ownership }
        }
        let waiting = Task {
            defer { returned = true; outcomeObservedAfterActivity = activity.ended == 1; activity.signal.changed() }
            try await ticket.value()
        }
        defer { waiting.cancel() }
        try await activity.signal.until { confirming }
        #expect(ticket.job != nil && !entered && !returned && !navigation.blocksObserverAdmission)
        confirmation.open()
        try await activity.signal.until { entered }
        #expect(!returned && activity.ended == 0)
        work.open()
        if fails { await #expect(throws: StageSwitchError.ownership) { try await waiting.value } }
        else { try await waiting.value }
        #expect(returned && outcomeObservedAfterActivity && !navigation.isDispatching)
        #expect((navigation.issue != nil) == fails)
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedEditKeepsTheInputStampBeforeWriting() async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation, confirmation = EditQueueLatch()
        defer { confirmation.open(); navigation.setDispatchAvailable(false) }
        var counters: [UInt32] = [1], confirming = false, wrote = false
        navigation.confirmDispatch = {
            confirming = true; activity.signal.changed(); await confirmation.wait(); return true
        }
        let ticket = IndependentStageGroupEditing.enqueue(navigation: navigation, current: { true }, input: { counters }) { current in
            guard current() else { throw StageSwitchError.interrupted }
            wrote = true
        }
        try await activity.signal.until { confirming }
        counters = [2]
        confirmation.open()
        await #expect(throws: StageSwitchError.interrupted) { try await ticket.value() }
        #expect(!wrote && activity.ended == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellingAnEditRevokesOnlyItsTicketAndDoesNotClaimRecoveryFinished(queued: Bool) async throws {
        let activity = EditQueueActivity(), navigation = activity.navigation, work = EditQueueLatch()
        defer { work.open(); navigation.setDispatchAvailable(false) }
        var otherEntered = false, otherCompleted = false, editEntered = false, wrote = false
        if queued {
            navigation.submit(selection: false, stage: true) { _ in
                otherEntered = true; activity.signal.changed(); await work.wait(); otherCompleted = true
            }
            try await activity.signal.until { otherEntered }
        }
        let ticket = IndependentStageGroupEditing.enqueue(navigation: navigation, current: { true }, input: { [7] }) { current in
            guard current() else { throw StageSwitchError.interrupted }
            editEntered = true; activity.signal.changed(); await work.wait()
            guard current() else { throw StageSwitchError.interrupted }
            wrote = true
        }
        let waiting = Task { try await ticket.value() }
        defer { waiting.cancel() }
        if !queued { try await activity.signal.until { editEntered } }
        let generation = navigation.generation, epoch = navigation.ownershipEpoch
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(ticket.isCancelled && !wrote && navigation.isDispatching && activity.ended == 0)
        #expect(navigation.generation == generation && navigation.ownershipEpoch == epoch && navigation.dispatchAvailable)
        // Cancelling the waiter is not completion of an already-running job or its recovery.
        work.open()
        try await activity.signal.until { activity.ended == (queued ? 2 : 1) }
        #expect(!wrote && (!queued || otherCompleted) && (!queued || !editEntered))
        var nextRan = false, nextOutcomes = [NativeSidebarNavigation.Outcome]()
        navigation.submit(stage: true, outcome: { nextOutcomes.append($0); activity.signal.changed() }) { _ in nextRan = true }
        try await activity.signal.until { nextOutcomes.count == 1 }
        #expect(nextRan && !nextOutcomes.allSatisfy(failed))
        await #expect(throws: CancellationError.self) { try await ticket.value() }
    }
}
