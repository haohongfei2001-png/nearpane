# Implementation collaboration contract — 2026-11-26

User now authorizes complete development in Nearpane branch `codex/lyrictile-standalone-20261126`. This product is an independent Swift package and macOS application at `Products/LyricTile`. Historical research is immutable under `Research/2026-11-26`. Native compile/test must be attempted in hosted Xcode/macOS; only actual player/TCC/physical-desktop/signing qualification remains for the local Mac.

## Ownership

- lyrics agent: Sources/LyricCore, Sources/LyricServices, their Tests, service/parser documentation.
- media agent: Sources/LyricPlayback, Sources/CPlayerBridge if useful, Tests/LyricPlaybackTests, Vendor/mediaremote-adapter, Scripts/build-media-helper.sh, media documentation.
- UI agent: Sources/LyricUI, Sources/LyricTileApp, Sources/NearpaneLyricsModule, Resources UI assets/settings, UI documentation.
- root: Package.swift, Sources/TileKit, Tests/TileKitTests, packaging/CI, integration and repository delivery. Do not modify the Nearpane root package or existing engine.
- All code is Swift 6. Package compilation floor macOS14 is acceptable for reusable source; certification/distribution target is macOS27. No preview fixtures in production paths. Use existing LyricDomain types in LyricCore/Domain.swift; add APIs without breaking these shared names.

## Playback public API (media agent implements; UI consumes)

`PlayerID: String, CaseIterable, Codable, Sendable` cases `appleMusic`, `spotify`, `qqMusic`, `netease`; properties `bundleID: String`, `displayName: String`.

`TransportCapabilities: Sendable, Equatable` booleans `canPlay`, `canPause`, `canNext`, `canPrevious`, `canSeek`; public initializer with all default false.

`PlaybackSnapshot: Sendable` properties `player: PlayerID?`, `selection: LyricDomain.Selection?`, `anchor: LyricDomain.PlaybackAnchor?`, `state: LyricDomain.PlaybackState`, `capabilities: TransportCapabilities`, `artwork: Data?`, `statusMessage: String?`, `requiresAuthorization: Bool`. Static `.empty`. Public full initializer. Artwork is actual bytes from source only.

`TransportCommand: Sendable` cases `play`, `pause`, `next`, `previous`, `seek(milliseconds: Int64)`.

`public actor PlaybackController`: `init()`, `func updates() -> AsyncStream<PlaybackSnapshot>`, `func start(preferred: PlayerID? = nil) async`, `func stop() async`, `func select(_ player: PlayerID?) async`, `func perform(_ command: TransportCommand, expected: LyricDomain.Selection) async throws`, `func openPlayer(_ player: PlayerID) async`. Command return success requires real readback. No guessed timings or automatic play to fix drift. No arbitrary player activation on probe.

Use `ProcessInfo.processInfo.systemUptime` converted to nanoseconds plus shared `PlaybackClock.domainID` UUID when producing anchors and projecting UI frames. `PlaybackClock.now() -> LyricDomain.MonotonicStamp` is owned by LyricCore.

## Lyrics public API (lyrics agent implements; UI consumes)

`LyricParser: LyricDocumentParsing`, `LyricMatcher: LyricMatching`, `LyricTimeline: LyricTimelineProjecting`, all have public `init()`.

`LyricResolution: Sendable` cases `document(LyricDomain.Document)`, `candidates([LyricDomain.Candidate])`, `notFound`.

`public actor LyricRepository`: `init(storageURL: URL, onlineEnabled: Bool = true)`, `func setOnlineEnabled(_ enabled: Bool)`, `func resolve(_ selection: LyricDomain.Selection) async throws -> LyricResolution`, `func fetch(_ candidate: LyricDomain.Candidate) async throws -> LyricDomain.Document`, `func importLyrics(_ data: Data, format: LyricDomain.Format, for selection: LyricDomain.Selection) async throws -> LyricDomain.Document`, `func bind(_ document: LyricDomain.Document, to recording: LyricDomain.RecordingIdentity) async throws`, `func adjustment(for recording: LyricDomain.RecordingIdentity, document: LyricDomain.Document) async -> LyricDomain.UserTimingAdjustment?`, `func setAdvance(_ milliseconds: Int64, for recording: LyricDomain.RecordingIdentity, document: LyricDomain.Document) async throws`, `func clearCache() async throws`. Binding/imports survive automatic cache eviction.

Timeline projects existing protocol with nullable ends, real clock quality, noPlayback outside selection, unknown/stale -> static. Parser handles LRC, enhanced LRC, explicit TTML profile, plain and strict versioned Lyricsfile (mature YAML dependency allowed; tell root exact pin). Matching checks recording identity before richer animation.

## UI / Tile integration

`@MainActor public final class LyricAppModel: ObservableObject` owns the above controllers, state, settings and user actions. `public struct LyricPanelView: View { public init(model: LyricAppModel) }` is host-reusable and does not instantiate NSPanel. UI agent implements standalone `@main` AppKit lifecycle, fixed-size nonactivating panel, menu bar, onboarding, settings, correct-source controls, candidates/import/offset/full lyrics and bounded active-only refresh. Host facade exposes a pure view and start/stop lifecycle.

Root supplies `TileGeometry.standaloneWidth(visibleWidth: Double) -> Double` and `TileSessionLease(moduleID: String = "lyrics", directory: URL? = nil)` with `acquire() throws -> Bool`, `release()`. Session ownership is required before media start. Geometry coordination will attach in root integration; UI may initially use top/right16 and height272. No hover resize or key stealing.

Any needed API correction: message root/peer before changing names. Add meaningful tests for parser/clock/generation/route/state risks, not assertion counts. No git commits by agents; root commits cohesive checkpoints and runs CI.
