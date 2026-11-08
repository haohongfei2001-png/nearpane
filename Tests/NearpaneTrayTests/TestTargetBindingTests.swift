import Foundation
import Testing
import RiftletAdapters
import RiftletCore
@testable import NearpaneTray

struct TestTargetBindingTests {
    @Test func acceptanceGateIsInstalledAtTheLockedSettersOnlyInTheBoundProgram() throws {
        let session = UUID().uuidString.lowercased()
        let binding = TestTargetBinding(session: session, process: "chrome-kernel-v1:12:3:4", window: "7", tab: "8",
            url: "https://chatgpt.com/c/test", nonce: UUID().uuidString.lowercased(), assetID: UUID().uuidString.lowercased(),
            sha256: String(repeating: "b", count: 64), timeOrigin: 123, boundAt: 100, expiresAt: 200)
        try binding.check(session: session, now: 101)
        #expect(throws: WebAdapterError.self) { try binding.check(session: session, now: 201) }
        #expect(throws: WebAdapterError.self) { try binding.check(session: UUID().uuidString, now: 101) }
        let original = try ChatGPTWebPageProgram.load()
        let result = try binding.program(original, guardSource: "function(){ throw Error('TARGET_INVALID'); }")
        #expect(result.functionSource.contains("nearpaneCheck(true, op.binding);\n      Reflect.apply(setter, input, [transfer.files])"))
        #expect(!original.functionSource.contains("nearpaneCheck"))
        #expect(throws: WebAdapterError.self) {
            try binding.program(WebPageProgram(sourceID: "changed", functionSource: "function(){}"), guardSource: "function(){}")
        }
    }
    @Test func aRestartedObserverCanOnlyReadTheOriginalClaim() throws {
        let session = UUID().uuidString.lowercased(), asset = UUID(), operation = UUID()
        let target = TargetLease(adapterID: "chatgpt-web", surface: .webChat, applicationID: "com.google.Chrome",
            sessionID: "chrome-kernel-v1:13:8:5", windowID: "3", tabID: "4", documentID: "doc", composerID: "c", draftGeneration: "g")
        let b = TestTargetBinding(session: session, process: target.sessionID, window: "3", tab: "4", url: "https://chatgpt.com/c/test",
            nonce: UUID().uuidString.lowercased(), assetID: asset.uuidString.lowercased(), sha256: String(repeating: "d",count: 64),
            timeOrigin: 100, boundAt: 100, expiresAt: 300)
        let first = ObservationIdentity(operationID: operation, assetID: asset, attempt: 1, assetSHA256: b.sha256, target: target)
        let claim = TestInputClaim(session: session, nonce: b.nonce, invocationID: UUID(), claimedAt: 150, identity: first)
        #expect(claim.permitsObservation(first,binding: b))
        #expect(!claim.permitsObservation(nil,binding: b))
        let foreign = ObservationIdentity(operationID: UUID(),assetID: asset,attempt: 1,assetSHA256: b.sha256,target: target)
        let retry = ObservationIdentity(operationID: operation,assetID: asset,attempt: 2,assetSHA256: b.sha256,target: target)
        let foreignAllowed = claim.permitsObservation(foreign,binding: b)
        let retryAllowed = claim.permitsObservation(retry,binding: b)
        #expect(foreignAllowed == false)
        #expect(retryAllowed == false)
    }
}
