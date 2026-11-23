import Foundation
import Testing
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneWindowEngine

struct EngineABITests {
    @Test func cLayoutAndSwiftRuntimeAgree() {
        #expect(np_engine_version() == NP_ENGINE_ABI)
        #expect(MemoryLayout<NPConfig>.size == 48)
        #expect(MemoryLayout<NPRequest>.size == 232)
        #expect(MemoryLayout<NPReceipt>.size == 96)
        #expect(MemoryLayout<NPRequest>.offset(of: \.birth) == 144)
        #expect(MemoryLayout<NPReceipt>.offset(of: \.frame) == 64)
        var cfg = NPConfig(), h: UInt64 = 0
        cfg.size = UInt32(MemoryLayout<NPConfig>.size); cfg.version = 2
        #expect(np_engine_create(&cfg, &h) == NP_INCOMPATIBLE)
        #expect(h == 0)
        #expect(NativeStageWindowEngine(qualifiedBackend: UInt32(NP_CORNER), evidence: UUID()) == nil)
        #expect(NativeStageWindowEngine(qualifiedBackend: UInt32(NP_SPACES), evidence: UUID()) == nil)
    }

    @Test func ordinaryHandleCannotDispatchFixtureWritesAndRevocationIsThreadSafe() async throws {
        let engine = try #require(NativeStageWindowEngine())
        let intent = UUID()
        // Complete fabricated lease: a normal Host must reject it before looking up a PID.
        let request = NativeStageEngineRequest(backend: UInt32(NP_SPACES), operation: UInt32(NP_HIDE),
            intent: intent, group: UUID(), scope: .init(display: UUID(), nativeSpace: UUID()),
            member: UUID(), lifetime: UUID(), generation: UUID(),
            window: .init(pid: Int32.max, birth: 1, number: UInt32.max), nativeID: 1,
            frame: .init(width: 100, height: 100))
        let result = try await engine.submit(request)
        #expect(result.status == NP_UNSUPPORTED && result.intent == intent && result.owned == 0)
        let launch = try await engine.launchSpaces()
        #expect(launch.status == NP_UNSUPPORTED && launch.owned == 0)
        #expect(launch.epoch == (try engine.currentEpoch()))
        engine.revoke()
        #expect(await engine.close())
    }

    @Test func cornerParkPreflightObservesOnlyTheCallingProcess() async throws {
        let engine = try #require(NativeStageWindowEngine())
        let intent = UUID()
        let access = try await engine.submit(.init(backend: UInt32(NP_CORNER), operation: UInt32(NP_CORNER_PARK_ACCESS), intent: intent))
        #expect(access.intent == intent && access.flags == 0 && access.owned == 0 && access.nativeID == 0)
        #expect((access.status == NP_PASS && access.detail == 0) || (access.status == NP_UNSUPPORTED && access.detail != 0))
        for request in [
            NativeStageEngineRequest(backend: UInt32(NP_SPACES), operation: UInt32(NP_CORNER_PARK_ACCESS), intent: intent),
            NativeStageEngineRequest(backend: UInt32(NP_CORNER), operation: UInt32(NP_CORNER_PARK_ACCESS), intent: intent,
                                     window: .init(pid: 42, birth: 73, number: 93))
        ] {
            await #expect(throws: NativeStageEngineError.self) { try await engine.submit(request) }
        }
        #expect(await engine.close())
    }

    @Test func delayedSubmissionCannotAdoptTheEpochThatReplacedItsAuthorization() async throws {
        let engine = try #require(NativeStageWindowEngine())
        let approved = try engine.currentEpoch()
        let request = NativeStageEngineRequest(
            backend: UInt32(NP_CORNER), operation: UInt32(NP_HIDE), intent: UUID(),
            group: UUID(), scope: .init(display: UUID(), nativeSpace: UUID()), member: UUID(),
            lifetime: UUID(), generation: UUID(), window: .init(pid: Int32.max, birth: 1, number: UInt32.max),
            nativeID: 1, frame: .init(width: 100, height: 100)
        )
        // Same ordering as a queued MainActor request after focus or permission invalidation.
        engine.revoke()
        let after = try engine.currentEpoch()
        #expect(after != approved)
        let pending: [() async throws -> NativeStageEngineReceipt] = [
            { try await engine.submit(request, expectedEpoch: approved) },
            { try await engine.launchSpaces(expectedEpoch: approved) },
            { try await engine.cleanSpacesLaunch(expectedEpoch: approved) }
        ]
        for delayed in pending {
            do {
                _ = try await delayed()
                Issue.record("A stale request received a ticket")
            } catch NativeStageEngineError.transport(let code) {
                #expect(code == NP_INVALID)
            }
        }
        // A fresh cleanup can reach the read-only handle, which still has zero write authority.
        let fresh = try await engine.cleanSpacesLaunch(expectedEpoch: after)
        #expect(fresh.epoch == after && fresh.status == NP_UNSUPPORTED && fresh.owned == 0)
        #expect(await engine.close())
    }
}
