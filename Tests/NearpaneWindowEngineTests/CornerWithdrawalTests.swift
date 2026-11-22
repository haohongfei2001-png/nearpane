import Darwin
import Foundation
import CNearpaneWindowEngine
import NearpaneCore
import Testing
@testable import NearpaneWindowEngine

struct CornerWithdrawalTests {
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
