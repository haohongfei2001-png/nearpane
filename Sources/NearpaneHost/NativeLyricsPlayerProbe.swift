#if DEBUG && canImport(LyricPlayback) && canImport(LyricUI)
import AppKit
import Foundation
import LyricPlayback
import LyricUI

/// Optional cloud probe of the actual production playback adapter. Its audio is
/// generated locally, but the player process, metadata and command readbacks are
/// real. No standalone lyric application or auxiliary window is constructed.
@MainActor
enum NativeLyricsPlayerProbe {
    private struct Input: Decodable { let playerPID: Int32; let expectedTitle: String }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private final class Observations {
        var snapshot = PlaybackSnapshot.empty
        var count = 0
    }

    static func run(_ session: NativeAcceptanceSession) async {
        let output = session.directory.appendingPathComponent("native-player", isDirectory: true)
        let controller = PlaybackController()
        let observations = Observations()
        var checks: [[String: Any]] = []
        var status = "FAIL"
        var reason: String?
        var watcher: Task<Void, Never>?
        var policy = LyricPanelVisibilityPolicy()
        func snapshotRow() -> [String: Any] {
            let value = observations.snapshot
            return ["state": value.state.rawValue, "player": value.player?.rawValue ?? "",
                    "title": value.selection?.recording.title ?? "",
                    "positionMS": value.anchor?.positionMS as Any? ?? NSNull(),
                    "generation": value.selection?.generation as Any? ?? NSNull(),
                    "requiresAuthorization": value.requiresAuthorization,
                    "adapterMessage": value.statusMessage as Any? ?? NSNull()]
        }
        func record(_ name: String, _ passed: Bool) async throws {
            let source = "source-" + String(checks.count + 1) + "-" + name + ".json"
            let data = try await controller.diagnosticReport()
            try data.write(to: output.appendingPathComponent(source), options: .atomic)
            checks.append(["check": name, "passed": passed,
                           "snapshot": snapshotRow(), "sourceEvidence": source])
            guard passed else { throw Failure(name) }
        }
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            return condition()
        }
        func confirmed(_ intent: String) async -> Bool {
            guard let data = try? await controller.diagnosticReport(),
                  let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  report["dataOrigin"] as? String == "real_player",
                  let commands = report["commands"] as? [[String: Any]], let last = commands.last else { return false }
            return last["intent"] as? String == intent && last["outcome"] as? String == "readback_confirmed"
                && last["targetBundleID"] as? String == PlayerID.appleMusic.bundleID
        }

        do {
            guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
                throw Failure("This optional player probe is restricted to the disposable GitHub macOS desktop.")
            }
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: output.appendingPathComponent("input.json")))
            guard input.playerPID > 1, !input.expectedTitle.isEmpty,
                  let music = NSRunningApplication(processIdentifier: input.playerPID),
                  music.bundleIdentifier == PlayerID.appleMusic.bundleID, !music.isTerminated else {
                throw Failure("The caller's locally launched Music process was not available.")
            }
            let launchDate = music.launchDate
            let updates = await controller.updates()
            watcher = Task { @MainActor in
                for await update in updates {
                    if Task.isCancelled { break }
                    observations.snapshot = update
                    observations.count += 1
                }
            }
            await controller.start(preferred: .appleMusic)
            let observed = await wait(25) {
                observations.snapshot.requiresAuthorization ||
                    (observations.snapshot.player == .appleMusic && observations.snapshot.state == .playing &&
                     observations.snapshot.selection?.recording.title == input.expectedTitle && observations.snapshot.anchor != nil)
            }
            if observations.snapshot.requiresAuthorization {
                status = "BLOCKED"
                throw Failure("The actual Nearpane executable needs macOS Automation permission for Apple Music.")
            }
            try await record("real-local-track-observed", observed && observations.snapshot.state == .playing)
            guard let selection = observations.snapshot.selection else { throw Failure("No valid media session was established.") }
            try await record("playing-card-policy", policy.shouldPresent(observations.snapshot, wasVisible: false, isInteracting: false))

            try await controller.perform(.pause, expected: selection)
            let paused = await wait(10) { observations.snapshot.state == .paused }
            let pauseConfirmed = await confirmed("pause")
            try await record("production-pause-readback", paused && pauseConfirmed)
            try await record("paused-without-hover-remains-present", policy.shouldPresent(observations.snapshot, wasVisible: false, isInteracting: false))
            let pausedAt = observations.snapshot.anchor?.positionMS
            let pausedSelection = observations.snapshot.selection
            let pauseStart = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(15))
            let stillPaused = observations.snapshot.state == .paused && observations.snapshot.selection == pausedSelection
            let stillPresent = policy.shouldPresent(observations.snapshot, wasVisible: false, isInteracting: false)
            let clockStable: Bool
            if let first = pausedAt, let current = observations.snapshot.anchor?.positionMS {
                clockStable = abs(current - first) <= 100
            } else { clockStable = false }
            try await record("pause-survives-fifteen-seconds", stillPaused && stillPresent && clockStable &&
                             ProcessInfo.processInfo.systemUptime - pauseStart >= 15)

            guard let pausedSelection else { throw Failure("The paused media session was lost.") }
            try await controller.perform(.play, expected: pausedSelection)
            let resumed = await wait(10) { observations.snapshot.state == .playing }
            let playConfirmed = await confirmed("play")
            try await record("production-resume-readback", resumed && playConfirmed)

            // Only the process launched for this fixture is terminated. The
            // runner also performs bounded cleanup if the adapter is blocked.
            guard let current = NSRunningApplication(processIdentifier: input.playerPID),
                  current.bundleIdentifier == PlayerID.appleMusic.bundleID,
                  current.launchDate == launchDate, current.terminate() else { throw Failure("Music did not accept normal termination.") }
            let exited = await wait(15) { observations.snapshot.selection == nil && current.isTerminated }
            try await record("player-exit-clears-session", exited)
            try await record("player-exit-releases-card", !policy.shouldPresent(observations.snapshot, wasVisible: true, isInteracting: true))
            status = "PASS"
        } catch {
            reason = error.localizedDescription
        }
        watcher?.cancel()
        await controller.stop()
        var receipt: [String: Any] = ["schema": 1, "status": status,
            "scope": "Production PlaybackController and lyric visibility policy with the real Apple Music process",
            "audio": "original generated local WAV; no account or commercial music catalog",
            "physicalPointerTest": false, "sidebarRenderingTest": "separate native-workbench receipt",
            "qqMusicAndNetEase": "NOT_RUN", "observedSnapshots": observations.count, "checks": checks]
        if let reason { receipt["reason"] = reason }
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("real-music-receipt.json"), options: .atomic)
        }
    }
}
#endif
