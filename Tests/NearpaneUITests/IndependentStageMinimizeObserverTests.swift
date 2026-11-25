import Testing
@testable import NearpaneUI

struct IndependentStageMinimizeObserverTests {
    private let window = DesktopWindowKey(pid: 42, birth: 17, number: 100)
    private let sibling = DesktopWindowKey(pid: 42, birth: 17, number: 101)

    @Test func preexistingMinimizedWindowsNeverBecomeARequest() {
        var order = IndependentStageMinimizeOrder()
        #expect(!order.observe(window, event: .snapshot, minimized: true, onscreen: false))
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
    }

    @Test func aYellowButtonEventActsOnlyOnThePreviouslyVisibleExactWindow() {
        var order = IndependentStageMinimizeOrder()
        #expect(!order.observe(window, event: .snapshot, minimized: false, onscreen: true))
        #expect(!order.observe(sibling, event: .miniaturized, minimized: true, onscreen: false))
        #expect(order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
    }

    @Test func aCatalogReadCannotConsumeThePendingNativeEvent() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        #expect(!order.observe(window, event: .snapshot, minimized: true, onscreen: false))
        #expect(order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
    }

    @Test func clearingMinimizationInHiddenSpaceDoesNotRearmTheWindow() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        #expect(order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
        #expect(!order.observe(window, event: .deminiaturized, minimized: false, onscreen: false))
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        #expect(order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
    }

    @Test func delayedMiniNoticeAfterRestoreCannotHideAVisibleWindow() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        #expect(!order.observe(window, event: .miniaturized, minimized: false, onscreen: true))
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: true))
    }

    @Test func closedOrReplacedIdentityLosesItsPriorObservation() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        order.remove(window)
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
        let replacement = DesktopWindowKey(pid: window.pid, birth: window.birth + 1, number: window.number)
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        order.retain([replacement])
        #expect(!order.observe(window, event: .miniaturized, minimized: true, onscreen: false))
        #expect(!order.observe(replacement, event: .miniaturized, minimized: true, onscreen: false))
    }
}
