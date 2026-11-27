# Native film capture

These tools capture the actual LyricTile AppKit/SwiftUI production views on a disposable macOS runner. They do not redraw the product interface in a browser, canvas, image model or video model.

## Source and separation

The source product is the standalone LyricTile tree inherited from commit `d57878e51137f9dbf238a61ac97ea4b0da8b81f6`. Its released build49 source is `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`. Nearpane's host does not yet consume this lyrics module, so the resulting film is a Nearpane product preview; these captures do not establish completed host integration.

`prepare_capture.py` copies the product to a temporary build directory. It adds native image capture instrumentation, records its exact changes, and leaves the repository's production source untouched. It changes only original test media, capture functions and verification pauses in that temporary copy. This is an instrumented filming build, not the released signed binary.

## Outputs

- `authored-native`: native production-view renders using original Chinese and English demo lyrics. Stills render at six times logical size. Short sequences retain the production cue transition with monotonic fixture input. Their manifests identify authored input; they are not real-player tests.
- `real-music`: the existing actual Music playback and OS pointer workflow. The real adapter, imported local original PCM audio, imported original LRC, real seek/pause/next/previous and independently read-back source remain in use. The result must be checked; an attempted run is not a pass.
- `music-lyrics` and `music-controls`: four-times native-view sequences sampled during that actual-player run, with authoritative elapsed-time stamps. These are native-view captures, not WindowServer screen recordings.
- `real-desktop.mov`: an attempted actual desktop video during the player run. `desktop-video.json` reports whether the operating system capture succeeded.
- `work-window`: actual TextEdit window screenshots containing only original film copy.

The source and capture manifests distinguish real playback, authored view fixtures, staged desktop composition and the later film edit. No commercial song, lyrics or private user desktop content is recorded by this workflow. Demo audio is technical input; the final film score is supplied separately.

## Run

The dedicated `.github/workflows/film-native-capture.yml` runs on pushes to the film branch that touch this directory or that workflow. It does not modify another workflow, publish a product release or write to the user's Mac.

Inspect the uploaded artifact, `native-player.json`, capture manifests, image dimensions and continuous frames before using outputs. Keep raw footage separate from the published film and retain elapsed timing if conforming it to a constant frame rate.
