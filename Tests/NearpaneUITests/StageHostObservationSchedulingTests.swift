import Foundation
import Dispatch
import NearpaneCore
import os
import Testing
@testable import NearpaneUI

@MainActor struct StageHostObservationSchedulingTests {
    @Test func aSlowWindowNumberHintDoesNotBlockTheInputActor() async throws {
        let fixture = StageHostGroupProjectionTests()
        let result = OSAllocatedUnfairLock(initialState: (finished: false, mainThread: false, responsive: false))
        let (completions, completed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let feed = CurrentDesktopWindows(read: { request in
            await fixture.snapshot([], request: request)
        }, sessionAvailable: { true }, fingerprint: {
            let progress = DispatchSemaphore(value: 0)
            Task { @MainActor in progress.signal() }
            let responsive = progress.wait(timeout: .now() + 2) == .success
            result.withLock { $0 = (true, Thread.isMainThread, responsive) }
            completed.yield(())
            return 1
        })
        feed.observe(true)
        defer { feed.observe(false); completed.finish() }
        var completion = completions.makeAsyncIterator()
        _ = try #require(await completion.next())
        let observed = result.withLock { $0 }
        #expect(observed.finished && !observed.mainThread && observed.responsive)
        #expect(!feed.stageEngine.holdsDispatch)
    }

    @Test func aStoppedDetectorCannotPublishItsDelayedHint() async throws {
        let fixture = StageHostGroupProjectionTests()
        let state = OSAllocatedUnfairLock(initialState: (started: false, finished: false, reads: 0))
        let release = DispatchSemaphore(value: 0)
        let (starts, started) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (completions, completed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (samples, sampled) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let feed = CurrentDesktopWindows(read: { request in
            state.withLock { $0.reads += 1 }
            return await fixture.snapshot([], request: request)
        }, sessionAvailable: { true }, fingerprint: {
            state.withLock { $0.started = true }
            started.yield(())
            release.wait()
            state.withLock { $0.finished = true }
            completed.yield(())
            return 7
        })
        feed.didSample = { sampled.yield(()) }
        feed.observe(true)
        defer {
            release.signal(); feed.observe(false)
            started.finish(); completed.finish(); sampled.finish()
        }
        var start = starts.makeAsyncIterator(), sample = samples.makeAsyncIterator()
        _ = try #require(await start.next())
        _ = try #require(await sample.next())
        // The authoritative reader runs even while the advisory hint is blocked.
        try #require(feed.snapshot != nil && feed.revision > 0)
        try #require(state.withLock { $0.started && !$0.finished })
        let revision = feed.revision, reads = state.withLock { $0.reads }
        feed.observe(false)
        release.signal()
        var completion = completions.makeAsyncIterator()
        _ = try #require(await completion.next())
        await Task.yield()
        #expect(state.withLock { $0.finished && $0.reads == reads })
        #expect(feed.snapshot == nil && feed.revision == revision && !feed.stageEngine.holdsDispatch)
    }
}
