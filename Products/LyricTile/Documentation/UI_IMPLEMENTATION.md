# Native LyricTile UI implementation

## Production surfaces

- `LyricUI/LyricAppModel.swift`: real PlaybackController + LyricRepository composition. No recordings or lyrics are injected. A kernel TileSessionLease is acquired before media observation starts. A cancelled/overlapping start and stop share lifecycle barriers; pending transport readback drains before ownership release.
- `LyricUI/LyricArtworkDecoder.swift`: serial ImageIO decoding outside MainActor. Original artwork is limited to 8 MiB, one frame and 4096 pixels per side before decoding; AppKit receives only a thumbnail of at most 512 pixels per side. Cancelled requests and mismatched session/data tokens cannot publish a cover for a different recording.
- `LyricUI/LyricPanelView.swift`: five-cue reading layout (current cue with two neighbours on each side; adaptive one/two-row native current cue and actual overflow indicator), immediate pointer entry / 280 ms control leave delay, native material, actual cover bytes, correct-source controls and readonly unavailable progress. The 192pt lyric surface and 104pt metadata-only surface each keep their frame on hover. No selection draws a transparent root. Missing artists are omitted rather than replaced by a player name.
- `LyricUI/LyricGlyphText.swift`: native CoreText paragraph and glyph-run shaping. Layout is cached. A one-shot timer updates masks only during a known active word, at up to 60 Hz (30 Hz in Low Power Mode); pauses, hidden views and unknown/stale clocks stop that timer. Source tokens with unknown ends activate discretely. UTF-16 spans are checked against composed-character boundaries. RTL glyph runs retain their native shaping and mask direction. Short cues are vertically centred; the viewport exposes whole rows at rest. Very long cues can be scrolled without shrinking the font.
- `LyricUI/LyricAuxiliaryController.swift`: real native windows for welcome, settings, candidate search, local import, source provenance, timing adjustment and the full lyric document. A line does not seek on ordinary click; an explicit context-menu action sends a guarded seek. Login start uses SMAppService and is disabled for an unpackaged executable.
- `LyricUI/LyricPanelController.swift`: nonactivating NSPanel, transparent rounded surface, top-strip drag, stable display UUID placement, sleep/display recovery, 192pt lyric / 104pt compact playing surfaces sharing a 192pt maximum slot. No playback has no surface or standalone registration. Playing is the only automatic show state; pausing retains only an existing same-recording pointer/keyboard interaction. Actual interaction is separate from accessibility-driven control visibility. User clicks may establish keyboard focus; pointer entry cannot activate the app.
- `LyricTileApp`: AppKit lifecycle and menu-bar entry. Normal installation starts with a welcome page and asks only the player's Automation permission when it is connected. Quit withdraws UI and drains the session.
- `NearpaneLyricsModule`: reusable View + the same domain/service composition. It does not create a second standalone panel or alter the host width.

## Geometry integration contract

The standalone app integrates TileDesktopCoordinator through these public PanelController hooks:

```swift
var slotFrame: NSRect { get }       // Active reservation: maximum 192 pt rectangle.
var wantsPresentation: Bool { get }
var visibilityIntentDidChange: ((Bool) -> Void)?
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

`LyricTile --smoke-test` constructs the production NSPanel, hosting view and genuine no-playback state; it skips media start, provider calls and permission requests. It checks that the no-playback panel remains hidden even after a user-initiated show request, then opens the production welcome and settings windows through `model.show`, waits once for each layout and checks actual visibility/content attachment. With `--smoke-screenshot <path>`, it writes `native-welcome.png` and `native-settings.png` in that directory; an absent panel has no screenshot. `PanelLayoutTests` separately render authored lyric/metadata fixtures through the real NSHostingView, saving PNG and explicit fixture metadata when `LYRICTILE_UI_EVIDENCE_DIR` is set. These fixtures do not start a player or acquire a session; their transport controls are disabled and artwork acceptance is not exercised. Missing windows or failed requested screenshots fail the combined JSON result. The check closes the auxiliary windows and terminates through the normal application lifecycle. It neither supplies fixture music nor proves player control, TCC, material contrast, glyph correctness or physical desktop behavior.

## Qualification still requiring physical environments

Hosted Xcode compilation/load checks are distinct from physical-machine validation. Remaining checks are actual player and permission flows, mixed-DPI/Spaces/fullscreen presentation, WindowServer withdrawal, long/bidirectional/combining-character lyric masks, hover/key-focus behavior, VoiceOver and accessibility preferences, CoreText CPU/profile measurements, and a long session with sleep/wake. Any CI results belong to the actual run's commit and logs; this document does not claim a build passed before it ran.
