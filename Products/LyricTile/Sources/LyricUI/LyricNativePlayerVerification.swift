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
        let nextTitle = argument("--verification-next-title")
        let nextLyrics = argument("--verification-next-lyrics")
        let trackSwitchRequested = nextTitle != nil || nextLyrics != nil
        let capturePrefix = expectedPlayer == .appleMusic ? "real-music" : "real-\(expectedPlayer.rawValue)"
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        var checks: [[String: Any]] = []
        var pointerAttempted = false
        var pointerPassed = true
        var trackSwitchAttempted = false
        var trackSwitchPassed = false
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
        func qqPausedSourceDoesNotReusePlayingClock() async -> Bool {
            guard let data = try? await model.nativePlayerDiagnosticReport(),
                  let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let players = report["players"] as? [[String: Any]],
                  let player = players.first(where: { $0["player"] as? String == "qqMusic" }) else { return false }
            guard ["73284", "73285"].contains(player["build"] as? String ?? "") else { return true }
            guard let payload = report["currentMediaRemotePayload"] as? [String: Any],
                  payload["playing"] as? Bool == false else { return false }
            // CI43's real pause retained the earlier seek timestamp/elapsed
            // with a positive rate. A stable number alone was a false pass:
            // this source must not be exposed as a current paused clock.
            if ((payload["playbackRate"] as? NSNumber)?.doubleValue ?? 0) > 0 {
                return model.playbackPositionMS == nil && player["positionMS"] == nil
                    && player["quality"] as? String == "unavailable"
            }
            return true
        }
        func finish(_ passed: Bool) -> Bool {
            write("native-player.json", ["status": passed ? "PASS" : "FAIL", "scope": "ordinary-native-app-real-player",
                "player": expectedPlayer.rawValue, "audio": "authored local PCM recording played by the actual installed player",
                "lyrics": "caller-supplied original local LRC imported by the production repository",
                "physicalMouseTest": false, "commercialCatalogTest": false, "independentClockAccuracyTest": false,
                "nativePointerEventTest": pointerAttempted ? (pointerPassed ? "PASS" : "FAIL") : "BLOCKED_OR_UNAVAILABLE",
                "nativeTrackSwitchTest": trackSwitchAttempted ? (trackSwitchPassed ? "PASS" : "FAIL") : "NOT_RUN",
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
        var lyricBaselineSelection = selection
        func retainsImportedLyrics() -> Bool {
            importedHash != nil && model.document?.contentHash == importedHash && model.document?.source.providerID == "local"
                && model.snapshot.selection?.recording.fingerprint == lyricBaselineSelection.recording.fingerprint
                && model.snapshot.selection?.generation == lyricBaselineSelection.generation
                && model.snapshot.selection?.sessionID == lyricBaselineSelection.sessionID
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
        if expectedPlayer == .qqMusic {
            let sourceConsistent = await qqPausedSourceDoesNotReusePlayingClock()
            await record("qq-paused-source-does-not-reuse-playing-anchor", sourceConsistent)
        }
        capture(capturePrefix + "-paused")
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

        if trackSwitchRequested {
            trackSwitchAttempted = true
            guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else { return finish(false) }
            guard expectedPlayer == .appleMusic, let nextTitle, !nextTitle.isEmpty, nextTitle != title,
                  let nextLyrics, nextLyrics.hasPrefix("/"), FileManager.default.isReadableFile(atPath: nextLyrics),
                  let originalHash = importedHash else {
                await record("two-track-original-fixture-configuration", false)
                return finish(false)
            }
            // Only production transport commands and independently recorded
            // player observations move between the caller's two local tracks.
            model.perform(.next)
            let switched = await wait {
                guard let current = model.snapshot.selection else { return false }
                return model.snapshot.state == .playing && !model.isPerformingCommand && model.actionMessage == nil
                    && current.recording.title == nextTitle && current.playerBundleID == selection.playerBundleID
                    && current.recording.fingerprint != selection.recording.fingerprint && current.generation > selection.generation
            }
            let nextConfirmed = await commandConfirmed("next")
            await record("next-selects-second-track-with-new-generation", switched && nextConfirmed)
            guard switched, nextConfirmed, let secondSelection = model.snapshot.selection else { return finish(false) }
            let oldLyricsCleared = await wait(4) {
                model.snapshot.selection?.recording.fingerprint == secondSelection.recording.fingerprint
                    && model.document == nil && model.currentCue == nil && panel.panel.isVisible
                    && panel.panel.frame.height == LyricPanelLayout.compactHeight
            }
            await record("next-clears-old-lyrics-and-contracts-panel", oldLyricsCleared)
            capture(capturePrefix + "-next-compact")
            guard oldLyricsCleared else { return finish(false) }

            model.importLyrics(from: URL(fileURLWithPath: nextLyrics), for: secondSelection)
            let secondImported = await wait {
                guard let current = model.snapshot.selection, let document = model.document else { return false }
                return current.recording.fingerprint == secondSelection.recording.fingerprint
                    && current.generation == secondSelection.generation && current.sessionID == secondSelection.sessionID
                    && document.source.providerID == "local" && document.recording.fingerprint == secondSelection.recording.fingerprint
                    && document.contentHash != originalHash && model.currentCue != nil && panel.panel.isVisible
                    && panel.panel.frame.height == LyricPanelLayout.lyricsHeight
            }
            await record("second-track-import-binds-distinct-document", secondImported)
            capture(capturePrefix + "-next-lyrics")
            guard secondImported, let secondHash = model.document?.contentHash else { return finish(false) }

            // Some players interpret Previous after several seconds as Restart.
            // A real, read-back-confirmed seek keeps this a previous-track test;
            // replaying the second track is never accepted as returning to A.
            if (model.playbackPositionMS ?? Int64.max) > 1_500 {
                model.perform(.seek(milliseconds: 0))
                let nearStart = await wait(5) {
                    guard let position = model.playbackPositionMS else { return false }
                    return !model.isPerformingCommand && model.actionMessage == nil && position >= 0 && position < 1_500
                        && model.snapshot.selection?.recording.fingerprint == secondSelection.recording.fingerprint
                        && model.document?.contentHash == secondHash
                }
                let resetConfirmed = await commandConfirmed("seek", seekMS: 0)
                await record("second-track-real-seek-before-previous", nearStart && resetConfirmed)
                guard nearStart, resetConfirmed else { return finish(false) }
            }
            model.perform(.previous)
            let returned = await wait {
                guard let current = model.snapshot.selection else { return false }
                return model.snapshot.state == .playing && !model.isPerformingCommand && model.actionMessage == nil
                    && current.recording.title == title && current.playerBundleID == selection.playerBundleID
                    && current.recording.fingerprint == selection.recording.fingerprint && current.generation > secondSelection.generation
            }
            let previousConfirmed = await commandConfirmed("previous")
            await record("previous-returns-original-track-with-new-generation", returned && previousConfirmed)
            guard returned, previousConfirmed else { return finish(false) }
            // Do not reimport A: this must recover the existing local binding.
            let restored = await wait {
                guard let current = model.snapshot.selection, let document = model.document else { return false }
                return current.recording.fingerprint == selection.recording.fingerprint && current.generation > secondSelection.generation
                    && document.recording.fingerprint == selection.recording.fingerprint && document.source.providerID == "local"
                    && document.contentHash == originalHash && document.contentHash != secondHash
                    && model.currentCue != nil && panel.panel.isVisible && panel.panel.frame.height == LyricPanelLayout.lyricsHeight
            }
            await record("original-local-binding-restores-without-reimport", restored)
            capture(capturePrefix + "-previous-restored")
            guard restored, let returnedSelection = model.snapshot.selection else { return finish(false) }
            // Earlier seek/pause/resume checks retained A's initial identity.
            // A genuine A -> B -> A transition must give the quiet hold a new baseline.
            lyricBaselineSelection = returnedSelection
            trackSwitchPassed = true
        }

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
        let cueBeforeHold = model.currentCueIndex
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        await record("continued-playback", model.snapshot.state == .playing && panel.panel.isVisible && retainsImportedLyrics()
            && model.currentCueIndex != nil && panel.panel.frame.height == LyricPanelLayout.lyricsHeight)
        if hold >= 16 {
            // A lower CPU result is invalid if the visible lyric stopped
            // advancing. Check the actually presented cue against the real
            // source position after the quiet sample, without polling inside it.
            var followsSource = false
            if let previous = cueBeforeHold, let current = model.currentCueIndex,
               let position = model.playbackPositionMS, model.leadCues.indices.contains(current),
               let start = model.leadCues[current].sourceStartMS {
                let sourceAdvance = model.document?.sourceTiming.interpretation == .normalizedKnownFormat
                    ? (model.document?.sourceTiming.sourceAdvanceMS ?? 0) : 0
                let lookup = position + sourceAdvance + model.advanceMS
                let nextStart = model.leadCues.dropFirst(current + 1).compactMap(\.sourceStartMS).first
                followsSource = current > previous && lookup >= start - 250
                    && (nextStart == nil || lookup < nextStart! + 250)
                write("native-line-progress.json", ["scope": "displayed original LRC cue versus the actual player source position",
                    "passed": followsSource, "beforeCueIndex": previous, "afterCueIndex": current,
                    "sourcePositionMS": position, "lookupMS": lookup, "currentCueStartMS": start,
                    "nextCueStartMS": nextStart as Any? ?? NSNull(), "publicationToleranceMS": 250,
                    "independentAcousticClockQualification": false])
            }
            await record("continued-lyric-cue-follows-real-source-position", followsSource)
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        return finish(passed)
    }
}
