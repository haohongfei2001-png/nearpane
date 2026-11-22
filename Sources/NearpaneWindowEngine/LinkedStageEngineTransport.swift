import Foundation
import NearpaneCore

/// Concrete visibility port for the Host. The ordinary controller and desktop reader never link it.
@MainActor final class LinkedStageEngineTransport: StageEngineTransport {
    private let engine: NativeStageWindowEngine
    private let acquiredOwner: StageEngineOwner
    private let acquisitionEpoch: UInt64
    private let guardian: CornerGuardianClient?
    private var startup: (epoch:UInt64, task:Task<NativeStageEngineReceipt,Error>)?
    private var startupHome: UInt64?
    private var startupFailed = false
    private var cleanup: Task<NativeStageEngineReceipt,Error>?
    func start(_ owner: StageEngineOwner, nativeID: UInt64) async throws {
        _ = try commandEpoch(owner)
        if owner.backend == .spaces { try await readySpaces(expectedHome:nativeID) }
    }
    init?(owner: StageEngineOwner, profile: URL) {
        guard let engine = NativeStageWindowEngine(qualifiedBackend:owner.backend == .corner ? 1 : 2,evidence:owner.evidence),
              let epoch = engine.qualifiedEpoch else { return nil }
        self.engine = engine
        acquiredOwner = owner
        acquisitionEpoch = epoch
        guardian = owner.backend == .corner ? CornerGuardianClient(profile:profile) : nil
    }

    private func commandEpoch(_ owner: StageEngineOwner, restoring: Bool = false) throws -> UInt64 {
        guard owner == acquiredOwner else { throw StageSwitchError.ownership }
        let current = try engine.currentEpoch()
        guard restoring || current == acquisitionEpoch else { throw StageSwitchError.interrupted }
        return current
    }

    nonisolated static func launchConfirmed(_ receipt: NativeStageEngineReceipt, expectedEpoch: UInt64, observedEpoch: UInt64,
                                            expectedHome: UInt64?) -> Bool {
        let required: UInt32 = 64 | 8 | 32 | 256 | 512 | 1024
        return expectedEpoch > 0 && receipt.epoch == expectedEpoch && expectedEpoch == observedEpoch && receipt.status == 0 &&
            receipt.flags & required == required && receipt.flags & (128 | 2) == 0 && receipt.owned == 0 &&
            receipt.nativeID > 0 && expectedHome.map { $0 == receipt.nativeID } != false
    }

    nonisolated static func cleanupConfirmed(_ receipt: NativeStageEngineReceipt, observedEpoch: UInt64) -> Bool {
        let cleared: UInt32 = 256 | 512 | 1024 | 32
        return receipt.status == 0 && receipt.owned == 0 && receipt.epoch > 0 && receipt.epoch == observedEpoch &&
            receipt.flags & cleared == cleared && receipt.flags & (128 | 2) == 0
    }

    private func readySpaces(expectedHome: UInt64?) async throws {
        guard try engine.currentEpoch() == acquisitionEpoch else { throw StageSwitchError.interrupted }
        guard !startupFailed else { throw StageSwitchError.unavailable }
        if let home = startupHome {
            guard expectedHome.map({ $0 == home }) != false, startup?.epoch == (try engine.currentEpoch()) else { throw StageSwitchError.interrupted }
            return
        }
        let initial: (epoch:UInt64,task:Task<NativeStageEngineReceipt,Error>)
        if let startup { initial = startup }
        else {
            let epoch = acquisitionEpoch
            let task = Task { [engine] in try await engine.launchSpaces(expectedEpoch: epoch) }
            initial = (epoch,task)
            startup = initial
        }
        do {
            let receipt = try await initial.task.value
            guard Self.launchConfirmed(receipt,expectedEpoch:initial.epoch,observedEpoch:try engine.currentEpoch(),
                                       expectedHome:expectedHome) else {
                throw StageSwitchError.unavailable
            }
            startupHome = receipt.nativeID
        } catch {
            startupFailed = true
            throw error
        }
    }

