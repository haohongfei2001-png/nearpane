import Foundation

/// Read-only evidence for an adjacent-desktop trial. Neither a row number nor a
/// keyboard shortcut identifies its destination without both enrolled windows.
public struct NativeRouteEvidence: Codable, Equatable, Sendable {
    public let topology: String
    public let currents: [String: String]
    public let orders: [String: [String]]
    public let membership: [UInt32: String]

    public init(topology: String, currents: [String: String], orders: [String: [String]], membership: [UInt32: String]) {
        self.topology = topology
        self.currents = currents
        self.orders = orders
        self.membership = membership
    }

    public func validates(display: String, source: String, sourceWindow: UInt32, target: String, targetWindow: UInt32,
                          sourceCurrents: [String: String], targetCurrents: [String: String],
                          frozenOrder: [String], frozenTopology: String, right: Bool, isolatedDisplays: Bool) -> Bool {
        var expected = sourceCurrents
        expected[display] = target
        guard currents.count == 2, currents == sourceCurrents, currents[display] == source,
              targetCurrents[display] == target, Set(currents.keys) == Set(targetCurrents.keys),
              Set(currents.keys) == Set(orders.keys),
              targetCurrents.allSatisfy({ orders[$0.key]?.contains($0.value) == true }),
              isolatedDisplays || expected == targetCurrents, !topology.isEmpty, topology == frozenTopology,
              source != target, sourceWindow != 0, targetWindow != 0, sourceWindow != targetWindow,
              membership == [sourceWindow: source, targetWindow: target],
              let order = orders[display], order == frozenOrder, Set(order).count == order.count,
              let i = order.firstIndex(of: source), let j = order.firstIndex(of: target) else { return false }
        return right ? j == i + 1 : i == j + 1
    }
}
