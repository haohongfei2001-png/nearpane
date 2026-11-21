import AppKit
import ApplicationServices
import Foundation
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneWindowEngine

/// Runs before profile selection, AppKit activation or TCC requests. No real window is supplied to a write.
enum StageEnginePackageProbe {
    /// A registration only permits reading membership of a signed fixture. The sampler rebinds the
    /// process, code image and window before and after each read. This entry never submits a write.
    static func enrolledFixture(_ channel: StageScopeReply?) throws -> StageEngineHostScope.Fixture {
        struct Registration: Decodable { let pid: Int32, birth: UInt64, window: UInt32, executable: String, cdhash: String }
        let data = try channel?.registration() ?? FileHandle.standardInput.readData(ofLength: 4097)
        guard !data.isEmpty, data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let item = try JSONDecoder().decode(Registration.self, from: data)
        guard item.pid > 1, item.birth > 0, item.window > 0, item.executable.hasPrefix("/"),
              item.cdhash.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return .init(pid: item.pid, birth: item.birth, number: item.window,
                     executable: URL(fileURLWithPath: item.executable), cdhash: item.cdhash)
    }

    @MainActor static func readScope(challenge: UUID, fixture: StageEngineHostScope.Fixture?, channel: StageScopeReply?) async -> Int32 {
        let bundle = Bundle.main
        let pid = getpid()
        do {
            let before = try OrdinaryProcessImage.read(pid)
            let digest = try OrdinaryProcessImage.signingDigest(pid)
            guard before.executable == bundle.executableURL?.resolvingSymlinksInPath() else { return 3 }
            let permissions = ["accessibility": AXIsProcessTrusted(), "listenEvent": CGPreflightListenEventAccess(),
                               "postEvent": CGPreflightPostEventAccess()]
            let scope = await StageEngineHostScope.sample(fixture: fixture)
            guard try OrdinaryProcessImage.read(pid) == before, try OrdinaryProcessImage.signingDigest(pid) == digest else { return 3 }
            let url = bundle.bundleURL.resolvingSymlinksInPath()
            let subject: [String: Any] = [
                "pid": pid, "birth": before.launch, "identifier": bundle.bundleIdentifier ?? "",
                "cdhash": digest.map { String(format: "%02x", $0) }.joined(),
                "atDailyInstallPath": url.path == "/Applications/Nearpane.app",
                "source": bundle.object(forInfoDictionaryKey: "NearpaneStageEngineSourceRevision") as? String ?? "",
                "sourceState": bundle.object(forInfoDictionaryKey: "NearpaneStageEngineSourceState") as? String ?? ""
            ]
            var report: [String: Any] = ["schema": 1, "abi": np_engine_version(), "challenge": challenge.uuidString,
                                         "subject": subject, "permissions": permissions, "spaceScope": scope]
            if let fixture {
                let summary = scope["scope"] as? [String: Any]
                var ordinary: StageGroupScope?
                var native: UInt64?
                if summary?["status"] as? String == "PASS",
                   let display = (summary?["displayUUID"] as? String).flatMap(UUID.init(uuidString:)),
                   let space = (summary?["spaceUUID"] as? String).flatMap(UUID.init(uuidString:)),
                   let id = summary?["nativeID"] as? UInt64 {
                    ordinary = .init(display: display, nativeSpace: space)
                    native = id
                }
                let guardian = CornerGuardianFixtureReport.sample(pid: fixture.pid, birth: fixture.birth, number: fixture.number,
                    executable: fixture.executable, cdhash: fixture.cdhash, scope: ordinary, nativeID: native)
                report["guardianFixture"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(guardian))
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            if let channel {
                try channel.finish(data + Data([10]))
            } else {
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return 0
        } catch { return 3 }
    }

    @MainActor static func run(observeSystem: Bool, challenge: UUID?) async -> Int32 {
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
            if let challenge { report["challenge"] = challenge.uuidString.lowercased() }
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
