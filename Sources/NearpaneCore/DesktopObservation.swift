import Foundation

public enum SnapshotFreshness: String, Codable, Sendable { case fresh, stale, transient }
public enum IdentityConfidence: String, Codable, Sendable { case synthetic, unknown, geometryOnly, corroboratedMetadata, ambiguous }
public enum UserSpaceSemantics: String, Codable, Sendable { case unknown, witnessedCurrent }
public enum ObservationSupport: String, Codable, Sendable { case mockOnly, degraded, unsupported, readOnly }

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
            throw DecodingError.dataCorruptedError(forKey: .observation, in: values, debugDescription: "Desktop observation cannot enable actions")
        }
        spaceSwitching = false; windowActivation = false
    }
}

public struct DisplayObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let rotationDegrees: Int
    public let backingScale: Double
    /// Usable frame in display-local top-left points; the snapshot frame is global Quartz for native reads.
    public var usable: SurfaceRect?
    public init(id: String, frame: SurfaceRect, rotationDegrees: Int, backingScale: Double, usable: SurfaceRect? = nil) {
        self.id = id; self.frame = frame; self.rotationDegrees = rotationDegrees; self.backingScale = backingScale; self.usable = usable
    }
}

public struct SpaceRecord: Codable, Equatable, Identifiable, Sendable {
    /// Session-local record identity. Never a configuration key or a user-facing desktop number.
    public let id: String
    public let isCurrent: Bool
    /// Optional WindowServer UUID from a type-0 record on a reader-supported build.
    public let ordinaryUUID: UUID?
    /// Type-4 system Space, distinct from an ordinary desktop.
    public let fullscreenUUID: UUID?
    /// Raw read-only type for a record whose system UUID is unavailable. This
    /// preserves inventory evidence; it never supplies a usable desktop identity.
    public let observedNativeType: Int64?
    public fileprivate(set) var previouslyWitnessed = false
    // Only the local Host can add historical evidence after validating the reader's live witness.
    private enum CodingKeys: String, CodingKey { case id, isCurrent, ordinaryUUID, fullscreenUUID, observedNativeType }
    public init(id: String, isCurrent: Bool, ordinaryUUID: UUID? = nil, fullscreenUUID: UUID? = nil,
                observedNativeType: Int64? = nil) {
        self.fullscreenUUID = fullscreenUUID
        self.observedNativeType = observedNativeType
        self.id = id; self.isCurrent = isCurrent; self.ordinaryUUID = ordinaryUUID
    }
}

public struct ManagedDisplayScope: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayID: String
    public let records: [SpaceRecord]
    public init(id: String, displayID: String, records: [SpaceRecord]) { self.id = id; self.displayID = displayID; self.records = records }
}

/// Retains only identities of independently witnessed ordinary desktops. No window data is cached.
public struct WitnessedSpaceHistory {
    private struct Identity: Hashable {
        let display, scope, record: String
        let uuid: UUID
    }
    private var identities = Set<Identity>()
    private var session: UUID?
    private var topology: String?
    private var lastRead: Double?
    private var revision: UInt64 = 0
    public init() {}

    public mutating func apply(to snapshot: inout DesktopSnapshot, now: Date, uptime: Double) {
        if session == snapshot.sessionID && revision >= snapshot.revision { return }
        if session != snapshot.sessionID || topology != snapshot.topologyFingerprint ||
            lastRead.map({ uptime < $0 || uptime - $0 > 12 }) == true {
            identities.removeAll()
        }
        session = snapshot.sessionID
        topology = snapshot.topologyFingerprint
        revision = snapshot.revision
        guard let native = snapshot.native, native.population == .workWindows, native.accessibility != .denied,
              snapshot.displays.count == 1 || snapshot.separateSpaces == true, !native.windowLimitReached else {
            identities.removeAll(); return
        }
        // A switch animation can lose inventory for a sample. Never expose history in that
        // sample; allow re-identification by UUID on the next fresh, complete inventory.
        if native.spaces == .unstable { return }
        guard native.spaces == .observed, snapshot.isStructurallyValid,
              snapshot.nativeIsFresh(now: now, uptime: uptime) else {
            identities.removeAll(); return
        }
        lastRead = uptime
        let uuidGroups = Dictionary(grouping: snapshot.scopes.flatMap(\.records).compactMap(\.ordinaryUUID), by: { $0 })
        var retained = Set<Identity>()
        snapshot.scopes = snapshot.scopes.map { scope in
            let currentWitness = native.rows.first { $0.displayID == scope.displayID && $0.scopeID == scope.id }
            let records = scope.records.map { item in
                var record = item
                guard let uuid = item.ordinaryUUID, uuidGroups[uuid]?.count == 1 else { return record }
                let key = Identity(display: scope.displayID, scope: scope.id, record: item.id, uuid: uuid)
                if (item.isCurrent && currentWitness?.recordID == item.id) || identities.contains(key) {
                    retained.insert(key)
                    record.previouslyWitnessed = !item.isCurrent
                }
                return record
            }
            return ManagedDisplayScope(id: scope.id, displayID: scope.displayID, records: records)
        }
        identities = retained
    }
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
    public var metadata: ObservedWindowMetadata?
    /// Added by the Host after an independent live check. Never accepted from a reader or exported in its wire format.
    public var sidebarOriginalWindow: UUID? = nil
    private enum CodingKeys: String, CodingKey { case id, displayID, bounds, membership, confidence, metadata }
    public init(id: String, displayID: String, bounds: SurfaceRect, membership: WindowMembership,
                confidence: IdentityConfidence, metadata: ObservedWindowMetadata? = nil) {
        self.id = id; self.displayID = displayID; self.bounds = bounds; self.membership = membership
        self.confidence = confidence; self.metadata = metadata
    }
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
    public var native: DesktopReadEvidence? = nil

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
        return (native?.validates(self) ?? (capabilities.observation != .readOnly && userSpaceSemantics == .unknown))
            && revision > 0 && sampledFrom <= sampledTo && !source.isEmpty && !sourceBuild.isEmpty
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

@MainActor
public protocol LiveDesktopObservationProvider: DesktopObservationProvider {
    func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot
    func discardVisitedSpaces()
}

public extension LiveDesktopObservationProvider {
    func discardVisitedSpaces() {}
    func snapshot() async throws -> DesktopSnapshot { try await snapshot(experimentalSpaces: false) }
}

/// Used when the read-only reader is unavailable or a test has not opted into real observation.
@MainActor
public struct UnavailableDesktopProvider: DesktopObservationProvider {
    public init() {}
    public var capabilities: DesktopCapabilities { .init(observation: .unsupported) }
    public func snapshot() async throws -> DesktopSnapshot { throw DesktopActionError.unsupported }
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
