import Foundation

public enum StageWindowBackend: String, Codable, CaseIterable, Sendable { case corner, spaces }

/// Fingerprint of the measured install and physical display configuration. A different install, SIP posture,
/// OS build, window class, resolution, refresh rate or topology needs its own qualification.
public struct StageEngineEnvironment: Equatable, Codable, Sendable {
    public let osBuild, engineRevision, hostCDHash, hardware, topology, windowClass: String
    public let sipEnabled: Bool
    public init(osBuild: String, engineRevision: String, hostCDHash: String, hardware: String,
                topology: String, windowClass: String, sipEnabled: Bool) {
        self.osBuild = osBuild; self.engineRevision = engineRevision; self.hostCDHash = hostCDHash
        self.hardware = hardware; self.topology = topology; self.windowClass = windowClass; self.sipEnabled = sipEnabled
    }
    var complete: Bool {
        !osBuild.isEmpty && !hardware.isEmpty && !topology.isEmpty && !windowClass.isEmpty && sipEnabled &&
        [engineRevision,hostCDHash].allSatisfy { $0.utf8.count == 40 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    }
}

public enum StageEngineCheck: String, Codable, CaseIterable, Hashable, Sendable {
    case independentlyObserved, twoAppsThreeWindows, sameAppSiblings, unmanagedBystanders, preminimizedAndDockUnchanged
    case exactKeyboardReceiver, nativeTakeovers, topologyChanges, normalQuitRecovery, crashRecovery, tenTransitions, fiftyTransitions
    case cornerGeometryAndClamp, sliverAndBorders, completeMouseSequences, systemSurfacesClickable, freshZOrderAndMarker
    case eventTapRevocation, inputPermissionsAndSecureInput
    case exactSIPBuild, validatedRoute, memberMembershipEachWay, applicationReactivation, modalPanels
    case allMissionControlEntrances, exposeFullscreenSplitView, physicalMultiDisplay, loginRecovery, skyLightLoss
    public static func required(for backend: StageWindowBackend) -> Set<Self> {
        let common: Set<Self> = [.independentlyObserved,.twoAppsThreeWindows,.sameAppSiblings,.unmanagedBystanders,
            .preminimizedAndDockUnchanged,.exactKeyboardReceiver,.nativeTakeovers,.topologyChanges,
            .normalQuitRecovery,.crashRecovery,.tenTransitions,.fiftyTransitions]
        switch backend {
        case .corner: return common.union([.cornerGeometryAndClamp,.sliverAndBorders,.completeMouseSequences,
            .systemSurfacesClickable,.freshZOrderAndMarker,.eventTapRevocation,.inputPermissionsAndSecureInput])
        case .spaces: return common.union([.exactSIPBuild,.validatedRoute,.memberMembershipEachWay,.applicationReactivation,
            .modalPanels,.allMissionControlEntrances,.exposeFullscreenSplitView,.physicalMultiDisplay,.loginRecovery,.skyLightLoss])
        }
    }
}

public enum StageEngineFinding: String, Codable, Sendable { case pass, fail, unknown, notRun, blocked }

/// Same-device independent measurements. Keep each tail so a faster median cannot conceal a regression.
public struct StageEngineComparison: Codable, Equatable, Sendable {
    public struct Latency: Codable, Equatable, Sendable {
        public let p50, p95, p99: Double
        public init(p50: Double, p95: Double, p99: Double) { self.p50 = p50; self.p95 = p95; self.p99 = p99 }
        var valid: Bool { p50 >= 0 && p50 <= p95 && p95 <= p99 && p99.isFinite }
    }
    public let protocolDigest: String, samplesPerDirection: Int
    public let firstFrame, interactive, settled: Latency
    public let longestSettling, frameGapP99, droppedFramePercent, idleCPU, burstCPU, windowServerCPU, replaydCPU, memoryMB: Double

