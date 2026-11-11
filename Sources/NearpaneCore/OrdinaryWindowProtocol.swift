import Foundation

/// Anonymous pipes connect the signed Host to one short-lived worker scoped to one process incarnation.
public struct OrdinaryWindowRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case list, refresh, prepare, verify, write, release }
    public let nonce: UUID, action: Action, pid: Int32, launch: UInt64, bundle: String
    public let id: ManagedWindowID?, expected: SurfaceRect?, destination: SurfaceRect?

    public init(_ action: Action, pid: Int32, launch: UInt64, bundle: String,
                id: ManagedWindowID? = nil, expected: SurfaceRect? = nil, destination: SurfaceRect? = nil) {
        self.nonce = UUID()
        self.action = action
        self.pid = pid
        self.launch = launch
        self.bundle = bundle
        self.id = id
        self.expected = expected
        self.destination = destination
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
    public var steps: [OrdinaryWindowStep]?
    public var choices: [ManagedWindowID?]?, pair: AdmissionPair?, failure: String?
    public var closure: OrdinaryWindowClosure?
    public init(_ nonce: UUID) { self.nonce = nonce }
}
