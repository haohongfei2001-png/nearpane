import Foundation

public enum StageWindowBackend: String, Codable, CaseIterable, Sendable { case corner, spaces }

/// Fingerprint of the measured install and physical display configuration. A different install, SIP posture,
/// OS build, window class, resolution, refresh rate or topology needs its own qualification.
public struct StageEngineEnvironment: Equatable, Codable, Sendable {
    public let osBuild, engineRevision, hostCDHash, hardware, topology, windowClass: String
    public let permissions: Set<StageVisibilityPermission>?
    public let sipEnabled: Bool
    public init(osBuild: String, engineRevision: String, hostCDHash: String, hardware: String,
                topology: String, windowClass: String, sipEnabled: Bool, permissions: Set<StageVisibilityPermission>? = nil) {
        self.osBuild = osBuild; self.engineRevision = engineRevision; self.hostCDHash = hostCDHash
        self.hardware = hardware; self.topology = topology; self.windowClass = windowClass; self.sipEnabled = sipEnabled
        self.permissions = permissions
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
    case nativeMembershipAndOrderUnchanged, independentVisualIsolation, exactAXGeometryReturned
    case guardianDurableHandoff, guardianRecoversAfterHostExit, realPointerAndDocumentReceivers
    public static func required(for backend: StageWindowBackend) -> Set<Self> {
        let common: Set<Self> = [.independentlyObserved,.twoAppsThreeWindows,.sameAppSiblings,.unmanagedBystanders,
            .preminimizedAndDockUnchanged,.exactKeyboardReceiver,.nativeTakeovers,.topologyChanges,
            .normalQuitRecovery,.crashRecovery,.tenTransitions,.fiftyTransitions,.signedHostThreeGroups,
            .signedHostExactKeyboard,.pairedApplePerformance,.hundredPerDirection,.thousandTransitions,
            .sixtyAndHighRefresh,.physicalDisplayConfigurations,.boundedResourceUseAndRecovery]
        switch backend {
        case .corner: return common.union(WindowVisibilityProvider.corner.singleWindowChecks).union([.cornerGeometryAndClamp,.sliverAndBorders,.completeMouseSequences,
            .systemSurfacesClickable,.freshZOrderAndMarker,.eventTapRevocation,.inputPermissionsAndSecureInput])
        case .spaces: return common.union([.exactSIPBuild,.validatedRoute,.memberMembershipEachWay,.applicationReactivation,
            .modalPanels,.allMissionControlEntrances,.exposeFullscreenSplitView,.physicalMultiDisplay,.loginRecovery,.skyLightLoss])
        }
    }
}

public enum StageEngineFinding: String, Codable, Sendable { case pass, fail, unknown, notRun, blocked }

/// A permission observation belongs to the signed canonical Host. Older receipts decode with no observation.
public enum StageVisibilityPermission: String, Codable, CaseIterable, Sendable {
    case accessibility, listenEvent, postEvent, screenCapture
}

/// Only mechanisms which keep the native desktop membership and roster intact belong to this API.
/// StageWindowBackend also describes archived receipts and the separately scoped research ABI.
public enum WindowVisibilityProvider: Sendable {
    case corner

    public enum Stage: Sendable { case isolatedGroupTrial, production }
    public enum Admission: Equatable, Sendable {
        case supported, unsupported
    }
    public var assessedBuilds: Set<String> { ["26A428"] }
    public var requiredPermissions: Set<StageVisibilityPermission> { Set(StageVisibilityPermission.allCases) }
    public var singleWindowChecks: Set<StageEngineCheck> {
        [.independentlyObserved, .exactSIPBuild, .twoAppsThreeWindows, .sameAppSiblings, .unmanagedBystanders,
         .preminimizedAndDockUnchanged, .exactKeyboardReceiver, .nativeMembershipAndOrderUnchanged,
         .independentVisualIsolation, .exactAXGeometryReturned, .guardianDurableHandoff, .guardianRecoversAfterHostExit,
         .realPointerAndDocumentReceivers, .cornerGeometryAndClamp, .sliverAndBorders, .completeMouseSequences,
         .systemSurfacesClickable, .freshZOrderAndMarker, .eventTapRevocation, .inputPermissionsAndSecureInput,
         .normalQuitRecovery, .crashRecovery]
    }

    /// The isolated result is a progression decision; it never creates a product transport or write grant.
    public static func admission(for record: StageEngineQualification, in live: StageEngineEnvironment, stage: Stage) -> Admission {
        let provider = Self.corner
        guard record.backend == .corner, record.environment == live, live.complete,
              provider.assessedBuilds.contains(live.osBuild), live.windowClass == "ordinary-standard",
              let actual = live.permissions, provider.requiredPermissions.isSubset(of: actual),
              provider.singleWindowChecks.allSatisfy({ record.checks[$0] == .pass }) else { return .unsupported }
        switch stage {
        case .isolatedGroupTrial:
            return record.checks.values.contains(.fail) ? .unsupported : .supported
        case .production:
            guard record.comparison?.passesAbsoluteLimits == true,
                  StageEngineCheck.required(for: .corner).allSatisfy({ record.checks[$0] == .pass }),
                  record.checks.values.allSatisfy({ $0 == .pass }) else { return .unsupported }
            return .supported
        }
    }
}

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
    public func admits(_ live: StageEngineEnvironment) -> Bool {
        WindowVisibilityProvider.admission(for: self, in: live, stage: .production) == .supported
    }

    public static func choose(_ records: [Self], in live: StageEngineEnvironment, excluding unavailable: Set<UUID> = []) -> Self? {
        let candidates = records.filter { $0.backend == .corner && $0.environment == live }
        guard candidates.count == 1, let candidate = candidates.first, !unavailable.contains(candidate.evidence),
              candidate.admits(live) else { return nil }
        return candidate
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
