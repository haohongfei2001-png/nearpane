import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Read-only WindowServer evidence, also used for a deliberate click on a background window.
enum OrdinaryDesktopMembership {
    static func matches(display: String, record: UInt64, uuid: UUID?, exclusive: Bool,
                        inventory: [[String: Any]], members: [UInt64]) -> Bool {
        guard record > 0, exclusive ? members == [record] : members.contains(record) else { return false }
        let rows = inventory.filter { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(display) == .orderedSame }
        guard rows.count == 1, let row = rows.first, let current = row["Current Space"] as? [String: Any],
              current["id64"] as? UInt64 == record, let records = row["Spaces"] as? [[String: Any]] else { return false }
        let matches = records.filter { $0["id64"] as? UInt64 == record }
        guard matches.count == 1, let entry = matches.first, entry["type"] as? Int == 0,
              let id = (entry["uuid"] as? String).flatMap(UUID.init(uuidString:)) else { return false }
        if let type = current["type"], type as? Int != 0 { return false }
        if let raw = current["uuid"], (raw as? String).flatMap(UUID.init(uuidString:)) != id { return false }
        return uuid == nil || uuid == id
    }

    static func pairMatches(_ a: UInt32, _ b: UInt32, on desktop: OrdinaryDesktopIdentity, inventory: [[String: Any]],
                            forwardA: [UInt64], forwardB: [UInt64], reverse: [UInt32]) -> Bool {
        guard a != 0, b != 0, a != b, let record = UInt64(desktop.record),
              reverse.filter({ $0 == a }).count == 1, reverse.filter({ $0 == b }).count == 1 else { return false }
        return matches(display: desktop.display, record: record, uuid: desktop.uuid, exclusive: true, inventory: inventory, members: forwardA)
            && forwardB == [record]
    }

    static func containsPair(_ a: UInt32, _ b: UInt32, on desktop: OrdinaryDesktopIdentity) -> Bool {
        guard let record = UInt64(desktop.record), NPReadOnlySpacesOpen() == 1,
              let inventory = NPReadInventory() as? [[String: Any]],
              let first = NPReadWindowSpaces(a) as? [UInt64], let second = NPReadWindowSpaces(b) as? [UInt64],
              let reverse = NPReadCatalogSpaceWindowNumbers(record) as? [UInt32],
              let current = NPReadInventory() as? [[String: Any]] else { return false }
        return pairMatches(a, b, on: desktop, inventory: inventory, forwardA: first, forwardB: second, reverse: reverse)
            && matches(display: desktop.display, record: record, uuid: desktop.uuid, exclusive: true, inventory: current, members: second)
    }

    static func contains(_ number: UInt32, display: String, record: String, uuid: UUID? = nil) -> Bool {
        guard let space = UInt64(record), NPReadOnlySpacesOpen() == 1,
              let inventory = NPReadInventory() as? [[String: Any]],
              let members = NPReadWindowSpaces(number) as? [UInt64] else { return false }
        return matches(display: display, record: space, uuid: uuid, exclusive: uuid != nil, inventory: inventory, members: members)
    }
}
