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
    public let bottomSitesOnly: Bool
    let measuredReturn: Bool
    public let frame, target: SurfaceRect?
    public init(backend: UInt32, operation: UInt32, intent: UUID, group: UUID? = nil,
                scope: StageGroupScope? = nil, member: UUID? = nil, lifetime: UUID? = nil,
                generation: UUID? = nil, window: NativeSpaceWindow? = nil, nativeID: UInt64 = 0,
                frame: SurfaceRect? = nil, target: SurfaceRect? = nil, bottomSitesOnly: Bool = false,
                measuredReturn: Bool = false) {
        self.backend = backend; self.operation = operation; self.intent = intent; self.group = group
        self.scope = scope; self.member = member; self.lifetime = lifetime; self.generation = generation
        self.window = window; self.nativeID = nativeID; self.frame = frame; self.target = target
        self.bottomSitesOnly = bottomSitesOnly
        self.measuredReturn = measuredReturn
    }
}
public struct NativeStageEngineReceipt: Sendable {
    public let status, flags, detail, owned: UInt32
    public let nativeID, epoch: UInt64
    public let frame: SurfaceRect
    public let intent: UUID
}
public enum NativeStageEngineError: Error { case transport(UInt32), correlation }

struct CornerGuardianPeer: Sendable {
    let pid: Int32
    let birth: UInt64
    let writer: FileHandle
}

