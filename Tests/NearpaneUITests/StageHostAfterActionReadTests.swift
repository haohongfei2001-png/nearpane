import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

private struct AfterActionBoundary: Sendable {
    let date: Date
    let uptime: TimeInterval
}

private struct PendingAfterActionRead: Sendable {
    let request: DesktopReadRequest
    let reply: AsyncStream<DesktopSnapshot>.Continuation
}

private enum AfterActionReadEvent: Sendable {
    case requested(PendingAfterActionRead)
    case entered(AfterActionBoundary)
    case returned(DesktopSnapshot?)
}

@MainActor private final class AfterActionReader {
    let events = AsyncStream<AfterActionReadEvent>.makeStream()
    var sessionAvailable = true
    private var replies = [AsyncStream<DesktopSnapshot>.Continuation]()
    private var closed = false

    func read(_ request: DesktopReadRequest) async throws -> DesktopSnapshot {
        guard !closed else { throw ReaderFailure.unavailable }
        let response = AsyncStream<DesktopSnapshot>.makeStream()
        replies.append(response.continuation)
        events.continuation.yield(.requested(.init(request: request, reply: response.continuation)))
        var result = response.stream.makeAsyncIterator()
        guard let sample = await result.next() else { throw ReaderFailure.unavailable }
        return sample
    }

    func action(_ feed: CurrentDesktopWindows) -> Task<DesktopSnapshot?, Never> {
        Task {
            let result = await feed.readAfterAction()
            events.continuation.yield(.returned(result))
            return result
        }
    }

    func close() {
        closed = true
        for reply in replies { reply.finish() }
        events.continuation.finish()
    }
}

fileprivate enum PendingReadCase: String, CaseIterable, Sendable {
    case afterEntry, beforeEntry, wallClockOnly, uptimeOnly, equalWallClock, equalUptime
    case otherSession, wrongRevision, incompleteCatalog, cappedInventory, backwardsNativeTime, futureWallClock
    case epochChanged, sessionUnavailable, observationStopped, actionCancelled

    var losesAuthority: Bool {
        [.epochChanged, .sessionUnavailable, .observationStopped, .actionCancelled].contains(self)
    }
}

