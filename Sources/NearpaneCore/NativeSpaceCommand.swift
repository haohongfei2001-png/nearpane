import Foundation

public struct NativeSpaceWindow: Codable, Sendable, Hashable {
    public let pid: Int32
    /// Process start time, in microseconds since the epoch.
    public let birth: UInt64
    public let number: UInt32

    public init(pid: Int32, birth: UInt64, number: UInt32) {
        self.pid = pid
        self.birth = birth
        self.number = number
    }
}

public enum NativeSpaceKind: Int, Codable, Sendable {
    case ordinary = 0, fullscreen = 4
}

public extension SpaceRecord {
    var nativeKind: NativeSpaceKind? {
        if ordinaryUUID != nil && fullscreenUUID == nil { return .ordinary }
        if fullscreenUUID != nil && ordinaryUUID == nil { return .fullscreen }
        return nil
    }
    var nativeUUID: UUID? { nativeKind == .ordinary ? ordinaryUUID : (nativeKind == .fullscreen ? fullscreenUUID : nil) }
}

public struct NativeSpaceStepPermission: Codable, Sendable {
    public let id: UUID
    /// Number of complete gestures already posted for this request.
    public let submittedSteps: Int
    public let proceed: Bool
    public init(id: UUID, submittedSteps: Int, proceed: Bool) {
        self.id = id
        self.submittedSteps = submittedSteps
        self.proceed = proceed
    }

    public func permitsFocus(_ request: OrdinaryWindowRequest, after steps: Int, now: TimeInterval) -> Bool {
        guard request.action == .focusCurrent, let deadline = request.focusDeadline else { return false }
        return id == request.nonce && submittedSteps == steps && (0..<8).contains(steps) && proceed &&
            deadline > now && deadline - now <= 12
    }

    public func permits(_ request: NativeSpaceCommand, after steps: Int, now: TimeInterval) -> Bool {
        let requested = request.action == .select || (request.action == .move && request.confirmMoveBeforeSubmission == true && steps == 0)
        return requested && id == request.id && submittedSteps == steps && proceed && request.isFresh(at: now)
    }
}

/// A read-only catalogue request. An original token is meaningful only to the
/// signed helper process that retained the AX object while this Space was current.
public struct NativeSidebarWindowLocation: Codable, Hashable, Sendable {
    public let window: NativeSpaceWindow
    public let display: UUID
    public let space: String
    public let spaceUUID: UUID
    public init(window: NativeSpaceWindow, display: UUID, space: String, spaceUUID: UUID) {
        self.window = window
        self.display = display
        self.space = space
        self.spaceUUID = spaceUUID
    }
}

public struct NativeSidebarWindowProbe: Codable, Sendable {
    public let location: NativeSidebarWindowLocation
    public let current: Bool
    public let original: UUID?
    public let audit: Bool?
    public init(_ location: NativeSidebarWindowLocation, current: Bool, original: UUID?, audit: Bool? = nil) {
        self.audit = audit
        self.location = location
        self.current = current
        self.original = original
    }
}

public struct NativeSpaceCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case probe, select, move, observeWindows }
    public let id: UUID
    public let action: Action
    public let display, source, target: String
    public let sourceUUID, targetUUID: UUID?
    public let sourceKind, targetKind: NativeSpaceKind
    public let createdAtUptime: TimeInterval
    public let window: NativeSpaceWindow?
    public let originalWindow: UUID?
    public let observations: [NativeSidebarWindowProbe]?
    /// Production Host moves request one final permit after the helper has prepared the exact window.
    /// Absent in the older direct fixture protocol.
    public let confirmMoveBeforeSubmission: Bool?
    public var deadlineUptime: TimeInterval { createdAtUptime + 5 }
    public func isFresh(at now: TimeInterval) -> Bool {
        createdAtUptime.isFinite && now >= createdAtUptime && now < deadlineUptime
    }

    public init(id: UUID, action: Action, display: String, source: String, target: String,
                sourceUUID: UUID? = nil, targetUUID: UUID? = nil, window: NativeSpaceWindow? = nil,
                sourceKind: NativeSpaceKind = .ordinary, targetKind: NativeSpaceKind = .ordinary,
                originalWindow: UUID? = nil, observations: [NativeSidebarWindowProbe]? = nil,
                confirmMoveBeforeSubmission: Bool? = nil, createdAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id
        self.action = action
        self.display = display
        self.source = source
        self.target = target
        self.sourceUUID = sourceUUID
        self.targetUUID = targetUUID
        self.sourceKind = sourceKind
        self.targetKind = targetKind
        self.createdAtUptime = createdAtUptime
        self.window = window
        self.originalWindow = originalWindow
        self.observations = observations
        self.confirmMoveBeforeSubmission = confirmMoveBeforeSubmission
    }
}

