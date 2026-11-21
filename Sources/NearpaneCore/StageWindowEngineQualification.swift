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
    case signedHostThreeGroups, signedHostExactKeyboard, pairedApplePerformance, hundredPerDirection, thousandTransitions
    case sixtyAndHighRefresh, physicalDisplayConfigurations, boundedResourceUseAndRecovery
    case cornerGeometryAndClamp, sliverAndBorders, completeMouseSequences, systemSurfacesClickable, freshZOrderAndMarker
    case eventTapRevocation, inputPermissionsAndSecureInput
    case exactSIPBuild, validatedRoute, memberMembershipEachWay, applicationReactivation, modalPanels
    case allMissionControlEntrances, exposeFullscreenSplitView, physicalMultiDisplay, loginRecovery, skyLightLoss
    public static func required(for backend: StageWindowBackend) -> Set<Self> {
        let common: Set<Self> = [.independentlyObserved,.twoAppsThreeWindows,.sameAppSiblings,.unmanagedBystanders,
            .preminimizedAndDockUnchanged,.exactKeyboardReceiver,.nativeTakeovers,.topologyChanges,
            .normalQuitRecovery,.crashRecovery,.tenTransitions,.fiftyTransitions,.signedHostThreeGroups,
            .signedHostExactKeyboard,.pairedApplePerformance,.hundredPerDirection,.thousandTransitions,
            .sixtyAndHighRefresh,.physicalDisplayConfigurations,.boundedResourceUseAndRecovery]
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
    public struct Reference: Codable, Equatable, Sendable {
        public let appleFirstFrameP95, appleInteractiveP95, nominalInterval, frameGapP95, longestGap, recoverySeconds: Double
        public init(appleFirstFrameP95: Double, appleInteractiveP95: Double, nominalInterval: Double, frameGapP95: Double,
                    longestGap: Double, recoverySeconds: Double) {
            self.appleFirstFrameP95 = appleFirstFrameP95; self.appleInteractiveP95 = appleInteractiveP95
            self.nominalInterval = nominalInterval; self.frameGapP95 = frameGapP95; self.longestGap = longestGap
            self.recoverySeconds = recoverySeconds
        }
    }
    public let reference: Reference?
    public let longestSettling, frameGapP99, droppedFramePercent, idleCPU, burstCPU, windowServerCPU, replaydCPU, memoryMB: Double

    public init(protocolDigest: String, samplesPerDirection: Int, firstFrame: Latency, interactive: Latency, settled: Latency,
                longestSettling: Double, frameGapP99: Double, droppedFramePercent: Double,
                idleCPU: Double, burstCPU: Double, windowServerCPU: Double, replaydCPU: Double, memoryMB: Double, reference: Reference? = nil) {
        self.reference = reference
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
    var passesAbsoluteLimits: Bool {
        guard let r = reference, [r.appleFirstFrameP95,r.appleInteractiveP95,r.nominalInterval].allSatisfy({ $0.isFinite && $0 > 0 }),
              [r.frameGapP95,r.longestGap,r.recoverySeconds].allSatisfy({ $0.isFinite && $0 >= 0 }),
              r.frameGapP95 <= r.nominalInterval*1.25, r.longestGap <= 50, frameGapP99 <= r.longestGap,
              r.recoverySeconds <= 2, firstFrame.p95 <= 1.2*r.appleFirstFrameP95+20,
              interactive.p95 <= 1.2*r.appleInteractiveP95+30 else { return false }
        return comparable && firstFrame.p50 <= 100 && firstFrame.p95 <= 150 && firstFrame.p99 <= 250 &&
            interactive.p50 <= 150 && interactive.p95 <= 220 && interactive.p99 <= 350 &&
            settled.p95 <= 250 && longestSettling <= 500 && frameGapP99 <= 50 && droppedFramePercent <= 1 &&
            idleCPU <= 1 && burstCPU <= 20 && memoryMB <= 100
    }
    func matchesBenchmark(_ peer: Self) -> Bool {
        guard let a = reference, let b = peer.reference, comparable, peer.comparable, protocolDigest == peer.protocolDigest,
              a.nominalInterval == b.nominalInterval, a.appleInteractiveP95 == b.appleInteractiveP95,
              a.appleFirstFrameP95 == b.appleFirstFrameP95 else { return false }
        return true
    }
    func dominates(_ peer: Self) -> Bool {
        guard matchesBenchmark(peer), let a = reference, let b = peer.reference else { return false }
        let pairs = zip(values + [a.frameGapP95,a.longestGap,a.recoverySeconds],peer.values + [b.frameGapP95,b.longestGap,b.recoverySeconds])
        return pairs.allSatisfy { $0 <= $1 } && pairs.contains { $0 < $1 }
    }
    var startupOrder: [Double] {
        let recovery = reference.map { [$0.frameGapP95, $0.longestGap, $0.recoverySeconds] } ?? []
        return [interactive.p99, firstFrame.p95, settled.p95, frameGapP99, droppedFramePercent] + values + recovery
    }
}

/// Supplied only by a trusted capability source (never decoded from a profile preference or a UI argument).
public struct StageEngineQualification: Codable, Equatable, Sendable {
    public let backend: StageWindowBackend, environment: StageEngineEnvironment, evidence: UUID
    public let checks: [StageEngineCheck:StageEngineFinding], comparison: StageEngineComparison?, spacesBaseline: UUID?
    public init(backend: StageWindowBackend, environment: StageEngineEnvironment, evidence: UUID,
                checks: [StageEngineCheck:StageEngineFinding], comparison: StageEngineComparison? = nil, spacesBaseline: UUID? = nil) {
        self.backend = backend; self.environment = environment; self.evidence = evidence
        self.checks = checks; self.comparison = comparison; self.spacesBaseline = spacesBaseline
    }
    private var completePhysical: Bool {
        environment.complete && comparison?.passesAbsoluteLimits == true && StageEngineCheck.required(for:backend).allSatisfy { checks[$0] == .pass } &&
            !checks.values.contains { $0 != .pass }
    }
    public func admits(_ live: StageEngineEnvironment, reviewed: [Self] = []) -> Bool {
        guard completePhysical, environment == live else { return false }
        if backend != .spaces || live.osBuild == "26A428" { return true }
        guard let spacesBaseline else { return false }
        let match = reviewed.filter { $0.evidence == spacesBaseline }
        return match.count == 1 && match[0].backend == .spaces && match[0].environment.osBuild == "26A428" &&
            match[0].environment.engineRevision == live.engineRevision && match[0].environment.windowClass == live.windowClass &&
            match[0].completePhysical
    }
    public static func choose(_ records: [Self], in live: StageEngineEnvironment,
                              retaining owner: StageWindowBackend? = nil, excluding unavailable: Set<UUID> = []) -> Self? {
        let matching = records.filter { $0.environment == live }
        let byBackend = Dictionary(grouping: matching, by: \.backend)
        let reviewed = records.filter { !unavailable.contains($0.evidence) }
        let eligible = matching.filter { byBackend[$0.backend]?.count == 1 && !unavailable.contains($0.evidence) && $0.admits(live,reviewed:reviewed) }
        if eligible.count == 1 { return eligible[0] }
        guard eligible.count == 2 else { return nil }
        let a = eligible[0], b = eligible[1]
        let current = eligible.first { $0.backend == owner }
        guard let lhs = a.comparison, let rhs = b.comparison, lhs.matchesBenchmark(rhs), a.evidence != b.evidence else { return current }
        if lhs.dominates(rhs) { return a }
        if rhs.dominates(lhs) { return b }
        if let current { return current }
        if lhs.startupOrder.lexicographicallyPrecedes(rhs.startupOrder) { return a }
        if rhs.startupOrder.lexicographicallyPrecedes(lhs.startupOrder) { return b }
        // Identical measured product quality. Keep startup deterministic across catalog ordering.
        return a.evidence.uuidString < b.evidence.uuidString ? a : b
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