    public init(protocolDigest: String, samplesPerDirection: Int, firstFrame: Latency, interactive: Latency, settled: Latency,
                longestSettling: Double, frameGapP99: Double, droppedFramePercent: Double,
                idleCPU: Double, burstCPU: Double, windowServerCPU: Double, replaydCPU: Double, memoryMB: Double) {
        self.protocolDigest = protocolDigest; self.samplesPerDirection = samplesPerDirection
        self.firstFrame = firstFrame; self.interactive = interactive; self.settled = settled; self.longestSettling = longestSettling
        self.frameGapP99 = frameGapP99; self.droppedFramePercent = droppedFramePercent; self.idleCPU = idleCPU
        self.burstCPU = burstCPU; self.windowServerCPU = windowServerCPU; self.replaydCPU = replaydCPU; self.memoryMB = memoryMB
    }
    private var values: [Double] {
        [firstFrame,interactive,settled].flatMap { [$0.p50,$0.p95,$0.p99] } +
            [longestSettling,frameGapP99,droppedFramePercent,idleCPU,burstCPU,windowServerCPU,replaydCPU,memoryMB]
    }
    private var comparable: Bool {
        samplesPerDirection >= 100 && !protocolDigest.isEmpty && [firstFrame,interactive,settled].allSatisfy(\.valid) &&
            longestSettling >= settled.p99 && values.allSatisfy { $0.isFinite && $0 >= 0 }
    }
    func dominates(_ peer: Self) -> Bool {
        guard comparable, peer.comparable, protocolDigest == peer.protocolDigest else { return false }
        let pairs = zip(values,peer.values)
        return pairs.allSatisfy { $0 <= $1 } && pairs.contains { $0 < $1 }
    }
}

/// Supplied only by a trusted capability source (never decoded from a profile preference or a UI argument).
public struct StageEngineQualification: Codable, Equatable, Sendable {
    public let backend: StageWindowBackend, environment: StageEngineEnvironment, evidence: UUID
    public let checks: [StageEngineCheck:StageEngineFinding], comparison: StageEngineComparison?
    public init(backend: StageWindowBackend, environment: StageEngineEnvironment, evidence: UUID,
                checks: [StageEngineCheck:StageEngineFinding], comparison: StageEngineComparison? = nil) {
        self.backend = backend; self.environment = environment; self.evidence = evidence
        self.checks = checks; self.comparison = comparison
    }
    public func admits(_ live: StageEngineEnvironment) -> Bool {
        live.complete && environment == live && (backend != .spaces || live.osBuild == "26A428") &&
        StageEngineCheck.required(for: backend).allSatisfy { checks[$0] == .pass } &&
        !checks.values.contains { $0 != .pass }
    }
    public static func choose(_ records: [Self], in live: StageEngineEnvironment,
                              retaining owner: StageWindowBackend? = nil) -> Self? {
        let matching = records.filter { $0.environment == live }
        let byBackend = Dictionary(grouping: matching, by: \.backend)
        let eligible = matching.filter { byBackend[$0.backend]?.count == 1 && $0.admits(live) }
        if eligible.count == 1 { return eligible[0] }
        guard eligible.count == 2 else { return nil }
        let a = eligible[0], b = eligible[1]
        if let lhs = a.comparison, let rhs = b.comparison {
            if lhs.dominates(rhs) { return a }
            if rhs.dominates(lhs) { return b }
        }
        return eligible.first { $0.backend == owner }
    }
}

/// A generation issued by the Rust worker for this exact environment. The durable stamp is a lookup key only.
public struct StageEngineOwner: Codable, Equatable, Sendable {
    public let backend: StageWindowBackend, environment: StageEngineEnvironment, generation: UUID, evidence: UUID
    public init(qualification: StageEngineQualification, generation: UUID) {
        self.backend = qualification.backend; self.environment = qualification.environment
        self.evidence = qualification.evidence; self.generation = generation
    }
}
