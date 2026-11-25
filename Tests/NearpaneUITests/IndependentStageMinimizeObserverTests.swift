import Testing
@testable import NearpaneUI

struct IndependentStageMinimizeObserverTests {
    private let window = DesktopWindowKey(pid: 42, birth: 17, number: 100)
    private let sibling = DesktopWindowKey(pid: 42, birth: 17, number: 101)

    @Test func preexistingMinimizedWindowsNeverBecomeARequest() {
        var order = IndependentStageMinimizeOrder()
        let snapshot = order.observe(window, event: .snapshot, minimized: true, onscreen: false)
        let notice = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        #expect(!snapshot && !notice)
    }

    @Test func aYellowButtonEventActsOnlyOnThePreviouslyVisibleExactWindow() {
        var order = IndependentStageMinimizeOrder()
        let visible = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        let unrelated = order.observe(sibling, event: .miniaturized, minimized: true, onscreen: false)
        let first = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        let duplicate = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        #expect(!visible && !unrelated && first && !duplicate)
    }

    @Test func aCatalogReadCannotConsumeThePendingNativeEvent() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        let snapshot = order.observe(window, event: .snapshot, minimized: true, onscreen: false)
        let notice = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        #expect(!snapshot && notice)
    }

    @Test func clearingMinimizationInHiddenSpaceDoesNotRearmTheWindow() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        let first = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        let clearedWhileHidden = order.observe(window, event: .deminiaturized, minimized: false, onscreen: false)
        let repeatedWhileHidden = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        let afterVisibleRestore = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        #expect(first && !clearedWhileHidden && !repeatedWhileHidden && afterVisibleRestore)
    }

    @Test func delayedMiniNoticeAfterRestoreCannotHideAVisibleWindow() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        let restored = order.observe(window, event: .miniaturized, minimized: false, onscreen: true)
        let animation = order.observe(window, event: .miniaturized, minimized: true, onscreen: true)
        #expect(!restored && !animation)
    }

    @Test func closedOrReplacedIdentityLosesItsPriorObservation() {
        var order = IndependentStageMinimizeOrder()
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        order.remove(window)
        let removed = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        let replacement = DesktopWindowKey(pid: window.pid, birth: window.birth + 1, number: window.number)
        _ = order.observe(window, event: .snapshot, minimized: false, onscreen: true)
        order.retain([replacement])
        let previous = order.observe(window, event: .miniaturized, minimized: true, onscreen: false)
        let replaced = order.observe(replacement, event: .miniaturized, minimized: true, onscreen: false)
        #expect(!removed && !previous && !replaced)
    }
}
