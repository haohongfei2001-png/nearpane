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
        let feed = CurrentDesktopWindows(read: { request in
            await fixture.snapshot([], request: request)
        }, sessionAvailable: { true }, fingerprint: {
            let progress = DispatchSemaphore(value: 0)
            Task { @MainActor in progress.signal() }
            let responsive = progress.wait(timeout: .now() + 2) == .success
            result.withLock { $0 = (true, Thread.isMainThread, responsive) }
            return 1
        })
        feed.observe(true)
        defer { feed.observe(false) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !result.withLock({ $0.finished }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let observed = result.withLock { $0 }
        #expect(observed.finished && !observed.mainThread && observed.responsive)
        #expect(!feed.stageEngine.holdsDispatch)
    }

    @Test func aStoppedDetectorCannotPublishItsDelayedHint() async throws {
        let fixture = StageHostGroupProjectionTests()
        let state = OSAllocatedUnfairLock(initialState: (started: false, finished: false, reads: 0))
        let release = DispatchSemaphore(value: 0)
        let feed = CurrentDesktopWindows(read: { request in
            state.withLock { $0.reads += 1 }
            return await fixture.snapshot([], request: request)
        }, sessionAvailable: { true }, fingerprint: {
            state.withLock { $0.started = true }
            _ = release.wait(timeout: .now() + 2)
            state.withLock { $0.finished = true }
            return 7
        })
        feed.observe(true)
        defer { release.signal(); feed.observe(false) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !state.withLock({ $0.started }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(state.withLock { $0.started && !$0.finished })
        feed.observe(false)
        release.signal()
        while !state.withLock({ $0.finished }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        #expect(state.withLock { $0.finished && $0.reads == 0 })
        #expect(feed.snapshot == nil && feed.revision == 0 && !feed.stageEngine.holdsDispatch)
    }
}
