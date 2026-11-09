import Foundation
import Testing
import NearpaneCore
@testable import NearpaneDesktopReader

struct SpaceInventoryTests {
    let id = "12000000-0000-0000-0000-000000000001"
    var displays: [DisplayObservation] { [.init(id: id, frame: .init(width: 800, height: 1280), rotationDegrees: 90, backingScale: 2)] }
    func scope(_ records: [Any], current: Any = 5) -> [[String: Any]] {
        [["Display Identifier": id, "Current Space": ["id64": current], "Spaces": records]]
    }
    let records: [[String: Any]] = [["id64": 5, "type": 0], ["id64": 9, "type": 4]]

    @Test func membershipKeepsMultipleIDsAndEmptyOrInvalidIsUnknown() throws {
        let inventory = try #require(SpaceInventory(scope(records), displays: displays))
        #expect(inventory.membership([9,5]) == .known(recordIDs: ["5","9"]))
        for value: Any in [[], [5,5], [11], [true], ["5"], [5.1], [-1]] {
            #expect(inventory.membership(value) == .unknown)
        }
        #expect(inventory.scopes[0].records.map(\.isCurrent) == [true,false])
    }
    @Test func unknownDisplayMalformedCurrentAndReusedIDsRejectInventory() {
        #expect(SpaceInventory(scope(records, current: 7), displays: displays) == nil)
        #expect(SpaceInventory(scope(records + [records[0]]), displays: displays) == nil)
        #expect(SpaceInventory(scope(records), displays: []) == nil)
        #expect(SpaceInventory(scope(records) + scope(records), displays: displays) == nil)
        #expect(SpaceInventory(scope([["id64": true, "type": 0]]), displays: displays) == nil)
    }
}
