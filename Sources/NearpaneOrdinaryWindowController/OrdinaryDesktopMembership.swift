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

    static func contains(_ number: UInt32, display: String, record: String, uuid: UUID? = nil) -> Bool {
        guard let space = UInt64(record), NPReadOnlySpacesOpen() == 1,
              let inventory = NPReadInventory() as? [[String: Any]],
              let members = NPReadWindowSpaces(number) as? [UInt64] else { return false }
        return matches(display: display, record: space, uuid: uuid, exclusive: uuid != nil, inventory: inventory, members: members)
    }
}
