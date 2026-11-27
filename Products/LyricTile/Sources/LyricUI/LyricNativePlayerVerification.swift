import AppKit
import Foundation
import LyricCore
import LyricPlayback

/// Explicit, disposable-host verification of the ordinary app. Every playback
/// snapshot comes from the production adapter; this never supplies a fake clock,
/// player, recording, or document. The imported file is provided by the caller.
@MainActor
public enum LyricNativePlayerVerification {
    public static var requested: Bool { CommandLine.arguments.contains("--verify-native-player") }

    public static func run(model: LyricAppModel, panel: LyricPanelController) async -> Bool {
        func argument(_ flag: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(i + 1) else { return nil }
            return CommandLine.arguments[i + 1]
        }
        guard let output = argument("--verification-output"), let lyrics = argument("--verification-lyrics"),
              let title = argument("--verification-title"), output.hasPrefix("/"), lyrics.hasPrefix("/") else { return false }
        guard let expectedPlayer = PlayerID(rawValue: argument("--verification-player") ?? "appleMusic") else { return false }
        let capturePrefix = expectedPlayer == .appleMusic ? "real-music" : "real-\(expectedPlayer.rawValue)"
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        var checks: [[String: Any]] = []
        func write(_ name: String, _ value: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
        func observation() -> [String: Any] {
            ["title": model.snapshot.selection?.recording.title ?? "", "state": model.snapshot.state.rawValue,
             "detectedPlayer": model.snapshot.player?.rawValue ?? "",
             "requiresAuthorization": model.snapshot.requiresAuthorization,
             "adapterStatus": model.snapshot.statusMessage as Any? ?? NSNull(),
             "positionMS": model.playbackPositionMS as Any? ?? NSNull(), "nativePanelVisible": panel.panel.isVisible,
             "height": panel.panel.frame.height, "ownsSession": model.ownsSession,
             "documentSource": model.document?.source.providerID ?? "", "cueIndex": model.currentCueIndex as Any? ?? NSNull(),
             "actionMessage": model.actionMessage as Any? ?? NSNull()]
        }
        func record(_ name: String, _ passed: Bool) {
            checks.append(["check": name, "passed": passed, "observation": observation()])
            write("native-player-progress.json", ["checks": checks])
        }
        func wait(_ seconds: Double = 8, until condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
            return condition()
        }
        func capture(_ name: String) {
            do { try LyricNativeSmoke.capture(window: panel.panel, to: directory.appendingPathComponent(name + ".png")) }
            catch { checks.append(["check": name + "-capture", "passed": false, "error": error.localizedDescription]) }
        }
        let found = await wait(25) {
            model.ownsSession && model.snapshot.player == expectedPlayer && model.snapshot.state == .playing
                && model.snapshot.selection?.recording.title == title && model.playbackPositionMS != nil
        }
        record("production-adapter-real-local-track", found)
        guard found, let selection = model.snapshot.selection else {
            // The harness already confirmed actual player playback. Only an
            // observed authorization denial is an environmental BLOCKED result;
            // an unexplained adapter/session failure must remain a real failure.
            let blocked = model.snapshot.requiresAuthorization
            write("native-player.json", ["status": blocked ? "BLOCKED" : "FAIL",
                "scope": "ordinary-native-app-real-player",
                "reason": blocked ? "The ordinary app requires player authorization."
                    : "The production app did not observe the expected playing track and position within 25 seconds.",
                "expectedPlayer": expectedPlayer.rawValue,
                "observation": observation(), "checks": checks])
            return false
        }
        let compact = await wait { panel.panel.isVisible && panel.panel.frame.height == LyricPanelLayout.compactHeight }
        record("playing-without-lyrics-shows-compact-summary", compact)
        capture(capturePrefix + "-compact")
        let initial = model.playbackPositionMS ?? 0
        let advancing = await wait(6) { (model.playbackPositionMS ?? 0) > initial + 1_000 }
        record("real-player-position-advances", advancing)

        model.importLyrics(from: URL(fileURLWithPath: lyrics), for: selection)
        let imported = await wait {
            model.document?.source.providerID == "local" && panel.panel.isVisible
                && panel.panel.frame.height == LyricPanelLayout.lyricsHeight && model.currentCue != nil
        }
        record("local-import-expands-real-panel", imported)
        capture(capturePrefix + "-lyrics")
        let firstCue = model.currentCueIndex
        let seekTarget: Int64 = (model.playbackPositionMS ?? 0) < 48_000 ? 64_000 : 24_000
        model.perform(.seek(milliseconds: seekTarget))
        let sought = await wait {
            !model.isPerformingCommand && model.actionMessage == nil && (model.playbackPositionMS ?? 0) >= seekTarget - 1_000
                && (model.playbackPositionMS ?? 0) < seekTarget + 8_000
        }
        record("seek-command-readback", sought)
        record("seek-updates-current-lyric", model.currentCueIndex != firstCue)

        // This drives the same presentation state as pointer entry. It proves
        // native control/pause integration, not physical mouse hit testing.
        model.setControlsVisible(true); model.panelInteractionActive = true
        try? await Task.sleep(for: .milliseconds(350))
        capture(capturePrefix + "-hover")
        record("hover-keeps-outer-frame", panel.panel.frame.height == LyricPanelLayout.lyricsHeight)
        model.perform(.pause)
        let paused = await wait { model.snapshot.state == .paused && !model.isPerformingCommand && model.actionMessage == nil }
        record("pause-confirmed-and-interacted-panel-retained", paused && panel.panel.isVisible)
        let pausedPosition = model.playbackPositionMS
        try? await Task.sleep(for: .seconds(1))
        record("paused-position-stays-still", pausedPosition != nil && abs((model.playbackPositionMS ?? 0) - (pausedPosition ?? 0)) < 300)
        model.panelInteractionActive = false; model.setControlsVisible(false)
        let hidden = await wait { !panel.panel.isVisible && !panel.wantsPresentation }
        record("paused-without-interaction-withdraws-panel", hidden)
        model.perform(.play)
        let resumed = await wait { model.snapshot.state == .playing && panel.panel.isVisible && !model.isPerformingCommand && model.actionMessage == nil }
        record("resume-automatically-restores-lyrics", resumed)

        model.settings.appearance = .dark
        try? await Task.sleep(for: .milliseconds(350)); capture(capturePrefix + "-dark")
        model.settings.appearance = .light
        try? await Task.sleep(for: .milliseconds(350)); capture(capturePrefix + "-light")
        // Let the external harness measure the ordinary process without requests
        // from this verifier. The expected source remains real player playback.
        write("native-player-ready.json", ["pid": ProcessInfo.processInfo.processIdentifier, "mode": "line",
            "scope": "real-player-local-audio-local-lyrics", "player": expectedPlayer.rawValue, "observation": observation()])
        let hold = min(120, max(0, Double(argument("--verification-hold-seconds") ?? "0") ?? 0))
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        record("continued-playback", model.snapshot.state == .playing && panel.panel.isVisible && model.document != nil)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        write("native-player.json", ["status": passed ? "PASS" : "FAIL", "scope": "ordinary-native-app-real-player",
            "player": expectedPlayer.rawValue, "audio": "authored local PCM recording played by the actual installed player",
            "lyrics": "caller-supplied original local LRC imported by the production repository",
            "physicalMouseTest": false, "commercialCatalogTest": false, "independentClockAccuracyTest": false,
            "wordSyncQualification": "NOT_RUN", "checks": checks])
        return passed
    }
}
