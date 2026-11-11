import Foundation

/// Anonymous pipes connect the signed Host to one short-lived worker scoped to one process incarnation.
public struct OrdinaryWindowRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case list, prepare, verify, write, release }
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

public struct OrdinaryWindowReply: Codable, Sendable {
    public let nonce: UUID
    public var steps: [OrdinaryWindowStep]?
    public var choices: [ManagedWindowID?]?, pair: AdmissionPair?, failure: String?
    public init(_ nonce: UUID) { self.nonce = nonce }
}
