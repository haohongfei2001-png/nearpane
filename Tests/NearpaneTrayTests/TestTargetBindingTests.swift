import Foundation
import CryptoKit
import Testing
import RiftletAdapters
import RiftletCore
@testable import NearpaneTray

struct TestTargetBindingTests {
    @Test func completeLockedProgramRunsAgainstSyntheticFileReceivers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let b = TestTargetBinding(session: UUID().uuidString.lowercased(), process: "chrome-kernel-v1:12:3:4",
            window: "7", tab: "8", url: "https://chatgpt.com/c/test", nonce: UUID().uuidString.lowercased(),
            assetID: UUID().uuidString.lowercased(), sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            timeOrigin: 123, boundAt: 100, expiresAt: 200)
        let guardSource = try String(contentsOf: root.appendingPathComponent("Resources/AcceptanceTargetGuard.js"), encoding: .utf8)
        let program = try b.program(ChatGPTWebPageProgram.load(), guardSource: guardSource)
        struct Fixture: Encodable { let binding: TestTargetBinding; let source: String; let png: Data }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("nearpane-js-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try JSONEncoder().encode(Fixture(binding: b, source: program.functionSource, png: png)).write(to: fixture, options: .withoutOverwriting)
        let child = Process(), log = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", "--test", "--test-reporter=spec", "scripts/acceptance/test-composed-target.js"]
        child.currentDirectoryURL = root
        child.environment = ProcessInfo.processInfo.environment.merging(["NEARPANE_COMPOSED_FIXTURE":fixture.path]) { _, new in new }
        child.standardOutput = log; child.standardError = log
        try child.run()
        let output = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        print(output)
        #expect(child.terminationStatus == 0)
    }
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
        #expect(result.functionSource.contains("const receiver = nearpaneCheck(true, op.binding,"))
        #expect(result.functionSource.contains("""
        if (!receiver.ready(input)) return retire('targetInvalidBeforeInput', 'picker', 'targetChanged');
              op.inputCount = 1; op.inputSequence = tick(); op.inputTime = inputTime;
              diag.stage = 'setter'; diag.setterEntered = true;
              Reflect.apply(setter, input, [transfer.files]);
        """))
        #expect(result.functionSource.contains("receiver.require(input);\n      input.dispatchEvent(new Event('input'"))
        #expect(result.functionSource.contains("receiver.require(input);\n      input.dispatchEvent(new Event('change'"))
        #expect(!original.functionSource.contains("nearpaneCheck"))
        #expect(throws: WebAdapterError.self) {
            try binding.program(WebPageProgram(sourceID: "changed", functionSource: "function(){}"), guardSource: "function(){}")
        }
        // Even an added, unreviewed path that leaves every injection anchor intact must be refused.
        let drift = original.functionSource.replacingOccurrences(of: "op.binding.input = input;",
            with: "op.binding.input = input; input.dispatchEvent(new Event('change'));")
        #expect(throws: WebAdapterError.self) {
            try binding.program(WebPageProgram(sourceID: original.sourceID, functionSource: drift), guardSource: "function(){}")
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
