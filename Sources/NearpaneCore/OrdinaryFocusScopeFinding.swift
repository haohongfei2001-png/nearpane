import Foundation

/// Selection diagnostics contain classifications and counts, never window IDs,
/// bounds, process names, desktop names or document contents.
public struct OrdinaryFocusScopeFinding: Codable, Equatable, Sendable {
    public enum Point: String, Codable, Sendable { case opening, surface, retainedAX, closing }
    public enum Reason: String, Codable, Sendable {
        case physicalDisplayCount, physicalDisplayID, physicalFrame, usableFrame, backingScale, rotation, separateSpaces
        case physicalTopology, stagePreference, spaceInventory, displaySet, currentRecord, currentType, currentUUID
        case spaceOrder, recordType, recordUUID, forwardMembership, reverseMembership
        case surfaceMissing, surfaceOwner, surfaceLayer, surfaceVisibility, surfaceAlpha, surfaceFrame, frameDisplay
        case axList, originalElement, axRole, axMinimized, axFrame
    }
    public let point: Point, reason: Reason, state: OrdinaryFocusScopeEvidence
    /// Finite count, Boolean or coordinate mismatch bitmask. No absolute coordinates.
    public let expected, observed: Int?
    public init(_ point: Point, _ reason: Reason, _ state: OrdinaryFocusScopeEvidence, _ expected: Int?, _ observed: Int?) {
        self.point = point; self.reason = reason; self.state = state
        self.expected = expected; self.observed = observed
    }
}
