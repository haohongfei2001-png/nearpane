import CNearpaneWindowEngine
import Testing
@testable import NearpaneUI

struct AppleStageMinimizeObserverTests {
    @Test func registersOnlyCurrentUnambiguousOrdinaryWindowIdentities() {
        func key(_ pid: Int32, _ birth: UInt64, _ number: UInt32) -> DesktopWindowKey {
            DesktopWindowKey(pid: pid, birth: birth, number: number)
        }
        let first = key(15, 5, 311), sibling = key(15, 5, 312)
        let targets = [first, sibling, first, key(11, 3, 42), key(11, 4, 42), key(11, 3, 42),
                       key(17, 0, 92), key(17, 1, 0), key(0, 20, 2), key(18, 4, 53)]
        #expect(AppleStageMinimizeObserver.admitted(targets, ownPID: 18) == [15: [first, sibling]])
    }

    @Test func boundsProcessAndWindowRegistrationsInCallerOrder() {
        let processes = (2...51).map { DesktopWindowKey(pid: Int32($0), birth: 42, number: UInt32($0)) }
        let windows = (1...200).map { DesktopWindowKey(pid: 7, birth: 90, number: UInt32($0)) }
        #expect(Set(AppleStageMinimizeObserver.admitted(processes, ownPID: 100).keys) == Set(processes.prefix(24).map(\.pid)))
        #expect(AppleStageMinimizeObserver.admitted(windows, ownPID: 100)[7] == Set(windows.prefix(128)))
    }

    @Test func aNewerNoticeDiscardsTheOldReadAndNeverAdvancesItsSibling() {
        let w = DesktopWindowKey(pid: 10, birth: 22, number: 1), sibling = DesktopWindowKey(pid: 10, birth: 22, number: 2)
        var order = AppleMinimizeReadOrder()
        #expect(order.begin(w, event: 1) == 0)
        #expect(order.begin(w, event: 1) == nil)
        #expect(order.begin(w, event: 2) == nil)
        #expect(order.begin(sibling, event: 1) == 0)
        #expect(order.finish(w, confirmed: 2) == .readLatest(2))
        #expect(order.begin(w, event: 2) == 0)
        #expect(order.finish(sibling, confirmed: 2) == .refresh)
        #expect(order.finish(w, confirmed: nil) == .idle)
        #expect(order.begin(sibling, event: 2) == 2)
        order.remove(sibling)
        #expect(order.finish(sibling, confirmed: 1) == .idle)
        #expect(order.begin(sibling, event: 1) == 0)
    }

    @Test func linkedABIRequiresLivePerWindowReadbackAndPassesOtherEvents() {
        let window = NPAppleMinimizeWindow(pid: 102, window: 415, birth: 550)
        let sibling = NPAppleMinimizeWindow(pid: 102, window: 416, birth: 550)
        func change(_ event: Int, _ current: NPAppleMinimizeWindow, _ before: Int, _ now: Int) -> Int {
            Int(np_apple_native_minimize_change_v1(UInt32(event), window, current, UInt32(before), UInt32(now), UInt32(NP_APPLE_MINIMIZE_OBSERVING)))
        }
        #expect(change(NP_APPLE_AX_MINIATURIZED, window, NP_APPLE_WINDOW_NORMAL, NP_APPLE_WINDOW_MINIMIZED) == NP_APPLE_MINIMIZE_REFRESH_MINIMIZED)
        #expect(change(NP_APPLE_AX_DEMINIATURIZED, window, NP_APPLE_WINDOW_MINIMIZED, NP_APPLE_WINDOW_NORMAL) == NP_APPLE_MINIMIZE_REFRESH_RESTORED)
        #expect(change(NP_APPLE_AX_MINIATURIZED, sibling, NP_APPLE_WINDOW_NORMAL, NP_APPLE_WINDOW_MINIMIZED) == NP_APPLE_MINIMIZE_NO_CHANGE)
        #expect(change(NP_APPLE_AX_MINIATURIZED, window, NP_APPLE_WINDOW_NORMAL, NP_APPLE_WINDOW_NORMAL) == NP_APPLE_MINIMIZE_NO_CHANGE)
        #expect(change(99, window, NP_APPLE_WINDOW_NORMAL, NP_APPLE_WINDOW_MINIMIZED) == NP_APPLE_MINIMIZE_NO_CHANGE)
    }
}
