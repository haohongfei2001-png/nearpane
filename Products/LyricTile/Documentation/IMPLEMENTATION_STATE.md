# LyricTile implementation state

User authorized all feasible development on 2026-11-26. Repository: `haohongfei2001-png/nearpane`; branch: `codex/lyrictile-standalone-20261126`; base: Nearpane native head `6ac5eb63c97b7597e662770bac485be61f571bb8`.

The complete 54-file research/design handoff and implementation collaboration contract are committed at `7211d2ab3e6b0858af31f5e08d57624bbfbfb70a` under `Products/LyricTile/Research/2026-11-26`.

## Active implementation

- LyricCore/LyricServices: parser, matcher, monotonic timeline, LRCLIB, local persistence, recording bindings and offsets. Yams6.2.2 is pinned for YAML.
- LyricPlayback/CPlayerBridge: targeted Music/Spotify AppleEvents; isolated pinned BSD MediaRemote helper for QQ/NetEase; honest capabilities and command readback.
- LyricUI/App/Host: native fixed-frame glass panel, controls, states, preferences, import/candidates/offset/source, native reusable Host facade.
- TileKit/build/CI: root owns coordination, source integration, macOS/Xcode builds, package generation and remote delivery.

## Native verification checkpoint

Actual hosted environment: **macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Swift 6.4, arm64**. The exact observed tool output is retained in each run's artifact.

- `5bcf0ad541a45fe28d071054089b64f0e2947229` / [run 45742911197](https://github.com/haohongfei2001-png/nearpane/actions/runs/45742911197): first native compile found Dictionary.values property syntax; fixed.
- `5f0c32556ca948508bc5c2751fab01a0e026f544` / [run 45743865027](https://github.com/haohongfei2001-png/nearpane/actions/runs/45743865027): test expression mishandled optional Frame.selection; fixed with explicit unwrapping.
- `57fd7d1788c504be381b1f43d10f0536aa7f1646` / [run 45744413038](https://github.com/haohongfei2001-png/nearpane/actions/runs/45744413038): a new layout-authority test passed a throwing assertion into a nonthrowing UI callback; fixed in the test, preserving the production contract.
- `189e096b73de712f7da4614c967c2b973c98e569` / [run 45744887973](https://github.com/haohongfei2001-png/nearpane/actions/runs/45744887973): **the complete production app and NearpaneLyricsModule compiled successfully**. Test compilation exposed Swift Testing macro capture of mutating fixture methods; fixed by separating mutation and assertion. Optional `.none` warnings also exposed an actual plain-lyrics UI branch ambiguity, corrected explicitly.

Packaging, helper load, production window load, unit execution and hosted idle measurement are still pending this checkpoint; their final results will be appended. No four-player, acoustic, local macOS 27.0, eight-hour, signing or notarization pass is inferred from compilation. Only those physical/player/owner-credential qualifications belong in the local handoff.

## ADR-001: Runtime health and release certification are different

The research's strict fallback wording could incorrectly disable all synchronized lyrics on a new installation or after any player update. Runtime synchronization uses actual fresh source anchors, measured read latency/quantization and state consistency. A healthy coarse anchor may drive line synchronization without claiming independently measured P95 precision. Missing or stale position yields static lyrics. Token sweep still requires real token timings plus sufficient precision evidence. An exact OS/player certification record is release evidence, not an allowlist required for ordinary line display. Never fill unknown error with zero or invent source time.

Historical research remains unchanged for provenance. This ADR takes precedence for implementation of that distinction.
