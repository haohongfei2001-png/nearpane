import CoreGraphics
import Foundation

/// Compare physical input without reading event contents. Used by the Host intent
/// check and by the worker across the final in-process check immediately before AX.
package enum WindowSelectionInput {
    package static func counters() -> [UInt32] {
        let kinds: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        return kinds.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }
}

/// The record number alone can be reused. The display and ordinary Space UUID
/// must still agree with the live inventory at each window write.
public struct OrdinaryDesktopIdentity: Codable, Equatable, Sendable {
    public let display: String
    public let record: String
    public let uuid: UUID
    public init(display: String, record: String, uuid: UUID) {
        self.display = display; self.record = record; self.uuid = uuid
    }
}

/// Identity carried by an already published, visible card on one ordinary display.
/// The worker independently re-reads every field. This value grants no AX operation.
public struct OrdinaryFocusScope: Codable, Equatable, Sendable {
    public let desktop: OrdinaryDesktopIdentity
    public let topology: String
    public let order: [SpaceRecord]
    public let physicalDisplay: DisplayObservation?, separateSpaces: Bool?

    public init?(display: String, topology: String, order: [SpaceRecord], physicalDisplay: DisplayObservation? = nil,
                 separateSpaces: Bool? = nil) {
        let knownUUIDs = order.compactMap { $0.ordinaryUUID ?? $0.fullscreenUUID }
        guard UUID(uuidString: display) != nil, topology.utf8.count == 64,
              topology.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !order.isEmpty, order.count <= 256, Set(order.map(\.id)).count == order.count,
              order.allSatisfy({ record in
                  guard (UInt64(record.id) ?? 0) > 0 else { return false }
                  if (record.ordinaryUUID != nil) != (record.fullscreenUUID != nil) {
                      return record.observedNativeType == nil || record.observedNativeType == (record.ordinaryUUID != nil ? 0 : 4)
                  }
                  // An inactive, uninitialized ordinary Desktop is part of the
                  // live order, but it cannot become the selected desktop.
                  return !record.isCurrent && record.ordinaryUUID == nil && record.fullscreenUUID == nil && record.observedNativeType == 0
              }),
              Set(knownUUIDs).count == knownUUIDs.count,
              order.filter(\.isCurrent).count == 1, let current = order.first(where: \.isCurrent),
              let uuid = current.ordinaryUUID else { return nil }
        guard physicalDisplay == nil || (physicalDisplay?.id == display && separateSpaces != nil) else { return nil }
        self.physicalDisplay = physicalDisplay
        self.separateSpaces = separateSpaces
        desktop = .init(display: display, record: current.id, uuid: uuid)
        self.topology = topology
        // Previously witnessed is Host history, not part of the live WindowServer order.
        self.order = order.map { .init(id: $0.id, isCurrent: $0.isCurrent, ordinaryUUID: $0.ordinaryUUID,
            fullscreenUUID: $0.fullscreenUUID, observedNativeType: $0.observedNativeType) }
    }
}

public enum OrdinaryFocusScopeEvidence: String, Codable, Sendable {
    case confirmed, fullRosterRequired, changed
}

/// The two retained windows and the final side-by-side slots chosen in one explicit drop.
public struct OrdinaryWindowPairPlacement: Codable, Equatable, Sendable {
    public let desktop: OrdinaryDesktopIdentity
    public let left, right: ManagedWindowID
    public let leftFrame, rightFrame: SurfaceRect
    public init(desktop: OrdinaryDesktopIdentity, left: ManagedWindowID, right: ManagedWindowID,
                leftFrame: SurfaceRect, rightFrame: SurfaceRect) {
        self.desktop = desktop
        self.left = left
        self.right = right
        self.leftFrame = leftFrame
        self.rightFrame = rightFrame
    }
}

