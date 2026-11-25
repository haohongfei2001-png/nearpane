import CNearpaneWindowEngine
import Foundation
import NearpaneCore

/// The independent scheduler's candidate transport. Its only window-retirement
/// mechanism is a process-owned hidden Space; there is no visual cover, event tap,
/// Corner fallback, or control of Apple's thumbnail strip in this implementation.
@MainActor final class LinkedSpacesEngineTransport: StageEngineTransport {
    private let engine: SpacesEngineWorker
    private let owner: StageEngineOwner
    private let acquisitionEpoch: UInt64
    private var started = false

    init?(owner: StageEngineOwner, profile: URL) {
        guard owner.backend == .spaces,
              let engine = SpacesEngineWorker(profile: profile) else { return nil }
        self.engine = engine
        self.owner = owner
        acquisitionEpoch = engine.acquisitionEpoch
    }

    private func epoch(for requested: StageEngineOwner, restoring: Bool = false) throws -> UInt64 {
        guard requested == owner else { throw StageSwitchError.ownership }
        let current = try engine.currentEpoch()
        guard restoring || current == acquisitionEpoch else { throw StageSwitchError.interrupted }
        return current
    }

    func start(_ owner: StageEngineOwner, nativeID: UInt64) async throws {
        guard nativeID > 0 else { throw StageSwitchError.incomplete }
        let expected = try epoch(for: owner)
        if started { return }
        let result = try await engine.launchSpaces(expectedEpoch: expected)
        let observed = try engine.currentEpoch()
        guard SpacesResearchReceipt.launchConfirmed(result, expectedEpoch: expected,
                                                     observedEpoch: observed, expectedHome: nil)
        else { throw StageSwitchError.unavailable }
        // This means only the own-window launch check succeeded. The first external
        // hide still has to establish exclusive hidden membership and invisibility.
        started = true
    }

    func checkRetirementSurface(_ scope: StageGroupScope, nativeID: UInt64,
                                bottomOnly: Bool, owner: StageEngineOwner) async throws {
        _ = try epoch(for: owner)
        guard nativeID > 0 else { throw StageSwitchError.incomplete }
    }

    func prepareHide(_ command: StageWindowCommand, owner: StageEngineOwner) async throws {
        _ = try epoch(for: owner)
        guard started, command.action == .hide, command.generation == owner.generation,
              command.before.visibility == .visible || command.before.visibility == .minimized
        else { throw StageSwitchError.ownership }
    }

    func submit(_ operation: UInt32, owner: StageEngineOwner,
                _ command: StageWindowCommand) async throws -> StageEngineReply {
        let restoring = command.restoring && command.action == .show
        guard operation != NP_RESTORE || restoring else { throw StageSwitchError.ownership }
        let expected = try epoch(for: owner, restoring: restoring)
        let nativeOperation = operation == NP_HIDE && command.before.visibility == .minimized
            ? UInt32(NP_HIDE_MINIMIZED) : operation
        let request = NativeStageEngineRequest(backend: UInt32(NP_SPACES), operation: nativeOperation,
            intent: command.intent, group: command.group, scope: command.scope,
            member: command.member, lifetime: command.before.lifetime, generation: command.generation,
            window: command.before.window, nativeID: command.nativeID ?? 0,
            frame: command.before.frame, target: command.restoreFrame)
        let result = try await engine.submit(request, timeoutMilliseconds: 2_000, expectedEpoch: expected)
        guard try engine.currentEpoch() == expected else { throw StageSwitchError.interrupted }
        return Self.reply(result)
    }

    func verified(_ command: StageWindowCommand, after: StageWindowState,
                  owner: StageEngineOwner) async throws {
        _ = try epoch(for: owner, restoring: command.restoring)
        guard command.before.window == after.window, command.before.lifetime == after.lifetime else {
            throw StageSwitchError.ownership
        }
        switch command.action {
        case .hide:
            guard after.visibility == .stageSpace, let hidden = after.hiddenSpaceID,
                  hidden > 0, hidden != command.nativeID else { throw StageSwitchError.incomplete }
        case .show:
            guard after.visibility == .visible, after.hiddenSpaceID == nil else { throw StageSwitchError.incomplete }
        case .place, .focus:
            // The ordinary controller and coordinator independently verify these.
            break
        }
    }

    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply {
        let expected = try epoch(for: owner)
        let result = try await engine.submit(.init(backend: UInt32(NP_SPACES), operation: UInt32(NP_HEALTH),
                                                  intent: intent), expectedEpoch: expected)
        guard try engine.currentEpoch() == expected else { throw StageSwitchError.interrupted }
        return Self.reply(result)
    }

    func revoke() { engine.revoke() }

    func close() async -> Bool {
        // Cleanup must outlive cancellation of the UI action. The worker restores only
        // its retained original leases and refuses to destroy a Space with occupants.
        let engine = engine
        return await Task.detached {
            do {
                let current = try engine.currentEpoch()
                let result = try await engine.releaseSpaces(expectedEpoch: current)
                guard result.status == NP_PASS, result.owned == 0, result.flags & UInt32(NP_OWNED) == 0 else { return false }
                return await engine.close()
            } catch {
                // A broken pipe already started the original worker's release.
                // close accepts only that worker's normal zero exit; the session
                // still requires independent returned-home observations.
                return await engine.close()
            }
        }.value
    }

    private static func reply(_ receipt: NativeStageEngineReceipt) -> StageEngineReply {
        .init(status: receipt.status, flags: receipt.flags, intent: receipt.intent,
              nativeID: receipt.nativeID, frame: receipt.frame)
    }
}
