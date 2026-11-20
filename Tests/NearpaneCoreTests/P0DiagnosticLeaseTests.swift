#if NEARPANE_P0_DIAGNOSTIC
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NearpaneCore

struct P0DiagnosticLeaseTests {
    let a = UUID(), b = UUID(), display = UUID(), op = UUID()
    func payload() -> [String:Any] {
        let base = "/private/tmp/nearpane-d01.test/"
        func window(_ n: Int, _ name: String, _ id: String) -> [String:Any] {
            ["pid":n,"birth":99,"number":n+10,"executable":base+name+".app/Contents/MacOS/FieldNotes","identifier":id,"hash":String(repeating:"d",count:40)]
        }
        return ["operation":op.uuidString,"generation":UUID().uuidString,"observerSession":UUID().uuidString,
                "home":"/private/test","hostPID":123,"hostBirth":42,"hostHash":String(repeating:"c",count:40),"revision":String(repeating:"b",count:40),
                "issued":10.0,"expires":16.0,"observerPID":456,"observerBirth":89,"observerHash":String(repeating:"a",count:40),
                "observerExecutable":"/private/tmp/nearpane-p0-drift.test/p0-drift-reader","target":17,
                "topology":["display":display.uuidString,"current":12,"records":[["id":12,"type":0,"uuid":a.uuidString],["id":17,"type":0,"uuid":b.uuidString]]],
                "sourceWindow":window(41,"Field Notes","net.example.spaces-document"),"targetWindow":window(42,"Route Notes","net.example.spaces-route-witness"),
                "hid":Array(repeating:1,count:8),"additionalHID":Array(repeating:2,count:8)]
    }

    func envelope(_ p: [String:Any], _ key: Curve25519.Signing.PrivateKey) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject:p)
        return try JSONEncoder().encode(P0DiagnosticLease.Envelope(payload:bytes,signature:try key.signature(for:bytes)))
    }

    @Test func onlyExactSignedSelectOfAHeldWindowCanUseTheGrant() throws {
        let key = Curve25519.Signing.PrivateKey(), signed = try envelope(payload(),key)
        let grant = try P0DiagnosticLease.decoded(signed,key:key.publicKey,now:13)
        func request(_ id: UUID, _ target: String, _ member: NativeSpaceWindow?, original: UUID?) -> NativeSpaceCommand {
            .init(id:id,action:.select,display:display.uuidString,source:"12",target:target,sourceUUID:a,targetUUID:b,
                  window:member,originalWindow:original)
        }
        #expect(grant.matches(request(op,"17",grant.targetWindow.identity,original:UUID())))
        #expect(!grant.matches(request(UUID(),"17",grant.targetWindow.identity,original:UUID())))
        #expect(!grant.matches(request(op,"12",grant.targetWindow.identity,original:UUID())))
        #expect(!grant.matches(request(op,"17",grant.sourceWindow.identity,original:UUID())))
        #expect(!grant.matches(request(op,"17",grant.targetWindow.identity,original:nil)))
        #expect(!grant.matches(.init(id:op,action:.probe,display:display.uuidString,source:"",target:"")))
        #expect(throws:(any Error).self) { try P0DiagnosticLease.decoded(signed,key:Curve25519.Signing.PrivateKey().publicKey,now:13) }
        #expect(throws:(any Error).self) { try P0DiagnosticLease.decoded(signed,key:key.publicKey,now:17) }
        var changed=payload()
        changed["target"]=12
        #expect(throws:(any Error).self) { try P0DiagnosticLease.decoded(envelope(changed,key),key:key.publicKey,now:13) }
        changed=payload()
        var window=try #require(changed["targetWindow"] as? [String:Any])
        window["executable"]="/Applications/Private.app/Contents/MacOS/Private"
        changed["targetWindow"]=window
        #expect(throws:(any Error).self) { try P0DiagnosticLease.decoded(envelope(changed,key),key:key.publicKey,now:13) }
    }

    @Test func concurrentAndRestartedClaimsConsumeOnlyOneSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let folder = root.appendingPathComponent("spent"), key = String(repeating:"e",count:64)
        let ids = await withTaskGroup(of:UUID?.self) { tasks in
            for _ in 0..<16 {
                tasks.addTask {
                    let candidate = UUID()
                    do { try P0DiagnosticLease.spend(in:folder,campaign:key,operation:candidate); return candidate }
                    catch { return nil }
                }
            }
            var ids = [UUID]()
            for await item in tasks { if let item { ids.append(item) } }
            return ids
        }
        #expect(ids.count == 1)
        let stored = try String(contentsOf:folder.appendingPathComponent(key),encoding:.utf8)
        #expect(stored == ids.first?.uuidString)
        #expect(throws:(any Error).self) { try P0DiagnosticLease.spend(in:folder,campaign:key,operation:UUID()) }
    }
}
#endif
