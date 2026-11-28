import Foundation
@testable import NearpaneUI
import Testing

@MainActor struct StageHostOwnershipSchedulingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func utilityParentRunsOwnershipReadAtTheRequestedPriority(duringUserAction: Bool) async throws {
        let submitted = AsyncStream<TaskPriority>.makeStream()
        let started = AsyncStream<TaskPriority>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<TaskPriority>.makeStream()
        defer {
            submitted.continuation.finish(); started.continuation.finish()
            resume.continuation.finish(); finished.continuation.finish()
        }
        let submitter = Task.detached(priority: .utility) {
            await MainActor.run {
                let parentPriority = Task.currentPriority
                DisplayPanels.startOwnershipRead(duringUserAction: duringUserAction) {
                    started.continuation.yield(Task.currentPriority)
                    var waiting = resume.stream.makeAsyncIterator()
                    _ = await waiting.next()
                    finished.continuation.yield(Task.currentPriority)
                }
                submitted.continuation.yield(parentPriority)
            }
        }
        // Waiting on submitter.value or the poll Task here would promote that
        // task and hide the idle priority inheritance we need to verify.
        var origin = submitted.stream.makeAsyncIterator()
        var entry = started.stream.makeAsyncIterator()
        var completion = finished.stream.makeAsyncIterator()
        let parentPriority = try #require(await origin.next())
        let enteredPriority = try #require(await entry.next())
        #expect(parentPriority == .utility)
        #expect(enteredPriority == (duringUserAction ? .userInitiated : .utility))
        resume.continuation.yield(())
        let resumedPriority = try #require(await completion.next())
        #expect(resumedPriority == (duringUserAction ? .userInitiated : .utility))
        await submitter.value
    }
}