/// Anonymous pipes connect the signed Host to one short-lived worker scoped to one process incarnation.
public struct OrdinaryWindowRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case list, refresh, prepare, verify, write, release, observeBoundary, acknowledgeBoundary
        case watchCreated, takeCreated, endCreated, focusCurrent, inspectFocusScope, checkFocusPermission, requestFocusPermission, stageRead, stagePlace

        public var allowedForFocusScopeProbe: Bool { self == .list || self == .inspectFocusScope || self == .release }

        public var allowedForStillPreview: Bool {
            switch self {
            case .list, .prepare, .verify, .release: true
            default: false
            }
        }
    }
    public let nonce: UUID, action: Action, pid: Int32, launch: UInt64, bundle: String
    public let id: ManagedWindowID?, expected: SurfaceRect?, destination: SurfaceRect?
    public let focusDisplay: String?, focusDeadline: TimeInterval?
    public let focusSpace: String?
    public let creationGrant: UUID?
    public let boundaryRevision: UUID?
    public let desktop: OrdinaryDesktopIdentity?
    public let pairPlacement: OrdinaryWindowPairPlacement?
    public let focusScope: OrdinaryFocusScope?
    public let focusTimingID: UUID?

    public init(_ action: Action, pid: Int32, launch: UInt64, bundle: String,
                id: ManagedWindowID? = nil, expected: SurfaceRect? = nil, destination: SurfaceRect? = nil,
                boundaryRevision: UUID? = nil, creationGrant: UUID? = nil, focusDisplay: String? = nil,
                focusDeadline: TimeInterval? = nil, focusSpace: String? = nil, desktop: OrdinaryDesktopIdentity? = nil,
                pairPlacement: OrdinaryWindowPairPlacement? = nil, focusTimingID: UUID? = nil, focusScope: OrdinaryFocusScope? = nil) {
        self.focusScope = focusScope
        self.desktop = desktop
        self.pairPlacement = pairPlacement
        self.focusTimingID = focusTimingID
        self.focusSpace = focusSpace
        self.focusDisplay = focusDisplay; self.focusDeadline = focusDeadline
        self.nonce = UUID()
        self.action = action
        self.pid = pid
        self.launch = launch
        self.bundle = bundle
        self.id = id
        self.expected = expected
        self.destination = destination
        self.boundaryRevision = boundaryRevision
        self.creationGrant = creationGrant
    }
}

/// Read-only evidence of an unattributed external geometry change. A revision does not grant
/// an AX write; the Host must persist its changed recovery policy before acknowledging it.
public struct OrdinaryBoundaryObservation: Codable, Sendable {
    public let pair: AdmissionPair?
    public let previous: SurfaceRect
    public let revision: UUID?
    public let settled: Bool
    public init(pair: AdmissionPair?, previous: SurfaceRect, revision: UUID?, settled: Bool) {
        self.pair = pair
        self.previous = previous
        self.revision = revision
        self.settled = settled
    }
}

public struct OrdinaryWindowStep: Codable, Sendable {
    public let from, to, ax, cg: SurfaceRect
    public let notification: String
    public let uptime: Double
    public init(from: SurfaceRect, to: SurfaceRect, ax: SurfaceRect, cg: SurfaceRect, notification: String, uptime: Double) {
        self.from = from
        self.to = to
        self.ax = ax
        self.cg = cg
        self.notification = notification
        self.uptime = uptime
    }
}

/// Destruction of the retained element plus two independent AX and CG absence reads.
public struct OrdinaryWindowClosure: Codable, Sendable, LocalizedError {
    public enum Evidence: String, Codable, Sendable { case notification, invalidAXElement }
    public let id: ManagedWindowID
    public let destroyed, firstAbsent, secondAbsent: TimeInterval
    public let evidence: Evidence
    public init(id: ManagedWindowID, destroyed: TimeInterval, firstAbsent: TimeInterval, secondAbsent: TimeInterval,
                evidence: Evidence = .notification) {
        self.id = id
        self.destroyed = destroyed
        self.firstAbsent = firstAbsent
        self.secondAbsent = secondAbsent
        self.evidence = evidence
    }
    public var errorDescription: String? { "已确认原窗口关闭。" }
}

public struct OrdinaryWindowReply: Codable, Sendable {
    public let nonce: UUID
    /// Set only for a read-only listing refused by the process that performs AX operations.
    public var listAccessDenied: Bool?
    public var focusScopeEvidence: OrdinaryFocusScopeEvidence?
    public var focusScopeFindings: [OrdinaryFocusScopeFinding]?
    public var stageObservation: StageWindowPhysicalObservation?
    public var focusPermission: Bool?
    public var focusStep: Int?
    public var steps: [OrdinaryWindowStep]?
    public var choices: [ManagedWindowID?]?, pair: AdmissionPair?, failure: String?
    public var closure: OrdinaryWindowClosure?
    public var boundary: OrdinaryBoundaryObservation?
    public var created: ManagedWindowID?
    public var skippedCreated: String?
    public init(_ nonce: UUID) { self.nonce = nonce }
}
