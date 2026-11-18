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

    public func permits(_ request: NativeSpaceCommand, after steps: Int, now: TimeInterval) -> Bool {
        request.action == .select && id == request.id && submittedSteps == steps && proceed && request.isFresh(at: now)
    }
}

public struct NativeSpaceCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case probe, select, move }
    public let id: UUID
    public let action: Action
    public let display, source, target: String
    public let sourceUUID, targetUUID: UUID?
    public let sourceKind, targetKind: NativeSpaceKind
    public let createdAtUptime: TimeInterval
    public let window: NativeSpaceWindow?
    public var deadlineUptime: TimeInterval { createdAtUptime + 5 }
    public func isFresh(at now: TimeInterval) -> Bool {
        createdAtUptime.isFinite && now >= createdAtUptime && now < deadlineUptime
    }

    public init(id: UUID, action: Action, display: String, source: String, target: String,
                sourceUUID: UUID? = nil, targetUUID: UUID? = nil, window: NativeSpaceWindow? = nil,
                sourceKind: NativeSpaceKind = .ordinary, targetKind: NativeSpaceKind = .ordinary,
                createdAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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

    public init(id: UUID, state: State, detail: String, canSwitch: Bool, canMove: Bool,
                currentBefore: [String: String]? = nil, currentAfter: [String: String]? = nil,
                membershipBefore: [String]? = nil, membershipAfter: [String]? = nil,
                issuedAtUptime: TimeInterval? = nil, confirmedAtUptime: TimeInterval? = nil, submittedSteps: Int = 0) {
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
    }
}
