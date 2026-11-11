import Foundation
import Testing
import RiftletCore
@testable import RiftletAdapters
@testable import NearpaneTray

@MainActor struct ProductDraftExecutorTests {
    private final class Browser: WebClickTargetPinning {
        let target: TargetLease
        var actions = [WebBridgeAction]()
        init(_ target: TargetLease) { self.target = target }
        func targetForClick(program: WebPageProgram) throws -> Task<TargetLease, Error> {
            let captured = target
            return Task { captured }
        }
        func execute(_ command: WebBridgeCommand, program: WebPageProgram) async throws -> Data {
            actions.append(command.action)
            // Chrome received commit but its reply did not reach the caller.
            if command.action == .commit { throw WebAdapterError.invalidReply }
            return Data()
        }
    }

    @Test func newExplicitAttemptAfterUnusedPressCanCommitButLostReplyCannotBeReplayed() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory:true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at: root) }
        let nonce = UUID(), asset = ImportedAsset(sourceKey:"fixture",fileName:"fixture.png",sha256:String(repeating:"f",count:64),
                                                   byteCount:400,pixelWidth:12,pixelHeight:9,mediaType:"image/png")
        let lease = TargetLease(adapterID:"chatgpt-web",surface:.webChat,applicationID:"com.google.Chrome",
            sessionID:"chrome-kernel-v1:42:10:2",windowID:"3",tabID:"7",documentID:"doc",composerID:"editor",draftGeneration:"draft",clickBindingID:nonce)
        let browser = Browser(lease), now = Date().timeIntervalSince1970
        let binding = ProductDraftBinding(nonce:nonce.uuidString.lowercased(),process:lease.sessionID,window:"3",tab:"7",assetID:asset.id.uuidString.lowercased(),
                                          sha256:asset.sha256,boundAt:now,expiresAt:now+60,timeOrigin:1)
        let code = try ChatGPTWebPageProgram.load()
        let first = ProductDraftExecutor(root:root,base:browser,guardSource:"function(){}",arm:{ _ in binding },selected:{ _ in })
        try first.checkAsset(asset)
        let target = try await first.targetForClick(program:code).value
        let unused = ObservationIdentity(operationID: UUID(), assetID: asset.id, attempt: 1,
                                         assetSHA256: asset.sha256, target: target)
        let unusedInvocation = UUID()
        _ = try await first.execute(.init(action:.begin, target:target, identity:unused,
                                         invocationID:unusedInvocation), program:code)
        _ = try await first.execute(.init(action:.discard,target:target,identity:unused,
                                         invocationID:unusedInvocation),program:code)
        first.cancelSelections()
        try first.checkAsset(asset)
        let fresh = try await first.targetForClick(program:code).value
        let id = ObservationIdentity(operationID:UUID(),assetID:asset.id,attempt:2,assetSHA256:asset.sha256,target:fresh)
        let invocation = UUID()
        func command(_ action: WebBridgeAction, id: ObservationIdentity, invocationID: UUID) -> WebBridgeCommand {
            WebBridgeCommand(action:action,target:id.target,identity:id,invocationID:invocationID)
        }
        _ = try await first.execute(command(.begin,id:id,invocationID:invocation),program:code)
        await #expect(throws: WebAdapterError.self) {
            _ = try await first.execute(command(.commit,id:id,invocationID:UUID()),program:code)
        }
        #expect(browser.actions == [.begin,.discard,.begin])
        await #expect(throws: WebAdapterError.self) {
            _ = try await first.execute(command(.commit,id:id,invocationID:invocation),program:code)
        }
        let second = ProductDraftExecutor(root:root,base:browser,guardSource:"function(){}",arm:{ _ in
            throw WebAdapterError.captureSuperseded
        },selected:{ _ in })
        try second.checkAsset(asset)
        let previous = try await second.targetForClick(program:code).value
        #expect(target == previous)
        await #expect(throws: WebAdapterError.self) {
            _ = try await second.execute(command(.commit,id:id,invocationID:invocation),program:code)
        }
        let other = ObservationIdentity(operationID:UUID(),assetID:asset.id,attempt:1,assetSHA256:asset.sha256,target:lease)
        await #expect(throws: WebAdapterError.self) {
            _ = try await second.execute(command(.observe,id:other,invocationID:invocation),program:code)
        }
        _ = try await second.execute(command(.observe,id:id,invocationID:invocation),program:code)
        #expect(browser.actions == [.begin,.discard,.begin,.commit,.observe])
    }
}