    private func request(_ operation: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) -> NativeStageEngineRequest {
        .init(backend:owner.backend == .corner ? 1 : 2,operation:operation,intent:c.intent,group:c.group,scope:c.scope,
              member:c.member,lifetime:c.before.lifetime,generation:c.generation,window:c.before.window,nativeID:c.nativeID ?? 0,
              frame:c.action == .show ? c.restoreFrame : c.before.frame,target:c.restoreFrame)
    }
    func prepareHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws {
        guard let guardian, owner.backend == .corner, c.action == .hide else { throw StageSwitchError.ownership }
        let epoch = try commandEpoch(owner)
        try await guardian.prepare(request(3,owner:owner,c),epoch:epoch)
    }
    func withdrawUnsubmittedHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool {
        guard owner == acquiredOwner, owner.backend == .corner, let guardian,
              c.action == .hide, !c.restoring, c.generation == owner.generation else { return false }
        let hide = request(3, owner: owner, c)
        return try await guardian.withdraw(hide, epoch: acquisitionEpoch) {
            try engine.excludeUnsubmittedHide(hide, epoch: acquisitionEpoch)
        }
    }
    func submit(_ operation: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) async throws -> StageEngineReply {
        let restoring = c.restoring && c.action == .show && (operation == 5 || operation == 2)
        guard operation != 5 || restoring else { throw StageSwitchError.ownership }
        let epoch = try commandEpoch(owner, restoring: restoring)
        if owner.backend == .spaces, operation == 6 { try await readySpaces(expectedHome:c.nativeID) }
        if owner.backend == .spaces, operation == 3 || operation == 4 {
            guard startupHome == c.nativeID, !startupFailed else { throw StageSwitchError.unavailable }
        }
        let command = request(operation,owner:owner,c)
        let receipt = try await engine.submit(command, expectedEpoch: epoch)
        if c.action == .hide, operation == 3 || operation == 2 { try guardian?.observe(command,receipt:receipt) }
        guard try engine.currentEpoch() == epoch else { throw StageSwitchError.interrupted }
        return .init(status:receipt.status,flags:receipt.flags,intent:receipt.intent,nativeID:receipt.nativeID,frame:receipt.frame)
    }
    func verified(_ c: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws {
        guard let guardian, owner == acquiredOwner, owner.backend == .corner else { throw StageSwitchError.ownership }
        switch c.action {
        case .hide: try await guardian.confirm(request(3,owner:owner,c),verifiedFrame:after.frame)
        case .show: try await guardian.disarm(request(c.restoring ? 5 : 4,owner:owner,c))
        default: throw StageSwitchError.ownership
        }
    }
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply {
        let epoch = try commandEpoch(owner)
        if owner.backend == .spaces { try await readySpaces(expectedHome:nil) }
        let r = try await engine.submit(.init(backend:owner.backend == .corner ? 1 : 2,operation:6,intent:intent), expectedEpoch: epoch)
        guard try engine.currentEpoch() == epoch else { throw StageSwitchError.interrupted }
        return .init(status:r.status,flags:r.flags,intent:r.intent,nativeID:r.nativeID,frame:r.frame)
    }
    func revoke() { engine.revoke() }
    func close() async -> Bool {
        do {
            try await guardian?.finish()
            if startup != nil && startupHome == nil {
                if cleanup == nil {
                    let epoch = try engine.currentEpoch()
                    cleanup = Task { [engine] in try await engine.cleanSpacesLaunch(expectedEpoch: epoch) }
                }
                guard let receipt = try await cleanup?.value else { return false }
                guard Self.cleanupConfirmed(receipt,observedEpoch:try engine.currentEpoch()) else { return false }
            }
        } catch { return false }
        return await engine.close()
    }
}

public extension StageEngineSession {
    convenience init?(owner: StageEngineOwner, witness: any StageEngineWindowWitness, profile: URL) {
        guard let transport = LinkedStageEngineTransport(owner:owner,profile:profile) else { return nil }
        self.init(owner:owner,witness:witness,transport:transport)
    }
}
