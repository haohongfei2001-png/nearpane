import Testing
@testable import NearpaneCore

struct NativeRouteEvidenceTests {
    @Test(arguments: [true, false])
    func singleScreenRequiresExplicitTopology(currentDisplayOnly: Bool) {
        let evidence = NativeRouteEvidence(topology: "one-screen", currents: ["main": "1309"],
            orders: ["main": ["1130", "1309"]], membership: [7: "1309", 8: "1130"])
        #expect(evidence.validates(display: "main", source: "1309", sourceWindow: 7, target: "1130", targetWindow: 8,
            sourceCurrents: ["main": "1309"], targetCurrents: ["main": "1130"], frozenOrder: ["1130", "1309"],
            frozenTopology: "one-screen", right: false, isolatedDisplays: false, currentDisplayOnly: currentDisplayOnly) == currentDisplayOnly)
    }
    @Test(arguments: ["valid", "missing", "moved", "other-display", "source-changed", "reordered", "nonadjacent", "reversed", "new-topology", "id-reused", "isolated-coupled", "coupled-record-gone"])
    func adjacentRouteRequiresLiveDestinationAndOtherDisplay(caseName: String) {
        let source: UInt32 = 7, target: UInt32 = caseName == "id-reused" ? 7 : 8
        let before = ["side": "A", "main": "M"]
        let isolated = ["isolated-coupled","coupled-record-gone"].contains(caseName)
        let after = ["side": "B", "main": caseName == "other-display" || isolated ? "N" : "M"]
        let frozen = caseName == "nonadjacent" ? ["A","C","B"] : ["A","B"]
        var members: [UInt32:String] = [7:"A", 8:"B"]
        if caseName == "missing" { members[8] = nil }
        if caseName == "moved" { members[8] = "C" }
        let current = NativeRouteEvidence(topology: caseName == "new-topology" ? "new" : "screen",
            currents: caseName == "source-changed" ? after : before,
            orders: ["side": caseName == "reordered" ? ["B","A"] : frozen, "main": caseName == "coupled-record-gone" ? ["M"] : ["M","N"]],
            membership: members)
        #expect(current.validates(display: "side", source: "A", sourceWindow: source, target: "B", targetWindow: target,
                                  sourceCurrents: before, targetCurrents: after, frozenOrder: frozen, frozenTopology: "screen",
                                  right: caseName != "reversed", isolatedDisplays: isolated) == (caseName == "valid" || caseName == "isolated-coupled"))
    }
}
