# LyricTile implementation state

User authorized all feasible development on 2026-11-26. Repository: `haohongfei2001-png/nearpane`; branch: `codex/lyrictile-standalone-20261126`; base: Nearpane native head `6ac5eb63c97b7597e662770bac485be61f571bb8`.

The complete 54-file research/design handoff and implementation collaboration contract are committed at `7211d2ab3e6b0858af31f5e08d57624bbfbfb70a` under `Products/LyricTile/Research/2026-11-26`.

## Active implementation

- LyricCore/LyricServices: parser, matcher, monotonic timeline, LRCLIB, local persistence, recording bindings and offsets. Yams6.2.2 is pinned for YAML.
- LyricPlayback/CPlayerBridge: targeted Music/Spotify AppleEvents; isolated pinned BSD MediaRemote helper for QQ/NetEase; honest capabilities and command readback.
- LyricUI/App/Host: native fixed-frame glass panel, controls, states, preferences, import/candidates/offset/source, native reusable Host facade.
- TileKit/build/CI: root owns coordination, source integration, macOS/Xcode builds, package generation and remote delivery.

Do not treat in-progress source as compiled or released. Hosted CI and final evidence will update this file. Only physical macOS/player/TCC/real signing qualification belongs in the remaining local handoff.

## ADR-001: Runtime health and release certification are different

The research's strict fallback wording could incorrectly disable all synchronized lyrics on a new installation or after any player update. Runtime synchronization uses actual fresh source anchors, measured read latency/quantization and state consistency. A healthy coarse anchor may drive line synchronization without claiming independently measured P95 precision. Missing or stale position yields static lyrics. Token sweep still requires real token timings plus sufficient precision evidence. An exact OS/player certification record is release evidence, not an allowlist required for ordinary line display. Never fill unknown error with zero or invent source time.

Historical research remains unchanged for provenance. This ADR takes precedence for implementation of that distinction.
