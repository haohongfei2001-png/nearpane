import CryptoKit
import Foundation
@testable import RiftletAdapters
import RiftletCore

private struct RestartStamp: Codable {
    let intentID, assetID, operationID, invocationID: UUID
    let pid: Int32
    let session, sha256: String
}

enum ColdRestart {
    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func run(stage: String, request args: Request, route: DraftQualificationRoute, base: URL,
                               session: String) async throws -> [String: Any] {
        guard let receiver = ChromeProcessIdentity.read(pid: args.pid, applicationID: args.browserID), receiver.isCurrent(),
              receiver.session == session, ["original", "successor"].contains(stage) else { throw FixtureError.invalid }
        let media = base.appendingPathComponent("media", isDirectory: true)
        let store = try QueueStore(databaseURL: base.appendingPathComponent("queue.sqlite"))
        let adapter = try DraftAttachmentQualification.adapter(route, media: media, executor: HeadlessDraftPipe(route))
        // Both independently launched pages expose the identical logical window and tab address.
        let fresh = try await adapter.targetForClick().value
        guard fresh.sessionID == session, fresh.windowID == "1", let tab = fresh.tabID, tab == "1",
              try await adapter.validate(fresh) else { throw FixtureError.invalid }
        let key = "cold-restart-" + args.intentID.uuidString
        var report: [String: Any] = ["done": true, "stage": stage, "intentID": args.intentID.uuidString,
            "pid": receiver.pid, "kernelBirthSeconds": receiver.birth.seconds,
            "kernelBirthMicroseconds": receiver.birth.microseconds, "processSession": session,
            "identitySource": "LaunchServicesAndKernel", "signedPIDVerified": true, "observedUptime": ProcessInfo.processInfo.systemUptime,
            "windowID": fresh.windowID, "tabID": tab, "currentLeaseValidatedByPage": true,
            "documentID": fresh.documentID, "draftGeneration": fresh.draftGeneration]
        if stage == "original" {
            let image = try Driver.syntheticAsset(in: media)
            _ = try await store.importAsset(image)
            let operation = try await store.prepare(assetID: image.id, target: fresh)
            let invocation = try await store.markDispatchIntent(operation.id)
            guard let original = try await store.operation(id: operation.id), original.phase == .dispatchIntent,
                  original.target == fresh, try digest(media.appendingPathComponent(image.fileName)) == image.sha256
            else { throw FixtureError.invalid }
            let stamp = RestartStamp(intentID: args.intentID, assetID: image.id, operationID: operation.id,
                                     invocationID: invocation, pid: receiver.pid, session: session, sha256: image.sha256)
            let bytes = try JSONEncoder().encode(stamp)
            guard try await store.saveCheckpointIfAbsent(bytes, for: key) == bytes else { throw FixtureError.invalid }
            report.merge(["assetID": image.id.uuidString, "operationID": operation.id.uuidString,
                          "invocationID": invocation.uuidString, "attempt": original.attempt, "phase": original.phase.rawValue,
                          "sourceSHA256": image.sha256]) { _, new in new }
            return report
        }

        guard let bytes = try await store.checkpoint(for: key) else { throw FixtureError.invalid }
        let stamp = try JSONDecoder().decode(RestartStamp.self, from: bytes)
        guard stamp.intentID == args.intentID, !receiver.matches(session: stamp.session),
              !receiver.matches(session: stamp.session, allowLegacyObservation: true),
              let original = try await store.operation(id: stamp.operationID), original.phase == .dispatchIntent,
              original.target.sessionID == stamp.session, original.target.windowID == fresh.windowID,
              original.target.tabID == fresh.tabID, original.target.applicationID == fresh.applicationID,
              original.target.adapterID == fresh.adapterID, original.target.documentID != fresh.documentID,
              !(try await adapter.validate(original.target)),
              try await store.dispatchInvocationID(for: stamp.operationID) == stamp.invocationID,
              let asset = try await store.asset(id: stamp.assetID), asset.activeOperationID == original.id,
              asset.image.id == original.assetID, asset.image.origin == .synthetic, asset.image.sha256 == stamp.sha256,
              asset.image.fileName == asset.id.uuidString + ".png"
        else { throw FixtureError.invalid }
        let oldFields = stamp.session.split(separator: ":")
        guard oldFields.count == 4, Int32(oldFields[1]) == stamp.pid,
              let oldSeconds = UInt64(oldFields[2]), let oldMicros = UInt64(oldFields[3]) else { throw FixtureError.invalid }
        let oldProcessGone = KernelProcessBirth.read(pid: stamp.pid).map {
            $0.seconds != oldSeconds || $0.microseconds != oldMicros
        } ?? true
        guard oldProcessGone else { throw FixtureError.invalid }
        let file = media.appendingPathComponent(asset.image.fileName)
        let initialHash = try digest(file)
        guard initialHash == stamp.sha256 else { throw FixtureError.invalid }

        // Challenge the actual unprimed native writer with the frozen intent. Its write gate
        // rejects before selecting any receiver or constructing an Apple Event. Do not capture
        // the foreground or request a native read against any browser.
        let directory = base.appendingPathComponent("restart-diagnostics", isDirectory: true)
        let trace = BoundedDiagnosticTrace(enabled: true, directory: directory, emitStandardError: false)
        let native = ChromeAppleEventsExecutor(diagnosticTrace: trace)
        let writer = try DraftAttachmentQualification.adapter(route, media: media, executor: native)
        let frozen = TransferRequest(operation: original, asset: asset.image, fileURL: file, invocationID: stamp.invocationID)
        do {
            _ = try await writer.append(frozen)
            throw FixtureError.invalid
        } catch let refusal as PreInputRejection {
            guard refusal.stage == .localBeforeBegin, refusal.reason == "fileInputCommandNotInvoked",
                  refusal.target == original.target, refusal.invocationID == stamp.invocationID,
                  refusal.operationID == original.id, refusal.assetID == asset.id, refusal.assetSHA256 == stamp.sha256
            else { throw FixtureError.invalid }
        }
        trace.flushForTesting()
        let lines = try String(contentsOf: directory.appendingPathComponent("acceptance-recent.jsonl"), encoding: .utf8)
        let events = try lines.split(separator: "\n").compactMap { line -> [String]? in
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard row?["event"] as? String == "native_bridge" else { return nil }
            guard let action = row?["action"] as? String, let phase = row?["phase"] as? String,
                  row?["transportSucceeded"] as? Bool == false else { throw FixtureError.invalid }
            return [action, phase]
        }
        guard events == [["begin", "originalRouteUnavailable"], ["discard", "originalRouteUnavailable"]] else {
            throw FixtureError.invalid
        }
        try await store.recoverInterruptedOperations()
        do {
            _ = try await store.markDispatchIntent(original.id)
            throw FixtureError.invalid
        } catch RiftletError.invalidTransition {}
        guard let recovered = try await store.operation(id: original.id), recovered.target == original.target,
              recovered.attempt == original.attempt, recovered.phase == .unknown,
              let restored = try await store.asset(id: asset.id), restored.image == asset.image, restored.visibility == .visible,
              try await store.dispatchInvocationID(for: original.id) == stamp.invocationID,
              try await store.checkpoint(for: key) == bytes, try digest(file) == initialHash
        else { throw FixtureError.invalid }
        report.merge(["assetID": asset.id.uuidString, "operationID": original.id.uuidString,
                      "invocationID": stamp.invocationID.uuidString, "attempt": recovered.attempt,
                      "originalProcessGone": true, "oldSessionMatchesSuccessor": false,
                      "oldSessionMatchesSuccessorReadOnly": false, "oldLeaseValidInSuccessorPage": false,
                      "sameLogicalWindowAndTab": true,
                      "sourceSHA256Before": initialHash, "sourceSHA256After": try digest(file),
                      "nativeBridgeRefusals": events, "dispatchRearmRefused": true,
                      "phase": recovered.phase.rawValue, "assetVisibility": restored.visibility.rawValue]) { _, new in new }
        return report
    }
}
