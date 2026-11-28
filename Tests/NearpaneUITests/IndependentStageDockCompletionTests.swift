import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class DockCompletionFixture {
    let host = HostSession(store: MemoryConfigurationStore())
    let lane = NativeSidebarNavigation()
    let primary: EdgeWindowController
    let panels: DisplayPanels

    init(reader: MissionControlVisibilityReader = .init(sample: { (.ordinary, "fixtureDock") })) {
        primary = EdgeWindowController(host: host)
        panels = DisplayPanels(host: host, primary: primary, navigation: lane,
                               missionControlReader: reader, present: { _ in })
        panels.setMissionControl(.ordinary, evidence: "initialDock", interval: (10, 10.01))
    }
    func request(at time: TimeInterval = 10.7) throws -> DisplayPanels.MissionControlPoll {
        try #require(panels.beginMissionControlPoll(at: time))
    }
    func close() { panels.stop(); primary.close() }
}

@MainActor @Suite(.serialized) struct IndependentStageDockCompletionTests {
    @Test func aCompletedCurrentPollIsConsumedBeforeTheOldObservationExpires() throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        // Exact ef5 FAST intervals: the native read finished before the timer,
        // but the old actor callback was not applied until after that timer.
        fixture.panels.setMissionControl(.ordinary, evidence: "initialDock",
            interval: (1214.0263022083334, 1214.03013525))
        let epoch = fixture.lane.ownershipEpoch
        let request = try fixture.request(at: 1214.8083624583335)
        request.completion.store((.ordinary, "signedDockAXListWithoutMC", 1214.8958832916667, 1214.8978839583333))
        #expect(fixture.panels.servicePendingMissionControlPoll(now: 1214.98410325))
        #expect(fixture.panels.windowDispatchEligible && fixture.lane.ownershipEpoch == epoch)
        #expect(fixture.panels.missionControlReadInterval?.start == 1214.8958832916667)
        #expect(fixture.panels.missionControlReadInterval?.end == 1214.8978839583333)
        #expect(!fixture.panels.consumeMissionControlPoll(request, now: 1215.072639))
        #expect(!fixture.panels.servicePendingMissionControlPoll(now: 1215.072639))
    }

    @Test(arguments: [MissionControlVisibility.unknown, .exposed])
    func aCompletedUnknownOrExposedReadImmediatelyRevokesDispatch(_ visibility: MissionControlVisibility) throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        let epoch = fixture.lane.ownershipEpoch, request = try fixture.request()
        request.completion.store((visibility, "completed-" + visibility.rawValue, 10.71, 10.72))
        #expect(fixture.panels.servicePendingMissionControlPoll(now: 10.8))
        #expect(!fixture.panels.windowDispatchEligible && !fixture.lane.dispatchAvailable)
        #expect(fixture.lane.ownershipEpoch != epoch)
        #expect(fixture.panels.missionControlDispatchState == visibility.rawValue)
        #expect(fixture.panels.missionControlDispatchEvidence == "completed-" + visibility.rawValue)
        #expect(fixture.panels.missionControlReadInterval?.start == 10.71)
        #expect(!fixture.panels.consumeMissionControlPoll(request, now: 10.81))
    }

    @Test(arguments: ["late", "backwards", "future", "nanBegin", "infEnd", "nonfiniteNow", "exactBudget", "justExpired"])
    func aCompletedPollStillUsesTheWholeOriginalPhysicalClockBudget(_ change: String) throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        var reading: MissionControlVisibilityReader.Reading = (.ordinary, "clock-test", 10.7, 10.71)
        var now: TimeInterval = 10.8
        switch change {
        case "late": reading.startUptime = 10; reading.endUptime = 10.7
        case "backwards": reading.endUptime = 10.6
        case "future": reading.endUptime = 10.9
        case "nanBegin": reading.startUptime = .nan
        case "infEnd": reading.endUptime = .infinity
        case "nonfiniteNow": now = .infinity
        case "exactBudget": reading.startUptime = 10; reading.endUptime = 10.2; now = 10.75
        default: reading.startUptime = 10; reading.endUptime = 10.2; now = 10.75.nextUp
        }
        let request = try fixture.request()
        request.completion.store(reading)
        #expect(fixture.panels.servicePendingMissionControlPoll(now: now))
        #expect(fixture.panels.windowDispatchEligible == (change == "exactBudget"))
        if change != "exactBudget" {
            #expect(fixture.panels.missionControlDispatchState == "unknown")
            #expect(fixture.panels.missionControlDispatchEvidence == "sampleExpired")
        }
        #expect(!fixture.panels.consumeMissionControlPoll(request, now: now))
    }

    @Test(arguments: ["generation", "stop", "suspend", "resume", "beforeAcceptGeneration", "beforeAcceptSuspend"])
    func aCompletedOldPeriodCannotReopenDispatchAfterInvalidation(_ change: String) throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        let request = try fixture.request()
        request.completion.store((.ordinary, "late-old-period", 10.71, 10.72))
        switch change {
        case "generation": fixture.panels.nativeDesktopChanged()
        case "stop": fixture.panels.stop()
        case "suspend": fixture.panels.setSuspended(true)
        case "resume": fixture.panels.setSuspended(true); fixture.panels.setSuspended(false)
        default: break
        }
        var preferenceReads = 0
        #expect(fixture.panels.consumeMissionControlPoll(request, now: 10.8) {
            preferenceReads += 1
            if change == "beforeAcceptGeneration" { fixture.panels.nativeDesktopChanged() }
            if change == "beforeAcceptSuspend" { fixture.panels.setSuspended(true) }
        })
        #expect(preferenceReads == (change.hasPrefix("beforeAccept") ? 1 : 0))
        #expect(!fixture.panels.windowDispatchEligible && !fixture.lane.dispatchAvailable)
        #expect(fixture.panels.missionControlDispatchEvidence != "late-old-period")
        #expect(!fixture.panels.consumeMissionControlPoll(request, now: 10.81))
    }

    @Test func anUnfinishedReadStillExpiresAndItsLaterCompletionCannotReviveThatPeriod() throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        let epoch = fixture.lane.ownershipEpoch, request = try fixture.request()
        #expect(fixture.panels.servicePendingMissionControlPoll(now: 10.8))
        #expect(!fixture.panels.windowDispatchEligible && fixture.lane.ownershipEpoch != epoch)
        #expect(fixture.panels.missionControlDispatchEvidence == "sampleExpired")
        #expect(fixture.panels.beginMissionControlPoll(at: 10.81) == nil)
        request.completion.store((.ordinary, "old-period-finished", 10.81, 10.82))
        #expect(fixture.panels.consumeMissionControlPoll(request, now: 10.83))
        #expect(!fixture.panels.windowDispatchEligible)
        #expect(fixture.panels.missionControlDispatchEvidence == "sampleExpired")
        let next = try fixture.request(at: 10.84)
        #expect(next.id != request.id && next.generation != request.generation)
        next.completion.store((.ordinary, "new-period-read", 10.85, 10.86))
        #expect(fixture.panels.servicePendingMissionControlPoll(now: 10.87))
        #expect(fixture.panels.windowDispatchEligible && fixture.panels.missionControlDispatchEvidence == "new-period-read")
    }

    @Test func aConsumedPollCannotOverwriteItsResultOrClearTheNextRequest() throws {
        let fixture = DockCompletionFixture()
        defer { fixture.close() }
        let first = try fixture.request(at: 10.6)
        first.completion.store((.ordinary, "first-completion", 10.65, 10.66))
        #expect(fixture.panels.servicePendingMissionControlPoll(now: 10.7))
        let next = try fixture.request(at: 10.71)
        #expect(next.generation == first.generation)
        first.completion.store((.exposed, "cannot-replace-consumed", 10.72, 10.73))
        var preferenceReads = 0
        #expect(!fixture.panels.consumeMissionControlPoll(first, now: 10.74) { preferenceReads += 1 })
        #expect(preferenceReads == 0 && fixture.panels.beginMissionControlPoll(at: 10.74) == nil)
        let wrongSlot = DisplayPanels.MissionControlPoll(id: next.id, generation: next.generation,
            requestedAt: next.requestedAt, completion: .init())
        wrongSlot.completion.store((.ordinary, "wrong-slot", 10.74, 10.75))
        #expect(!fixture.panels.consumeMissionControlPoll(wrongSlot, now: 10.76))
        next.completion.store((.unknown, "first-stored-result", 10.74, 10.75))
        next.completion.store((.ordinary, "cannot-overwrite-ready", 10.76, 10.77))
        #expect(fixture.panels.consumeMissionControlPoll(next, now: 10.78) { preferenceReads += 1 })
        #expect(preferenceReads == 1 && !fixture.panels.windowDispatchEligible)
        #expect(fixture.panels.missionControlDispatchEvidence == "first-stored-result")
        #expect(!fixture.panels.consumeMissionControlPoll(next, now: 10.79) { preferenceReads += 1 })
        #expect(preferenceReads == 1 && fixture.panels.beginMissionControlPoll(at: 10.8) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theNativeQueueStoresOneResultWhileActorApplicationIsHeld() async throws {
        let reader = MissionControlVisibilityReader(sample: { (.ordinary, "serial-queue-sample") })
        let fixture = DockCompletionFixture(reader: reader)
        let sampled = AsyncStream<MissionControlVisibilityReader.Reading>.makeStream()
        let apply = AsyncStream<Void>.makeStream()
        defer { apply.continuation.finish(); sampled.continuation.finish(); fixture.close() }
        let old = ProcessInfo.processInfo.systemUptime - 1
        fixture.panels.setMissionControl(.ordinary, evidence: "old-read", interval: (old, old + 0.01))
        let epoch = fixture.lane.ownershipEpoch
        let request = try fixture.request(at: ProcessInfo.processInfo.systemUptime)
        let callback = Task {
            let reading = await reader.read(completion: request.completion)
            sampled.continuation.yield(reading)
            var application = apply.stream.makeAsyncIterator()
            _ = await application.next()
            return fixture.panels.consumeMissionControlPoll(request, now: reading.endUptime + 0.05)
        }
        defer { callback.cancel() }
        var samples = sampled.stream.makeAsyncIterator()
        let reading = try #require(await samples.next())
        #expect(reading.visibility == .ordinary && reading.evidence == "serial-queue-sample")
        #expect(fixture.panels.missionControlReadInterval?.start == old)
        #expect(fixture.panels.servicePendingMissionControlPoll(now: reading.endUptime + 0.05))
        #expect(fixture.panels.windowDispatchEligible && fixture.lane.ownershipEpoch == epoch)
        #expect(fixture.panels.missionControlReadInterval?.start == reading.startUptime)
        apply.continuation.yield(()); apply.continuation.finish()
        #expect(await callback.value == false)
        #expect(request.completion.take() == nil)
    }
}
