import Testing
@testable import NearpaneOrdinaryWindowController

struct WindowRemovalTests {
    @Test func genuineCGClosingAnimationMustSettleBeforeTwoConfirmedReads() throws {
        var t = 10.0
        var reads = [Double]()
        let (first, second) = try confirmedRemovalTimes(now: { t }, wait: { t += $0 }) {
            reads.append(t)
            return t >= 10.27
        }
        #expect(reads.count >= 5 && first >= 10.27 && second - first >= 0.094)
        #expect(reads.suffix(2) == [first, second])
    }

    @Test func retainedBackingUnavailableProofAndReappearingIDCannotRetire() {
        var t = 10.0
        #expect(throws: Refusal.self) {
            _ = try confirmedRemovalTimes(now: { t }, wait: { t += $0 }, readAbsent: { false })
        }
        #expect(t == 10.8)
        var waits = 0
        #expect(throws: Refusal.self) {
            _ = try confirmedRemovalTimes(now: { t }, wait: { _ in waits += 1 },
                                          readAbsent: { throw Refusal("unavailable") })
        }
        #expect(waits == 0)
        #expect(throws: Refusal.self) {
            _ = try confirmedRemovalTimes(now: { t }, wait: { delta in waits += 1; t += delta },
                                          readAbsent: { waits == 0 })
        }
        #expect(waits == 1)
    }
}
