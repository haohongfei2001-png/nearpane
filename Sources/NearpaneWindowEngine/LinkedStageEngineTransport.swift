import CNearpaneWindowEngine
import Foundation
import NearpaneCore

private extension NativeStageEngineReceipt {
    var stageReply: StageEngineReply {
        let obstructed = detail == NP_CORNER_SITE_DESKTOP || detail == NP_CORNER_SITE_OVERLAY || detail == NP_CORNER_SITE_DOCK
        return .init(status: status, flags: flags, intent: intent, nativeID: nativeID, frame: frame,
                     workAreaObstructed: status == NP_UNKNOWN && (flags == 0 || flags == NP_OWNED) && obstructed)
    }
}

/// Concrete visibility port for the Host. The ordinary controller and desktop reader never link it.
@MainActor final class LinkedStageEngineTransport: StageEngineTransport {
    private let engine: NativeStageWindowEngine
    private let acquiredOwner: StageEngineOwner
    private let acquisitionEpoch: UInt64
    private let guardian: CornerGuardianClient

    func start(_ owner: StageEngineOwner, nativeID: UInt64) async throws {
        guard nativeID > 0 else { throw StageSwitchError.incomplete }
        _ = try commandEpoch(owner)
    }

    func checkRetirementSurface(_ scope: StageGroupScope, nativeID: UInt64, bottomOnly: Bool, owner: StageEngineOwner) async throws {
        let epoch = try commandEpoch(owner), intent = UUID()
        let permissionIntent = UUID()
        let access = try await engine.submit(.init(backend: UInt32(NP_CORNER), operation: UInt32(NP_CORNER_PARK_ACCESS),
                                                   intent: permissionIntent), expectedEpoch: epoch)
        guard access.epoch == epoch, access.intent == permissionIntent, access.status == NP_PASS, access.flags == 0
        else { throw StageSwitchError.unavailable }
        let request = NativeStageEngineRequest(backend: UInt32(NP_CORNER), operation: UInt32(NP_CORNER_RETIREMENT_SURFACE),
                                               intent: intent, scope: scope, nativeID: nativeID, bottomSitesOnly: bottomOnly)
        let read = try await engine.submit(request, timeoutMilliseconds: 4_000, expectedEpoch: epoch)
        guard try engine.currentEpoch() == epoch, read.epoch == epoch, read.intent == intent,
              read.status == NP_PASS, read.detail == NP_CORNER_MATERIAL_WALLPAPER_SURFACE,
              read.flags == 0, read.nativeID == nativeID,
              read.frame.width > 0, read.frame.height > 0 else { throw StageSwitchError.unavailable }
    }

    init?(owner: StageEngineOwner, profile: URL, releaseExited: @escaping @MainActor (UUID) -> Void) {
        guard owner.backend == .corner,
              let engine = NativeStageWindowEngine(qualifiedBackend: UInt32(NP_CORNER), evidence: owner.evidence),
              let epoch = engine.qualifiedEpoch else { return nil }
        self.engine = engine
        acquiredOwner = owner
        acquisitionEpoch = epoch
        guardian = CornerGuardianClient(profile: profile, releaseExited: releaseExited)
    }

    private func commandEpoch(_ owner: StageEngineOwner, restoring: Bool = false) throws -> UInt64 {
        guard owner == acquiredOwner else { throw StageSwitchError.ownership }
        let current = try engine.currentEpoch()
        guard restoring || current == acquisitionEpoch else { throw StageSwitchError.interrupted }
        return current
    }

    private func request(_ operation: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) -> NativeStageEngineRequest {
        .init(backend:UInt32(NP_CORNER),operation:operation,intent:c.intent,group:c.group,scope:c.scope,
              member:c.member,lifetime:c.before.lifetime,generation:c.generation,window:c.before.window,nativeID:c.nativeID ?? 0,
              frame:c.action == .show ? c.restoreFrame : c.before.frame,target:c.restoreFrame)
    }
    func prepareHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws {
        guard owner.backend == .corner, c.action == .hide else { throw StageSwitchError.ownership }
        let epoch = try commandEpoch(owner)
        try await guardian.prepare(request(3,owner:owner,c),epoch:epoch)
    }
    func withdrawUnsubmittedHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool {
        guard owner == acquiredOwner, owner.backend == .corner,
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
        let command = request(operation,owner:owner,c)
        if operation == NP_HEALTH || operation == NP_HIDE || operation == NP_SHOW { try guardian.checkLiveOwners() }
        let peer = operation == 3 ? try guardian.preparedPeer(for: command, epoch: epoch) : nil
        // A guarded hide includes the settled AX position and the asynchronous compositor comparison.
        // Cancellation and the Guardian handoff remain live during that read-only interval.
        let timeout: UInt32 = operation == NP_HIDE ? 2_500 : 1_000
        let receipt = try await engine.submit(command, timeoutMilliseconds: timeout, expectedEpoch: epoch, guardian: peer)
        if c.action == .hide, operation == 3 { try await guardian.observe(command,receipt:receipt) }
        guard try engine.currentEpoch() == epoch else { throw StageSwitchError.interrupted }
        return receipt.stageReply
    }
    func verified(_ c: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws {
        guard owner == acquiredOwner, owner.backend == .corner else { throw StageSwitchError.ownership }
        switch c.action {
        case .hide: try await guardian.confirm(request(3,owner:owner,c),verifiedFrame:after.frame)
        case .show: try await guardian.disarm(request(c.restoring ? 5 : 4,owner:owner,c))
        default: throw StageSwitchError.ownership
        }
    }
    func readsFinalRelease(_ c: StageWindowCommand, owner: StageEngineOwner) async -> Bool {
        guard owner == acquiredOwner else { return false }
        return guardian.consumeFinalRelease(request(5, owner: owner, c))
    }
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply {
        let epoch = try commandEpoch(owner)
        try guardian.checkLiveOwners()
        let r = try await engine.submit(.init(backend:UInt32(NP_CORNER),operation:6,intent:intent), expectedEpoch: epoch)
        guard try engine.currentEpoch() == epoch else { throw StageSwitchError.interrupted }
        return r.stageReply
    }
    func revoke() { engine.revoke() }
    func close() async -> Bool {
        do {
            try await guardian.finish()
        } catch { return false }
        return await engine.close()
    }
}

public extension StageEngineSession {
    convenience init?(owner: StageEngineOwner, witness: any StageEngineWindowWitness, profile: URL,
                      releaseExited: @escaping @MainActor (UUID) -> Void = { _ in }) {
        guard let transport = LinkedStageEngineTransport(owner:owner,profile:profile,releaseExited:releaseExited) else { return nil }
        self.init(owner:owner,witness:witness,transport:transport)
    }
}
