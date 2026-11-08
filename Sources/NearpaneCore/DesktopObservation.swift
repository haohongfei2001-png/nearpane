import Foundation

public enum SnapshotFreshness: String, Codable, Sendable { case fresh, stale, transient }
public enum IdentityConfidence: String, Codable, Sendable { case synthetic, unknown }
public enum UserSpaceSemantics: String, Codable, Sendable { case unknown }
public enum ObservationSupport: String, Codable, Sendable { case mockOnly, degraded, unsupported }

public struct DesktopCapabilities: Codable, Equatable, Sendable {
    public var observation: ObservationSupport = .mockOnly
    public let spaceSwitching: Bool
    public let windowActivation: Bool
    public init(observation: ObservationSupport = .mockOnly) {
        self.observation = observation; spaceSwitching = false; windowActivation = false
    }

    private enum CodingKeys: String, CodingKey { case observation, spaceSwitching, windowActivation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        observation = try values.decode(ObservationSupport.self, forKey: .observation)
        guard try !values.decode(Bool.self, forKey: .spaceSwitching),
              try !values.decode(Bool.self, forKey: .windowActivation) else {
            throw DecodingError.dataCorruptedError(forKey: .observation, in: values, debugDescription: "P2 supports observation fixtures only")
        }
        spaceSwitching = false; windowActivation = false
    }
}

public struct DisplayObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let rotationDegrees: Int
    public let backingScale: Double
}

public struct SpaceRecord: Codable, Equatable, Identifiable, Sendable {
    /// Session-local synthetic identity. Never a configuration key or a user-facing desktop number.
    public let id: String
    public let isCurrent: Bool
}

public struct ManagedDisplayScope: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayID: String
    public let records: [SpaceRecord]
}

public enum WindowMembership: Codable, Equatable, Sendable {
    case known(recordIDs: [String])
    case unknown
}

public struct WindowObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayID: String
    /// Display-local top-left logical points; NOT raw CG/AX/AppKit global coordinates.
    public let bounds: SurfaceRect
    public let membership: WindowMembership
    public let confidence: IdentityConfidence
}

public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var sessionID: UUID
    public var sampledFrom: Date
    public var sampledTo: Date
    public var source: String
    public var sourceBuild: String
    public var freshness: SnapshotFreshness
    public var topologyFingerprint: String
    public var topologyConsistent: Bool
    public var identityConfidence: IdentityConfidence
    public var capabilities: DesktopCapabilities
    public var separateSpaces: Bool?
    public var userSpaceSemantics: UserSpaceSemantics
    public var displays: [DisplayObservation]
    public var scopes: [ManagedDisplayScope]
    public var windows: [WindowObservation]

    public func effectiveFreshness(at now: Date, maxAge: TimeInterval = 10) -> SnapshotFreshness {
        if freshness == .transient || !topologyConsistent { return .transient }
        if freshness == .stale || sampledTo > now || now.timeIntervalSince(sampledTo) > maxAge { return .stale }
        return .fresh
    }

    public var isStructurallyValid: Bool {
        let displayIDs = Set(displays.map(\.id))
        let scopeIDs = Set(scopes.map(\.id))
        let recordIDs = scopes.flatMap(\.records).map(\.id)
        let records = Set(recordIDs)
        return revision > 0 && sampledFrom <= sampledTo && !source.isEmpty && !sourceBuild.isEmpty
            && !topologyFingerprint.isEmpty && !displays.isEmpty
            && displayIDs.count == displays.count && scopeIDs.count == scopes.count
            && recordIDs.count == records.count && Set(windows.map(\.id)).count == windows.count
            && displays.allSatisfy {
                [$0.frame.x, $0.frame.y, $0.frame.width, $0.frame.height, $0.backingScale].allSatisfy(\.isFinite)
                    && $0.frame.width > 0 && $0.frame.height > 0 && $0.backingScale > 0
            }
            && scopes.allSatisfy { displayIDs.contains($0.displayID) && $0.records.filter(\.isCurrent).count <= 1 }
            && windows.allSatisfy { window in
                guard displayIDs.contains(window.displayID),
                      [window.bounds.x, window.bounds.y, window.bounds.width, window.bounds.height].allSatisfy(\.isFinite),
                      window.bounds.width >= 0, window.bounds.height >= 0 else { return false }
                if case .known(let ids) = window.membership { return Set(ids).isSubset(of: records) }
                return true
            }
    }
}

@MainActor
public protocol DesktopObservationProvider {
    var capabilities: DesktopCapabilities { get }
    func snapshot() async throws -> DesktopSnapshot
}

public struct DesktopTarget: Equatable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let runtimeID: String
    public init(sessionID: UUID, revision: UInt64, runtimeID: String) {
        self.sessionID = sessionID; self.revision = revision; self.runtimeID = runtimeID
    }
}

@MainActor
public protocol DesktopActionProvider {
    func switchToSpace(_ target: DesktopTarget) async throws
    func activateWindow(_ target: DesktopTarget) async throws
}

public enum DesktopActionError: Error { case unsupported }

/// The only action adapter shipped in P2. It cannot perform any OS action.
@MainActor
public struct UnsupportedDesktopActionProvider: DesktopActionProvider {
    public init() {}
    public func switchToSpace(_ target: DesktopTarget) async throws { throw DesktopActionError.unsupported }
    public func activateWindow(_ target: DesktopTarget) async throws { throw DesktopActionError.unsupported }
}
