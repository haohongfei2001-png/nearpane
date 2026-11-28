import Foundation
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct StageWindowInventoryDiagnosticTests {
    @Test func differencesNameOnlyChangedFieldsAndBoundTheirTraversal() {
        func inventory(_ name: String) -> NSArray {
            let space: [String: Any] = ["id64": 41, "TileLayout": ["name": name]]
            return [["Spaces": [space]]] as NSArray
        }
        let opening = inventory("private document A"), closing = inventory("private document B")
        let difference = StageWindowPhysicalReader.inventoryDifference(opening, closing)
        #expect(difference.paths == ["$[0].Spaces[0].TileLayout.name"])
        #expect(!difference.truncated)
        #expect(!difference.paths.joined().contains("private document"))
        #expect(StageWindowPhysicalReader.inventoryDifference(opening, opening).paths.isEmpty)

        let many = StageWindowPhysicalReader.inventoryDifference(
            Array(repeating: 0, count: 20) as NSArray, Array(repeating: 1, count: 20) as NSArray)
        #expect(many.paths.count == 12)
        #expect(many.truncated)

        let unchangedPrefix = StageWindowPhysicalReader.inventoryDifference(
            Array(repeating: 0, count: 1000) as NSArray, (Array(repeating: 0, count: 999) + [1]) as NSArray)
        #expect(unchangedPrefix.inspected == 256)
        #expect(unchangedPrefix.paths.isEmpty)
        #expect(unchangedPrefix.truncated)

        var deepBefore: NSArray = [0], deepAfter: NSArray = [1]
        for _ in 0..<12 { deepBefore = [deepBefore]; deepAfter = [deepAfter] }
        let deep = StageWindowPhysicalReader.inventoryDifference(deepBefore, deepAfter)
        #expect(deep.paths.isEmpty)
        #expect(deep.truncated)
        #expect(deep.inspected <= 9)
    }
}
