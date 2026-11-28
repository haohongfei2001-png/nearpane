import Foundation
import Testing
@testable import NearpaneUI

@MainActor
struct CurrentCardFocusPreparationTests {
    @Test func aPreparedWorkerIsConsumedOnceAndHasNoWindowOrPermissionToReuse() async throws {
        let standby = FocusWorkerStandby<Int>()
        var launches = 0
        func launch() -> Task<Int,Error> {
            launches += 1
            let worker = launches
            return Task { worker }
        }
        #expect(!standby.prepare(launch))
        #expect(standby.prepare(launch))
        #expect(try await standby.take(launch) == 1)
        #expect(try await standby.take(launch) == 2)
        #expect(launches == 2)
    }

    @Test func expiredAndDiscardedWorkersCannotBeClaimedByLaterInput() async throws {
        var clock = ContinuousClock.now, launches = 0
        let standby = FocusWorkerStandby<Int>(lifetime:.seconds(5), now:{clock})
        func launch() -> Task<Int,Error> {
            launches += 1
            let worker = launches
            return Task { worker }
        }
        standby.prepare(launch)
        clock = clock.advanced(by:.seconds(5))
        #expect(try await standby.take(launch) == 2)
        standby.prepare(launch)
        standby.discard()
        #expect(try await standby.take(launch) == 4)
    }

    @Test func failedReadinessCannotAuthorizeASecondClick() async throws {
        let standby = FocusWorkerStandby<Int>()
        standby.prepare { Task { throw CancellationError() } }
        await #expect(throws: CancellationError.self) {
            _ = try await standby.take { Task { 7 } }
        }
        #expect(try await standby.take { Task { 8 } } == 8)
    }

    @Test func workerPreferenceDoesNotFollowPIDReuseAnotherAppOrAnotherHostSession() {
        let app = AdmissionApplication(pid:21, launch:100, bundle:"test.focus", name:"")
        let start = ContinuousClock.now, session = UUID()
        let hint = RecentWorkerFocus(application:app,session:session,completed:start)
        #expect(hint.prefers(app,session:session,now:start.advanced(by:.seconds(1))))
        #expect(!hint.prefers(.init(pid:21,launch:101,bundle:"test.focus",name:""),session:session,now:start))
        #expect(!hint.prefers(.init(pid:21,launch:100,bundle:"test.other",name:""),session:session,now:start))
        #expect(!hint.prefers(app,session:UUID(),now:start))
        #expect(!hint.prefers(app,session:session,now:start.advanced(by:.seconds(12))))
    }

    @Test func concurrentFreshScopeFinishingAfterBindingRequiresOnlyOneRead() async throws {
        var count = 0
        let bound = ContinuousClock.now
        let scope = CurrentCardScopeRead { count += 1; return true }
        try await scope.confirm(boundAt:bound, current:{true})
        #expect(count == 1)
    }

    @Test func scopeThatFinishesBeforeBindingCannotAuthorizeActionAlone() async throws {
        var count = 0
        let beforeRead = ContinuousClock.now
        let scope = CurrentCardScopeRead { count += 1; return count == 1 }
        // Join the actual read before establishing the binding boundary. A busy
        // executor can delay the first task indefinitely without changing this order.
        try await scope.confirm(boundAt: beforeRead, current: { true })
        #expect(count == 1)
        let afterRead = ContinuousClock.now.advanced(by: .nanoseconds(1))
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await scope.confirm(boundAt: afterRead, current: { true })
        }
        #expect(count == 2)
    }

    @Test func aChangedRosterIsNeverRecapturedAsPermissionAndNewInputStops() async {
        var count = 0, current = true
        let lost = CurrentCardScopeRead { count += 1; return false }
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await lost.confirm(boundAt:.now.advanced(by:.seconds(1)), current:{true})
        }
        #expect(count == 1)
        let superseded = CurrentCardScopeRead { current = false; return true }
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await superseded.confirm(boundAt:.now, current:{current})
        }
    }
}