public struct NativeSwitchTrace: Codable, Sendable {
    public var adapter = 0
    public var phasesMachTicks: [UInt64] = []
    public var naturalScrolling: Bool?
    public var progress: Double?
    public var endVelocity: Double?
    public var dockNotificationUptimes: [Double] = []
    public var observations: [Observation] = []
    public var emptyGuard: String?
    public init() {}

    public struct Observation: Codable, Sendable {
        public let uptime: Double, currents: [String: String], frontPID: Int32?
        public init(uptime: Double, currents: [String: String], frontPID: Int32?) {
            self.uptime = uptime; self.currents = currents; self.frontPID = frontPID
        }
    }
}

public struct NativeSpaceReply: Codable, Sendable {
    public enum State: String, Codable, Sendable { case ready, awaitingStep, issued, confirmed, failed, outcomeUnknown }
    public let id: UUID
    public let state: State
    public let detail: String
    public let canSwitch, canMove: Bool
    /// System readbacks, keyed by display UUID. Membership uses actual Space IDs.
    public let currentBefore, currentAfter: [String: String]?
    public let membershipBefore, membershipAfter: [String]?
    public let issuedAtUptime, confirmedAtUptime: TimeInterval?
    public let submittedSteps: Int
    public let switchTrace: NativeSwitchTrace?
    public let originalWindow: UUID?
    public let observedWindows: [UUID?]?
    public let observationReasons: [String?]?
    public let observationWorkerPID: Int32?
    public let observationFacts: [[String: String]?]?
    /// Indices whose original was held privately without renewing its verification time.
    public let withheldOriginals: [Int]?

    public init(id: UUID, state: State, detail: String, canSwitch: Bool, canMove: Bool,
                currentBefore: [String: String]? = nil, currentAfter: [String: String]? = nil,
                membershipBefore: [String]? = nil, membershipAfter: [String]? = nil,
                issuedAtUptime: TimeInterval? = nil, confirmedAtUptime: TimeInterval? = nil, submittedSteps: Int = 0,
                switchTrace: NativeSwitchTrace? = nil, originalWindow: UUID? = nil, observedWindows: [UUID?]? = nil,
                observationReasons: [String?]? = nil, observationWorkerPID: Int32? = nil,
                observationFacts: [[String: String]?]? = nil, withheldOriginals: [Int]? = nil) {
        self.id = id
        self.state = state
        self.detail = detail
        self.canSwitch = canSwitch
        self.canMove = canMove
        self.currentBefore = currentBefore
        self.currentAfter = currentAfter
        self.membershipBefore = membershipBefore
        self.membershipAfter = membershipAfter
        self.issuedAtUptime = issuedAtUptime
        self.confirmedAtUptime = confirmedAtUptime
        self.submittedSteps = submittedSteps
        self.switchTrace = switchTrace
        self.originalWindow = originalWindow
        self.observedWindows = observedWindows
        self.observationReasons = observationReasons
        self.observationWorkerPID = observationWorkerPID
        self.observationFacts = observationFacts
        self.withheldOriginals = withheldOriginals
    }
}
