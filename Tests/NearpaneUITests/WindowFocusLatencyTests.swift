import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct WindowFocusLatencyTests {
    @Test func readyRaiseReturnsWithoutAQuietPeriod() async throws {
        var clock = 0.0, reads = 0
        let ready = try await HostCurrentWindowFocus.observe(until: 0.1, now: { clock }, pause: { clock += $0 }) {
            reads += 1
            return true
        }
        #expect(ready && clock == 0 && reads == 1)
    }

    @Test func delayedRaiseAndSiblingOnlyRaiseRetainTheFallbackDeadline() async throws {
        var clock = 5.0
        let ready = try await HostCurrentWindowFocus.observe(until: 5.1, now: { clock }, pause: { clock += $0 }) { clock >= 5.030 }
        #expect(ready && clock >= 5.030 && clock <= 5.042)
        clock = 5
        let sibling = try await HostCurrentWindowFocus.observe(until: 5.1, now: { clock }, pause: { clock += $0 }) { false }
        #expect(!sibling && clock == 5.1)
    }

    @Test func freshScopeBracketsOnlyTheBoundAction() async throws {
        var steps = [String]()
        try await DesktopWindowSelection.focusBoundCard(verify: { steps.append("read"); return true }, current: { true }) {
            steps.append("focus")
        }
        #expect(steps == ["read", "focus", "read"])
    }

    @Test func newInputStopsTheBoundActionAndSupersededFocusSkipsItsClosingScan() async {
        var active = true, count = 0
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await DesktopWindowSelection.focusBoundCard(verify: { active = false; return true }, current: { active }) { count += 1 }
        }
        #expect(count == 0)
        active = true
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await DesktopWindowSelection.focusBoundCard(verify: { count += 1; return true }, current: { active }) { active = false }
        }
        #expect(count == 1)
        var scopes = [true, false]
        await #expect(throws: OrdinaryWindowFailure.self) {
            try await DesktopWindowSelection.focusBoundCard(verify: { scopes.removeFirst() }, current: { true }) { count += 1 }
        }
        #expect(scopes.isEmpty && count == 2)
    }
}
