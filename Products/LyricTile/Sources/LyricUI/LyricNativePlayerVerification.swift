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
        var pointerAttempted = false
        var pointerPassed = true
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
             "recordingFingerprint": model.snapshot.selection?.recording.fingerprint ?? "",
             "selectionGeneration": model.snapshot.selection?.generation as Any? ?? NSNull(),
             "selectionSessionID": model.snapshot.selection?.sessionID.uuidString ?? "",
             "documentSource": model.document?.source.providerID ?? "", "cueIndex": model.currentCueIndex as Any? ?? NSNull(),
             "documentHash": model.document?.contentHash ?? "",
             "documentFingerprint": model.document?.recording.fingerprint ?? "",
             "lyricFailure": model.lyricFailure as Any? ?? NSNull(),
             "actionMessage": model.actionMessage as Any? ?? NSNull()]
        }
        func record(_ name: String, _ passed: Bool) async {
            var row: [String: Any] = ["check": name, "passed": passed, "observation": observation()]
            do {
                let data = try await model.nativePlayerDiagnosticReport()
                let file = String(format: "source-%02d-", checks.count + 1) + name + ".json"
                try data.write(to: directory.appendingPathComponent(file), options: .atomic)
                row["sourceEvidenceFile"] = file
            } catch {
                row["sourceEvidenceError"] = error.localizedDescription
                row["passed"] = false
            }
            checks.append(row)
            write("native-player-progress.json", ["checks": checks])
        }
        func commandConfirmed(_ intent: String, seekMS: Int64? = nil) async -> Bool {
            guard let data = try? await model.nativePlayerDiagnosticReport(),
                  let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let commands = report["commands"] as? [[String: Any]], let command = commands.last,
                  command["intent"] as? String == intent,
                  command["outcome"] as? String == "readback_confirmed",
                  command["targetBundleID"] as? String == model.snapshot.selection?.playerBundleID else { return false }
            return seekMS == nil || (command["seekMS"] as? NSNumber)?.int64Value == seekMS
        }
        func finish(_ passed: Bool) -> Bool {
            write("native-player.json", ["status": passed ? "PASS" : "FAIL", "scope": "ordinary-native-app-real-player",
                "player": expectedPlayer.rawValue, "audio": "authored local PCM recording played by the actual installed player",
                "lyrics": "caller-supplied original local LRC imported by the production repository",
                "physicalMouseTest": false, "commercialCatalogTest": false, "independentClockAccuracyTest": false,
                "nativePointerEventTest": pointerAttempted ? (pointerPassed ? "PASS" : "FAIL") : "BLOCKED_OR_UNAVAILABLE",
                "stateDrivenHoverFallback": !pointerAttempted,
                "wordSyncQualification": "NOT_RUN", "checks": checks])
            return passed
        }
        func wait(_ seconds: Double = 8, until condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
            return condition()
        }
        func pointerReport() -> [String: Any]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("native-pointer.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func pointerAction(_ sequence: Int, _ action: String) async -> Bool {
            let requestID = UUID().uuidString
            write("pointer-request.json", ["sequence": sequence, "requestID": requestID, "action": action,
                "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": panel.panel.windowNumber])
            var posted = false
            _ = await wait {
                let actions = pointerReport()?["actions"] as? [[String: Any]] ?? []
                guard let result = actions.last(where: { ($0["sequence"] as? NSNumber)?.intValue == sequence
                    && $0["requestID"] as? String == requestID && $0["action"] as? String == action }) else { return false }
                posted = result["posted"] as? Bool == true
                return true
            }
            return posted
        }
        func capture(_ name: String) {
            do { try LyricNativeSmoke.capture(window: panel.panel, to: directory.appendingPathComponent(name + ".png")) }
            catch { checks.append(["check": name + "-capture", "passed": false, "error": error.localizedDescription]) }
        }
        if CommandLine.arguments.contains("--verification-first-use") {
            let shown = await wait {
                model.presentation == .welcome && !model.settings.completedWelcome
                    && NSApp.windows.contains { $0.isVisible && $0.contentView?.bounds.size == NSSize(width: 400, height: 360) }
            }
            if let welcome = NSApp.windows.first(where: { $0.isVisible && $0.contentView?.bounds.size == NSSize(width: 400, height: 360) }) {
                do { try LyricNativeSmoke.capture(window: welcome, to: directory.appendingPathComponent("first-use-welcome.png")) }
                catch { checks.append(["check": "first-use-capture", "passed": false, "error": error.localizedDescription]) }
            }
            await record("first-use-shows-complete-welcome-window", shown)
            write("first-use-ready.json", ["pid": ProcessInfo.processInfo.processIdentifier, "welcomeObserved": shown])
            let started = await wait(25) { model.settings.completedWelcome && model.presentation != .welcome && model.ownsSession }
            await record("first-use-get-started-activates-session", started)
        }
        let found = await wait(25) {
            model.ownsSession && model.snapshot.player == expectedPlayer && model.snapshot.state == .playing
                && model.snapshot.selection?.recording.title == title && model.playbackPositionMS != nil
        }
        await record("production-adapter-real-local-track", found)
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
        await record("playing-without-lyrics-shows-compact-summary", compact)
        capture(capturePrefix + "-compact")
        let initial = model.playbackPositionMS ?? 0
        let advancing = await wait(6) { (model.playbackPositionMS ?? 0) > initial + 1_000 }
        await record("real-player-position-advances", advancing)

        model.importLyrics(from: URL(fileURLWithPath: lyrics), for: selection)
        let imported = await wait {
            model.document?.source.providerID == "local" && panel.panel.isVisible
                && panel.panel.frame.height == LyricPanelLayout.lyricsHeight && model.currentCue != nil
        }
        await record("local-import-expands-real-panel", imported)
        capture(capturePrefix + "-lyrics")
        let importedHash = model.document?.contentHash
        func retainsImportedLyrics() -> Bool {
            importedHash != nil && model.document?.contentHash == importedHash && model.document?.source.providerID == "local"
                && model.snapshot.selection?.recording.fingerprint == selection.recording.fingerprint
                && model.snapshot.selection?.generation == selection.generation
                && model.snapshot.selection?.sessionID == selection.sessionID
        }
        let firstCue = model.currentCueIndex
        let seekTarget: Int64 = (model.playbackPositionMS ?? 0) < 48_000 ? 64_000 : 24_000
        model.perform(.seek(milliseconds: seekTarget))
        let sought = await wait {
            !model.isPerformingCommand && model.actionMessage == nil && (model.playbackPositionMS ?? 0) >= seekTarget - 1_000
                && (model.playbackPositionMS ?? 0) < seekTarget + 8_000
        }
        let seekConfirmed = await commandConfirmed("seek", seekMS: seekTarget)
        await record("seek-command-readback", sought && seekConfirmed)
        let retainedAfterSeek = await wait {
            retainsImportedLyrics() && model.currentCueIndex != nil && panel.panel.frame.height == LyricPanelLayout.lyricsHeight
        }
        await record("seek-retains-imported-lyrics-and-recording-identity", retainedAfterSeek)
        await record("seek-updates-current-lyric", retainedAfterSeek && firstCue != nil && model.currentCueIndex != nil && model.currentCueIndex != firstCue)

        // A separate disposable-host helper may send real OS pointer events
        // through existing AX/PostEvent access. No permission is requested by
        // this product. Without that helper, the state-driven fallback remains
        // explicitly distinguished from native pointer/hit-testing evidence.
        pointerAttempted = pointerReport()?["available"] as? Bool == true
        if pointerAttempted {
            let posted = await pointerAction(1, "enter")
            let hovered = await wait { model.controlsVisible && model.panelInteractionActive }
            pointerPassed = posted && hovered
            await record("native-pointer-enters-hover", pointerPassed)
        } else {
            model.setControlsVisible(true); model.panelInteractionActive = true
        }
        try? await Task.sleep(for: .milliseconds(350))
        capture(capturePrefix + "-hover")
        await record("hover-keeps-outer-frame", panel.panel.frame.height == LyricPanelLayout.lyricsHeight && retainsImportedLyrics())
        let pausePosted: Bool
        if pointerAttempted { pausePosted = await pointerAction(2, "pause") }
        else { model.perform(.pause); pausePosted = true }
        let paused = await wait { model.snapshot.state == .paused && !model.isPerformingCommand && model.actionMessage == nil }
        let pauseConfirmed = await commandConfirmed("pause")
        if pointerAttempted {
            let clicked = pausePosted && paused && pauseConfirmed
            pointerPassed = pointerPassed && clicked
            await record("native-pointer-clicks-pause", clicked)
        }
        await record("pause-confirmed-and-interacted-panel-retained", pausePosted && paused && pauseConfirmed && panel.panel.isVisible
            && panel.panel.frame.height == LyricPanelLayout.lyricsHeight && retainsImportedLyrics())
        let pausedPosition = model.playbackPositionMS
        try? await Task.sleep(for: .seconds(1))
        let pausedClockStable = pausedPosition == nil ? model.playbackPositionMS == nil
            : model.playbackPositionMS != nil && abs((model.playbackPositionMS ?? 0) - (pausedPosition ?? 0)) < 300
        await record("paused-position-does-not-advance-or-invent-a-clock", pausedClockStable)
        if pointerAttempted {
            let posted = await pointerAction(3, "leave")
            let left = await wait { !model.panelInteractionActive && !model.controlsVisible }
            pointerPassed = pointerPassed && posted && left
            await record("native-pointer-leaves-hover", posted && left)
        } else {
            model.panelInteractionActive = false; model.setControlsVisible(false)
        }
        let hidden = await wait { !panel.panel.isVisible && !panel.wantsPresentation }
        await record("paused-without-interaction-withdraws-panel", hidden)
        model.perform(.play)
        let resumed = await wait {
            model.snapshot.state == .playing && panel.panel.isVisible && !model.isPerformingCommand && model.actionMessage == nil
                && retainsImportedLyrics() && model.currentCueIndex != nil && panel.panel.frame.height == LyricPanelLayout.lyricsHeight
        }
        let resumeConfirmed = await commandConfirmed("play")
        await record("resume-automatically-restores-lyrics", resumed && resumeConfirmed)

        model.settings.appearance = .dark
        try? await Task.sleep(for: .milliseconds(350)); capture(capturePrefix + "-dark")
        model.settings.appearance = .light
        try? await Task.sleep(for: .milliseconds(350)); capture(capturePrefix + "-light")
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else { return finish(false) }
        // Let the external harness measure the ordinary process without requests
        // from this verifier. The expected source remains real player playback.
        write("native-player-ready.json", ["pid": ProcessInfo.processInfo.processIdentifier, "mode": "line",
            "scope": "real-player-local-audio-local-lyrics", "player": expectedPlayer.rawValue, "observation": observation()])
        let hold = min(120, max(0, Double(argument("--verification-hold-seconds") ?? "0") ?? 0))
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        await record("continued-playback", model.snapshot.state == .playing && panel.panel.isVisible && retainsImportedLyrics()
            && model.currentCueIndex != nil && panel.panel.frame.height == LyricPanelLayout.lyricsHeight)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        return finish(passed)
    }
}