@MainActor struct StageHostAfterActionReadTests {
    @Test(.timeLimit(.minutes(1)), arguments: PendingReadCase.allCases)
    fileprivate func onlyAnActualSampleAfterBothEntryClocksCanReplaceTheFreshRead(mode: PendingReadCase) async throws {
        let reader = AfterActionReader(), fixture = StageHostGroupProjectionTests()
        let feed = CurrentDesktopWindows(read: { try await reader.read($0) },
            sessionAvailable: { reader.sessionAvailable }, fingerprint: { nil })
        feed.didBeginAfterActionRead = { date, uptime in
            reader.events.continuation.yield(.entered(.init(date: date, uptime: uptime)))
        }
        var actions = [Task<DesktopSnapshot?, Never>]()
        defer {
            for action in actions { action.cancel() }
            feed.observeManagement(false)
            reader.close()
        }
        var events = reader.events.stream.makeAsyncIterator()
        feed.observeManagement(true)
        guard case .requested(let pending) = try #require(await events.next()) else {
            Issue.record("The observation loop must first create a real pending read."); return
        }
        // The old request is already executing, but its native sample is held.
        // For the negative case, take that sample before starting the action.
        let earlier = fixture.snapshot([fixture.window(17)], request: pending.request)
        let action = reader.action(feed)
        actions.append(action)
        guard case .entered(let boundary) = try #require(await events.next()) else {
            Issue.record("The action must capture both entry clocks before releasing the pending reader."); return
        }
        var sample = mode == .beforeEntry ? earlier : fixture.snapshot([fixture.window(17)], request: pending.request)
        let native = try #require(sample.native)
        var began = native.beganUptime, ended = native.endedUptime
        var capped = false, complete = true
        switch mode {
        case .afterEntry, .beforeEntry: break
        case .wallClockOnly: began = boundary.uptime - 0.001
        case .uptimeOnly: sample.sampledFrom = boundary.date.addingTimeInterval(-0.001)
        case .equalWallClock: sample.sampledFrom = boundary.date
        case .equalUptime: began = boundary.uptime
        case .otherSession: sample.sessionID = UUID()
        case .wrongRevision: sample.revision += 100
        case .incompleteCatalog: complete = false
        case .cappedInventory: capped = true
        case .backwardsNativeTime: ended = began - 0.001
        case .futureWallClock:
            sample.sampledFrom = Date().addingTimeInterval(60)
            sample.sampledTo = sample.sampledFrom
        case .epochChanged: feed.invalidate(reason: "test-action-epoch")
        case .sessionUnavailable: reader.sessionAvailable = false
        case .observationStopped: feed.observeManagement(false)
        case .actionCancelled: action.cancel()
        }
        sample.native = .init(population: native.population, accessibility: native.accessibility, spaces: native.spaces,
            rows: native.rows, windowLimitReached: capped, beganUptime: began, endedUptime: ended,
            stageManagerEnabled: native.stageManagerEnabled, catalogComplete: complete)
        pending.reply.yield(sample)
        pending.reply.finish()

        // Complete any genuinely new request, rather than hanging on a broken
        // reuse implementation. An automatic observation may also request a
        // read; the returned revision, not a wall-clock-based call count, proves
        // which actual sample satisfied the action.
        var result: DesktopSnapshot?, returned = false
        while let event = await events.next() {
            switch event {
            case .requested(let next):
                next.reply.yield(fixture.snapshot([fixture.window(17)], request: next.request))
                next.reply.finish()
            case .returned(let value): result = value; returned = true
            case .entered: Issue.record("Unexpected concurrent action.")
            }
            if returned { break }
        }
        #expect(returned)
        _ = await action.value
        if mode.losesAuthority {
            #expect(result == nil)
            return
        }
        let first = try #require(result)
        if mode != .afterEntry {
            #expect(first.revision > pending.request.revision)
            #expect(first.sessionID == pending.request.session)
            #expect(first.native?.catalogComplete == true && first.native?.windowLimitReached == false)
            return
        }
        #expect(first == sample)
        #expect(first.revision == pending.request.revision)
        let firstNative = try #require(first.native)
        #expect(first.sampledFrom > boundary.date && firstNative.beganUptime > boundary.uptime)

        // A second call is a new read boundary (also the boundary used after a
        // write). It cannot reuse the first result. Hold any already-created
        // automatic request until this boundary, then actually sample anew.
        let secondAction = reader.action(feed)
        actions.append(secondAction)
        var waiting = [PendingAfterActionRead](), secondBoundary: AfterActionBoundary?
        while let event = await events.next() {
            switch event {
            case .requested(let next): waiting.append(next)
            case .entered(let value): secondBoundary = value
            case .returned: Issue.record("A second action returned without capturing its boundary.")
            }
            if secondBoundary != nil { break }
        }
        let nextBoundary = try #require(secondBoundary)
        func answer(_ next: PendingAfterActionRead) {
            next.reply.yield(fixture.snapshot([fixture.window(17), fixture.window(18, rank: 1)], request: next.request))
            next.reply.finish()
        }
        for next in waiting { answer(next) }
        var secondResult: DesktopSnapshot?, secondReturned = false
        while let event = await events.next() {
            switch event {
            case .requested(let next): answer(next)
            case .returned(let value): secondResult = value; secondReturned = true
            case .entered: Issue.record("Unexpected third action.")
            }
            if secondReturned { break }
        }
        #expect(secondReturned)
        _ = await secondAction.value
        let second = try #require(secondResult), secondNative = try #require(second.native)
        #expect(second.revision > first.revision && second.sessionID == first.sessionID)
        #expect(second.sampledFrom > nextBoundary.date && secondNative.beganUptime > nextBoundary.uptime)
        #expect(second.windows.map { $0.metadata?.number } == [17, 18])
        #expect(firstNative.endedUptime < secondNative.beganUptime)
    }
}
