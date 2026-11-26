import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct SystemWindowDispatchTests {
    @Test func onlyDirectOverviewOrOrdinaryDockListCanDecideOwnership() {
        #expect(MissionControlVisibility.classify([.dockList]) == .ordinary)
        #expect(MissionControlVisibility.classify([.other, .overview, .dockList]) == .exposed)
        #expect(MissionControlVisibility.classify([.overview]) == .exposed)
        #expect(MissionControlVisibility.classify([]) == .unknown)
        #expect(MissionControlVisibility.classify([.other]) == .unknown)
        #expect(MissionControlVisibility.classify([.overview, .overview, .dockList]) == .unknown)
    }

    @Test func overlappingSystemOwnershipAndSessionTransitionsRefreshWithoutPersistingARequest() {
        let host = HostSession(store: MemoryConfigurationStore()), lane = NativeSidebarNavigation()
        let primary = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: primary, navigation: lane, present: { _ in })
        defer { panels.stop(); primary.close() }
        var transitions = [Bool]()
        panels.refresh = { transitions.append(panels.windowDispatchEligible) }
        #expect(panels.windowDispatchEligible)
        panels.setMissionControl(.unknown)
        panels.request("held")
        #expect(!lane.dispatchAvailable && panels.missionControlDispatchState == "unknown")
        panels.setMissionControl(.exposed)
        panels.setSystemManagesWindows(true)
        panels.setMissionControl(.exposed, evidence: "signedDockMCIdentifier")
        #expect(!lane.dispatchAvailable && panels.missionControlDispatchState == "exposed")
        panels.setMissionControl(.ordinary)
        #expect(!lane.dispatchAvailable && panels.missionControlDispatchState == "ordinary")
        panels.setSuspended(true)
        panels.setSystemManagesWindows(false)
        #expect(!lane.dispatchAvailable)
        panels.setSuspended(false)
        #expect(!lane.dispatchAvailable)
        panels.setMissionControl(.ordinary)
        #expect(lane.dispatchAvailable && panels.windowDispatchEligible)
        #expect(transitions.first == false && transitions.last == true)
        #expect(transitions.dropLast().allSatisfy { !$0 })
        #expect(host.configuration.displays["held"] == nil)
        panels.stop()
        #expect(!panels.windowDispatchEligible && !lane.dispatchAvailable)
        panels.refresh = nil
    }

    @Test func freshPreflightMustBelongToTheSameOwnershipPeriodAsTheClick() async {
        let lane = NativeSidebarNavigation()
        var resume: CheckedContinuation<Bool, Never>?
        lane.confirmDispatch = { await withCheckedContinuation { resume = $0 } }
        var writes = [String]()
        lane.submit { _ in writes.append("old") }
        while resume == nil { await Task.yield() }
        lane.setDispatchAvailable(false)
        lane.setDispatchAvailable(true)
        lane.confirmDispatch = { true }
        await withCheckedContinuation { done in
            lane.submit { _ in writes.append("fresh"); done.resume() }
            resume?.resume(returning: true) // Positive result from before the system took ownership.
        }
        #expect(writes == ["fresh"])
    }

    @Test func preparedHelperStepRereadsSystemOwnershipAndRechecksIntentAfterThatRead() async {
        let id = UUID()
        let refused = NativeSelectionPermit(confirmDispatch: { false })
        #expect(await !refused.gesturePermission(for: id, after: 0).proceed)
        var stillCurrent = true
        let superseded = NativeSelectionPermit(current: { stillCurrent }, confirmDispatch: {
            stillCurrent = false
            return true
        })
        #expect(await !superseded.gesturePermission(for: id, after: 0).proceed)
        let healthy = NativeSelectionPermit(confirmDispatch: { true })
        #expect(await healthy.gesturePermission(for: id, after: 0).proceed)
    }

    @Test func aHandoffCancelsAWaitingSwitchMoveAndOldFocusEvenAfterReentry() async {
        let lane = NativeSidebarNavigation()
        var continuation: CheckedContinuation<Void, Never>?
        var writes = [String]()
        lane.submit { token in
            await withCheckedContinuation { continuation = $0 }
            if lane.isCurrent(token) { writes.append("old focus") }
        }
        while continuation == nil { await Task.yield() }
        let oldEpoch = lane.ownershipEpoch
        let oldMove = NativeSelectionPermit { lane.dispatchAvailable && lane.ownershipEpoch == oldEpoch }
        lane.submit(selection: false) { _ in writes.append("old move") }
        lane.submit { _ in writes.append("old switch") }
        lane.setDispatchAvailable(false)
        lane.submit { _ in writes.append("while system owns dispatch") }
        #expect(!oldMove.permission(for: UUID(), after: 0).proceed)
        lane.setDispatchAvailable(true)
        #expect(!oldMove.permission(for: UUID(), after: 0).proceed)
        await withCheckedContinuation { done in
            lane.submit { token in
                if lane.isCurrent(token) { writes.append("new gesture") }
                done.resume()
            }
            continuation?.resume()
        }
        #expect(writes == ["new gesture"])
    }
}

@MainActor struct IndependentStageDockFreshnessTests {
    @Test func queuedDockReadUsesActualObservationAgeWithoutExtendingFreshness() {
        let host = HostSession(store: MemoryConfigurationStore()), lane = NativeSidebarNavigation()
        let primary = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: primary, navigation: lane, present: { _ in })
        defer { panels.stop(); primary.close() }
        let epoch = lane.ownershipEpoch
        // Actual 2f3eddda read/rejection-trace timestamps; an earlier request does not age
        // the observation which the reader has only just made.
        let sample: MissionControlVisibilityReader.Reading =
            (.ordinary, "signedDockAXListWithoutMC", 1484.9186721666667, 1484.9199426250002)
        panels.acceptMissionControl(sample, requestedAt: 1484, now: 1485.4037624166667)
        #expect(panels.windowDispatchEligible && lane.ownershipEpoch == epoch)
        #expect(panels.missionControlReadInterval?.start == sample.startUptime)
        // A recent request cannot renew genuinely old observations.
        panels.acceptMissionControl(sample, requestedAt: 1485.699, now: 1485.7)
        #expect(!panels.windowDispatchEligible && lane.ownershipEpoch != epoch)
        #expect(panels.missionControlDispatchEvidence == "sampleExpired")
        panels.acceptMissionControl((.ordinary, "signedDockAXListWithoutMC", 1486, 1486.01), requestedAt: 1485, now: 1486.1)
        #expect(panels.windowDispatchEligible)
        panels.acceptMissionControl((.exposed, "signedDockMCIdentifier", 1487, 1487.01), requestedAt: 1486, now: 1487.1)
        #expect(!panels.windowDispatchEligible && panels.missionControlDispatchState == "exposed")
    }

    @Test func dockFreshnessBoundsTheWholePhysicalReadAndDeliveryInterval() {
        #expect(DisplayPanels.missionControlReadIsFresh(start: 10, end: 10.2, now: 10.75))
        #expect(!DisplayPanels.missionControlReadIsFresh(start: 10, end: 10.6, now: 11.2))
        #expect(!DisplayPanels.missionControlReadIsFresh(start: 10, end: 9, now: 10))
        #expect(!DisplayPanels.missionControlReadIsFresh(start: 10, end: 10.2, now: 10.1))
        #expect(!DisplayPanels.missionControlReadIsFresh(start: .nan, end: 10, now: 10))
        #expect(!DisplayPanels.missionControlReadIsFresh(start: 10, end: .infinity, now: .infinity))
    }
}
