import CNearpaneWindowEngine
import Foundation
import NearpaneCore

/// Read-only observations of one registered signed acceptance window.
package struct CornerGuardianFixtureReport: Encodable, Sendable {
    struct Handoff: Encodable, Sendable {
        let state: String
        var guardianPID: Int32?
        var guardianBirth, preparedAckUptimeNS, confirmedAckUptimeNS, epoch: UInt64?
        var sameChildGenerationNow: Bool?
        var originalIntent, member, lifetime, generation: UUID?
        var original, parked: SurfaceRect?

        init(state: String) { self.state = state }
    }

    struct Sample: Encodable, Sendable {
        let uptimeNS: UInt64
        let registeredSignatureMatches, kernelBirthMatches, exactCGOwner, onscreen, hostAXTrusted: Bool
        let cornerAXAndMembershipStatus: UInt32?
        let heldHostReferenceMatches: Bool
        let ax, cg: SurfaceRect?

        init(_ raw: NPGuardianFixtureRead) {
            uptimeNS = raw.uptime_ns
            registeredSignatureMatches = raw.signature == 1
            kernelBirthMatches = raw.kernel_generation == 1
            exactCGOwner = raw.cg_owner == 1
            onscreen = raw.cg_onscreen == 1
            hostAXTrusted = raw.ax_trusted == 1
            cornerAXAndMembershipStatus = raw.native_sample_attempted != 0 ? raw.native_sample_code : nil
            heldHostReferenceMatches = raw.same_retained == 1
            ax = Self.frame(raw.ax)
            cg = Self.frame(raw.cg)
        }

        private static func frame(_ r: NPGuardianRect) -> SurfaceRect? {
            guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite), r.width > 0, r.height > 0 else { return nil }
            return SurfaceRect(x: r.x, y: r.y, width: r.width, height: r.height)
        }
    }

    struct Recovery: Encodable, Sendable {
        let status, reason: String
        let normalWindowWriter = "qualifiedOriginalHostOnly"
        let guardianCanWriteWhileOriginalHostLives = false
        let thisDiagnosticAuthorizesWrites = false
        let retainedByGuardianAtPrepare, currentGuardianReference: String
        let pendingWALWitness, committedWALWitness: String
        let currentWALRead = "NOT_RUN"
        let comparableParkedFrame: Bool?
        let postExit = "survivingPreparedGuardianOnlyAfterRevalidation"
        let crashAndRecovery = "NOT_RUN"
        let recoveryConditions = [
            "originalPipeEOF", "originalKernelExitAndProcessGenerationGone", "survivingOriginalGuardianGeneration",
            "independentGuardianAX", "retainedOriginalAXObjectStillExact", "freshApplicationBirthAndOriginalCodeSignature",
            "reviewedCommittedOwnershipInActiveProfile", "sameDisplayAndOrdinarySpace", "exactCommittedParkedGeometry",
            "replacementHostExcludedAndRecoveryLockHeld", "unchangedPhysicalInputAndSecureInputOff", "setterNotPreviouslyIssued",
            "twoIndependentOriginalFrameReadbacksBeforeRetiringMatchingOwnership",
        ]
    }

    let schema = 1
    let scope = "readOnlySignedFixtureOwnership"
    let hostPID: Int32
    let hostBirth: UInt64?
    let registered: NativeSpaceWindow?
    let registeredCDHash: String?
    let sampledScope: StageGroupScope?
    let nativeID: UInt64?
    let hostObservation, hostObservationReason: String
    let hostTemporaryReferenceReleased: Bool
    let hostReceiptCode: Int32
    let samples: [Sample]
    let handoff: Handoff
    let recovery: Recovery
    let guardianLaunchedByDiagnostic = false
    let globalEventsPosted = 0
    let windowWrites = 0

    static func assess(_ h: Handoff, observedFrame: SurfaceRect?) -> Recovery {
        let absent = h.state == "NO_LIVE_HANDOFF_IN_THIS_HOST"
        let sealed = h.state == "SEALED_ACKNOWLEDGED"
        let prepared = (sealed || h.state == "PREPARED_ACKNOWLEDGED") && (h.preparedAckUptimeNS ?? 0) > 0 &&
            (h.epoch ?? 0) > 0 && h.originalIntent != nil && h.member != nil && h.lifetime != nil &&
            h.generation != nil && h.original != nil
        let committed = prepared && sealed && h.parked != nil && (h.confirmedAckUptimeNS ?? 0) >= (h.preparedAckUptimeNS ?? 1)
        let comparable = observedFrame.flatMap { actual in h.parked.map { sameFrame(actual, $0) } }
        let status: String, reason: String
        if absent {
            (status, reason) = ("BLOCKED", "thisHostHasNoPreparedGuardianForThisWindow")
        } else if !prepared {
            (status, reason) = ("UNKNOWN", "noAuthenticatedPrepareAckForThisLease")
        } else if h.sameChildGenerationNow != true {
            (status, reason) = ("BLOCKED", "survivingOriginalGuardianUnconfirmed")
        } else if !committed {
            (status, reason) = ("BLOCKED", "noCommittedParkedPostimageAck")
        } else if comparable == false {
            (status, reason) = ("BLOCKED", "currentFixtureGeometryDiffersFromCommittedPostimage")
        } else {
            (status, reason) = ("UNKNOWN", "liveHostCannotWitnessPostDeathLocksPermissionAndObject")
        }
        return Recovery(
            status: status, reason: reason,
            retainedByGuardianAtPrepare: prepared ? "CONFIRMED_AT_PREPARE_ACK" : absent ? "NO_HANDOFF_BY_THIS_HOST" : "UNKNOWN",
            currentGuardianReference: absent ? "NO_HANDOFF_BY_THIS_HOST" : "NOT_FRESHLY_OBSERVED",
            pendingWALWitness: prepared ? "MATCHED_AT_PREPARE_ACK" : "NOT_OBSERVED",
            committedWALWitness: committed ? "MATCHED_AT_CONFIRM_ACK" : "NOT_OBSERVED",
            comparableParkedFrame: comparable
        )
    }

    static func sameFrame(_ a: SurfaceRect, _ b: SurfaceRect) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { $0.isFinite && abs($0) <= 0.75 }
    }

    /// The caller supplies the independently witnessed ordinary scope. This command only reads the registered
    /// fixture and the original Host’s in-memory handoff state. It never opens a profile or launches a helper.
    @MainActor package static func sample(pid: Int32, birth: UInt64, number: UInt32, executable: URL, cdhash: String,
                                         scope: StageGroupScope?, nativeID: UInt64?) -> Self {
        let selfPID = getpid()
        let selfBirth = (try? OrdinaryProcessImage.read(selfPID))?.launch
        var native = NPGuardianFixtureObservation()
        native.size = UInt32(MemoryLayout.size(ofValue: native))
        native.version = 1
        let display: CFString? = scope.map { $0.display.uuidString as CFString }
        let space: CFString? = scope.map { $0.nativeSpace.uuidString as CFString }
        let code = np_guardian_observe_fixture(pid, birth, number, executable.path as CFString, cdhash as CFString,
                                               nativeID ?? 0, display, space, &native)
        let verified = code == 0 && native.signatures_closed == 1
        let window = NativeSpaceWindow(pid: pid, birth: birth, number: number)
        let reads = [native.first, native.second].filter { $0.uptime_ns > 0 }.map(Sample.init)
        let exactOwner = verified && reads.count == 2 && reads.allSatisfy(\.exactCGOwner)
        let exact = exactOwner && selfBirth != nil && (try? OrdinaryProcessImage.read(selfPID))?.launch == selfBirth &&
            reads[0].uptimeNS < reads[1].uptimeNS && reads.allSatisfy {
                $0.registeredSignatureMatches && $0.kernelBirthMatches && $0.onscreen && $0.hostAXTrusted &&
                    $0.cornerAXAndMembershipStatus == 0 && $0.heldHostReferenceMatches
            } && native.held_in_caller == 1 && native.released == 1 && native.same_geometry == 1
        let h = exactOwner ? CornerGuardianClient.observedHandoff(for: window, scope: scope, nativeID: nativeID)
            : Handoff(state: "UNVERIFIED_FIXTURE")
        let why: String
        if !verified { why = "fixtureGenerationPathOrCodeUnconfirmed" }
        else if !exactOwner { why = "exactFixtureWindowNotConfirmedTwice" }
        else if !reads.allSatisfy(\.hostAXTrusted) { why = "hostAccessibilityNotAlreadyGranted" }
        else if scope == nil || (nativeID ?? 0) == 0 { why = "registeredOrdinaryScopeUnavailable" }
        else { why = exact ? "hostHeldOneExactObjectAcrossIndependentAXCGAndMembershipReads" : "exactGeometryOrRetainedReferenceNotConfirmedTwice" }
        return Self(
            hostPID: selfPID, hostBirth: selfBirth, registered: verified ? window : nil, registeredCDHash: verified ? cdhash : nil,
            sampledScope: scope, nativeID: nativeID, hostObservation: exact ? "CONFIRMED" : "UNKNOWN", hostObservationReason: why,
            hostTemporaryReferenceReleased: native.released == 1, hostReceiptCode: code, samples: reads, handoff: h,
            recovery: assess(h, observedFrame: exact ? reads.last?.cg : nil)
        )
    }
}
