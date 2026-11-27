# LyricTile · HOLDSNOW

**歌词，自然在旁。** A native macOS companion for the music player you already use.

LyricTile is an **independent application**, maintained in the Nearpane repository under `Products/LyricTile`. It has its own Swift package, bundle identifier (`com.holdsnow.lyrictile`), app lifecycle, settings, updater and package pipeline. It does not launch Nearpane and does not require the Nearpane window engine. Future Nearpane integration uses the native view and service modules directly.

**Current channel: final release preparation.** The latest source and cloud-built candidate are identified in [STATUS](STATUS.md). Notarized LyricTile 1.0.0 (4) is a historical installation baseline, predating the current interface; it is not offered as the latest download. The initial platform remains Apple silicon, macOS 27 or later. [Product page source](Website/README.md) · [Installation](Documentation/INSTALL.md) · [Release preparation](Documentation/RELEASE.md).

## Evidence and supported scope

Historical build 4 played local tracks through Apple Music 1.7 and QQ Music 11.11.0 on macOS 27.0 (26A428), with native controls and a signed build 2→4 update exercised on a MacBook Air. These results apply to that package. Latest cloud compilation, native UI, real-player attempts, and exact evidence are linked from [STATUS](STATUS.md); [support scope](Documentation/SUPPORT.md) separates current and historical results. Spotify and NetEase must not be called verified merely because their adapters exist. First release support is limited to the actual passing paths, not gated on all four players.

## Start here

- [Current status and exact next step](STATUS.md): latest implementation, validation, remaining work and the small set of files to read next; no prior conversation retrieval is needed.
- [Complete product/design/source research](Research/2026-11-26/README_START_HERE.md): 54 archived deliverables, three high-fidelity directions, selected design, interaction specification, source pins and macOS acceptance cases.
- [Actual implementation architecture](Documentation/ARCHITECTURE.md): module boundaries, lifecycle and where earlier research was refined.
- [Native UI implementation](Documentation/UI_IMPLEMENTATION.md), [media implementation](Documentation/MEDIA_IMPLEMENTATION.md), [lyrics implementation](Documentation/LYRICS_IMPLEMENTATION_STATE.md).
- [Local-only Codex handoff](Documentation/LOCAL_ONLY_HANDOFF.md): the remaining physical environment and owner-controlled release work. Ordinary coding/compilation is not a handoff item.
- [Third-party notices](Documentation/THIRD_PARTY_NOTICES.md).
- [Chinese/English installation](Documentation/INSTALL.md), [privacy](Documentation/PRIVACY.md), [release checks](Documentation/RELEASE.md), and [product page](Website/README.md).

## Independent build

Use Xcode with Swift 6 on a Mac. The first distribution target is **macOS 27, Apple silicon**. Reusable sources have a macOS 14 API floor to keep the package modular; this is not a public support promise for macOS 14–26.

```sh
git switch codex/lyrictile-standalone-20261126
cd Products/LyricTile
swift test --parallel
bash Scripts/build-app.sh
open dist/LyricTile.app
```

The default build is a release-optimized, ad-hoc signed arm64 **candidate**. It includes the real pinned media helper and Sparkle framework. It produces `dist/LyricTile.app`, ZIP, DMG, checksums and bundle verification. This does not notarize or publish anything. `LYRICTILE_ARCH=x86_64` is available for host diagnostics; no Intel support qualification is claimed.

For a native UI loading check with no player, network lookup or fabricated track:

```sh
python3 Scripts/run-native-smoke.py dist/LyricTile.app --output dist/evidence
```

Tests use clearly authored fixtures under `Tests/`; production startup has no demo playlist, synthetic elapsed time or preset lyrics. The timeline projects only a real, sufficiently fresh source anchor.

## What the application does

The panel appears automatically only while an identified song is playing. Its 192-point lyric surface centers the current cue and softens surrounding context. Ordinary cues show up to two cues above and below; long cues reduce context to allow three or four complete text rows, with native scrolling for exceptionally long lines. Songs without lyrics use a 104-point summary. Hover reveals artwork, title, artist, transport, and progress in the same outer frame while retaining the current lyric. Missing artwork uses a neutral symbol; unknown fields stay unknown. No playback leaves no desktop panel. A paused song retains an already-visible panel only during interaction. Connection status, local import, and settings remain in the menu bar.

