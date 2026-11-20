import Foundation
import CoreFoundation
import CReadOnlySpaces
import NearpaneCore
import WindowGeometryCore

// P1-B Parsing.swift, with exact integers and a one-to-one scope/display UUID check.
struct SpaceInventory: Equatable {
    let scopes: [ManagedDisplayScope]
    let rawTypes: [String: Int64]
    /// Only numeric, display-local evidence from the live managed Space dictionary is retained.
    struct Tile: Equatable {
        let pid: Int32
        let number: UInt32
        let frame: Rect
    }
    let activeTiles: [String: [Tile]]

    static func tiles(_ space: [String: Any]) -> [Tile]? {
        guard let raw = space["TileLayoutManager"] else { return nil }
        guard let manager = raw as? [String: Any], let rows = manager["TileSpaces"] as? [[String: Any]],
              rows.count == 2 else { return [] }
        var result = [Tile]()
        for row in rows {
            guard let pidNumber = integer(row["pid"]), let pid = Int32(pidNumber.stringValue), pid > 0,
                  let window = integer(row["TileWindowID"]), let number = UInt32(window.stringValue), number > 0,
                  let values = row["TileRect"] as? [String: Any] else { return [] }
            let parts = ["X","Y","Width","Height"].compactMap { key -> Double? in
                guard let n = values[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                return n.doubleValue
            }
            guard parts.count == 4 else { return [] }
            let frame = Rect(parts[0],parts[1],parts[2],parts[3])
            guard frame.isValid, !result.contains(where: { $0.number == number }) else { return [] }
            result.append(Tile(pid: pid, number: number, frame: frame))
        }
        return result.sorted { $0.number < $1.number }
    }
    var ids: Set<String> { Set(rawTypes.keys) }
    /// A raw ordinary record is eligible for calibration, not proof of a desktop or membership.
    var ordinaryRecordsByDisplay: [String: [String]] {
        Dictionary(uniqueKeysWithValues: scopes.map { scope in
            (scope.displayID, scope.records.map(\.id).filter { rawTypes[$0] == 0 })
        })
    }

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
        var tilesBySpace = [String: [Tile]]()
        for row in rows {
            guard let key = row["Display Identifier"] as? String, let uuid = UUID(uuidString: key),
                  let display = displays.first(where: { UUID(uuidString: $0.id) == uuid }), seen.insert(display.id).inserted,
                  let currentRecord = row["Current Space"] as? [String: Any],
                  let current = Self.recordID(currentRecord["id64"]),
                  let values = row["Spaces"] as? [[String: Any]], !values.isEmpty, values.count <= 256 else { return nil }
            var records: [SpaceRecord] = []
            for item in values {
                guard let id = Self.recordID(item["id64"]), types[id] == nil, let n = Self.integer(item["type"]),
                      let type = Int64(n.stringValue) else { return nil }
                types[id] = type
                let uuid = (item["uuid"] as? String).flatMap(UUID.init(uuidString:))
                if id == current {
                    if let declared = currentRecord["type"], Self.integer(declared)?.int64Value != type { return nil }
                    if let value = currentRecord["uuid"] {
                        guard let raw = value as? String, let live = UUID(uuidString: raw), live == uuid else { return nil }
                    }
                    if type == 4 {
                        let a = Self.tiles(item), b = Self.tiles(currentRecord)
                        tilesBySpace[id] = a != nil && b != nil && a != b ? [] : a ?? b
                    }
                }
                records.append(SpaceRecord(id: id, isCurrent: id == current, ordinaryUUID: type == 0 ? uuid : nil,
                    fullscreenUUID: type == 4 ? uuid : nil))
            }
            guard records.contains(where: \.isCurrent) else { return nil }
            scopes.append(.init(id: "scope-" + display.id, displayID: display.id, records: records))
        }
        guard seen == Set(displays.map(\.id)) else { return nil }
        self.scopes = scopes; rawTypes = types; activeTiles = tilesBySpace
    }

    /// A failed query concerns only this display. Another screen's selected Space cannot attest these windows.
    func fullscreenMembers(read: (UInt64) -> [NSNumber]? = { NPReadCatalogSpaceWindowNumbers($0) as? [NSNumber] }) -> [String: Set<UInt32>] {
        var result = [String: Set<UInt32>]()
        for scope in scopes {
            guard let record = scope.records.first(where: { $0.isCurrent && $0.fullscreenUUID != nil }),
                  let id = UInt64(record.id), let raw = read(id), raw.count <= 8192 else { continue }
            let numbers = raw.compactMap { Self.integer($0).flatMap { UInt32($0.stringValue) } }
            if numbers.count == raw.count, Set(numbers).count == numbers.count, !numbers.contains(0) {
                result[record.id] = Set(numbers)
            }
        }
        return result
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

    /// Independent active-Space observation plus a unique, stable current membership on the same display.
    /// Neither scope counts nor the raw type alone identify a user desktop.
    func confirmedRows(displays: [DisplayObservation], separateSpaces: Bool, complete: Bool,
                       candidates: [ActiveSpaceAnchor], windows: [CGWindowMetadata], parent: Int32) -> [ObservedSpaceRow] {
        guard complete, displays.count == 1 || separateSpaces, let inventory else { return [] }
        return displays.compactMap { display in
            guard let scope = inventory.scopes.first(where: { $0.displayID == display.id }),
                  let current = scope.records.first(where: \.isCurrent), inventory.rawTypes[current.id] == 0,
                  let anchor = candidates.first(where: { a in
                      a.displayID == display.id && display.frame.geometry.intersection(a.globalFrame.geometry) == a.globalFrame.geometry &&
                      membership[a.number] == .known(recordIDs: [current.id]) &&
                      windows.contains { $0.windowID == a.number && $0.process.hasLifecycleEvidence &&
                          (a.witness == .ownedWindow ? $0.process.pid == parent : $0.process.pid != parent) &&
                          $0.frame.componentError(from: a.globalFrame.geometry) <= 2 }
                  }) else { return nil }
            return ObservedSpaceRow(displayID: display.id, scopeID: scope.id, recordID: current.id, anchor: anchor)
        }
    }
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
