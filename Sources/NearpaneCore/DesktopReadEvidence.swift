import CoreFoundation
import Foundation
import WindowGeometryCore

public extension SurfaceRect {
    var geometry: Rect { Rect(x, y, width, height) }
    init(_ rect: Rect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

/// The preference describes this login's configuration, not the presentation of a particular window.
public enum StageManagerPreference {
    public static func read() -> Bool? {
        guard let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}

public enum DesktopReadPopulation: String, Codable, Sendable { case workWindows, markedFixture }
public enum SpaceReadStatus: String, Codable, Sendable { case disabled, unsupportedBuild, unavailable, unstable, observed }
public enum AXReadStatus: String, Codable, Sendable { case available, denied, partial }

public struct ObservedWindowMetadata: Codable, Equatable, Sendable {
    public let number: UInt32
    public let pid: Int32
    public let launchMicroseconds: UInt64?
    public let element: UUID?
    public let globalFrame: SurfaceRect
    public let axFrame: SurfaceRect?
    /// Returned by the unique, twice-read standard AX window. May be absent in an older sample.
    public let axStandardWindowNumber: UInt32?
    public let isOnscreen: Bool?
    public var presentation: WindowPresentationGeometry {
        .init(cg: globalFrame.geometry, ax: axFrame?.geometry, onScreen: isOnscreen)
    }
    public let frontToBack: Int
    public let minimized, fullScreen: Bool?
    public init(number: UInt32, pid: Int32, launchMicroseconds: UInt64?, element: UUID?, globalFrame: SurfaceRect,
                frontToBack: Int, minimized: Bool?, fullScreen: Bool?, axFrame: SurfaceRect? = nil, isOnscreen: Bool? = nil,
                axStandardWindowNumber: UInt32? = nil) {
        self.number = number; self.pid = pid; self.launchMicroseconds = launchMicroseconds; self.element = element
        self.globalFrame = globalFrame; self.frontToBack = frontToBack; self.minimized = minimized; self.fullScreen = fullScreen
        self.axFrame = axFrame; self.isOnscreen = isOnscreen; self.axStandardWindowNumber = axStandardWindowNumber
    }
}

public extension WindowObservation {
    /// Membership and active-Space visibility are checked separately by the reader.
    var canWitnessCurrentSpace: Bool {
        guard confidence == .geometryOnly || confidence == .corroboratedMetadata,
              let m = metadata, m.number > 0, m.axStandardWindowNumber == m.number,
              m.pid > 0, (m.launchMicroseconds ?? 0) > 0, m.element != nil else { return false }
        return m.presentation == .confirmed && m.fullScreen == false && m.minimized == false
    }
}

public enum ActiveSpaceWitness: String, Codable, Sendable { case ownedWindow, appKitActiveList }

/// Identifies the independent public AppKit observation used to attest the current record.
public struct ActiveSpaceAnchor: Equatable, Codable, Sendable {
    public let number: UInt32
    public let displayID: String
    public let globalFrame: SurfaceRect
    public let witness: ActiveSpaceWitness
    public init(number: UInt32, displayID: String, globalFrame: SurfaceRect, witness: ActiveSpaceWitness = .ownedWindow) {
        self.number = number; self.displayID = displayID; self.globalFrame = globalFrame; self.witness = witness
    }
}

public struct ObservedSpaceRow: Equatable, Codable, Sendable {
    public let displayID, scopeID, recordID: String
    public let anchor: ActiveSpaceAnchor
    public init(displayID: String, scopeID: String, recordID: String, anchor: ActiveSpaceAnchor) {
        self.displayID = displayID; self.scopeID = scopeID; self.recordID = recordID; self.anchor = anchor
    }
}

public struct DesktopReadRequest: Codable, Sendable {
    public let version: Int
    public let session: UUID
    public let revision: UInt64
    public let parentPID: Int32
    /// nil samples ordinary work windows. A non-nil allowlist admits only these windows of parentPID.
    public let fixtureWindows: [UInt32]?
    public let anchors: [ActiveSpaceAnchor]
    public let experimentalSpaces: Bool
    public init(session: UUID, revision: UInt64, parentPID: Int32, fixtureWindows: [UInt32]?,
                anchors: [ActiveSpaceAnchor], experimentalSpaces: Bool) {
        version = 1; self.session = session; self.revision = revision; self.parentPID = parentPID
        self.fixtureWindows = fixtureWindows; self.anchors = anchors; self.experimentalSpaces = experimentalSpaces
    }
}

public struct DesktopReadEvidence: Equatable, Codable, Sendable {
    public let population: DesktopReadPopulation
    public let accessibility: AXReadStatus
    public var spaces: SpaceReadStatus
    public var rows: [ObservedSpaceRow]
    /// Read-only system preference, independent of any individual window's presentation.
    public let stageManagerEnabled: Bool?
    public let windowLimitReached: Bool
    public let beganUptime, endedUptime: Double

    public init(population: DesktopReadPopulation, accessibility: AXReadStatus, spaces: SpaceReadStatus,
                rows: [ObservedSpaceRow], windowLimitReached: Bool, beganUptime: Double, endedUptime: Double, stageManagerEnabled: Bool? = nil) {
        self.stageManagerEnabled = stageManagerEnabled
        self.population = population; self.accessibility = accessibility; self.spaces = spaces; self.rows = rows
        self.windowLimitReached = windowLimitReached; self.beganUptime = beganUptime; self.endedUptime = endedUptime
    }

    func validates(_ snapshot: DesktopSnapshot) -> Bool {
        guard snapshot.source == "macos-window-server", snapshot.capabilities.observation == .readOnly,
              beganUptime.isFinite, endedUptime.isFinite, beganUptime >= 0, endedUptime >= beganUptime,
              snapshot.displays.allSatisfy({ d in
                  guard let usable = d.usable?.geometry, usable.isValid else { return false }
                  return usable.intersection(Rect(0, 0, d.frame.width, d.frame.height)) == usable
              }), Set(rows.map(\.displayID)).count == rows.count, Set(rows.map(\.recordID)).count == rows.count,
              Set(snapshot.windows.compactMap { $0.metadata?.frontToBack }).count == snapshot.windows.count,
              Set(snapshot.windows.compactMap { $0.metadata?.number }).count == snapshot.windows.count,
              snapshot.userSpaceSemantics == (rows.isEmpty ? .unknown : .witnessedCurrent) else { return false }
        if spaces != .observed && (!rows.isEmpty || !snapshot.scopes.isEmpty) { return false }
        if !rows.isEmpty && (!snapshot.topologyConsistent || windowLimitReached ||
            (snapshot.displays.count > 1 && snapshot.separateSpaces != true)) { return false }
        for row in rows {
            guard row.anchor.number > 0, row.displayID == row.anchor.displayID,
                  let display = snapshot.displays.first(where: { $0.id == row.displayID }),
                  display.frame.geometry.intersection(row.anchor.globalFrame.geometry) == row.anchor.globalFrame.geometry,
                  snapshot.scopes.contains(where: { scope in
                      scope.id == row.scopeID && scope.displayID == row.displayID &&
                      scope.records.contains { $0.id == row.recordID && $0.isCurrent }
                  }) else { return false }
            if row.anchor.witness == .appKitActiveList {
                guard population == .workWindows, snapshot.windows.contains(where: {
                    $0.metadata?.number == row.anchor.number && $0.metadata?.globalFrame == row.anchor.globalFrame &&
                    $0.displayID == row.displayID && $0.canWitnessCurrentSpace &&
                    $0.membership == .known(recordIDs: [row.recordID])
                }) else { return false }
            }
        }
        return snapshot.windows.allSatisfy { w in
            guard let m = w.metadata, m.number > 0, m.pid > 0, m.frontToBack >= 0, m.globalFrame.geometry.isValid,
                  w.confidence != .synthetic else { return false }
            guard let display = snapshot.displays.first(where: { $0.id == w.displayID }),
                  m.globalFrame.geometry.intersection(display.frame.geometry) != nil,
                  w.bounds == SurfaceRect(x: m.globalFrame.x - display.frame.x, y: m.globalFrame.y - display.frame.y,
                                          width: m.globalFrame.width, height: m.globalFrame.height) else { return false }
            if let ax = m.axFrame, !ax.geometry.isValid { return false }
            if w.confidence == .corroboratedMetadata && (m.element == nil || m.axFrame == nil || (m.launchMicroseconds ?? 0) == 0) { return false }
            if case let .known(ids) = w.membership {
                return spaces == .observed && !ids.isEmpty && Set(ids).count == ids.count
            }
            return true
        }
    }
}

public extension DesktopSnapshot {
    static func observed(_ request: DesktopReadRequest, from: Date, to: Date, build: String, topology: String,
                         consistent: Bool, separateSpaces: Bool, displays: [DisplayObservation],
                         scopes: [ManagedDisplayScope], windows: [WindowObservation], evidence: DesktopReadEvidence) -> Self {
        Self(revision: request.revision, sessionID: request.session, sampledFrom: from, sampledTo: to,
             source: "macos-window-server", sourceBuild: build, freshness: consistent ? .fresh : .transient,
             topologyFingerprint: topology, topologyConsistent: consistent, identityConfidence: .unknown,
             capabilities: .init(observation: .readOnly), separateSpaces: separateSpaces,
             userSpaceSemantics: evidence.rows.isEmpty ? .unknown : .witnessedCurrent,
             displays: displays, scopes: scopes, windows: windows, native: evidence)
    }

    /// A reference is meaningful only during this exact sample, including the process and AX incarnation.
    func containsObservation(_ window: WindowObservation, target: DesktopTarget, now: Date, uptime: Double) -> Bool {
        guard nativeIsFresh(now: now, uptime: uptime), target.sessionID == sessionID, target.revision == revision,
              target.runtimeID == window.id, window.confidence == .corroboratedMetadata,
              window.metadata?.presentation == .confirmed else { return false }
        return windows.first(where: { $0.id == target.runtimeID }) == window
    }

    func nativeIsFresh(now: Date, uptime: Double) -> Bool {
        guard let native, effectiveFreshness(at: now, maxAge: 12) == .fresh else { return false }
        return uptime >= native.endedUptime && uptime - native.beganUptime <= 12 &&
            native.endedUptime - native.beganUptime <= 3
    }
}
