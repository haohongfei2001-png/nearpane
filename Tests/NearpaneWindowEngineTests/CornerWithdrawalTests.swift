import Darwin
import Foundation
import CNearpaneWindowEngine
import NearpaneCore
import Testing
@testable import NearpaneWindowEngine

struct CornerWithdrawalTests {
    @Test func exitedMeasuredReturnNeedsTheSamePreparedWindowAndTerminalRecovery() throws {
        let (request, envelope) = envelope()
        let original = try #require(envelope["withdrawal"] as? [String: Any])
        let first = try #require(request.frame), window = try #require(request.window)
        let scope = try #require(request.scope)
        let env = StageEngineEnvironment(osBuild: "26A428", engineRevision: "fixture", hostCDHash: "fixture",
                                         hardware: "test", topology: "test", windowClass: "ordinary", sipEnabled: true)
        let qualification = StageEngineQualification(backend: .corner, environment: env, evidence: UUID(), checks: [:])
        let owner = StageEngineOwner(qualification: qualification, generation: try #require(request.generation))
        func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
        }
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let row = try decode(StageGroupCoordinator.HidePrimitive.self, [
            "transaction": original["transaction"]!, "intent": request.intent.uuidString, "group": original["group"]!,
            "member": original["member"]!, "owner": try object(owner), "scope": try object(scope), "nativeID": request.nativeID,
            "before": try object(StageWindowState(window: window, lifetime: try #require(request.lifetime), frame: first, visibility: .visible))])
        let prepared = try decode(CornerPreparedReceipt.self, ["schema": 1, "status": "PREPARED", "guardianPID": 41, "original": original])
        let landing = [899, 682, 300, 160]
        let flags = UInt32(NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID | NP_OWNED | NP_CORNER_RECOVERY_FRAME)
        let measured = try decode(CornerMeasuredFrameReceipt.self, ["schema": 1, "status": "RECOVERY_FRAME_ONLY", "guardianPID": 41,
            "original": original, "postimage": landing, "engineStatus": NP_UNKNOWN, "engineFlags": flags])
        let final: [String: Any] = ["schema": 1, "status": "PASS", "reason": "unqualifiedHideReturnedAfterKernelExit",
            "durableOwnership": "measuredReturnAwaitingCoordinator", "owner": try object(owner), "physicalRestoration": "PASS", "issued": 1, "originalFrameReadbacks": 2,
            "original": original, "preimage": original["frame"]!, "postimage": landing, "guardianPID": 41,
            "retainedBeforePark": true, "committedPostimage": false, "unqualifiedPostimageObserved": true,
            "originalPipeEOF": true, "kernelHostExit": true, "originalHostGone": true, "serializedRecoveryWriter": true,
            "sameRetainedWindow": true, "postimageExactBeforeWrite": true, "sameDisplay": true, "unchangedInput": true,
            "journalExact": true, "processSignatureRechecked": true, "guardianOwnAccessibilityBeforeWrite": true]
        func matches(_ change: [String: Any]) throws -> Bool {
            try decode(CornerExitedReturnReceipt.self, final.merging(change) { _, new in new })
                .matches(row, prepared: prepared, measured: measured)
        }
        #expect(try matches([:]))
        let inverse = original.merging(["expectedPark": landing, "sourceShowIntent": UUID().uuidString]) { _, new in new }
        let inversePrepared = try decode(CornerPreparedReceipt.self, ["schema": 1, "status": "PREPARED",
            "guardianPID": 41, "original": inverse])
        let inverseMeasured = try decode(CornerMeasuredFrameReceipt.self, ["schema": 1, "status": "RECOVERY_FRAME_ONLY",
            "guardianPID": 41, "original": inverse, "postimage": landing, "engineStatus": NP_UNKNOWN, "engineFlags": flags])
        let inverseExit = try decode(CornerExitedReturnReceipt.self, final.merging(["original": inverse]) { _, new in new })
        #expect(!inverseExit.matches(row, prepared: inversePrepared, measured: inverseMeasured))
        for invalid: [String: Any] in [["status": "UNKNOWN"], ["guardianPID": 42], ["originalFrameReadbacks": 1],
            ["postimage": [898,682,300,160]], ["kernelHostExit": false], ["committedPostimage": true],
            ["original": original.merging(["birth": 55]) { _, new in new }], ["unchangedInput": false]] {
            #expect(try !matches(invalid))
        }
        let undo = UUID()
        let live = final.merging(["reason":"originalHostReturnedUnqualifiedHide", "issued":0,
            "measuredReturnIntent":undo.uuidString, "originalPipeEOF":false, "kernelHostExit":false,
            "originalHostGone":false]) { _, new in new }
        func acceptsReturn(_ fields: [String: Any], onRestart: Bool = false) throws -> Bool {
            try decode(CornerLiveMeasuredReturnReceipt.self, fields)
                .matches(owner:owner, undo:undo, prepared:prepared, measured:measured, acceptExitWitness:onRestart)
        }
        #expect(try acceptsReturn(live))
        #expect(try acceptsReturn(live, onRestart:true))
        let afterDeath = live.merging(["reason":"originalMeasuredReturnFoundAfterHostExit",
            "originalPipeEOF":true, "kernelHostExit":true, "originalHostGone":true,
            "serializedRecoveryWriter":true, "exclusiveHostWriterExcluded":true]) { _, new in new }
        #expect(try !acceptsReturn(afterDeath))
        #expect(try acceptsReturn(afterDeath, onRestart:true))
        for invalid: [String: Any] in [["issued":1], ["originalFrameReadbacks":1], ["kernelHostExit":false],
            ["exclusiveHostWriterExcluded":false], ["measuredReturnIntent":request.intent.uuidString],
            ["postimage":[898,682,300,160]], ["unqualifiedPostimageObserved":false]] {
            #expect(try !acceptsReturn(afterDeath.merging(invalid) { _, new in new }, onRestart:true))
        }
    }
    @Test func ordinaryABIHandleCannotPublishANoTicketWitness() throws {
        var config = NPConfig(), handle: UInt64 = 0
        config.size = UInt32(MemoryLayout<NPConfig>.size)
        config.version = UInt32(NP_ENGINE_ABI)
        try #require(np_engine_create(&config, &handle) == NP_OK)
        defer { _ = np_engine_destroy(handle) }
        var r = NPRequest()
        r.size = UInt32(MemoryLayout<NPRequest>.size)
        r.version = UInt32(NP_ENGINE_ABI)
        r.backend = UInt32(NP_CORNER); r.operation = UInt32(NP_HIDE); r.epoch = 1
        r.intent = UUID().uuid; r.group = UUID().uuid; r.generation = UUID().uuid
        r.lifetime = UUID().uuid; r.member = UUID().uuid; r.display = UUID().uuid; r.native_space = UUID().uuid
        r.timeout_ms = 500; r.native_id = 2; r.pid = .max; r.window = .max; r.birth = 1
        r.frame = NPRect(x: 3, y: 9, width: 212, height: 160)
        #expect(np_engine_fence_unsubmitted_corner_hide(handle, &r) == NP_INCOMPATIBLE)
        #expect(np_engine_fence_unsubmitted_corner_hide(handle, nil) == NP_INVALID)
    }
    private func envelope() -> (NativeStageEngineRequest, [String: Any]) {
        let scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
        let intent = UUID(), group = UUID(), member = UUID(), lifetime = UUID(), generation = UUID()
        let r = NativeStageEngineRequest(backend: 1, operation: 3, intent: intent, group: group, scope: scope,
            member: member, lifetime: lifetime, generation: generation, window: .init(pid: 31, birth: 54, number: 72),
            nativeID: 9, frame: .init(x: 1, y: 2, width: 300, height: 160))
        let proof: [String: Any] = [
            "intent": intent.uuidString, "transaction": UUID().uuidString, "group": group.uuidString,
            "member": member.uuidString, "generation": generation.uuidString, "lifetime": lifetime.uuidString,
            "display": scope.display.uuidString, "space": scope.nativeSpace.uuidString, "native": 9,
            "pid": 31, "birth": 54, "window": 72, "epoch": 1, "frame": [1, 2, 300, 160],
            "hostPID": 32, "hostBirth": 81, "guardianBirth": 91, "originalReadbacks": 2
        ]
        return (r, ["schema": 1, "issued": 0, "guardianPID": 41, "status": "WITHDRAWN_BEFORE_SUBMISSION",
                    "retainedBeforePark": true, "committedPostimage": false, "originalPipeEOF": false,
                    "kernelHostExit": false, "withdrawal": proof])
    }

    @Test func releaseNeedsTheSamePreparedLeaseAndOriginalGuardianImageEvenAfterLostAck() throws {
        let (request, withdrawal) = envelope()
        let original = try #require(withdrawal["withdrawal"] as? [String: Any])
        let preparedJSON: [String: Any] = ["schema": 1, "status": "PREPARED", "guardianPID": 41, "original": original]
        let prepared = try JSONDecoder().decode(CornerPreparedReceipt.self, from: JSONSerialization.data(withJSONObject: preparedJSON))
        let frame = SurfaceRect(x: 899, y: 680, width: 300, height: 160)
        let parked = NativeStageEngineReceipt(status: 0, flags: 190, detail: 0, owned: 1, nativeID: 9,
                                              epoch: 1, frame: frame, intent: request.intent)
        let final: [String: Any] = ["schema": 1, "status": "PASS", "reason": "liveHostReleasedRestoredOwnership",
            "issued": 0, "guardianPID": 41, "original": original, "postimage": [899, 680, 300, 160],
            "liveReleaseOriginalFrameReadbacks": 2, "retainedBeforePark": true, "committedPostimage": true,
            "originalPipeEOF": false, "kernelHostExit": false]
        func confirmed(_ fields: [String: Any], _ image: Int32, ack: Bool, exit: Int32? = nil) throws -> Bool {
            let record = try JSONDecoder().decode(CornerLiveReleaseReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
            return record.confirms(prepared, parked: parked, image: image, acknowledged: ack, normalExitCode: exit)
        }
        let live = Int32(NP_GUARDIAN_IMAGE_LIVE), exited = Int32(NP_GUARDIAN_IMAGE_EXITED)
        #expect(try confirmed(final, live, ack: true))
        #expect(try !confirmed(final, live, ack: false))
        #expect(try confirmed(final, exited, ack: false, exit: 0))
        #expect(try confirmed(final, exited, ack: false, exit: 4))
        #expect(try !confirmed(final, exited, ack: false, exit: 3))
        #expect(try !confirmed(final, Int32(NP_GUARDIAN_IMAGE_LOST), ack: true, exit: 0))
        #expect(try !confirmed(final, Int32(NP_GUARDIAN_IMAGE_UNAVAILABLE), ack: true))
        let changes: [String: Any] = ["issued": 1, "liveReleaseOriginalFrameReadbacks": 1, "kernelHostExit": true,
            "guardianPID": 42, "postimage": [898, 680, 300, 160], "original": original.merging(["window": 73]) { _, new in new }]
        for (key, value) in changes {
            var changed = final
            changed[key] = value
            #expect(try !confirmed(changed, exited, ack: false, exit: 0))
        }
    }

    @Test func guardianCanClaimAMeasuredFrameWithoutCertifyingIsolation() throws {
        let (request, envelope) = envelope()
        let original = try #require(envelope["withdrawal"] as? [String: Any])
        let preparedData = try JSONSerialization.data(withJSONObject: ["schema": 1, "status": "PREPARED",
            "guardianPID": 41, "original": original] as [String: Any])
        let prepared = try JSONDecoder().decode(CornerPreparedReceipt.self, from: preparedData)
        let flags = UInt32(NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID | NP_OWNED | NP_CORNER_RECOVERY_FRAME)
        let frame = SurfaceRect(x: 899, y: 682, width: 300, height: 160)
        func result(_ bits: UInt32, status: UInt32 = UInt32(NP_UNKNOWN)) -> NativeStageEngineReceipt {
            .init(status: status, flags: bits, detail: 47, owned: 1, nativeID: 9, epoch: 1, frame: frame, intent: request.intent)
        }
        var record: [String: Any] = ["schema": 1, "status": "RECOVERY_FRAME_ONLY", "guardianPID": 41,
            "original": original, "postimage": [899,682,300,160], "engineStatus": NP_UNKNOWN, "engineFlags": flags]
        func matches(_ receipt: NativeStageEngineReceipt) throws -> Bool {
            let data = try JSONSerialization.data(withJSONObject: record)
            return try JSONDecoder().decode(CornerMeasuredFrameReceipt.self, from: data).matches(receipt, prepared: prepared)
        }
        #expect(try matches(result(flags)))
        #expect(try !matches(result(flags | UInt32(NP_HIDDEN | NP_INPUT_SAFE))))
        #expect(try !matches(result(flags, status: UInt32(NP_PASS))))
        record["postimage"] = [899,681,300,160]
        #expect(try !matches(result(flags)))
        record["postimage"] = [899,682,300,160]
        var changed = original
        changed["transaction"] = UUID().uuidString
        record["original"] = changed
        #expect(try !matches(result(flags)))
    }

    @Test func withdrawalRequiresBothProcessLifetimesExactWindowAndTwoReadbacks() throws {
        let (r, original) = envelope()
        func matches(_ data: [String: Any]) throws -> Bool {
            let bytes = try JSONSerialization.data(withJSONObject: data)
            let receipt = try JSONDecoder().decode(CornerWithdrawalReceipt.self, from: bytes)
            return receipt.matches(r, epoch: 1, host: 32, hostBirth: 81, child: 41, childBirth: 91)
        }
        #expect(try matches(original))
        let outer: [String: Any] = ["schema": 2, "issued": 1, "guardianPID": 33, "status": "UNKNOWN",
                                    "retainedBeforePark": false, "committedPostimage": true, "kernelHostExit": true,
                                    "originalPipeEOF": true]
        for (key, value) in outer {
            var changed = original
            changed[key] = value
            #expect(try !matches(changed))
        }
        let other = UUID().uuidString
        let substitutions: [String: Any] = [
            "intent": other, "group": other, "member": other, "generation": other, "lifetime": other,
            "display": other, "space": other, "native": 10, "pid": 99, "birth": 55, "window": 73,
            "epoch": 2, "frame": [1, 2, 301, 160], "hostPID": 33, "hostBirth": 82,
            "guardianBirth": 92, "originalReadbacks": 1
        ]
        for (key, value) in substitutions {
            var changed = original
            var proof = try #require(original["withdrawal"] as? [String: Any])
            proof[key] = value
            changed["withdrawal"] = proof
            #expect(try !matches(changed))
        }
    }

    @Test func preparedResponsibilityBelongsToTheSameWindowAndBothLiveGenerations() throws {
        let (request, withdrawal) = envelope()
        let original = try #require(withdrawal["withdrawal"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "status": "PREPARED", "guardianPID": 41,
                                                               "original": original] as [String: Any])
        let prepared = try JSONDecoder().decode(CornerPreparedReceipt.self, from: data)
        #expect(prepared.matches(request, epoch: 1, host: 32, hostBirth: 81, child: 41, childBirth: 91))
        #expect(!prepared.matches(request, epoch: 1, host: 32, hostBirth: 82, child: 41, childBirth: 91))
        #expect(!prepared.matches(request, epoch: 1, host: 32, hostBirth: 81, child: 41, childBirth: 92))
        let final = try JSONDecoder().decode(CornerWithdrawalReceipt.self, from: JSONSerialization.data(withJSONObject: withdrawal))
        #expect(final.withdrawal == prepared.original)
        #expect((try? JSONDecoder().decode(CornerWithdrawalReceipt.self, from: data)) == nil)
    }

    @Test func inversePreparationRequiresMatchingParkAndThreeDistinctIntents() throws {
        let (forward, withdrawal) = envelope()
        let original = try #require(withdrawal["withdrawal"] as? [String: Any])
        let park = SurfaceRect(x: 899, y: 682, width: 300, height: 160)
        let inverse = NativeStageEngineRequest(backend: forward.backend, operation: forward.operation, intent: forward.intent,
            group: forward.group, scope: forward.scope, member: forward.member, lifetime: forward.lifetime,
            generation: forward.generation, window: forward.window, nativeID: forward.nativeID, frame: forward.frame, target: park)
        let frame = [park.x, park.y, park.width, park.height]
        let source = UUID().uuidString
        func matches(_ request: NativeStageEngineRequest, _ change: [String: Any]) throws -> Bool {
            let data = try JSONSerialization.data(withJSONObject: original.merging(change) { _, new in new })
            return try JSONDecoder().decode(CornerGuardianOriginalProof.self, from: data)
                .matches(request, epoch: 1, host: 32, hostBirth: 81, childBirth: 91)
        }
        let valid: [String: Any] = ["expectedPark": frame, "sourceShowIntent": source]
        #expect(try matches(inverse, valid))
        #expect(try !matches(inverse, [:]))
        #expect(try !matches(forward, valid))
        for partial: [String: Any] in [["expectedPark": frame], ["sourceShowIntent": source]] {
            #expect(try !matches(inverse, partial))
            #expect(try !matches(forward, partial))
        }
        for change: [String: Any] in [["expectedPark": [898, 682, 300, 160]],
            ["sourceShowIntent": forward.intent.uuidString], ["sourceShowIntent": original["transaction"]!],
            ["sourceShowIntent": "00000000-0000-0000-0000-000000000000"], ["transaction": forward.intent.uuidString]] {
            #expect(try !matches(inverse, valid.merging(change) { _, new in new }))
        }
    }

    @Test func receiptReadRejectsMissingAliasedSharedOrTruncatedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try #require(dir >= 0)
        defer { close(dir) }
        #expect(CornerWithdrawalReceipt.read(in: dir) == nil)
        let receipt = root.appendingPathComponent("guardian-receipt.json")
        let data = try JSONSerialization.data(withJSONObject: envelope().1)
        try data.write(to: receipt)
        try #require(chmod(receipt.path, 0o600) == 0)
        #expect(CornerWithdrawalReceipt.read(in: dir) != nil)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: receipt, to: alias)
        #expect(CornerWithdrawalReceipt.read(in: dir) == nil)
        try FileManager.default.removeItem(at: alias)
        try #require(chmod(receipt.path, 0o644) == 0)
        #expect(CornerWithdrawalReceipt.read(in: dir) == nil)
        try FileManager.default.moveItem(at: receipt, to: alias)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: alias)
        #expect(CornerWithdrawalReceipt.read(in: dir) == nil)
        try FileManager.default.removeItem(at: receipt)
        try Data(data.prefix(30)).write(to: receipt)
        try #require(chmod(receipt.path, 0o600) == 0)
        #expect(CornerWithdrawalReceipt.read(in: dir) == nil)
    }
}
