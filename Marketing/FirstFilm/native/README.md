# Native film capture

These tools capture the actual LyricTile AppKit/SwiftUI production views on a disposable macOS runner. They do not redraw the product interface in a browser, canvas, image model or video model.

## Source and separation

The source product is the standalone LyricTile tree inherited from commit `d57878e51137f9dbf238a61ac97ea4b0da8b81f6`. Its released build49 source is `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`. Nearpane's host does not yet consume this lyrics module, so the resulting film is a Nearpane product preview; these captures do not establish completed host integration.

`prepare_capture.py` copies the product to a temporary build directory. It adds native image capture instrumentation, records its exact changes, and leaves the repository's production source untouched. It changes only original test media, capture functions and verification pauses in that temporary copy. This is an instrumented filming build, not the released signed binary.

## Outputs

- `authored-native`: native production-view renders using original Chinese and English demo lyrics. Stills render at six times logical size. The cacheDisplay sequences contain discrete native cue states with monotonic fixture input. Pixel review showed only three different images in a six-second capture: no continuous transition was observed and they are not suitable as final native animation. The later gate trace established that the runner had Reduce Motion enabled; these files alone do not prove a cacheDisplay limitation or a product animation bug. Their manifests identify authored input; they are not real-player tests.
- `real-music`: the existing actual Music playback and OS pointer workflow. The real adapter, imported local original PCM audio, imported original LRC, real seek/pause/next/previous and independently read-back source remain in use. The result must be checked; an attempted run is not a pass.
- `music-lyrics` and `music-controls`: four-times offscreen production-view sequences sampled from the same live model during that actual-player run, with authoritative elapsed-time stamps. These are native-view captures, not WindowServer screen recordings.
- `real-desktop.mov`: an attempted actual desktop video during the player run. `desktop-video.json` reports whether the operating system capture succeeded.
- `work-window`: actual TextEdit window screenshots containing only original film copy.

The source and capture manifests distinguish real playback, authored view fixtures, staged desktop composition and the later film edit. No commercial song, lyrics or private user desktop content is recorded by this workflow. Demo audio is technical input; the final film score is supplied separately.

## Run

The dedicated `.github/workflows/film-native-capture.yml` runs on pushes to the film branch that touch this directory or that workflow. It does not modify another workflow, publish a product release or write to the user's Mac.

Inspect the uploaded artifact, `native-player.json`, capture manifests, image dimensions and continuous frames before using outputs. Keep raw footage separate from the published film and retain elapsed timing if conforming it to a constant frame rate.

## High-resolution still photography (run 5)

The real player run retains the actual on-screen panel and native OS pointer path. After the first genuine lyric import, it also creates two offscreen, input-disabled copies of the exact production `LyricPanelView`, both bound to the same live model at a logical 208×192 pt. The 6× surface provides sharp stills; the 4× cacheDisplay surface provides state samples only, not presentation-layer motion. This prevents distortion between a 176 pt cloud display layout and the 208 pt film composition. Every photograph is explicitly a native production-view re-render from actual player state. Original source-window pixels and the WindowServer recording remain separate. Frame manifests retain the original panel geometry, normalized real mouse position, original visibility, controls state, playback state and current cue. The original panel is not resized or restyled.

## Historical WindowServer route (run 6; superseded)

The run-6 route was superseded after shared-model side effects hid controls after seeking and scaled 1x text remained soft. Its recordings are diagnostic evidence, not accepted final motion. A commit containing `[windowserver]` now selects the single-window route below. It skips authored fixture rendering, the runtime benchmark and TextEdit. A third filming configuration places the same live production view at an actual 624×576 pixel on-screen surface (208×192 logical points, native 3× scale), beside the unchanged 176 pt ordinary panel. Real pointer events target this photography window through freshly observed Accessibility geometry. Hover, slider drag, pause and resume execute the production controls against the real Music session and require source readback. The ordinary product window is not restyled or resized.

The final motion sources are `windowserver/{zh,en}-{lyrics,controls}-fullscreen.mov`: each language has 18 continuous seconds of actual Music-driven lyrics and a 10-second controls take, including the actual cursor. The OS screen recording captures the native SwiftUI presentation layer. There is no bitmap interpolation or reconstructed UI animation. JSON alongside each MOV records the native crop rectangle, actual visibility/state observations and the framing distinction. The fullscreen movie is the primary visual evidence; state samples are not claimed to be frame-perfect media timestamps. Extract crop pixels without stretching, retaining original fullscreen footage and movie metadata.

## Single-window native HiDPI A/B capture (run 7)

The latest WindowServer route removes the mirrored-view architecture. It temporarily replaces the original controller window's hosting hierarchy with exactly one unscaled, 208×192 logical production view; the controller continues to own source visibility, input, pause retention and withdrawal. A capture-only geometry mapping moves that same window onto the verified native HiDPI display. No other production view is retained. Window backing scale, actual convertToBacking pixels, selected display ID, screencapture display-index proof and exact pixel crop are recorded.

Each language is recorded twice for lyric motion: `a-{zh,en}-lyrics` keeps the original transition guard; `b-{zh,en}-lyrics` uses an unreleased candidate that makes the cue transition definition stable while keeping the production animation eligibility gate. Each take is 18 seconds. A separate native 0.4-second `withAnimation` rectangle appears outside the product crop as a recording/backend control. It never appears in the final product crop. The actual environment Reduce Motion value, selection stability, index change and every gate are logged. No candidate is accepted merely because it rendered. The source repository's product view remains unchanged until the A/B footage establishes a fix and it is separately committed as an unreleased product patch.

`{zh,en}-controls` retain the original transition behavior and record 10 seconds with actual pointer hover, actual slider drag and independent seek readback, pause, resume, pause and withdrawal. Native pixels and actual source `windowVisible` determine transparency after withdrawal. Fullscreen MOVs and manifests are retained; cacheDisplay samples remain excluded from final motion.

## Observed Reduce Motion cause and normal-motion lyrics capture

Run 8 verified native 2x window backing (416×384 pixels), 28/28 bounded actual-player/input checks, and both A/B recordings. Its actual system and SwiftUI `accessibilityReduceMotion` values were true, so every `flowsUpward` gate was false. Neither A nor B established a product defect. No product source fix was accepted or committed.

`[normal-motion] [lyrics-only]` requests the ordinary non-reduced-motion presentation on the disposable runner and records only the two 18-second original-logic lyric takes. It first tries the normal accessibility preference via defaults, recording the result. If NSWorkspace still reports Reduce Motion, only the film hosting environment sets `accessibilityReduceMotion=false`, explicitly representing the product's already-supported normal-motion user setting. The actual system value, whether this hosting override was applied, and actual SwiftUI gate values remain in the manifests. Product transition logic remains original; the positive native-animation control is retained outside the product crop. The existing run-8 controls are separate verified source footage.

### Final normal-motion session

The final `[normal-motion] [original-only]` session records only the original transition implementation: Chinese/English lyrics18s and controls16s. Sixteen seconds leave room for the actual second pause, pointer departure and controller withdrawal. Run8's source checks passed these actions but its10s movies ended before withdrawal; that tail was not represented as recorded footage. The final session removes this footage gap and keeps normal-motion presentation consistent across all four takes. No product animation patch was accepted.
