import Foundation

/// PID alone is never an incarnation. Missing launch evidence remains unknown.
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let launchEpochMicroseconds: UInt64?
    public init(pid: Int32, launchEpochMicroseconds: UInt64?) {
        self.pid = pid; self.launchEpochMicroseconds = launchEpochMicroseconds
    }
    public var hasLifecycleEvidence: Bool { pid > 0 && (launchEpochMicroseconds ?? 0) > 0 }
}

public struct CGWindowMetadata: Equatable, Sendable {
    public let process: ProcessIdentity
    public let windowID: UInt32
    public let title: String?
    public let frame: Rect
    public let layer: Int
    public let isOnscreen: Bool?
    public let frontToBackIndex: Int
    public init(process: ProcessIdentity, windowID: UInt32, title: String?, frame: Rect,
                layer: Int = 0, isOnscreen: Bool? = true, frontToBackIndex: Int = 0) {
        self.process = process; self.windowID = windowID; self.title = title; self.frame = frame
        self.layer = layer; self.isOnscreen = isOnscreen; self.frontToBackIndex = frontToBackIndex
    }
}

/// CG reports the on-screen presentation. A matching window identity alone does not
/// establish that its presentation is the ordinary AX window frame.
public enum WindowPresentationGeometry: String, Sendable {
    case confirmed, divergent, notOnScreen, unconfirmed

    public init(cg: Rect, ax: Rect?, onScreen: Bool?) {
        guard onScreen != false else { self = .notOnScreen; return }
        guard onScreen == true, cg.isValid, let ax, ax.isValid else { self = .unconfirmed; return }
        self = cg == ax ? .confirmed : .divergent
    }
}

public struct AXWindowMetadata: Equatable, Sendable {
    public let process: ProcessIdentity
    /// Observer-local nonce bound to a retained AXUIElement, never an AX array index.
    public let elementToken: UUID
    public let identifier: String?
    public let title: String?
    public let role: String?
    public let subrole: String?
    public let frame: Rect?
    public let minimized: Bool?
    /// Positive AX window-number read for a standard window, independent of title/position matching.
    public let standardWindowNumber: UInt32?
    public init(process: ProcessIdentity, elementToken: UUID, identifier: String?, title: String?,
                role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
                frame: Rect?, minimized: Bool? = false, standardWindowNumber: UInt32? = nil) {
        self.process = process; self.elementToken = elementToken; self.identifier = identifier
        self.title = title; self.role = role; self.subrole = subrole
        self.frame = frame; self.minimized = minimized
        self.standardWindowNumber = standardWindowNumber
    }
}

public enum IdentityConfidence: String, Sendable {
    case corroboratedMetadata, geometryOnly, ambiguous, unknown
}
public struct WindowMatch: Equatable, Sendable {
    public let cgIndex: Int
    public let axCandidateIndices: [Int]
    public let confidence: IdentityConfidence
    public let reason: String
}

/// Conservative bipartite matching: both ends must have degree one.
/// AXIdentifier is not a public CGWindowID bridge and does not increase confidence.
public enum WindowMatcher {
    public static func matches(cg: [CGWindowMetadata], ax: [AXWindowMetadata],
                               tolerance: Double = 2) -> [WindowMatch] {
        guard tolerance.isFinite, tolerance >= 0, tolerance <= 2 else {
            return cg.indices.map { WindowMatch(cgIndex: $0, axCandidateIndices: [],
                                                confidence: .unknown, reason: "invalidTolerance") }
        }
        func nonempty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value // Do not normalize potentially distinguishing titles.
        }
        let edges = cg.map { window in
            ax.indices.filter { index in
                let candidate = ax[index]
                guard window.windowID != 0, window.frame.isValid, window.process.hasLifecycleEvidence,
                      candidate.process == window.process, candidate.role == "AXWindow",
                      let frame = candidate.frame, frame.isValid,
                      window.frame.componentError(from: frame) <= tolerance else { return false }
                if let a = nonempty(window.title), let b = nonempty(candidate.title) { return a == b }
                return true
            }
        }
        return cg.indices.map { index in
            let candidates = edges[index]
            let duplicateCG = cg.filter { $0.windowID == cg[index].windowID }.count > 1
            let duplicateAX = candidates.contains { a in
                ax.filter { $0.elementToken == ax[a].elementToken }.count > 1
            }
            let sharedAX = candidates.contains { a in edges.filter { $0.contains(a) }.count > 1 }
            if duplicateCG || duplicateAX || sharedAX || candidates.count > 1 {
                return WindowMatch(cgIndex: index, axCandidateIndices: candidates,
                                   confidence: .ambiguous, reason: "nonUniqueCorrespondence")
            }
            guard let candidate = candidates.first else {
                return WindowMatch(cgIndex: index, axCandidateIndices: [], confidence: .unknown,
                                   reason: cg[index].process.hasLifecycleEvidence ? "noCandidate" : "missingLifecycle")
            }
            let corroborated = nonempty(cg[index].title) != nil
                && nonempty(cg[index].title) == nonempty(ax[candidate].title)
            return WindowMatch(cgIndex: index, axCandidateIndices: candidates,
                               confidence: corroborated ? .corroboratedMetadata : .geometryOnly,
                               reason: corroborated ? "uniquePIDLaunchTitleFrameRole" : "missingComparableTitle")
        }
    }
}

