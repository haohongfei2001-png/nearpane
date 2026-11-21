import AppKit
import ApplicationServices
import Foundation
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneWindowEngine

/// Runs before profile selection, AppKit activation or TCC requests. No real window is supplied to a write.
enum StageEnginePackageProbe {
    @MainActor static func run(observeSystem: Bool) async -> Int32 {
        guard let engine = NativeStageWindowEngine() else { return 3 }
        do {
            var results = [[String: Any]]()
            var safe = true
            for (name, id) in [("corner", UInt32(NP_CORNER)), ("spaces", UInt32(NP_SPACES))] {
                let intent = UUID()
                let request = NativeStageEngineRequest(backend: id, operation: UInt32(NP_HIDE), intent: intent,
                    group: UUID(), scope: .init(display: UUID(), nativeSpace: UUID()), member: UUID(),
                    lifetime: UUID(), generation: UUID(), window: .init(pid: .max, birth: 1, number: .max),
                    nativeID: 1, frame: .init(width: 100, height: 100))
                let refused = try await engine.submit(request)
                let rejected = refused.status == NP_UNSUPPORTED && refused.intent == intent && refused.owned == 0
                safe = safe && rejected
                var row: [String: Any] = ["backend": name, "unqualifiedWriteRefused": rejected]
                if observeSystem {
                    let result = try await engine.submit(.init(backend: id, operation: UInt32(NP_PROBE), intent: UUID()))
                    row["readOnlyProbe"] = ["status": result.status, "flags": result.flags, "detail": result.detail]
                }
                results.append(row)
            }
            let closed = await engine.close()
            var report: [String: Any] = ["abi": np_engine_version(), "engines": results, "closed": closed]
            if observeSystem {
                report["permissions"] = ["accessibility": AXIsProcessTrusted(), "listenEvents": CGPreflightListenEventAccess()]
                report["displays"] = NSScreen.screens.count
            }
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: json + Data([10]))
            return safe && closed ? 0 : 3
        } catch {
            engine.revoke()
            _ = await engine.close()
            return 3
        }
    }
}
