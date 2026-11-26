# Native LyricTile UI implementation

## Production surfaces

- `LyricUI/LyricAppModel.swift`: real PlaybackController + LyricRepository composition. No recordings or lyrics are injected. A kernel TileSessionLease is acquired before media observation starts. A cancelled/overlapping start and stop share lifecycle barriers; pending transport readback drains before ownership release.
- `LyricUI/LyricArtworkDecoder.swift`: serial ImageIO decoding outside MainActor. Original artwork is limited to 8 MiB, one frame and 4096 pixels per side before decoding; AppKit receives only a thumbnail of at most 512 pixels per side. Cancelled requests and mismatched session/data tokens cannot publish a cover for a different recording.
- `LyricUI/LyricPanelView.swift`: fixed reading anchor, 140 ms pointer dwell / 280 ms leave delay, native material, actual cover bytes, correct-source controls, readonly unavailable progress, and distinct initial / permission / lyric / position states. Hover never changes the outer frame.
- `LyricUI/LyricGlyphText.swift`: native CoreText paragraph and glyph-run shaping. Layout is cached. A one-shot timer updates masks only during a known active word, at up to 60 Hz (30 Hz in Low Power Mode); pauses, hidden views and unknown/stale clocks stop that timer. Source tokens with unknown ends activate discretely. UTF-16 spans are checked against composed-character boundaries. RTL glyph runs retain their native shaping and mask direction. Very long cues can be scrolled without shrinking the font.
- `LyricUI/LyricAuxiliaryController.swift`: real native windows for welcome, settings, candidate search, local import, source provenance, timing adjustment and the full lyric document. A line does not seek on ordinary click; an explicit context-menu action sends a guarded seek. Login start uses SMAppService and is disabled for an unpackaged executable.
- `LyricUI/LyricPanelController.swift`: nonactivating NSPanel, transparent rounded surface, top-strip drag, stable display UUID placement, sleep/display recovery, compact 62 pt idle surface retaining a 272 pt logical slot. User clicks may establish keyboard focus; pointer entry cannot activate the app.
- `LyricTileApp`: AppKit lifecycle and menu-bar entry. Normal installation starts with a welcome page and asks only the player's Automation permission when it is connected. Quit withdraws UI and drains the session.
- `NearpaneLyricsModule`: reusable View + the same domain/service composition. It does not create a second standalone panel or alter the host width.

## Geometry integration contract

The standalone app integrates TileDesktopCoordinator through these public PanelController hooks:

```swift
var slotFrame: NSRect { get }       // Always the reserved 272 pt rectangle.
var displayUUID: String? { get }
var windowIDs: [Int] { get }
var placementPermitted: Bool { get }
var usesCoordinatedPlacement: Bool
var placementDidChange: ((NSRect, String?, Bool) -> Void)?
func setPlacementPermission(_ permitted: Bool)
func withdraw()
func placeHidden(slot: NSRect, displayUUID: String?)
func show(userInitiated: Bool = false)
```

The app sets placement permission false before an ordinary startup becomes visible. False withdraws immediately and also gates snapshot-driven visibility, so an asynchronous player update cannot bypass the layout barrier. The coordinator applies a committed frame while hidden, then permits/shows only while the registry still grants that generation authority. With coordinated placement enabled, display changes withdraw and invalidate the plan instead of independently restoring/showing the panel. The drag strip proposes a new right-column order/display; it does not make another product move. `surrender()` also disables input for ownership handoff.

## Session handoff

1. The new surface tries the lifetime lock. If occupied and the user requested transfer, it sends a versioned local handoff request to the other role.
2. The standalone owner disables input, orders its panel out, and verifies its IDs disappear from the WindowServer on-screen list. A timeout does not release its lease.
3. The old model stops accepting commands, drains already dispatched readback, stops observation and releases the lease.
4. The new model must acquire the actual flock. Notifications and acknowledgements are hints, never ownership authority. It reads a fresh player snapshot before rendering actual content.
5. An embedded host removes its pure View before stop. It may provide `hostSurfaceDidWithdraw` to acknowledge its own completed view transaction; otherwise two main-loop opportunities are allowed. Native host presentation still needs macOS compositor verification.

Handoff request names and payloads are in `LyricUI/LyricHandoff.swift`. They carry only roles/request IDs/PID, not lyrics or transcripts. A same-user process can request a surface transition; it cannot gain control without acquiring the file lock. When the host exits normally, a previously suspended standalone app may reacquire and resume. The kernel releases ownership after a crash; no TTL steals a live lock.

## Native load check

`LyricTile --smoke-test` constructs the production NSPanel, hosting view and genuine no-playback state; it skips media start, provider calls and permission requests. After the empty-panel check, it opens the production welcome and settings windows through `model.show`, waits once for each layout and checks actual visibility/content attachment. With `--smoke-screenshot <path>`, it writes the empty panel to that path plus `native-welcome.png` and `native-settings.png` in the same directory. Missing windows or failed requested screenshots fail the combined JSON result. The check closes the auxiliary windows and terminates through the normal application lifecycle. It neither supplies fixture music nor proves player control, TCC, material contrast, glyph correctness or physical desktop behavior.

## Qualification still requiring physical environments

Hosted Xcode compilation/load checks are distinct from physical-machine validation. Remaining checks are actual player and permission flows, mixed-DPI/Spaces/fullscreen presentation, WindowServer withdrawal, long/bidirectional/combining-character lyric masks, hover/key-focus behavior, VoiceOver and accessibility preferences, CoreText CPU/profile measurements, and a long session with sleep/wake. Any CI results belong to the actual run's commit and logs; this document does not claim a build passed before it ran.