public struct SnapshotStamp: Equatable, Sendable {
    public let observerSession: UUID
    public let revision: UInt64
    public let sourceBuild: String
    public let topologyToken: String
    public let beganUptime: Double
    public let endedUptime: Double
    public let consistent: Bool
    public init(observerSession: UUID, revision: UInt64, sourceBuild: String, topologyToken: String,
                beganUptime: Double, endedUptime: Double, consistent: Bool) {
        self.observerSession = observerSession; self.revision = revision
        self.sourceBuild = sourceBuild
        self.topologyToken = topologyToken; self.beganUptime = beganUptime
        self.endedUptime = endedUptime; self.consistent = consistent
    }
}
public struct WindowSnapshot: Sendable {
    public let stamp: SnapshotStamp
    public let cg: [CGWindowMetadata]
    public let ax: [AXWindowMetadata]
    public let complete: Bool
    public init(stamp: SnapshotStamp, cg: [CGWindowMetadata], ax: [AXWindowMetadata], complete: Bool) {
        self.stamp = stamp; self.cg = cg; self.ax = ax; self.complete = complete
    }
}

public enum TargetRejection: String, Error, Equatable {
    case invalidSnapshot, expired, missingLifecycle, notFound, ambiguous, insufficientEvidence
    case sessionChanged, revisionChanged, sourceChanged, topologyChanged, processChanged, axElementChanged, metadataChanged
    case notVisibleStandardWindow
}

/// A short-lived observation reference, NOT an activation capability. No Codable conformance.
/// All fields are immutable; construction is restricted to the resolver.
public struct WindowTarget: Equatable, Sendable {
    public let stamp: SnapshotStamp
    public let cg: CGWindowMetadata
    public let ax: AXWindowMetadata
    public let confidence: IdentityConfidence
    fileprivate init(stamp: SnapshotStamp, cg: CGWindowMetadata, ax: AXWindowMetadata) {
        self.stamp = stamp; self.cg = cg; self.ax = ax; self.confidence = .corroboratedMetadata
    }
}

public struct TargetPolicy: Sendable {
    public let maximumAge: Double
    public let maximumSamplingDuration: Double
    public init(maximumAge: Double = 0.5, maximumSamplingDuration: Double = 0.25) {
        self.maximumAge = maximumAge; self.maximumSamplingDuration = maximumSamplingDuration
    }
}

public enum TargetResolver {
    private static func check(_ snapshot: WindowSnapshot, now: Double, policy: TargetPolicy) throws {
        let stamp = snapshot.stamp
        guard snapshot.complete, stamp.consistent, stamp.revision > 0,
              !stamp.sourceBuild.isEmpty, !stamp.topologyToken.isEmpty,
              [now, stamp.beganUptime, stamp.endedUptime, policy.maximumAge,
               policy.maximumSamplingDuration].allSatisfy(\.isFinite),
              stamp.beganUptime >= 0, stamp.endedUptime >= stamp.beganUptime,
              now >= stamp.endedUptime, policy.maximumAge > 0, policy.maximumSamplingDuration > 0,
              stamp.endedUptime - stamp.beganUptime <= policy.maximumSamplingDuration else {
            throw TargetRejection.invalidSnapshot
        }
        // Count age from START, not the end of an arbitrarily slow read.
        guard now - stamp.beganUptime <= policy.maximumAge else { throw TargetRejection.expired }
    }

    public static func issue(windowID: UInt32, in snapshot: WindowSnapshot, now: Double,
                             policy: TargetPolicy = TargetPolicy()) throws -> WindowTarget {
        try check(snapshot, now: now, policy: policy)
        let indices = snapshot.cg.indices.filter { snapshot.cg[$0].windowID == windowID }
        guard !indices.isEmpty else { throw TargetRejection.notFound }
        guard indices.count == 1 else { throw TargetRejection.ambiguous }
        let index = indices[0], cg = snapshot.cg[index]
        guard cg.process.hasLifecycleEvidence else { throw TargetRejection.missingLifecycle }
        let match = WindowMatcher.matches(cg: snapshot.cg, ax: snapshot.ax)[index]
        if match.confidence == .ambiguous { throw TargetRejection.ambiguous }
        guard match.confidence == .corroboratedMetadata, let axIndex = match.axCandidateIndices.first else {
            throw TargetRejection.insufficientEvidence
        }
        let ax = snapshot.ax[axIndex]
        guard cg.layer == 0, cg.isOnscreen == true, cg.frontToBackIndex >= 0,
              ax.minimized == false, ax.subrole == "AXStandardWindow" else {
            throw TargetRejection.notVisibleStandardWindow
        }
        guard WindowPresentationGeometry(cg: cg.frame, ax: ax.frame, onScreen: cg.isOnscreen) == .confirmed else {
            throw TargetRejection.insufficientEvidence
        }
        return WindowTarget(stamp: snapshot.stamp, cg: cg, ax: ax)
    }

    /// Even identical metadata in a later revision must be explicitly re-resolved.
    /// Success confirms only this observation; it does not authorize a system action.
    public static func validate(_ target: WindowTarget, in snapshot: WindowSnapshot, now: Double,
                                policy: TargetPolicy = TargetPolicy()) throws {
        guard target.stamp.observerSession == snapshot.stamp.observerSession else { throw TargetRejection.sessionChanged }
        guard target.stamp.sourceBuild == snapshot.stamp.sourceBuild else { throw TargetRejection.sourceChanged }
        guard target.stamp.topologyToken == snapshot.stamp.topologyToken else { throw TargetRejection.topologyChanged }
        guard target.stamp.revision == snapshot.stamp.revision else { throw TargetRejection.revisionChanged }
        try check(snapshot, now: now, policy: policy)
        guard target.stamp == snapshot.stamp else { throw TargetRejection.invalidSnapshot }
        let current = try issue(windowID: target.cg.windowID, in: snapshot, now: now, policy: policy)
        guard target.cg.process == current.cg.process else { throw TargetRejection.processChanged }
        guard target.ax.elementToken == current.ax.elementToken else { throw TargetRejection.axElementChanged }
        guard target.cg == current.cg, target.ax == current.ax else { throw TargetRejection.metadataChanged }
    }
}
