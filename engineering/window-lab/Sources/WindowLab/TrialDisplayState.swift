import NearpaneCore

/// Only the display currents may change during the supervised Space trial.
package struct TrialDisplayState: Equatable {
    package let build: String
    package let topology: String
    package let currents: [String: String]
    package let orders: [String: [String]]
    private let scopeIDs: [String: String]

    package init(_ snapshot: DesktopSnapshot, soleDisplay: String? = nil) throws {
        var currents = [String: String](), orders = [String: [String]](), ids = [String: String]()
        if let soleDisplay {
            guard snapshot.scopes.count == 1, snapshot.scopes[0].displayID == soleDisplay,
                  snapshot.displays.count == 1, snapshot.displays[0].id == soleDisplay else {
                throw Refusal("selected display is not the sole observed physical display and scope")
            }
        } else if snapshot.separateSpaces != true || snapshot.scopes.count != 2 {
            throw Refusal("two independently observable display scopes required")
        }
        for scope in snapshot.scopes {
            let active = scope.records.filter(\.isCurrent)
            guard active.count == 1, ids[scope.displayID] == nil else {
                throw Refusal("ambiguous display current")
            }
            currents[scope.displayID] = active[0].id
            orders[scope.displayID] = scope.records.map(\.id)
            ids[scope.displayID] = scope.id
        }
        self.currents = currents
        self.orders = orders
        scopeIDs = ids
        build = snapshot.sourceBuild
        topology = snapshot.topologyFingerprint
    }

    package func permits(_ next: Self, secondary: String, endpoint: String) -> Bool {
        var expected = currents
        expected[secondary] = endpoint
        return orders[secondary]?.contains(endpoint) == true
            && scopeIDs == next.scopeIDs && orders == next.orders && build == next.build
            && topology == next.topology && expected == next.currents
    }

    /// Native full screen can insert a temporary record and change the secondary's usable
    /// frame. The caller separately checks both physical displays and the enrolled AX/CG window.
    package func permitsFullscreen(_ next: Self, secondary: String, member: String) -> Bool {
        guard build == next.build, scopeIDs == next.scopeIDs, next.currents[secondary] == member,
              let ordinary = orders[secondary], !ordinary.contains(member),
              let fullscreen = next.orders[secondary], fullscreen.count == ordinary.count + 1,
              fullscreen.filter({ $0 != member }) == ordinary,
              let primary = currents.keys.first(where: { $0 != secondary }) else { return false }
        return next.currents[primary] == currents[primary] && next.orders[primary] == orders[primary]
    }
}