/// Submission copies PODs immediately. Revocation is safe from the main actor even
/// when another actor is waiting on an Accessibility call. Rust retains no Swift objects.
public actor NativeStageWindowEngine {
    private nonisolated let handle: UInt64
    nonisolated let qualifiedEpoch: UInt64?
    public init?() {
        var config = NPConfig(), created: UInt64 = 0
        config.version = UInt32(NP_ENGINE_ABI); config.size = UInt32(MemoryLayout<NPConfig>.size)
        guard np_engine_create(&config, &created) == NP_OK else { return nil }
        handle = created
        qualifiedEpoch = nil
    }
    public init?(qualifiedBackend: UInt32, evidence: UUID) {
        var bytes = evidence.uuid
        var created: UInt64 = 0
        let status = withUnsafeBytes(of: &bytes) {
            np_engine_create_qualified(qualifiedBackend, $0.bindMemory(to: UInt8.self).baseAddress, &created)
        }
        guard status == NP_OK else { return nil }
        var epoch: UInt64 = 0
        guard np_engine_epoch(created, &epoch) == NP_OK, epoch > 0 else {
            _ = np_engine_destroy(created)
            return nil
        }
        handle = created
        qualifiedEpoch = epoch
    }
    deinit { _ = np_engine_destroy(handle) }
    public nonisolated func revoke() { _ = np_engine_revoke(handle) }
    public nonisolated func currentEpoch() throws -> UInt64 {
        var epoch: UInt64 = 0
        let code = np_engine_epoch(handle, &epoch)
        guard code == NP_OK else { throw NativeStageEngineError.transport(code) }
        return epoch
    }
    @discardableResult public func close() -> Bool { np_engine_destroy(handle) == NP_OK }
    public func launchSpaces(expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try await submit(.init(backend: UInt32(NP_SPACES), operation: UInt32(NP_LAUNCH), intent: UUID()),
                         timeoutMilliseconds: 9_000, expectedEpoch: expectedEpoch)
    }
    public func cleanSpacesLaunch(expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try await submit(.init(backend: UInt32(NP_SPACES), operation: UInt32(NP_CLEAN_LAUNCH), intent: UUID()),
                         timeoutMilliseconds: 9_000, expectedEpoch: expectedEpoch)
    }
    private nonisolated static func encode(_ input: NativeStageEngineRequest, timeout: UInt32, epoch: UInt64) -> NPRequest {
        var request = NPRequest()
        request.size = UInt32(MemoryLayout<NPRequest>.size); request.version = UInt32(NP_ENGINE_ABI)
        request.backend = input.backend; request.operation = input.operation; request.timeout_ms = timeout
        if input.bottomSitesOnly { request.flags = UInt32(NP_CORNER_BOTTOM_SITES_ONLY) }
        if input.measuredReturn { request.flags |= UInt32(NP_CORNER_RETURN_MEASURED) }
        request.epoch = epoch
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
        return request
    }
    nonisolated func excludeUnsubmittedHide(_ input: NativeStageEngineRequest, epoch: UInt64) throws {
        guard epoch == qualifiedEpoch else { throw NativeStageEngineError.correlation }
        var request = Self.encode(input, timeout: 1000, epoch: epoch)
        let status = np_engine_fence_unsubmitted_corner_hide(handle, &request)
        guard status == NP_OK else { throw NativeStageEngineError.transport(status) }
    }
    /// The installed transport supplies the epoch it observed before its actor hop. Rust checks
    /// that epoch again on admission and immediately before each authorized system write.
    public func submit(_ input: NativeStageEngineRequest, timeoutMilliseconds: UInt32 = 1000,
                       expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try await submit(input, timeoutMilliseconds: timeoutMilliseconds, expectedEpoch: expectedEpoch, guardian: nil)
    }

    func submit(_ input: NativeStageEngineRequest, timeoutMilliseconds: UInt32 = 1000,
                expectedEpoch: UInt64?, guardian: CornerGuardianPeer?) async throws -> NativeStageEngineReceipt {
        if Task.isCancelled {
            if guardian != nil { throw CornerHideAdmissionRefused(CancellationError()) }
            throw CancellationError()
        }
        let epoch = try expectedEpoch ?? qualifiedEpoch ?? currentEpoch()
        var request = Self.encode(input, timeout: timeoutMilliseconds, epoch: epoch), ticket: UInt64 = 0
        let submitStatus: UInt32
        if let guardian {
            submitStatus = np_engine_submit_witnessed_corner_hide(handle, &request, guardian.pid, guardian.birth,
                                                                  guardian.writer.fileDescriptor, &ticket)
        } else {
            submitStatus = np_engine_submit(handle, &request, &ticket)
        }
        guard submitStatus == NP_OK else {
            let cause = NativeStageEngineError.transport(submitStatus)
            if guardian != nil, ticket == 0 { throw CornerHideAdmissionRefused(cause) }
            throw cause
        }
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
                    owned: result.owned, nativeID: result.native_id, epoch: result.epoch,
                    frame: SurfaceRect(x: result.frame.x, y: result.frame.y, width: result.frame.width, height: result.frame.height),
                    intent: id)
            }
        } onCancel: { [handle] in _ = np_engine_cancel(handle, accepted) }
    }
}

/// Receipt checks for the nonce-bound native Spaces research trial.
enum SpacesResearchReceipt {
    static func launchConfirmed(_ receipt: NativeStageEngineReceipt, expectedEpoch: UInt64, observedEpoch: UInt64,
                                            expectedHome: UInt64?) -> Bool {
        let required: UInt32 = 64 | 8 | 32 | 256 | 512 | 1024
        return expectedEpoch > 0 && receipt.epoch == expectedEpoch && expectedEpoch == observedEpoch && receipt.status == 0 &&
            receipt.flags & required == required && receipt.flags & (128 | 2) == 0 && receipt.owned == 0 &&
            receipt.nativeID > 0 && expectedHome.map { $0 == receipt.nativeID } != false
    }

    static func cleanupConfirmed(_ receipt: NativeStageEngineReceipt, observedEpoch: UInt64) -> Bool {
        let cleared: UInt32 = 256 | 512 | 1024 | 32
        return receipt.status == 0 && receipt.owned == 0 && receipt.epoch > 0 && receipt.epoch == observedEpoch &&
            receipt.flags & cleared == cleared && receipt.flags & (128 | 2) == 0
    }
}
