import Foundation

public enum Stability: String, Codable { case transient, stable, stableIncomplete }

public struct Assessment: Codable {
    public var stability: Stability
    public var identicalSamples: Int
    public var requiredSamples: Int
    public var candidateSinceRevision: Int?
    public var latestStableRevision: Int?
    public var topologyEpoch: Int
    public var topologyFingerprint, stateFingerprint: String
    public var transitionReasons, incompleteness: [String]
}

public struct StableDetector {
    public let requiredSamples: Int
    public let maxGapNS, maxSampleDurationNS: UInt64
    private var previous: Sample?
    private var previousStateFingerprint: String?
    private var previousTopologyFingerprint: String?
    private var count = 0
    private var candidateSince: Int?
    private var latestStable: Int?
    private var epoch = 0
    private var pendingMarker = false

    public init(requiredSamples: Int = 3, maxGapNS: UInt64 = 3_000_000_000,
                maxSampleDurationNS: UInt64 = 5_000_000_000) throws {
        guard requiredSamples >= 2, maxGapNS > 0, maxSampleDurationNS > 0 else { throw ObserverError.invalidConfiguration }
        self.requiredSamples = requiredSamples; self.maxGapNS = maxGapNS
        self.maxSampleDurationNS = maxSampleDurationNS
    }

    public mutating func operatorMarker() {
        // A marker is only an operator claim. Conservatively invalidate any pending/stable run.
        count = 0; candidateSince = nil; latestStable = nil; pendingMarker = true
    }

    public mutating func ingest(_ sample: Sample) throws -> Assessment {
        let stateHash = try fingerprint(sample.state)
        let topologyHash = try fingerprint(sample.state.boundary.topology)
        var reasons = try sample.consistencyIssues()
        var unusable = !reasons.isEmpty
        if sample.endedUptimeNS >= sample.startedUptimeNS,
           sample.endedUptimeNS - sample.startedUptimeNS > maxSampleDurationNS {
            reasons.append("sample_too_slow"); unusable = true
        }
        if let previous {
            if sample.revision <= previous.revision || sample.startedUptimeNS <= previous.endedUptimeNS {
                reasons.append("out_of_order_sample"); unusable = true
            } else if sample.startedUptimeNS - previous.endedUptimeNS > maxGapNS {
                reasons.append("sampling_gap")
            }
            if previous.state.boundary.separateSpaces != sample.state.boundary.separateSpaces { reasons.append("mode_changed") }
            if previousStateFingerprint != stateHash { reasons.append("state_changed") }
        } else { reasons.append("initial_sample") }
        if previousTopologyFingerprint != topologyHash {
            epoch += 1
            if previousTopologyFingerprint != nil { reasons.append("topology_changed") }
        }
        if pendingMarker { reasons.append("operator_marker"); pendingMarker = false }
        if !reasons.isEmpty { count = 0; candidateSince = nil; latestStable = nil }
        if !unusable {
            count += 1
            if candidateSince == nil { candidateSince = sample.revision }
        }
        let incomplete = sample.state.incompleteness
        let stability: Stability = count >= requiredSamples ? (incomplete.isEmpty ? .stable : .stableIncomplete) : .transient
        if stability != .transient { latestStable = sample.revision }
        previous = sample; previousStateFingerprint = stateHash; previousTopologyFingerprint = topologyHash
        return Assessment(stability: stability, identicalSamples: count, requiredSamples: requiredSamples,
                          candidateSinceRevision: candidateSince, latestStableRevision: latestStable,
                          topologyEpoch: epoch, topologyFingerprint: topologyHash, stateFingerprint: stateHash,
                          transitionReasons: reasons, incompleteness: incomplete)
    }
}

public enum ObserverError: Error {
    case invalidConfiguration, unsafeOutputDirectory, unsafeOutputFile, outputLimit, ioFailure, invalidMarker
}
