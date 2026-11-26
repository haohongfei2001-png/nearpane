# LyricTile · HOLDSNOW

**歌词，自然在旁。** A native macOS companion for the music player you already use.

LyricTile is an **independent application**, maintained in the Nearpane repository under `Products/LyricTile`. It has its own Swift package, bundle identifier (`com.holdsnow.lyrictile`), app lifecycle, settings, updater and package pipeline. It does not launch Nearpane and does not require the Nearpane window engine. Future Nearpane integration uses the native view and service modules directly.

**Current channel: engineering candidate.** Start each development session with [STATUS.md](STATUS.md), the compact, current resume entry. Read only the module and tests required for the next task. Real implementations are present; source compilation, fixture tests, package checks, production empty/welcome/settings surface load and real-player qualification are separate evidence classes. Detailed earlier evidence is indexed in [implementation status](Documentation/IMPLEMENTATION_STATE.md).

## Latest native candidate

[Verified source `123fd0bd1433`](https://github.com/haohongfei2001-png/nearpane/commit/123fd0bd1433ee2a20b7d4bd2f07b26920781b00) · [macOS CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041) · [candidate ZIP/DMG](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041/artifacts/15105338706) · [preserved evidence](Documentation/Verification/2026-11-26-continuation/README.md). Actual host: macOS 27.0.1 / Xcode 27.1 / Swift 6.4, arm64. **79 tests passed, zero failures or skips**; production app/host facade, three native surfaces, real helper load and ad-hoc package verification passed. Hosted idle CPU was **0.332% of one core**, slightly above the 0.3% target; RSS median/peak were **54.28/61.14 MiB**. The measured budget miss remains recorded, and real-player and release qualification still require the actual environment.

## Start here

- [Current status and exact next step](STATUS.md): latest implementation, validation, remaining work and the small set of files to read next; no prior conversation retrieval is needed.
- [Complete product/design/source research](Research/2026-11-26/README_START_HERE.md): 54 archived deliverables, three high-fidelity directions, selected design, interaction specification, source pins and macOS acceptance cases.
- [Actual implementation architecture](Documentation/ARCHITECTURE.md): module boundaries, lifecycle and where earlier research was refined.
- [Native UI implementation](Documentation/UI_IMPLEMENTATION.md), [media implementation](Documentation/MEDIA_IMPLEMENTATION.md), [lyrics implementation](Documentation/LYRICS_IMPLEMENTATION_STATE.md).
- [Local-only Codex handoff](Documentation/LOCAL_ONLY_HANDOFF.md): the remaining physical environment and owner-controlled release work. Ordinary coding/compilation is not a handoff item.
- [Third-party notices](Documentation/THIRD_PARTY_NOTICES.md).

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

The default surface is a narrow, quiet lyric panel. Pointer dwell reveals the real artwork, title, transport and seek controls without changing the panel's reserved size or removing the lyrics. Settings, lyric version selection, source information, local import, timing adjustment and full lyrics are separate small native windows. Paused, instrumental, interlude, missing lyrics, inaccessible position, permission denial and no playback remain distinct states.

| Player | Implemented route | Runtime limitation to verify on the exact installed build |
|---|---|---|
| Apple Music | Process-targeted ScriptingBridge metadata, progress, artwork and commands | On-demand Automation consent, local/cloud tracks, seek/readback, sleep/wake |
| Spotify desktop | Process-targeted ScriptingBridge and bounded official artwork download | Ads, podcasts/unsupported media, Connect, remote-output position and controls |
| QQ Music | Isolated MediaRemote stream/snapshot helper | Actual source participation; global commands only while the intended source owns Now Playing; paused seek disabled |
| NetEase Music | Same isolated helper, independent adapter capability state | Actual client version's timestamp/capability behavior and current-source ownership |

An installed/running player is not sufficient evidence for every control. Capabilities are derived from the actual route and observations. Commands are sent once and checked against fresh state; a successful process exit is not reported as successful playback control.

LRCLIB lookup is real, user-enabled and local to the device; local imports work independently. LRC/enhanced LRC/LRCX, TTML, LRCLIB Lyricsfile and plain text normalize into one model with source provenance. Automatic matching rejects ambiguous recording versions and provides explicit candidates. Unknown content rights remain unknown. A Release optimization flag does not silently disable lookup or grant content rights.

Fresh unmeasured position anchors support ordinary line synchronization. Continuous word sweep additionally requires real token timestamps and a matching, evidence-backed position qualification; unknown precision never becomes zero. No physical qualification profile is bundled by this remote implementation. See `MEDIA_IMPLEMENTATION.md` for the exact evidence format.

## Desktop and future Nearpane integration

TileKit coordinates cooperating apps through short locked transactions and explicit withdrawal acknowledgements. A missing heartbeat never authorizes drawing over a still-visible window. Shared width is 176–224 points; right/top margins are 16 points; spacing is 10 points; a collapsed/idle LyricTile retains its 272-point slot.

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

