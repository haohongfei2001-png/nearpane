import NearpaneCore

/// Only the display currents may change during the supervised Space trial.
package struct TrialDisplayState: Equatable {
    package let build: String
    package let topology: String
    package let currents: [String: String]
    package let orders: [String: [String]]
    private let scopeIDs: [String: String]

    package init(_ snapshot: DesktopSnapshot) throws {
        var currents = [String: String](), orders = [String: [String]](), ids = [String: String]()
        guard snapshot.separateSpaces == true, snapshot.scopes.count == 2 else {
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
}
