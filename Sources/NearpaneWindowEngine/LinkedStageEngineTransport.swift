import Foundation
import NearpaneCore

/// The linked Rust actor is instantiated only after the Host has chosen a qualified backend and admitted
/// the user's group operation. Independent OS readback is still required by StageGroupCoordinator.
@MainActor final class LinkedStageEngineTransport: StageEngineTransport {
    private let engine: NativeStageWindowEngine
    init?() {
        guard let engine = NativeStageWindowEngine() else { return nil }
        self.engine = engine
    }
    func submit(_ operation: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) async throws -> StageEngineReply {
        let request = NativeStageEngineRequest(backend: owner.backend == .corner ? 1 : 2, operation: operation,
            intent: c.intent, group: c.group, scope: c.scope, member: c.member, lifetime: c.before.lifetime,
            generation: c.generation, window: c.before.window, nativeID: c.nativeID ?? 0,
            frame: c.action == .show ? c.restoreFrame : c.before.frame, target: c.restoreFrame)
        let receipt = try await engine.submit(request)
        return .init(status: receipt.status, flags: receipt.flags, intent: receipt.intent, nativeID: receipt.nativeID,frame:receipt.frame)
    }
    func revoke() { engine.revoke() }
    func close() async -> Bool { await engine.close() }
}

public extension StageEngineSession {
    convenience init?(owner: StageEngineOwner, witness: any StageEngineWindowWitness) {
        guard let transport = LinkedStageEngineTransport() else { return nil }
        self.init(owner: owner, witness: witness, transport: transport)
    }
}
