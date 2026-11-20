import AppKit
import CReadOnlySpaces
import NearpaneCore

extension Reader {
  /// Public z-order can omit a window even while both WindowServer membership
  /// directions and the application's AX window number agree on its owner.
  nonisolated static func backgroundRows(
    in inventory: SpaceInventory,
    known: Set<UInt32>,
    members: (UInt64) -> [NSNumber]? = { NPReadCatalogSpaceWindowNumbers($0) as? [NSNumber] },
    reverse: (UInt32) -> [Any]? = { NPReadWindowSpaces($0) as? [Any] },
    metadata: (UInt32) -> [String: Any]? = backgroundMetadata
  ) -> (rows: [[String: Any]], complete: Bool) {
    var candidates = [UInt32: Set<String>]()
    var complete = true
    let background = inventory.scopes.flatMap(\.records).filter {
      !$0.isCurrent && $0.ordinaryUUID != nil
    }
    let backgroundIDs = Set(background.map(\.id))
    for space in background {
      guard let sid = UInt64(space.id), let raw = members(sid), raw.count <= 8192 else {
        complete = false
        continue
      }
      var seen = Set<UInt32>()
      for item in raw {
        guard let integer = SpaceInventory.integer(item), let number = UInt32(integer.stringValue),
          number > 0, seen.insert(number).inserted
        else {
          complete = false
          continue
        }
        if !known.contains(number) { candidates[number, default: []].insert(space.id) }
      }
    }
    guard candidates.count <= 4096 else { return ([], false) }
    var rows = [[String: Any]]()
    for number in candidates.keys.sorted() {
      guard let forward = candidates[number],
        case .known(let ids) = inventory.membership(reverse(number)),
        Set(ids).intersection(backgroundIDs) == forward, let row = metadata(number),
        row[kCGWindowNumber as String] as? UInt32 == number,
        let pid = row[kCGWindowOwnerPID as String] as? Int32, pid > 0
      else {
        complete = false
        continue
      }
      rows.append(row)
    }
    return (rows, complete)
  }

  nonisolated private static func backgroundMetadata(_ number: UInt32) -> [String: Any]? {
    guard let record = WindowSurfaceRecord(number: number) else { return nil }
    let f = record.frame
    return [
      kCGWindowNumber as String: number, kCGWindowOwnerPID as String: record.pid,
      kCGWindowLayer as String: record.layer, kCGWindowAlpha as String: record.isDrawn ? 1.0 : 0.0,
      kCGWindowIsOnscreen as String: record.isOnscreen,
      kCGWindowBounds as String: CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
        .dictionaryRepresentation,
    ]
  }
}
