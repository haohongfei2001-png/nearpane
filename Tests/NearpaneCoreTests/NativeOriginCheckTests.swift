import Foundation
import Testing
@testable import NearpaneCore

struct NativeOriginCheckTests {
    @Test func requiresTwoFreshIndependentReadsOfEnrolledWindowWithoutGrantingAction() throws {
        let f = NativeDesktopPreviewTests()
        let w = f.window(77, f.proof.anchor.globalFrame, 0, .known(recordIDs: ["9"]))
        let id = try #require(ManagedWindowID(w))
        func evidence(_ start: Double) -> DesktopReadEvidence {
            .init(population: .markedFixture, accessibility: .available, spaces: .observed, rows: [f.proof],
                  windowLimitReached: false, beganUptime: start, endedUptime: start + 0.25)
        }
        var a = f.sample([w], rows: [f.proof]); a.native = evidence(39)
        var b = a; b.revision += 1; b.native = evidence(40)
        let provider = NativeSpacesProvider()
        func check(_ s: DesktopSnapshot, now: Double = 42) throws -> WorkspaceID {
            try provider.stableTestOrigin(previous: a, current: s, session: a.sessionID, display: w.displayID,
                                          enrolled: id, date: f.date, uptime: now)
        }
        #expect(try check(b) == b.workspaceID(display: w.displayID, record: "9"))
        #expect(throws: WorkspaceFailure.self) { try check(a) }
        #expect(throws: WorkspaceFailure.self) { try check(b, now: 58) }
        var restarted = b
        restarted.windows = [f.window(77, f.proof.anchor.globalFrame, 0, .known(recordIDs: ["9"]))]
        #expect(throws: WorkspaceFailure.self) { try check(restarted) }
        var inventoryOnly = b; inventoryOnly.windows = []
        #expect(throws: WorkspaceFailure.self) { try check(inventoryOnly) }
        var changed = b; changed.sessionID = UUID()
        #expect(throws: WorkspaceFailure.self) { try check(changed) }
    }
}
