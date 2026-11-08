import Foundation

public enum DesktopFixture: String, Codable, CaseIterable, Identifiable, Sendable {
    case singleDisplay, twoDisplays, threeDisplays, internalScopes3Plus1, rotatedDisplay
    case unknownMembership, stale, transient

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .singleDisplay: "One synthetic display"
        case .twoDisplays: "Two synthetic displays"
        case .threeDisplays: "Three synthetic displays"
        case .internalScopes3Plus1: "3+1 internal records · semantics unknown"
        case .rotatedDisplay: "Rotated synthetic display"
        case .unknownMembership: "Unknown window membership"
        case .stale: "Stale snapshot"
        case .transient: "Transient topology"
        }
    }

    public func makeSnapshot(revision: UInt64 = 1, sessionID: UUID = UUID(), now: Date = Date()) -> DesktopSnapshot {
        let count = self == .threeDisplays ? 3 : (self == .singleDisplay ? 1 : 2)
        let rotated = self == .rotatedDisplay || self == .internalScopes3Plus1
        let displays = (0..<count).map { index in
            DisplayObservation(id: "fixture-display-\(index)",
                frame: SurfaceRect(x: index == 1 ? -1080 : Double(index) * 1440,
                                   y: index == 2 ? -900 : 0,
                                   width: index == 1 && rotated ? 1080 : 1440,
                                   height: index == 1 && rotated ? 1920 : 900),
                rotationDegrees: index == 1 && rotated ? 90 : 0, backingScale: index == 0 ? 2 : 1)
        }
        let scopes = displays.enumerated().map { index, display in
            ManagedDisplayScope(id: "fixture-scope-\(index)", displayID: display.id,
                records: (0..<(index == 0 ? 3 : 1)).map {
                    SpaceRecord(id: "fixture-record-\(index)-\($0)", isCurrent: $0 == 0)
                })
        }
        let windows = displays.enumerated().flatMap { index, display in
            [
                WindowObservation(id: "fixture-window-\(index)-a", displayID: display.id,
                    bounds: SurfaceRect(x: 40, y: 32, width: 640, height: 720),
                    membership: self == .unknownMembership ? .unknown : .known(recordIDs: [scopes[index].records[0].id]),
                    confidence: self == .unknownMembership ? .unknown : .synthetic),
                WindowObservation(id: "fixture-window-\(index)-b", displayID: display.id,
                    bounds: SurfaceRect(x: 200, y: 100, width: 500, height: 600),
                    membership: index == 0 ? .known(recordIDs: scopes[0].records.prefix(2).map(\.id)) : .known(recordIDs: []),
                    confidence: .synthetic)
            ]
        }
        return DesktopSnapshot(revision: revision, sessionID: sessionID,
            sampledFrom: now.addingTimeInterval(self == .stale ? -121 : -0.01),
            sampledTo: now.addingTimeInterval(self == .stale ? -120 : 0),
            source: "synthetic-fixture", sourceBuild: "P2-fixtures-v1",
            freshness: self == .stale ? .stale : (self == .transient ? .transient : .fresh),
            topologyFingerprint: "fixture-\(count)-\(rotated)-\(self == .transient)",
            topologyConsistent: self != .transient, identityConfidence: .synthetic,
            capabilities: DesktopCapabilities(observation: self == .transient ? .degraded : .mockOnly),
            separateSpaces: self == .internalScopes3Plus1 ? false : nil,
            userSpaceSemantics: .unknown, displays: displays, scopes: scopes, windows: windows)
    }
}

@MainActor
public final class MockDesktopObservationProvider: DesktopObservationProvider {
    public var fixture: DesktopFixture
    public let sessionID = UUID()
    private var revision: UInt64 = 0
    public var capabilities: DesktopCapabilities { DesktopCapabilities() }
    public init(fixture: DesktopFixture = .internalScopes3Plus1) { self.fixture = fixture }

    public func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        revision += 1
        return fixture.makeSnapshot(revision: revision, sessionID: sessionID)
    }
}
