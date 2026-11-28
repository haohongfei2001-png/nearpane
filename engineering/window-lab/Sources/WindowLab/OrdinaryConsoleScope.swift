import NearpaneCore

/// Type evidence accompanies a single frozen Reader snapshot. Order and display
/// identity come from the complete scope, including nonordinary records.
package struct OrdinaryConsoleScope: Decodable {
    let ordinaryRecordsByDisplay: [String: [String]]

    package func admits(_ scope: ManagedDisplayScope, current: String,
                        fullscreenOnly: Bool, other: String?) -> Bool {
        let order = scope.records.map(\.id)
        guard let ordinary = ordinaryRecordsByDisplay[scope.displayID],
              Set(ordinary).count == ordinary.count,
              order.filter(Set(ordinary).contains) == ordinary,
              scope.records.filter(\.isCurrent).map(\.id) == [current],
              ordinary.contains(current), let index = order.firstIndex(of: current) else { return false }
        if fullscreenOnly { return other == nil }
        // Do not skip a fullscreen, unknown or transitional record in the system order.
        return [index - 1, index + 1].contains { neighbor in
            order.indices.contains(neighbor) && ordinary.contains(order[neighbor])
                && (other == nil || order[neighbor] == other)
        }
    }
}
