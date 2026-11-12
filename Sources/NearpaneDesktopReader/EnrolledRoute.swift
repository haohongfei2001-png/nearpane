#if NEARPANE_ISOLATED_GUI_LAB
import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Reads only the named windows of the fixture parent, including inactive anchors.
@MainActor enum EnrolledRoute {
    static func sample(display: String, numbers: [UInt32]) throws -> NativeRouteEvidence {
        guard (2...3).contains(numbers.count), Set(numbers).count == numbers.count, !numbers.contains(0), getppid() > 1,
              NPReadOnlySpacesOpen() == 1 else { throw DesktopActionError.unsupported }
        func once() throws -> NativeRouteEvidence {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                  session[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
                  session[kCGSessionLoginDoneKey as String] as? Bool == true,
                  session["CGSSessionScreenIsLocked"] as? Bool != true else { throw DesktopActionError.unsupported }
            let topology = try Topology()
            guard topology.separateSpaces, topology.displays.count == 2, topology.geometry.primary.displayID != display,
                  topology.displays.contains(where: { $0.id == display }) else { throw DesktopActionError.unsupported }
            for number in numbers {
                guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
                      rows.count == 1, let row = rows.first,
                      row[kCGWindowOwnerPID as String] as? Int32 == getppid(),
                      row[kCGWindowNumber as String] as? UInt32 == number,
                      row[kCGWindowLayer as String] as? Int == 0 else { throw DesktopActionError.unsupported }
            }
            let state = SpaceBoundary.read(displays: topology.displays, windowIDs: numbers)
            guard let inventory = state.inventory, let scope = inventory.scopes.first(where: { $0.displayID == display }) else {
                throw DesktopActionError.unsupported
            }
            var membership = [UInt32: String](), currents = [String: String](), orders = [String: [String]]()
            for number in numbers {
                guard case .known(let ids) = state.membership[number], ids.count == 1,
                      inventory.rawTypes[ids[0]] == 0, scope.records.contains(where: { $0.id == ids[0] }) else {
                    throw DesktopActionError.unsupported
                }
                membership[number] = ids[0]
            }
            for scope in inventory.scopes {
                guard let current = scope.records.first(where: \.isCurrent) else { throw DesktopActionError.unsupported }
                currents[scope.displayID] = current.id
                orders[scope.displayID] = scope.records.map(\.id)
            }
            return .init(topology: topology.fingerprint, currents: currents, orders: orders, membership: membership)
        }
        let first = try once()
        Thread.sleep(forTimeInterval: 0.12)
        guard first == (try once()) else { throw DesktopActionError.unsupported }
        return first
    }
}
#endif
