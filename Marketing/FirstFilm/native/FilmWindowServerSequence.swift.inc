        if FilmCaptureSupport.windowServerEnabled {
            pointerAttempted = pointerReport()?["available"] as? Bool == true
            guard imported, pointerAttempted else { return finish(false) }
            var sequence = 0
            func input(_ action: String) async -> Bool {
                sequence += 1
                return await pointerAction(sequence, action)
            }
            func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            for language in ["zh", "en"] {
                if language == "en" {
                    let relaunched = await FilmCaptureSupport.restartOriginalMusicPlaylist(script: directory.appendingPathComponent("music-select-first.applescript"))
                    let restoredFirst = await wait(15) { model.snapshot.state == .playing && model.snapshot.selection?.recording.title == title && !model.isPerformingCommand }
                    await record("film-real-music-relaunch-original-playlist", relaunched && restoredFirst)
                    guard relaunched && restoredFirst else { return finish(false) }
                    model.perform(.next)
                    let selected = await wait { model.snapshot.selection?.recording.title == nextTitle && !model.isPerformingCommand }
                    let confirmed = await commandConfirmed("next")
                    trackSwitchAttempted = true; trackSwitchPassed = selected && confirmed
                    await record("film-next-real-source-confirmed", trackSwitchPassed)
                    guard trackSwitchPassed, let nextLyrics, let secondSelection = model.snapshot.selection else { return finish(false) }
                    model.importLyrics(from: URL(fileURLWithPath: nextLyrics), for: secondSelection)
                    let ready = await wait { model.document?.source.providerID == "local" && model.document?.recording.fingerprint == secondSelection.recording.fingerprint && model.currentCue != nil }
                    await record("film-english-original-lyrics-bound", ready)
                    guard ready else { return finish(false) }
                }
                FilmCaptureSupport.restoreWindowServerSurfaceIfSourceVisible()
                await settle(0.2)
                let left = await input("leave")
                _ = await wait { !model.controlsVisible && !model.panelInteractionActive }
                guard left else { return finish(false) }
                do {
                    FilmCaptureSupport.showAnimationControl(true)
                    for variant in ((FilmCaptureSupport.lyricsOnly || FilmCaptureSupport.originalOnly) ? ["a"] : ["a", "b"]) {
                        FilmCaptureSupport.useStableCueTransition = variant == "b"
                        model.perform(.seek(milliseconds: 0))
                        let reset = await wait { !model.isPerformingCommand && (model.playbackPositionMS ?? Int64.max) < 2_000 }
                        let resetConfirmed = await commandConfirmed("seek", seekMS: 0)
                        await record("film-" + variant + "-" + language + "-start-position-confirmed", reset && resetConfirmed)
                        guard reset && resetConfirmed else { return finish(false) }
                        await settle(0.35)
                        let lyricTake = try await FilmCaptureSupport.beginScreenTake(variant + "-" + language + "-lyrics", seconds: 18)
                        let recorded = await FilmCaptureSupport.finishScreenTake(lyricTake)
                        await record("film-" + variant + "-" + language + "-continuous-lyrics-windowserver", recorded)
                        guard recorded else { return finish(false) }
                    }
                    FilmCaptureSupport.showAnimationControl(false)
                    FilmCaptureSupport.useStableCueTransition = false
                    if FilmCaptureSupport.lyricsOnly { continue }
                    let controlsTake = try await FilmCaptureSupport.beginScreenTake(language + "-controls", seconds: 16)
                    await settle(1.4)
                    let entered = await input("enter")
                    let hovered = await wait { model.controlsVisible && model.panelInteractionActive }
                    await record("film-" + language + "-native-hover", entered && hovered)
                    await settle(0.65)
                    let positionBeforeSeek = model.playbackPositionMS ?? 0
                    let seekPosted = await input("seek")
                    let seekDone = await wait { !model.isPerformingCommand && model.seekPreviewMS == nil && model.actionMessage == nil && abs((model.playbackPositionMS ?? positionBeforeSeek)-positionBeforeSeek) > 12_000 }
                    let seekReadback = await commandConfirmed("seek")
                    await record("film-" + language + "-native-slider-drag-readback", seekPosted && seekDone && seekReadback)
                    await settle(0.35)
                    let pausePosted = await input("pause")
                    let paused = await wait { model.snapshot.state == .paused && !model.isPerformingCommand }
                    let pauseReadback = await commandConfirmed("pause")
                    await record("film-" + language + "-native-pause-readback", pausePosted && paused && pauseReadback)
                    await settle(0.5)
                    let playPosted = await input("play")
                    let resumed = await wait { model.snapshot.state == .playing && !model.isPerformingCommand }
                    let playReadback = await commandConfirmed("play")
                    await record("film-" + language + "-native-resume-readback", playPosted && resumed && playReadback)
                    await settle(0.5)
                    let leavePosted = await input("leave")
                    let leftWhilePlaying = await wait { !model.controlsVisible && !model.panelInteractionActive && model.snapshot.state == .playing }
                    await settle(0.35)
                    let musicApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
                    let quitPosted = musicApplication?.terminate() == true
                    let playerExited = await wait { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty }
                    let withdrawn = await wait { !panel.panel.isVisible && !model.controlsVisible }
                    await record("film-" + language + "-actual-player-exit-withdrawal", leavePosted && leftWhilePlaying && quitPosted && playerExited && withdrawn)
                    let recordedControls = await FilmCaptureSupport.finishScreenTake(controlsTake)
                    await record("film-" + language + "-controls-windowserver", recordedControls)
                    pointerPassed = pointerPassed && entered && hovered && seekPosted && seekDone && seekReadback && pausePosted && paused && pauseReadback && playPosted && resumed && playReadback && leavePosted && leftWhilePlaying && quitPosted && playerExited && withdrawn
                    // A failed interaction remains a failure, but preserve the other language
                    // in this same bounded run instead of discarding independent source footage.
                } catch {
                    write("film-windowserver-error.json", ["error": error.localizedDescription, "language": language])
                    return finish(false)
                }
            }
            return finish(checks.allSatisfy { $0["passed"] as? Bool == true })
        }
