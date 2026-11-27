import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct StageHostIdleRefreshSchedulingTests {
    @Test func idleVerificationCannotEnterSelectionPreparationOrCommitOrItsQueuedSuccessor() async {
        let lane = NativeSidebarNavigation()
        var preparation: CheckedContinuation<Void, Never>?
        var commit: CheckedContinuation<Void, Never>?
        var successor: CheckedContinuation<Void, Never>?
        var reads = [String]()
        lane.submit(stage: true) { _ in
            await withCheckedContinuation { preparation = $0 }
            await withCheckedContinuation { commit = $0 }
            // The engine can be idle again while the enclosing selection is
            // finishing. Queued input must still own the complete action lane.
            lane.whenIdle { reads.append("between choices") }
        }
        // submit owns the lane before the selection task gets its first turn.
        lane.whenIdle { reads.append("before preparation") }
        while preparation == nil { await Task.yield() }
        lane.whenIdle { reads.append("during fresh preflight") }
        #expect(reads.isEmpty)
        preparation?.resume()
        while commit == nil { await Task.yield() }
        lane.whenIdle { reads.append("during final commit") }
        lane.submit(stage: true) { _ in
            await withCheckedContinuation { successor = $0 }
        }
        commit?.resume()
        while successor == nil { await Task.yield() }
        lane.whenIdle { reads.append("during successor") }
        #expect(reads.isEmpty && lane.isDispatching)
        successor?.resume()
        while lane.isDispatching { await Task.yield() }
        lane.whenIdle { reads.append("settled idle verification") }
        #expect(reads == ["settled idle verification"])
    }

    @Test func aReadStartedWhileIdleStillFinishesBeforeSelectionFreshProof() async throws {
        let lane = NativeSidebarNavigation()
        var finishRead: CheckedContinuation<Void, Never>?
        var finishSelection: CheckedContinuation<Void, Never>?
        var existingRead: Task<Void, Never>?
        var events = [String]()
        lane.whenIdle {
            existingRead = Task {
                await withCheckedContinuation { finishRead = $0 }
                events.append("prior read completed")
            }
        }
        let read = try #require(existingRead)
        while finishRead == nil { await Task.yield() }
        lane.submit(stage: true) { _ in
            // chooseHeld and groupChoice drain the previously started task;
            // the admission gate does not cancel or bypass this observation.
            await read.value
            events.append("selection fresh proof")
            await withCheckedContinuation { finishSelection = $0 }
        }
        lane.whenIdle { events.append("racing second idle read") }
        #expect(events.isEmpty && !read.isCancelled)
        finishRead?.resume()
        while finishSelection == nil { await Task.yield() }
        lane.whenIdle { events.append("racing third idle read") }
        #expect(events == ["prior read completed", "selection fresh proof"])
        finishSelection?.resume()
        while lane.isDispatching { await Task.yield() }
        lane.whenIdle { events.append("next idle read") }
        #expect(events == ["prior read completed", "selection fresh proof", "next idle read"])
    }
}
