import NearpaneCore
import Testing
import WindowLab

struct TrialDisplayStateTests {
    func snapshot(_ primary: String, _ secondary: String, records: [String] = ["A", "B"]) -> DesktopSnapshot {
        var snapshot = DesktopFixture.twoDisplays.makeSnapshot()
        snapshot.separateSpaces = true
        snapshot.scopes = [
            .init(id: "main", displayID: "primary", records: ["X", "Y"].map { .init(id: $0, isCurrent: $0 == primary) }),
            .init(id: "side", displayID: "secondary", records: records.map { .init(id: $0, isCurrent: $0 == secondary) })
        ]
        return snapshot
    }

    @Test func independentCalibrationAcceptsOnlyTheSecondaryTransition() throws {
        let origin = try TrialDisplayState(snapshot("X", "A"))
        let destination = try TrialDisplayState(snapshot("X", "B"))
        #expect(origin.permits(destination, secondary: "secondary", endpoint: "B"))
        #expect(!origin.permits(destination, secondary: "secondary", endpoint: "A"))
        #expect(!origin.permits(try TrialDisplayState(snapshot("Y", "B")), secondary: "secondary", endpoint: "B"))
        #expect(!origin.permits(try TrialDisplayState(snapshot("X", "B", records: ["B", "A"])), secondary: "secondary", endpoint: "B"))
    }

    @Test func returnRequiresTheOriginalBuildAndBothScopeIdentities() throws {
        let snapshotA = snapshot("X", "A")
        let origin = try TrialDisplayState(snapshotA)
        var changed = snapshotA
        changed.sourceBuild += "-changed"
        #expect(try origin != TrialDisplayState(changed))
        changed = snapshotA
        changed.scopes[1] = .init(id: "newScope", displayID: changed.scopes[1].displayID, records: changed.scopes[1].records)
        #expect(try origin != TrialDisplayState(changed))
        #expect(try origin == TrialDisplayState(snapshot("X", "A")))
    }

    @Test func ambiguousScopesCannotServeAsReturnEvidence() {
        var missing = snapshot("X", "")
        #expect(throws: (any Error).self) { try TrialDisplayState(missing) }
        missing = snapshot("X", "A")
        missing.scopes = [missing.scopes[0], missing.scopes[0]]
        #expect(throws: (any Error).self) { try TrialDisplayState(missing) }
        missing.separateSpaces = false
        #expect(throws: (any Error).self) { try TrialDisplayState(missing) }
    }
}
