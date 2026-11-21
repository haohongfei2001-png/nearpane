import Foundation
import CNearpaneWindowEngine
import NearpaneCore

public struct NativeStageEngineRequest: Sendable {
    public let backend, operation: UInt32
    public let intent: UUID
    public let group, member, lifetime, generation: UUID?
    public let scope: StageGroupScope?
    public let window: NativeSpaceWindow?
    public let nativeID: UInt64
    public let frame, target: SurfaceRect?
    public init(backend: UInt32, operation: UInt32, intent: UUID, group: UUID? = nil,
                scope: StageGroupScope? = nil, member: UUID? = nil, lifetime: UUID? = nil,
                generation: UUID? = nil, window: NativeSpaceWindow? = nil, nativeID: UInt64 = 0,
                frame: SurfaceRect? = nil, target: SurfaceRect? = nil) {
        self.backend = backend; self.operation = operation; self.intent = intent; self.group = group
        self.scope = scope; self.member = member; self.lifetime = lifetime; self.generation = generation
        self.window = window; self.nativeID = nativeID; self.frame = frame; self.target = target
    }
}
public struct NativeStageEngineReceipt: Sendable {
    public let status, flags, detail, owned: UInt32
    public let nativeID: UInt64
    public let frame: SurfaceRect
    public let intent: UUID
}
public enum NativeStageEngineError: Error { case transport(UInt32), correlation }

/// Submission copies PODs immediately. Revocation is safe from the main actor even
/// when another actor is waiting on an Accessibility call. Rust retains no Swift objects.
public actor NativeStageWindowEngine {
    private nonisolated let handle: UInt64
    public init?() {
        var config = NPConfig(), created: UInt64 = 0
        config.version = UInt32(NP_ENGINE_ABI); config.size = UInt32(MemoryLayout<NPConfig>.size)
        guard np_engine_create(&config, &created) == NP_OK else { return nil }
        handle = created
    }
    deinit { _ = np_engine_destroy(handle) }
    public nonisolated func revoke() { _ = np_engine_revoke(handle) }
    @discardableResult public func close() -> Bool { np_engine_destroy(handle) == NP_OK }
    public func submit(_ input: NativeStageEngineRequest, timeoutMilliseconds: UInt32 = 1000) async throws -> NativeStageEngineReceipt {
        var request = NPRequest(), ticket: UInt64 = 0
        request.size = UInt32(MemoryLayout<NPRequest>.size); request.version = UInt32(NP_ENGINE_ABI)
        request.backend = input.backend; request.operation = input.operation; request.timeout_ms = timeoutMilliseconds
        request.intent = input.intent.uuid
        if let id = input.group { request.group = id.uuid }
        if let scope = input.scope { request.display = scope.display.uuid; request.native_space = scope.nativeSpace.uuid }
        if let id = input.member { request.member = id.uuid }
        if let id = input.lifetime { request.lifetime = id.uuid }
        if let id = input.generation { request.generation = id.uuid }
        if let window = input.window { request.pid = window.pid; request.window = window.number; request.birth = window.birth }
        request.native_id = input.nativeID
        if let f = input.frame { request.frame = NPRect(x: f.x, y: f.y, width: f.width, height: f.height) }
        if let f = input.target { request.target = NPRect(x: f.x, y: f.y, width: f.width, height: f.height) }
        try Task.checkCancellation()
        let epochStatus = np_engine_epoch(handle, &request.epoch)
        guard epochStatus == NP_OK else { throw NativeStageEngineError.transport(epochStatus) }
        let submitStatus = np_engine_submit(handle, &request, &ticket)
        guard submitStatus == NP_OK else { throw NativeStageEngineError.transport(submitStatus) }
        let accepted = ticket, usedEpoch = request.epoch
        return try await withTaskCancellationHandler {
            // Always consume the terminal receipt, including after Swift task cancellation.
            while true {
                var result = NPReceipt()
                result.size = UInt32(MemoryLayout<NPReceipt>.size); result.version = UInt32(NP_ENGINE_ABI)
                let code = np_engine_poll(handle, accepted, &result)
                if code == NP_PENDING {
                    // A cancelled parent would spin if it slept directly.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(2)) }.value
                    continue
                }
                guard code == NP_OK else { throw NativeStageEngineError.transport(code) }
                let id = UUID(uuid: result.intent)
                guard id == input.intent, result.epoch == usedEpoch else { throw NativeStageEngineError.correlation }
                return NativeStageEngineReceipt(status: result.status, flags: result.flags, detail: result.detail,
                    owned: result.owned, nativeID: result.native_id,
                    frame: SurfaceRect(x: result.frame.x, y: result.frame.y, width: result.frame.width, height: result.frame.height),
                    intent: id)
            }
        } onCancel: { [handle] in _ = np_engine_cancel(handle, accepted) }
    }
}
