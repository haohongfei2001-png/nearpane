# Third-party code and content boundaries

This candidate is an independent HOLDSNOW product inside the Nearpane repository. Repository access is not a grant of rights to the product's brand or to third-party lyrics, recordings, artwork, or player services.

## Runtime dependencies

| Dependency | Pinned version / revision | Code license | How it is used |
|---|---|---|---|
| [Yams](https://github.com/jpsim/Yams/tree/6.2.2) | 6.2.2 / `a27b21e0c81c5bf42049b897a62aaf387e80f279` | MIT; includes its upstream notices | Strict parsing of LRCLIB Lyricsfile YAML; complete upstream license copied into the application bundle |
| [Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.1) | 2.10.1 / `ab7d71291238df6e0492143b120c9b696a35f603` | Sparkle permissive license and bundled third-party notices | Optional owner-configured signed HTTPS update channel; complete upstream license and framework notices preserved |
| [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter/tree/2ef957c736256cee7905c9f3f1c7e279087bf195) | v0.9.0 / `2ef957c736256cee7905c9f3f1c7e279087bf195` | BSD 3-Clause | Pinned source compiled locally as a framework, loaded by the upstream Perl helper in a separate process; LICENSE, SOURCE.json and source checksums are retained |

The complete Yams and Sparkle licenses are copied from the **resolved source checkouts**, not paraphrased here. Their binary notice files remain intact. The adapter's complete BSD license is in `Vendor/mediaremote-adapter/LICENSE`. The framework build script is HOLDSNOW integration code; it does not replace or relicense upstream source.

The implementation does not link LyricsX, LyricsKit, Lyrimuse, Lyrics-Plus, Lyric Fever, AMLL or amll-ttml-db. They are research references in the immutable `Research/2026-11-26` archive. No GPL/AGPL project code or third-party lyric database is bundled into this product. Parsers in this implementation are independently authored against the documented formats; review their source history before changing this statement.

## Online lyrics and artwork

The [LRCLIB API documentation](https://lrclib.net/docs) describes a public lyrics lookup API. Access to that API does **not** establish a blanket copyright license for every returned lyric. Source provenance and unresolved content rights remain attached to documents. Lookup is user-controllable, enabled by default, and disclosed on the welcome screen; private caching stays on-device. The candidate neither includes a lyric catalog nor uploads cached or imported lyrics. Public stable distribution must record the applicable provider/content terms separately from code-license review. A compiler's Release optimization setting does not constitute public distribution approval or silently disable lookup.

**Distribution review, 2026-11-26.** LRCLIB requires an identifying request header and permits unregistered client-side API access. LyricTile sends its name, version and project URL and keeps imported files and cached results on the device. The public reference gives no territory list, lyric-display license or work-specific attribution terms for the returned text. The upstream issue tracker still has an unanswered request about on-demand display, attribution and caching in a commercial app. The release record therefore lists these rights and territories as unconfirmed. The downloadable app contains no third-party lyric repertoire. [Official client requirements](https://lrclib.net/docs.txt) · [Upstream rights inquiry](https://github.com/tranxuanthang/lrclib/issues/134)


Player artwork is used for the current recording, bounded and privately cached. It is not exported as product marketing material. User-imported LRC, TTML, Lyricsfile and text remain local. The test fixtures contain authored neutral examples, not a copyrighted song catalog.

## Private platform API

MediaRemote is a private macOS framework and is isolated behind a replaceable adapter. This product's initial distribution route is Developer ID direct distribution, subject to actual signing/notarization and macOS/player tests. Notarization does not turn a private framework into a public or stable API, and this document does not claim Mac App Store eligibility.
