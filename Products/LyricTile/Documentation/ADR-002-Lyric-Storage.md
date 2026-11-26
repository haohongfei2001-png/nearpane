# ADR-002 — Bounded actor-owned lyric storage

Status: accepted for the first independent product; root approved this implementation adjustment on 2026-11-26.

The research proposed a SQLite index. The first implementation uses one actor-owned, atomic JSON index and immutable hash-named document envelopes. Each envelope contains the normalized document and, where available, original raw bytes/format. This removes an unnecessary database bridge while retaining identity, provenance, source timing and user-owned data semantics.

Automatic cache is capped at **64 MiB and 256 entries** by default; entries also expire after at most seven days as an operational retention choice. An explicit provider cache age or rights expiry can shorten retention; an absent rights cache age is not interpreted as permission for unlimited storage. LRCLIB parsed-record memory cache is also bounded. Another module owns artwork, so the product's total 200 MiB target still requires integration accounting.

Imported/user-bound documents live in a separate protected directory. Clearing or evicting automatic cache preserves them and their recording+content-hash offsets. An explicit binding may intentionally select a non-default lyric version. Recording fingerprints are never used as raw filenames. Index/document writes use Foundation atomic writes under a private local directory. This is single-owner storage: the Tile session lease prevents independent app and host from writing concurrently.

Only completed empty searches/404 absence receive short negative caching. Transport failures, 429, parser failure and disabled access do not become “no lyrics”. In-flight results must still match selected player session and generation. Clearing the cache changes an epoch so an older request cannot silently repopulate it.

At significantly larger collections, concurrent multi-owner access or transaction requirements, migrate the index to SQLite with a versioned importer. The public repository API and stored normalized document schema need not change. No such scale is required for the initial companion panel.