| Player | Implemented route | Runtime limitation to verify on the exact installed build |
|---|---|---|
| Apple Music | Process-targeted ScriptingBridge metadata, progress, artwork and commands | On-demand Automation consent, local/cloud tracks, seek/readback, sleep/wake |
| Spotify desktop | Process-targeted ScriptingBridge and bounded official artwork download | Ads, podcasts/unsupported media, Connect, remote-output position and controls |
| QQ Music | Isolated MediaRemote stream/snapshot helper | Actual source participation; global commands only while the intended source owns Now Playing; paused seek disabled |
| NetEase Music | Same isolated helper, independent adapter capability state | Actual client version's timestamp/capability behavior and current-source ownership |

An installed/running player is not sufficient evidence for every control. Capabilities are derived from the actual route and observations. Commands are sent once and checked against fresh state; a successful process exit is not reported as successful playback control.

LRCLIB lookup is real and runs from the device. It is enabled by default, disclosed on the welcome screen, and can be switched off; local imports work independently. LRC/enhanced LRC/LRCX, TTML, LRCLIB Lyricsfile, and plain text normalize into one model with source provenance. Automatic matching rejects ambiguous recording versions and offers explicit candidates. API access does not establish copyright authorization for every lyric. The app contains no third-party lyric catalog. See [privacy and data flows](Documentation/PRIVACY.md).

Fresh unmeasured position anchors support ordinary line synchronization. Continuous word sweep additionally requires real token timestamps and a matching, evidence-backed position qualification; unknown precision never becomes zero. No physical qualification profile is bundled by this remote implementation. See `MEDIA_IMPLEMENTATION.md` for the exact evidence format.

## Desktop and future Nearpane integration

TileKit coordinates cooperating apps through short locked transactions and explicit withdrawal acknowledgements. A missing heartbeat never authorizes drawing over a visible window. Shared width is 176–224 points; margins are 16 points and spacing is 10 points. LyricTile reserves its actual 104/192-point height. Shrinking is briefly coalesced; expansion withdraws through the existing coordination barrier before occupying the larger slot. No playback unregisters the slot. Hover does not resize or reorder the panel.

Legacy Saytile and Riftlet versions do not yet implement that protocol. LyricTile reads only their public window geometry and avoids recognizable component windows, without moving them or requiring Accessibility/Screen Recording. This is compatibility avoidance, not a claim that old apps now negotiate reordering. Dragging in coordinated mode requests column order/display changes. Turning coordination off gives explicit local placement.

Nearpane can depend on `NearpaneLyricsModule`, embed its pure SwiftUI view and own the geometry. Explicit handoff withdraws the old surface before its module lease is released. There is one active lyrics service owner, not multiple floating apps assembled into a host UI.

## Build and release variables

| Variable | Meaning |
|---|---|
| `LYRICTILE_ARCH` | `arm64` default; native or cross build |
| `LYRICTILE_CONFIGURATION` | `release` default or `debug`; neither fabricates data |
| `LYRICTILE_VERSION`, `LYRICTILE_BUILD_NUMBER` | Bundle/display version and monotonically increasing build |
| `LYRICTILE_OUTPUT` | Generated output directory; defaults to this package's `dist` |
| `LYRICTILE_SIGN_IDENTITY` | Owner's installed Developer ID identity; defaults to ad-hoc `-` |
| `LYRICTILE_UPDATE_FEED`, `LYRICTILE_UPDATE_PUBLIC_KEY` | HTTPS appcast and real Ed25519 public key, supplied together |
| `LYRICTILE_NOTARY_PROFILE` | Existing local Keychain notary profile, used only by explicit notarization script |

Missing update configuration is shown honestly as an unconfigured candidate channel, never “up to date.” Keys, credentials, signing identities and private diagnostics are not committed. No app store, public release, telemetry or account service is created by this branch.

