import CNearpaneWindowEngine
import Darwin
import Foundation
import NearpaneCore

/// A restarted Host can release a dead owner without adopting its window. The
/// write-ahead entry, prepared original, measured landing and terminal receipt must agree.
package struct CornerExitedReturnReceipt: Decodable {
    let schema, issued, originalFrameReadbacks: Int
    let status, reason, physicalRestoration, durableOwnership: String
    let guardianPID: Int32
    let owner: StageEngineOwner
    let original: CornerGuardianOriginalProof
    let preimage, postimage: [Double]
    let originalPipeEOF, kernelHostExit, originalHostGone, serializedRecoveryWriter: Bool
    let retainedBeforePark, committedPostimage, unqualifiedPostimageObserved: Bool
    let sameRetainedWindow, postimageExactBeforeWrite, sameDisplay, unchangedInput: Bool
    let journalExact, processSignatureRechecked, guardianOwnAccessibilityBeforeWrite: Bool

    func matches(_ row: StageGroupCoordinator.HidePrimitive, prepared: CornerPreparedReceipt,
                 measured: CornerMeasuredFrameReceipt) -> Bool {
        let command = NativeStageEngineRequest(backend: UInt32(NP_CORNER), operation: UInt32(NP_HIDE), intent: row.intent,
            group: row.group, scope: row.scope, member: row.member, lifetime: row.before.lifetime,
            generation: row.owner.generation, window: row.before.window, nativeID: row.nativeID, frame: row.before.frame)
        let flags = UInt32(NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID | NP_OWNED | NP_CORNER_RECOVERY_FRAME)
        return prepared.matches(command, epoch: original.epoch, host: original.hostPID, hostBirth: original.hostBirth,
                                child: guardianPID, childBirth: original.guardianBirth) &&
            owner == row.owner && owner.backend == .corner && original.epoch > 0 && row.transaction == original.transaction &&
            original.hostPID > 1 && guardianPID > 1 && guardianPID != original.hostPID && original == prepared.original &&
            measured.schema == 1 && measured.status == "RECOVERY_FRAME_ONLY" && measured.guardianPID == guardianPID &&
            measured.original == original && measured.engineStatus == NP_UNKNOWN && measured.engineFlags == flags &&
            preimage == original.frame && postimage == measured.postimage && postimage.count == 4 &&
            postimage.allSatisfy(\.isFinite) && postimage[2] > 0 && postimage[3] > 0 && preimage != postimage &&
            schema == 1 && status == "PASS" && reason == "unqualifiedHideReturnedAfterKernelExit" &&
            durableOwnership == "measuredReturnAwaitingCoordinator" && physicalRestoration == "PASS" &&
            issued == 1 && originalFrameReadbacks == 2 && retainedBeforePark && !committedPostimage &&
            unqualifiedPostimageObserved && originalPipeEOF && kernelHostExit && originalHostGone &&
            serializedRecoveryWriter && sameRetainedWindow && postimageExactBeforeWrite && sameDisplay &&
            unchangedInput && journalExact && processSignatureRechecked && guardianOwnAccessibilityBeforeWrite
    }

    package static func confirmed(_ row: StageGroupCoordinator.HidePrimitive, in profile: URL) -> Bool {
        let parent = open(profile.appendingPathComponent(".corner-guardians").path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { return false }
        let job = openat(parent, row.intent.uuidString.lowercased(), O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard job >= 0 else { return false }
        defer { close(job) }
        guard let prepared = CornerPreparedReceipt.read(in: job), let measured = CornerMeasuredFrameReceipt.read(in: job)
        else { return false }
        if let undo = row.measuredReturnIntent,
           let final = CornerGuardianRecord.final.read(CornerLiveMeasuredReturnReceipt.self, in: job),
           final.matches(owner: row.owner, undo: undo, prepared: prepared, measured: measured, acceptExitWitness: true) {
            let command = NativeStageEngineRequest(backend: UInt32(NP_CORNER), operation: UInt32(NP_HIDE), intent: row.intent,
                group: row.group, scope: row.scope, member: row.member, lifetime: row.before.lifetime, generation: row.owner.generation,
                window: row.before.window, nativeID: row.nativeID, frame: row.before.frame)
            return row.transaction == final.original.transaction &&
                prepared.matches(command, epoch: final.original.epoch, host: final.original.hostPID, hostBirth: final.original.hostBirth,
                                 child: final.guardianPID, childBirth: final.original.guardianBirth) &&
                CornerGuardianClient.generationIsGone(final.original.hostPID, birth: final.original.hostBirth)
        }
        guard let final = CornerGuardianRecord.final.read(Self.self, in: job),
              final.matches(row, prepared: prepared, measured: measured) else { return false }
        // The new Host already holds the exclusive profile lock. After publishing
        // its final receipt, the original Guardian only closes descriptors and exits.
        return CornerGuardianClient.generationIsGone(final.original.hostPID, birth: final.original.hostBirth)
    }
}

/// A physical return by the original living Rust worker, independently witnessed by
/// its Guardian. The failed HIDE stays distinct from a qualified workset switch.
struct CornerLiveMeasuredReturnReceipt: Decodable {
    let schema, issued, originalFrameReadbacks: Int
    let status, reason: String
    let measuredReturnIntent: UUID
    let original: CornerGuardianOriginalProof, owner: StageEngineOwner
    let guardianPID: Int32, postimage: [Double]
    let retainedBeforePark, committedPostimage, unqualifiedPostimageObserved, originalPipeEOF, kernelHostExit: Bool
    let originalHostGone: Bool
    let serializedRecoveryWriter, exclusiveHostWriterExcluded: Bool?

    func matches(owner: StageEngineOwner, undo: UUID, prepared: CornerPreparedReceipt,
                 measured: CornerMeasuredFrameReceipt, acceptExitWitness: Bool = false) -> Bool {
        switch reason {
        case "originalHostReturnedUnqualifiedHide":
            guard !originalPipeEOF, !kernelHostExit, !originalHostGone else { return false }
        case "originalMeasuredReturnFoundAfterHostExit":
            guard acceptExitWitness, originalPipeEOF, kernelHostExit, originalHostGone,
                  serializedRecoveryWriter == true, exclusiveHostWriterExcluded == true else { return false }
        default: return false
        }
        let flags = UInt32(NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID | NP_OWNED | NP_CORNER_RECOVERY_FRAME)
        return schema == 1 && self.owner == owner && owner.backend == .corner && status == "PASS" &&
            issued == 0 && originalFrameReadbacks == 2 &&
            measuredReturnIntent == undo && undo != original.intent && undo != original.transaction && original.epoch > 0 &&
            retainedBeforePark && !committedPostimage && unqualifiedPostimageObserved &&
            original.hostPID > 1 && guardianPID > 1 && original.hostPID != guardianPID &&
            prepared.schema == 1 && prepared.status == "PREPARED" && prepared.original == original &&
            measured.schema == 1 && measured.status == "RECOVERY_FRAME_ONLY" && measured.original == original &&
            measured.engineStatus == NP_UNKNOWN && measured.engineFlags == flags && measured.guardianPID == guardianPID &&
            prepared.guardianPID == guardianPID && postimage == measured.postimage && postimage != original.frame &&
            postimage.count == 4 && postimage.allSatisfy(\.isFinite) && postimage[2] > 0 && postimage[3] > 0
    }
}
