# Nearpane v3 — native dynamic Riftlet take

This supplement replaces only the v2 Host scene that assigned the empty screenshot tray a lyric-sized height. The core Music-to-Preview and QQ takes are unchanged.

## Accepted source

- `host-fullscreen.mov`: original completed ScreenCaptureKit/WindowServer recording, 3840 × 2160, 24.2 s, with actual system audio and pointer.
- 649 native video frames, 1203 audio buffers; writer completed without an error. Full audio/video decode passed.
- Creative branch commit: `75911f8db472fe5fd2ffb0d7d9970dcfe241c3b3`.
- Run: https://github.com/haohongfei2001-png/nearpane/actions/runs/46124060079 .
- No production files or main branch changed in this supplement.

## Actual geometry

The production `TrayModule.rowCount` is one with its two empty entries, and two after a real screenshot introduces a third slot. Production `LayoutComposer.compose(...).screenshots.height` returns 76 and 144 pt. Photography retains a constant 280/208 uniform scale, the true production TraySurface and its unchanged icons/cells. Only the outer material is matched to the lyric card. It does not stretch the empty tray or apply opacity to its contents.

Measured card rectangles in captured 4K pixels, x/y from the top-left of the movie, excluding shadow:

| State | Riftlet x,y,w,h | Lyrics x,y,w,h |
|---|---|---|
| Before reorder | 3224,653,560,204.6154 | 3224,104,560,516.9231 |
| Reordered empty | 3224,104,560,204.6154 | 3224,341,560,516.9231 |
| Actual screenshot | 3224,105,560,387.6923 | 3224,524,560,516.9231 |

The one-pixel native top-edge shift on expansion is real raster rounding. Initial/final dimensions are actual AX readback. Reordered empty position uses actual camera-entry AX minus native padding and an encoded-pixel edge check. Do not prematurely apply the final tall matte: it would also reveal part of the lyric card below the short tray.

## Actual encoded event timing

- True management drag mouse down 3.630373; mouse up 7.016493 s.
- Host order sampled changed at 7.065330 s. Video 7.116667 still has old order; first swapped encoded frame is **7.150000 s**.
- Camera entry down 11.945231 s; actual region selection drag 16.417868–20.202204 s.
- Screenshot asset first observed in the store and rowCount=2 at 21.170554 s (uptime relative to first capture PTS).
- Video **21.166667 s** still has one row. **21.200000 s** is first two-row frame with a native loading placeholder. **21.233333 s** is first actual coastal thumbnail, preserved through the end.
- No intermediate card-swap or height geometry was present in the encoded frames. Do not add invented easing/interpolation.

The capture is a real region of the owned coastal wallpaper, not the Preview PDF. The region-selection UI and resulting matching thumbnail are retained as recorded.

## Actual audio source clock

For the audible source interval, `sourceSeconds = rawVideoSeconds + 168.04225053873157`. Measured by independent waveform comparison with Josh Woodward's original Good To Go recording; 17 windows, median normalized correlation 0.99995565. Read `capture-audio-alignment.json` for complete anchors and capture timestamp coverage.

The actual recorded song reaches its tail; from 17.64 s onward this take is below -70 dBFS. Do not claim the song continues at the later screenshot event. The screenshot tail can be presented as its own real detail view, retaining its raw temporal order. All music rights and original assets remain in the existing v2 licensed material package; this take introduces no new song.

## Evidence

`dynamic-tray-evidence.json` contains actual geometry and acceptance. `dual-state-timeline.json`, input reports, original media PTS lists, before/after full-screen frames, and native transition crops preserve verification. No screenshot or movie content was redrawn.
