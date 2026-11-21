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
        panels.setMissionControl(.ordinary) // A late AX read while Stage owns the display.
        panels.setSuspended(true)
        panels.setSystemManagesWindows(false)
        #expect(!lane.dispatchAvailable)
        panels.setSuspended(false)
        #expect(!lane.dispatchAvailable)
        panels.setMissionControl(.ordinary)
        #expect(lane.dispatchAvailable && panels.windowDispatchEligible)
        #expect(transitions == [false, false, false, false, false, false, true])
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
