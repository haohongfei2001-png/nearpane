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
        #expect(result.functionSource.contains("nearpaneCheck(true);\n      Reflect.apply(setter, input, [transfer.files])"))
        #expect(!original.functionSource.contains("nearpaneCheck"))
        #expect(throws: WebAdapterError.self) {
            try binding.program(WebPageProgram(sourceID: "changed", functionSource: "function(){}"), guardSource: "function(){}")
        }
    }
}
