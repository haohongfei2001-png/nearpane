# Independent implementation architecture

This document describes code actually present in this package. The immutable research archive explains the original alternatives; ADRs below take precedence where implementation exposed a simpler or more usable boundary.

## Package ownership

| Module | Responsibility | Must not own |
|---|---|---|
| `LyricCore` | Recording/session/generation identities; loss-aware lyric model; matcher; monotonic timeline; format and provider contracts | Windows, HTTP, Apple Events or fabricated player state |
| `LyricServices` | Bounded format parsing; LRCLIB; serialized HTTP; cache, recording bindings, user timing adjustments | A global player, UI clocks or redistribution of a lyric catalog |
| `CPlayerBridge` | Exception-safe Objective-C ScriptingBridge access to a specific running process | UI threading or launching a player during observation |
| `LyricPlayback` | Four source adapters, source selection, true anchors, capabilities, readback, helper lifetime, bounded artwork and diagnostic collection | Lyrics resolution, NSPanel ownership or source override workarounds |
| `TileKit` / `CTileLock` | Geometry, per-module lifetime lease, short registry transactions, native observation, withdraw/ack/commit | Shared media payloads, background daemon, AX moving foreign windows |
| `LyricUI` | Observable application model, SwiftUI panel/auxiliary views, CoreText glyph rendering, native panel shell | A second authoritative progress clock or a hidden demonstration mode |
| `LyricTileApp` | Menu-bar lifecycle, standalone presentation, coordination, update wiring, explicit CLI diagnostics and app termination | Nearpane's existing window engine |
| `NearpaneLyricsModule` | Direct native host facade and explicit ownership handoff | Launching/reparenting the independent app as its content |

Dependencies flow from the two shells down into reusable modules. `LyricPanelView` can be embedded without constructing `LyricPanelController`. Host and standalone share logic, not global singleton windows.

## Runtime data flow

1. A module acquires the `lyrics` lifetime file lock before starting media observation. Competing shells cannot both start the service.
2. PlaybackController observes real processes and selects a session. Source PID plus launch identity, track generation and anchor revision remain separate identities.
3. A new recording cancels prior lyric/candidate/artwork work. Optional late metadata does not manufacture a new recording. Every async completion checks the expected selection before publication.
4. LyricRepository tries explicit user binding/cache before public source lookup, normalizes returned data, and uses recording-aware matching. Ambiguous matches produce visible candidates.
5. LyricTimeline combines a real source anchor, monotonic elapsed time, documented format offset and recording/document-specific user advance. A positive advance displays text earlier. Missing/stale time remains unavailable.
6. UI schedules line-boundary updates and only renders word masks when real timing and precision permit. It stops frame work when occluded, paused or stopped. Transport waits for actual readback and preserves lyrics.
7. Window presentation is separately authorized by the current TileKit plan. Withdrawal is observed before a changed layout is committed; heartbeat age does not replace withdrawal proof.

## TileKit coordination and handoff

Registry state lives in the user's Application Support/HOLDSNOW directory, with an advisory lock inode that is never replaced. Data is atomically replaced under a short nonblocking lock. AppKit never blocks on a file lock; a small actor performs bounded registry transactions. A process start token prevents a recycled PID from inheriting a stale reservation.

The plan has an epoch, generation, committed placements, pending placements, a withdrawal set and acknowledgements. A moving old participant first stops presentation and withdraws. A matching acknowledgement plus observed WindowServer absence is necessary before the new placements are shown. Dead processes can be reclaimed only with process-identity evidence and absent windows. Corrupt state does not silently become an empty plan that overlays surviving apps.

The generic right-column geometry uses visible-frame points and persistent display UUIDs. Existing valid placement is retained on display reconnection; it does not jump back merely because a preferred display reappeared. Old Saytile/Riftlet windows are read-only obstacles, filtered by actual bundle/PID, layer, opacity and component-sized bounds. Full-screen capture masks are excluded. Unknown third-party applications are not managed.

Module handoff is separate from layout. Distributed notifications request a transition; they do not prove ownership. The old shell withdraws its view, stops media tasks/helpers and releases the lifetime lease. The new shell must acquire the lease itself before presenting. Nearpane provides the panel region and uses the in-process module directly.

## Refinements to the original research

- **ADR-001 — source health versus measured precision.** Healthy real anchors permit line synchronization. An unmeasured P95 stays nil. Word sweep can use a measured qualification profile, but no exact-version allowlist disables ordinary line display.
- **ADR-002 — bounded local store.** The first version uses an actor-owned, atomic JSON index plus content-addressed lyric documents rather than adding SQLite glue. Automatic cache size/count are bounded; bindings/imports and offsets are protected separately. See [the storage ADR](ADR-002-Lyric-Storage.md).
- **ADR-003 — build mode versus distribution authorization.** `Release` is compiler optimization. It does not certify content rights, disable real online lookup, publish a stable release or choose a fake data path. Source provenance records unresolved content rights; public distribution terms are reviewed independently.
- **ADR-004 — legacy interoperability.** Existing independent apps cannot be made protocol participants by this app alone. Read-only avoidance is implemented now; a small explicit adapter is the correct future migration, not an inferred permission to move their windows.
- **ADR-005 — updates.** Sparkle is pinned and genuinely linked. A candidate without a feed/public key states that fact. Owner-held signing credentials, real appcast signatures and publication are release configuration, not app functionality to simulate.
- **ADR-006 — actual parser provenance.** The research considered an isolated LyricsKit core fork. The shipping source inventory instead contains original Swift format implementations with explicit input, node, cue and token budgets, one normalized model, and authored format-boundary tests. No LyricsKit/MPL file is vendored or linked. This is a recorded implementation change, not a claim that translating upstream code removes its license. Reuse is concentrated in the pinned media adapter, Yams/libyaml and Sparkle; full provenance is in `THIRD_PARTY_NOTICES.md`.
- **ADR-007 — first online provider.** The candidate implements LRCLIB as its single remote lyric provider, together with local bindings, cache, candidate selection and file import. Lyricsfile → LRC → plain text is format fallback within that provider; it is not a second remote source. The optional AMLL exact-ID database and platform-specific lyric endpoints remain outside version 1.0's automatic lookup route. They require a concrete source/rights/availability decision before integration and are not assigned to local Codex as unfinished baseline functionality.

## Verification boundaries

Unit fixtures validate parsing, time arithmetic, race rejection, helper byte streams, transport decisions, image-decoding limits and layout barriers. Native CI compiles the real Objective-C/Swift bridge, builds the actual adapter/framework/app, loads the production empty/welcome/settings surfaces, and exercises normal application termination. A separate read-only helper probe loads the actual private framework and records its symbols and empty current-media response. Exact outcomes belong to the tested commit in [IMPLEMENTATION_STATE.md](IMPLEMENTATION_STATE.md).

Those checks do not certify installed QQ/NetEase behavior, TCC permission prompts, independent clock accuracy, display hot-plug on the user's monitor, eight-hour use, Developer ID acceptance or notarization. Native view bitmap captures establish content rendering, not WindowServer-composited glass contrast. These remaining qualifications need the actual environment and final signed package; scripts and case definitions are already included.
