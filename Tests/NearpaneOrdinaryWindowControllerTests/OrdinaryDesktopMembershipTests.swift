import Foundation
import Testing
@testable import NearpaneOrdinaryWindowRuntime

struct OrdinaryDesktopMembershipTests {
    @Test func returnCanBeVerifiedOnAnotherDesktopButRequiresTheOriginalOrdinaryHome() {
        let home = UUID(), current = UUID()
        let record: [String: Any] = ["id64": UInt64(41), "type": 0, "uuid": home.uuidString]
        let fullscreen: [String: Any] = ["id64": UInt64(42), "type": 4, "uuid": current.uuidString]
        let row: [String: Any] = ["Display Identifier": "side", "Current Space": fullscreen, "Spaces": [record, fullscreen]]
        func restored(_ inventory: [[String: Any]], _ members: [UInt64] = [41], uuid: UUID? = nil) -> Bool {
            OrdinaryDesktopMembership.restored(display: "SIDE", record: 41, uuid: uuid ?? home,
                inventory: inventory, members: members)
        }
        #expect(restored([row]))
        #expect(!OrdinaryDesktopMembership.matches(display: "SIDE", record: 41, uuid: home, exclusive: true,
            inventory: [row], members: [41]))
        var transient = row
        transient.removeValue(forKey: "Current Space")
        #expect(restored([transient]))
        #expect(!restored([row], []))
        #expect(!restored([row], [41, 42]))
        #expect(!restored([row, row]))
        #expect(!restored([row], uuid: UUID()))
        var missing = row
        missing["Spaces"] = [fullscreen]
        #expect(!restored([missing]))
        var reused = record
        reused["type"] = 4
        missing["Spaces"] = [reused, fullscreen]
        #expect(!restored([missing]))
        missing["Spaces"] = [record, record, fullscreen]
        #expect(!restored([missing]))
    }

    @Test func eachWriteRequiresTheSameOrdinarySpaceUUIDCurrentDisplayAndExclusiveMember() {
        let uuid = UUID()
        func matches(_ members: [UInt64] = [41], display: String = "side", current: UInt64 = 41,
                     witnessedUUID: UUID? = nil, type: Int = 0, duplicate: Bool = false,
                     currentType: Int? = nil, currentUUID: UUID? = nil) -> Bool {
            let record: [String: Any] = ["id64": UInt64(41), "type": type, "uuid": (witnessedUUID ?? uuid).uuidString]
            var currentEntry: [String: Any] = ["id64": current]
            currentEntry["type"] = currentType
            currentEntry["uuid"] = currentUUID?.uuidString
            let row: [String: Any] = ["Display Identifier": display, "Current Space": currentEntry, "Spaces": [record]]
            return OrdinaryDesktopMembership.matches(display: "SIDE", record: 41, uuid: uuid, exclusive: true,
                inventory: duplicate ? [row, row] : [row], members: members)
        }
        #expect(matches())
        #expect(!matches([41,42]))
        #expect(!matches([]))
        #expect(!matches(display: "another"))
        #expect(!matches(current: 42))
        #expect(!matches(witnessedUUID: UUID()))
        #expect(!matches(type: 4))
        #expect(!matches(duplicate: true))
        #expect(matches(currentType: 0, currentUUID: uuid))
        #expect(!matches(currentType: 4))
        #expect(!matches(currentUUID: UUID()))
    }
}
