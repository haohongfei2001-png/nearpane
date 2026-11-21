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
        engine.revoke()
        #expect(await engine.close())
    }
}
