# Lyrics Core / Services checkpoint

2026-11-26 — implementation checkpoint, not a macOS player certification.

## Implemented

- Shared process monotonic clock; anchored pause/seek projection; runtime clock health and independent word-accuracy evidence separated.
- Compiled overlap-aware timeline indexes: no per-frame sorting or full token scan; authored ends remain separate from display holds.
- Recording/artist/version/duration checks, no old inverted LyricsKit score.
- LRC, multiple timestamps, enhanced LRC, LRCX translation/word boundaries/annotations, restricted Apple/AMLL TTML, strict versioned Lyricsfile YAML, plain text, decoded QRC/YRC.
- Real LRCLIB HTTPS provider: identifiable client, optional public app ID, serialized transfers, bounded data, 429/503 cooldown, Retry-After plus jitter, strict draft → LRC → plain fallback. No cookies or server secret embedded.
- Repository: local binding priority, bounded automatic cache, negative-cache distinction, version selection, source provenance, raw payload, recording+document-specific signed offset, generation rejection.
- Parser, clock, matching, provider, cancellation-generation, offline, persistence/clear/eviction and request-concurrency tests use only original test text and injected transports. They are not actual player acceptance evidence.

## Validation status

Local Linux workspace has no Swift compiler. Hosted macOS compilation/test is owned by root; do not mark these tests passed until the CI results are recorded. No real player/TCC/clock-accuracy certification is inferred from injected transports.

## Stable API additions

`LyricRepository.searchCandidates(for:) async throws -> [LyricDomain.Candidate]` enables a real version picker even with an existing local binding. `sourceDescriptor()` exposes actual rights/provenance status. Injectable `LRCLIBProvider`, HTTP transport and bounded cache policy preserve the frozen default initializer call.

## Distribution boundary

`onlineEnabled` governs actual requests in Debug and optimized candidate builds. LRCLIB API access is documented; content rights remain `.unresolved`, and provider release disposition is `.internalResearch` until public release review records the applicable basis. Optimization level is not an authorization policy. No third-party lyric library is bundled or redistributed. This branch is a candidate evaluation implementation, not a claim that the complete corpus is licensed.

## Yams / CYaml provenance and notices

Yams is pinned to **6.2.2**, commit `a27b21e0c81c5bf42049b897a62aaf387e80f279` (MIT, Copyright © 2016 JP Simard). Its SwiftPM `CYaml` target bundles modified libyaml sources, not a separately versioned dynamic system library. The CYaml headers do not expose a trustworthy standalone release number; history was checked instead of calling it an unmodified latest libyaml.

- Yams update `409e565756cfdf50642a59c8f4290a6961fe7f1d` explicitly imports upstream libyaml through [`acd6f6f014c25e46363e718381e0b35205df2d83`](https://github.com/yaml/libyaml/tree/acd6f6f014c25e46363e718381e0b35205df2d83). That commit's `configure.ac` defines the **0.2.5** baseline.
- Yams security update `c7a3398466895c46c875966fc9da6ad11619bce6` names three later upstream patches: `51843fe48257c6b7b6e70cdec1db634f64a40818` (nesting-depth limit), `588eabff23ba2292f537872bbea5b64bce1e1a21`, and `840b65c40675e2d06bf40405ad3f12dec7f35923` (flow-sequence fixes). Yams also retains its own integration changes, most recently C++ header placement in `ac4f4d41e74f06990798c7c6115fc767ab425bfc`.
- `Packaging/Notices/libyaml-LICENSE` is the **complete verbatim License file from pinned patch commit `51843fe48257c6b7b6e70cdec1db634f64a40818`**, with Copyright © 2017–2020 Ingy döt Net and © 2006–2016 Kirill Simonov. `git diff acd6f6f 51843fe -- License` is empty: the imported baseline and later patch carry the same text. [Pinned license source](https://github.com/yaml/libyaml/blob/51843fe48257c6b7b6e70cdec1db634f64a40818/License).

Core/Services are original Swift implementations of published data-format behavior. They do not copy GPL/AGPL/MPL parser/provider code. Yams and its embedded libyaml are the only third-party lyric-module code dependencies requiring inclusion of license notices.
