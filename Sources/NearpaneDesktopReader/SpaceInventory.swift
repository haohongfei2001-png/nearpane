import Foundation
import CoreFoundation
import CReadOnlySpaces
import NearpaneCore

// P1-B Parsing.swift, with exact integers and a one-to-one scope/display UUID check.
struct SpaceInventory: Equatable {
    let scopes: [ManagedDisplayScope]
    let rawTypes: [String: Int64]
    var ids: Set<String> { Set(rawTypes.keys) }

    static func integer(_ raw: Any?) -> NSNumber? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c","s","i","l","q","C","S","I","L","Q"].contains(String(cString: number.objCType)) else { return nil }
        return number
    }

    static func recordID(_ raw: Any?) -> String? {
        guard let n = integer(raw), let id = UInt64(n.stringValue), id > 0 else { return nil }
        return String(id)
    }

    init?(_ raw: Any?, displays: [DisplayObservation]) {
        guard let rows = raw as? [[String: Any]], !rows.isEmpty, rows.count <= 32 else { return nil }
        var scopes: [ManagedDisplayScope] = [], types: [String: Int64] = [:], seen = Set<String>()
        for row in rows {
            guard let key = row["Display Identifier"] as? String, let uuid = UUID(uuidString: key),
                  let display = displays.first(where: { UUID(uuidString: $0.id) == uuid }), seen.insert(display.id).inserted,
                  let current = Self.recordID((row["Current Space"] as? [String: Any])?["id64"]),
                  let values = row["Spaces"] as? [[String: Any]], !values.isEmpty, values.count <= 256 else { return nil }
            var records: [SpaceRecord] = []
            for item in values {
                guard let id = Self.recordID(item["id64"]), types[id] == nil, let n = Self.integer(item["type"]),
                      let type = Int64(n.stringValue) else { return nil }
                types[id] = type
                records.append(SpaceRecord(id: id, isCurrent: id == current))
            }
            guard records.contains(where: \.isCurrent) else { return nil }
            scopes.append(.init(id: "scope-" + display.id, displayID: display.id, records: records))
        }
        guard seen == Set(displays.map(\.id)) else { return nil }
        self.scopes = scopes; rawTypes = types
    }

    func membership(_ raw: Any?) -> WindowMembership {
        guard let values = raw as? [Any], !values.isEmpty, values.count <= 256 else { return .unknown }
        let decoded = values.compactMap(Self.recordID)
        guard decoded.count == values.count, Set(decoded).count == decoded.count, Set(decoded).isSubset(of: ids) else { return .unknown }
        return .known(recordIDs: decoded.sorted())
    }
}

struct SpaceBoundary: Equatable {
    let inventory: SpaceInventory?
    let membership: [UInt32: WindowMembership]
    static func read(displays: [DisplayObservation], windowIDs: [UInt32]) -> Self {
        guard let raw = NPReadInventory(), let inventory = SpaceInventory(raw as [AnyObject], displays: displays) else {
            return Self(inventory: nil, membership: [:])
        }
        var result: [UInt32: WindowMembership] = [:]
        for id in Set(windowIDs) {
            result[id] = NPReadWindowSpaces(id).map { inventory.membership($0 as [AnyObject]) } ?? .unknown
        }
        return Self(inventory: inventory, membership: result)
    }
}
