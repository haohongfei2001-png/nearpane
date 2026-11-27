# Unified workbench native verification

Run `python3 scripts/acceptance/unified-workbench/run.py build/debug/Nearpane.app`
on an isolated native macOS desktop after building the full debug candidate. The
GitHub `Nearpane unified workbench` workflow performs this automatically.

The runner copies the candidate, applies the existing alpha fixture identity and
an ad-hoc signature, then uses the existing executable-bound acceptance profile.
It does not install over a daily app or read a user's profile. It opens the actual
retained main window, performs native accessibility presses, renders the actual
desktop sidebar and saves screenshots plus a structured receipt.

Screenshots prefer WindowServer `screencapture`. If screen recording access is
unavailable, the receipt identifies a fallback to `NSView.cacheDisplay` of the
same visible native window. The window's existence and visibility are checked
against WindowServer independently of either capture method.

## Evidence boundaries

- Navigation and toggle actions attempt the real views' accessibility actions.
  DEBUG CI alpha-fixture views explicitly enable the public SwiftUI
  `accessibilityEnabled` environment so the native logical accessibility tree is
  available without running VoiceOver. The receipt records this environment;
  normal app defaults, macOS permissions and playback ownership are unchanged.
  Every attempt saves a compact native accessibility tree and action result. A
  failed input remains FAIL even when explicitly labelled programmatic routing
  continues the independent screenshot inspection; the first native image is
  captured before any input probe.
- Repeated entry uses the Host's normal main-window opener and checks object
  identity, window number and the count of standard management windows.
  Close/reopen also checks the same retained object, allowing its WindowServer
  number to change after closing.
- Reordering exercises the same persisted command used by drag/drop. It is not a
  physical pointer drag test.
- Content consists of the existing generated native acceptance library entries.
  Counts and configuration readbacks check preservation while toggling modules.
- Lyric screenshots use labelled synthetic snapshots in the production lyric
  view/model. They do not certify Apple Music/QQ Music/NetEase control or discovery.
  A native cursor move separately checks paused hover presentation. The fixture
  owns no playback lease, so its transport controls deliberately remain disabled.
- A full sidebar layout and its dark appearance are captured with the real native
  panel. The all-module screenshot does not qualify real Spaces window dispatch.
- The existing PR 16 Spaces engine qualification is independent of this UI run.
- A successful debug build/native UI receipt is not a signed, notarized release.

Artifacts contain the original packaged candidate separately from the fixture
copy, complete build/test logs and the native screenshots and receipts.

## Optional actual Apple Music probe

`native_player.py` runs after the UI check on the disposable GitHub macOS runner.
It creates an original local WAV, asks the installed Music app to play it and
then starts `--native-player-probe` in the same packaged Nearpane executable.
The probe uses the production `PlaybackController` for pause/resume and saves
the real adapter's command readbacks. It checks a 15-second non-hovered pause,
the paused clock, normal resumption and the actual player's exit. No extra
standalone lyric panel or management window is created.

This probe may be BLOCKED by the runner's Music welcome flow or macOS Automation
permission. Its separate receipt never converts that into a UI-gate failure or
a false playback PASS. It does not exercise commercial streaming catalogs, QQ
Music, NetEase, physical pointer input, or independently measured clock accuracy.
