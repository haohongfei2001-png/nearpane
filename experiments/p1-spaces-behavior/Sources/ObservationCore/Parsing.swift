import Foundation
import CoreFoundation

// Reject booleans, floating-point numbers, strings, negative IDs and silent NSNumber truncation.
public func unsignedID(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let code = String(cString: number.objCType)
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(code) else { return nil }
    return UInt64(number.stringValue)
}

public func signedInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let code = String(cString: number.objCType)
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(code) else { return nil }
    return Int64(number.stringValue)
}

public func parseInventory(_ value: Any?) -> Inventory {
    guard let value else { return Inventory(status: .nullResult, scopes: []) }
    guard let rows = value as? [Any] else { return Inventory(status: .malformed, scopes: []) }
    var malformed = false
    var scopes: [ManagedScope] = []
    for row in rows {
        guard let fields = row as? [String: Any] else {
            malformed = true
            scopes.append(ManagedScope(identifier: nil, spaces: [], currentSpaceID: nil, issues: ["scope_malformed"]))
            continue
        }
        var issues: [String] = []
        let identifier = fields["Display Identifier"] as? String
        if identifier == nil { issues.append("scope_identifier_missing") }
        let current = (fields["Current Space"] as? [String: Any]).flatMap { unsignedID($0["id64"]) }
        if current == nil { issues.append("current_space_missing") }
        var spaces: [SpaceRecord] = []
        if let records = fields["Spaces"] as? [Any] {
            for record in records {
                let dictionary = record as? [String: Any]
                let id = unsignedID(dictionary?["id64"])
                let type = signedInteger(dictionary?["type"])
                if id == nil { issues.append("space_id_malformed") }
                if type == nil { issues.append("space_type_unknown") }
                spaces.append(SpaceRecord(id: id, rawType: type))
            }
            let ids = spaces.compactMap(\.id)
            if Set(ids).count != ids.count { issues.append("duplicate_space_record") }
        } else { issues.append("spaces_array_missing") }
        if !issues.isEmpty { malformed = true }
        scopes.append(ManagedScope(identifier: identifier, spaces: spaces, currentSpaceID: current, issues: Array(Set(issues))))
    }
    return Inventory(status: malformed ? .malformed : .ok, scopes: scopes)
}

public func parseMembership(_ value: Any?) -> Membership {
    guard let value else { return Membership(status: .nullResult) }
    guard let array = value as? [Any] else { return Membership(status: .malformed) }
    let ids = array.compactMap(unsignedID)
    if ids.count != array.count { return Membership(status: .malformed, spaceIDs: ids) }
    return Membership(status: ids.isEmpty ? .empty : .known, spaceIDs: ids)
}
