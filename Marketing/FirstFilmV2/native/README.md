# Nearpane first film — v2 native camera

## What this capture proves

The first take uses the production `NearpaneLyricsModule`, `LyricAppModel`,
`LyricPanelView`, playback bridge, artwork decoder and local lyric importer from
Nearpane commit `d5767d87bc45245b31d0980e91e43778c5f424ed`.
It plays Josh Woodward's released recording **Good To Go**, from **The Simple
Life**, in the actual macOS Music application. Album artwork comes back through
the actual current track's artwork data. The real song's words are imported as
a local LRC with absolute full-track timestamps. No playback snapshots, invented
titles, simulated album artwork, substitute UI, or artificial cue interpolation
are supplied.

The camera host is a small isolated executable linking those embedded libraries;
it is **not** the complete shipping Nearpane Host or a release acceptance test.
One extra extension exposes the existing local-file import action to this bounded
capture driver. A read-only bridge diagnostic records the actual `rawData` class
and image payload. Run `46109639614` proved that Music returned an `SBObject`
proxy resolving to an `NSAppleEventDescriptor`, rather than `NSData`. The actual
current-track payload passed the unchanged identity and 8 MiB guards, and decoded
as the original licensed JPEG (SHA-256
`1f309a4fb2127300b32495720f9a83cf44484dd12e3d6fc1826e08d0885e7682`).
The isolated candidate then produced the actual cover through the ordinary
production model and decoder in a real 4K hover recording with system audio.
That proven two-line unwrapping fix is now included on this **unreleased creative
branch only**. It is not merged to main and is not a shipping capability claim.
The original code, diagnostic, exact diff and result remain in the run artifact.
No album image is injected into the view. The view
keeps its canonical 208 × 192-point composition, with a stated photographic
scale of 280/208 on a verified real 2× display. The native window is positioned
at the upper right for this photograph. This is not evidence of a new product
window-placement control.

ScreenCaptureKit captures the actual full WindowServer desktop, actual cursor,
and actual system audio at the source display's physical resolution. The first
take begins with the real Music window and opens the supplied original PDF in real
Preview. Ordinary lyrics can be filmed even if the optional product artwork path
is missing. An independently verified candidate hover take uses real CGEvents. Native
state samples include frontmost application, track, player position, cue text,
artwork bytes and control visibility. Audio buffer counts and movie PTS are
recorded; a successful command alone is not proof of usable sound or visuals.

Only a fresh disposable GitHub Actions macOS runner is accepted. No personal
library, login, TCC database, real user's desktop or production app data is
modified. Permission/onboarding handling uses existing Accessibility permission
and narrowly identified real native controls. The recording and application data
remain in an Actions artifact, not in source control.

## Product claims allowed by the checked evidence

- Apple Music: CI49 ordinary-app playback evidence passed 24/24 checks.
- QQ Music and NetEase Cloud Music: 18/18 each for the tested actual clients and
  local track. Their queue/catalog breadth is not established by those checks.
- Spotify: adapter present, no actual signed-in playback pass found.
- IINA/Cog/VLC: not admitted by the current four-case `PlayerID` enum; this
  camera must not add them only for advertising.
- Artwork: actual Music `current track.artworks[0].rawData`; Spotify uses the
  bounded official-domain artwork URL path; QQ/NetEase are MediaRemote sources.
- Lyrics: local supported formats or metadata-based LRCLIB lookup. The native
  player is not itself a proprietary lyric feed.
- Module reordering: management-window drag/drop calls the real Host order
  command. Desktop-card drag reordering is not currently implemented.
- Default install: lyric module remains optional/disabled on a fresh Host.
  Riftlet is statically compiled. Actual module download/remove is still a goal.
- No public unified Nearpane download was verified. Use “product preview” and
  “visit nearpane.com”, not an immediate-download/default-on promise.

The two equal-card composition and a short actual screenshot take are separate
v2 tasks. If their wrapper changes Riftlet size/material, this must remain
explicitly film-only; its text and image opacity must not be faded as a shortcut.

## Licensed recording

Recording and composition: Josh Woodward, **Good To Go**, CC BY 3.0 US.
Album artwork: Josh Woodward, **The Simple Life**, CC BY 3.0 US; Wikimedia VRT
permission `2013022010009149`.
Attribution URL: https://www.joshwoodward.com/
License: https://creativecommons.org/licenses/by/3.0/us/

`build_good_to_go.py` downloads only the reviewed original OGG and artwork,
verifies their SHA-256 values, preserves the actual artist/title/album, and
converts to ALAC for Music import without changing speed or pitch. This avoids
another lossy encode; it does not claim the downloaded Vorbis was a lossless
studio master. The LRC words have been checked against the author's lyrics;
its ASR-derived times were cross-checked with two models in a wider audio context;
they have not been described as a completed human listening calibration.

The private `CGVirtualDisplay` helper is a camera-only utility with Chromium
BSD attribution in `np-hidpi-third-party.txt`. It is not shipped in Nearpane.
