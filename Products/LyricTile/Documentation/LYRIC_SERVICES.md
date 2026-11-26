# LyricCore / LyricServices implementation notes

The public entry points are `PlaybackClock`, `LyricMatcher`, `LyricTimeline` in LyricCore, and `LyricParser`, `LRCLIBProvider`, `LyricRepository` in LyricServices. The frozen Domain value types remain the shared vocabulary. SwiftUI/AppKit, player observation, audio playback and window coordination do not enter either module.

## Real time, unknown time, and rendering

`PlaybackClock.now()` uses process uptime and a process-local clock UUID. An anchor cannot be projected using a different clock domain or a timestamp before its observation. Playing projection is anchor + elapsed × rate, capped at known track duration. A seek uses a new anchor, retaining recording generation. Paused/buffering/stopped state does not integrate elapsed time. A playing anchor older than 15 seconds stops projecting; media health reads must refresh it independently of stream event density.

Fresh `coarseSourceAnchor` and `verifiedSourceAnchor` allow line synchronization without requiring a per-version allowlist. A nil expected error is **unknown**, not zero. Word mode requires genuine parsed token times plus a verified anchor with measured/qualified expected error at most 250 ms. These runtime rules do not replace the separate release P95 evaluation.

`lookupMS = mediaMS + sourceAdvanceMS + userAdvanceMS`; positive advance shows lyrics earlier. User adjustment applies only to the same recording fingerprint and content hash. Unresolved Lyricsfile offset remains in provenance but is not guessed. A source end is never filled using the next cue; the compiled timeline index has a separate display hold. Explicit overlaps remain simultaneous. Start-only words activate discretely; UI must not derive a continuous word-duration mask from the display hold. Layout/rendering can read immutable document tokens plus `Frame.lookupMS` for genuinely timed masks.

Timeline indexes are cached for at most two immutable document IDs/hashes. Binary search and prefix interval bounds select overlapping active cues/tokens without per-frame sorting or scanning every token. No network, filesystem, or Core Text work is performed by projection.

## Parser profiles

| Format | Implemented profile and intentional boundary |
|---|---|
| LRC | `[mm:ss.fraction]`, hours variant, multiple timestamps, signed integer offset. Cue ends stay unknown. Untimed metadata is not converted to invented timing. |
| Enhanced LRC | Explicit angle-bracket word starts; a final empty timed marker may close the last word/line. Intermediate starts do not imply authored word ends. |
| LRCX | Translation and language tags, UTF-16 word-boundary attachment, linked romanization/ruby text. Ruby attachment ranges are validated; the current shared domain presents the annotation lane rather than claiming per-glyph ruby placement. |
| TTML Apple/AMLL | Real namespace-aware XMLParser tree; media-absolute p/span clock, decimal seconds, s/ms/m/h, explicit duration/end, inherited language/agent, translation/background/romanization lanes. No layout engine, frames/ticks, clock/wall time or sequential containers. Generic TTML with incompatible inherited timing must be rejected rather than relabeled as a successful Apple profile. |
| Lyricsfile | Exact string version `1.0`, required track metadata, native line/word times, optional real end, independent plain fallback, explicit instrumental. Yams parses the YAML; the bounded safety pass and tree validation reject duplicates, tags, anchors/aliases and unsupported scalar types. Quote literal alias-like tokens in plain values; block/quoted text remains data. |
| QRC/YRC | Already-decoded text, absolute word start/duration. QRC's XML `LyricContent` envelope is accepted with entity resolution disabled. There is no decryption or private-player-cache reader. |
| Plain text | Preserves lines and text, contains no timing, never auto-scrolls as synchronized lyrics. |

All input is UTF-8 and at most 2 MiB; depth 32, cues 10,000, tokens 100,000. Repeated LRC timestamps are checked **before expansion**. UTF-16 ranges must refer to complete graphemes and the exact cue substring; ranges cannot split surrogate pairs or joined emoji. Source time must be nonnegative and end cannot precede start. Unsupported timing is an error, never zero. Parser source text is hashed with SHA-256; normalization for matching never replaces displayed text.

## Network and storage

LRCLIB has no bundled secret. Every request includes app name/version/project URL; a public `Lrclib-App-Id` may be injected. Default endpoints are HTTPS on `lrclib.net`. Responses are streamed with an 8 MiB limit, cookies/cache disabled, request/resource timeouts, and explicit status/content-type validation. One request permit is held across network awaits, preventing actor reentrancy from causing concurrent transfers. A 350 ms gap is the default. 429/503 stores a monotonic cooldown from Retry-After plus jitter; the UI receives an error instead of a hidden rapid retry loop.

Repository resolution prefers user binding, valid cache, known LRCLIB record ID, exact metadata lookup, one bounded search, then user selection. Search returns up to 40 records. Two equally acceptable search records require user choice. Provider `hasWordSync` is only an advertised candidate capability; the actual parsed document determines line/token rendering. Invalid/unsupported Lyricsfile falls back to genuine synced LRC, then genuine plain text.

`searchCandidates(for:)` deliberately bypasses binding and cache preference for the normal-playback version picker. All asynchronous publications validate player session and generation. After online lookup is disabled, another network stage and result publication are blocked. The original already-sent request may finish; no new lookup is authorized by that completion.

Storage semantics and bounds are in ADR-002. `clearCache` preserves bindings/imports and offsets. Raw imports are copied into private storage; original filesystem paths are not written to provenance or logs. No lyric body, cookie, listening history or import path is logged by this module.

## Rights and candidate distribution

The default LRCLIB descriptor records the documented public API access and unresolved content rights separately. Candidate/optimized build settings do not silently disable the product's core networking; the explicit online preference controls access. No library of third-party lyrics ships inside the application, and no local cache is uploaded or redistributed. A stable public release must record its provider-content review separately; neither HTTP 200, an app ID, user consent nor Yams' MIT license supplies a blanket lyric copyright grant.

Official API reference: <https://lrclib.net/docs.txt>. Fixed Lyricsfile specification: <https://github.com/tranxuanthang/lyricsfile/blob/348cd04b9d002fac8f5f67694064605026f9d030/SPECIFICATION.md>. Code dependency provenance is recorded in `LYRICS_IMPLEMENTATION_STATE.md` and package notices.
