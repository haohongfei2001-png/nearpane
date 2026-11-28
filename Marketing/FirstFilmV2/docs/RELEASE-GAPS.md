# Remaining release work

The film can describe the recorded product preview. It is not evidence that a
signed unified Nearpane download or the intended module-installation model is
already public.

## Already resolved for this film branch

`Products/LyricTile/Sources/CPlayerBridge/CPlayerBridge.m` now resolves Music's
`SBObject` artwork value and unwraps an `NSAppleEventDescriptor` before the
existing NSData validation. The actual decoded 486,932-byte image matches the
licensed original cover SHA256. The two-line product fix is in commit
`c5db289d422744eafa5a31e84931e9321f4d3d6e`, verified in an actual macOS capture.
It has not been represented as a released main-branch update.

## Minimal product handoff

1. **New-install preset.** At filming baseline
   `d5767d87bc45245b31d0980e91e43778c5f424ed`,
   `Sources/NearpaneCore/Modules.swift` registers LyricTile as `.builtin` and
   defaults `enabled` to `manifest.kind == .core`, also during restore. Define
   the lyric-led first-install preset without overwriting saved user choices.
2. **Actual optional installation.** Riftlet is presently compiled into Host
   and `.core`. The real management controls enable/disable and reorder the
   registered modules. Implement the intended package download, removal and
   re-add lifecycle before advertising those controls as downloads.
3. **Public release and CTA.** Qualify the integrated signed/notarized app and
   publish its actual installer on the verified official site. Then replace
   the preview ending with “下载 Nearpane / Download Nearpane” and an accurate
   included-lyrics statement. Source-check the installed package, not merely
   the website wording.

## Limits of the filmed evidence

The lyric views use current native code with real Music and QQ Music playback.
The selected canonical lyrics were loaded through the actual local LRC import
path because the available online match for this song was incorrect. The film
therefore does not certify automatic online matching for this particular song.
Host ordering is actual registry ordering. The matched Riftlet outer glass is
the authorized photography adaptation. No desktop drag ordering, network
module installation, voice input, translation or Spaces function is advertised.

The current Host preserves a valid lyric/player session while paused; player
exit or module disable removes it. Do not advertise pause as unconditional
instant disappearance.
