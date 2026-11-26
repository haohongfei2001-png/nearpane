# LyricPlayback implementation and remaining physical qualification

This module contains real implementations, not demonstration playback data. The unit-test payloads are explicitly synthetic fixtures. A successful build or fixture test does not certify installed Apple Music, Spotify, QQ Music, NetEase Music, TCC, physical output latency, or macOS 27 compatibility.

## Routes and actual runtime behavior

| Player | Observation | Transport | Important boundary |
|---|---|---|---|
| Apple Music | PID-directed ScriptingBridge, bulk track properties, actual position/state, on-demand raw artwork | PID-directed play/pause/previous/next/position assignment | Automation permission required. No MusicKit SystemMusicPlayer claim. Subscription synchronized lyrics are not read through the scripting bridge. |
| Spotify desktop | PID-directed ScriptingBridge; duration **milliseconds**, position **seconds**; bounded official cover CDN request | PID-directed explicit commands and position assignment | No cookie, OAuth token or web playback API. Spotify Connect / ads must be physically qualified; unsupported actions fail or lose that recording's capability after failed readback. |
| QQ Music | Bundled MediaRemote helper, current-source stream and targeted snapshots | Enabled supportedCommands on the **current system media source**, followed by real readback | Targeted read is not targeted send. No global NowPlaying override. Paused seek is disabled, as some versions resume audio when seeking. |
| NetEase Music | Same isolated helper, per-application reads when another source owns Now Playing | Same current-source gate | Off-focus global transport/seek is disabled. Missing timing remains missing. |

Automatic selection only considers these four native applications. Browser media can revoke a global MediaRemote control route but never becomes the lyric source. A user pin does not grant background transport authority. Process IDs are paired with kernel process start times, including the selected MediaRemote helper process where applicable. Multiple indistinguishable instances/sessions fail closed.

No probe activates an application. Only the explicit `openPlayer` action may open/activate it. No `play` workaround is used to repair synchronization. Transport is sent once; the controller performs repeated reads, not repeated next/previous actions. “Readback confirmed” means the selected player's observed state matched the requested outcome. Global MediaRemote preflight and readback are not atomic with dispatch and cannot prove that a race caused absolutely zero effects elsewhere.

## Native bridge

`CPlayerBridge` links Foundation, AppKit and ScriptingBridge and is compiled with ARC. It caches only the two native scriptable applications, uses `SBApplication.applicationWithProcessIdentifier`, a 90-tick (1.5-second) Apple Event timeout, catches Objective-C exceptions, and exits a failed probe at the first delegate error. Each successful probe checks the track ID again after reading position to avoid joining old metadata with a new track's time. Error values distinguish Automation denial, timeout, process exit, unsupported command and mid-probe track transition.

Calls execute on a serial utility queue. There is no `osascript` process per position read and no per-frame Apple Event. The selected playing native app is normally calibrated once a second; paused selected apps every three seconds and unselected apps every five seconds. Distributed playback notifications request earlier refreshes. A TCC denial backs off for 15 seconds; source selection or playback notifications can recheck sooner.

## MediaRemote helper and package layout

The unmodified BSD-3-Clause source is fixed at `ungive/mediaremote-adapter@2ef957c736256cee7905c9f3f1c7e279087bf195` (v0.9.0). `Vendor/mediaremote-adapter/LICENSE`, `SOURCE.json` and `SHA256SUMS` identify the material. No GPL implementation has been copied.

Build on macOS with Xcode:

```sh
Scripts/build-media-helper.sh /absolute/output/MediaRemote arm64
```

The architecture can also be set with `LYRICTILE_ARCH`; the default is arm64. The script invokes `xcrun clang`, so CMake/Homebrew are not consumer or build prerequisites. Place the result at:

```text
LyricTile.app/Contents/Resources/MediaRemote/
  mediaremote-adapter.pl
  MediaRemoteAdapter.framework/
  LICENSE
  SOURCE.json
```

The build's ad-hoc signature is only for development. The distribution pipeline must replace it with Developer ID, sign the enclosing app, notarize and test the **same package**. The main application must have `NSAppleEventsUsageDescription` and the Hardened Runtime Apple Events entitlement. It does not require microphone, screen recording, Full Disk Access or Accessibility permission for these routes. App Sandbox / Mac App Store distribution is not the current route.

Debug builds can resolve a local helper directory using `LYRICTILE_MEDIA_HELPER=/absolute/path/MediaRemote`; the value is a directory containing the expected fixed filenames, not a command. Release builds ignore this environment variable and use their bundled resources. A missing helper produces an installation error, never synthetic Now Playing data. No Homebrew process or downloaded executable is launched at runtime.

The helper runs `/usr/bin/perl` with a minimal environment, stripping inherited `PERL5OPT`, `PERL5LIB` and `DYLD_*` variables. Only stream/get/send/seek are invoked. The upstream test executable is not built or shipped, and the application never invokes the upstream `test` action, which can create fake Now Playing information.

NDJSON full snapshots replace all state; diffs merge keys; JSON null removes keys. A diff before a full baseline is rejected. Streams omit artwork and use `--micros --no-artwork --allow-missing-title --debounce=80`. Metadata lines are limited to 512 KiB, artwork reads to 12 MiB base64 / 8 MiB decoded, stderr to 64 KiB. Stdout and stderr drain concurrently. Dropped stream chunks terminate the stream and require a new full baseline. Helpers time out, terminate, escalate to SIGKILL when necessary and are reaped. Stream reconnection backs off up to 30 seconds. All subprocesses are cancelled on stop/sleep.

Health snapshots occur at approximately six-second intervals, including targeted reads for off-focus music sessions. Lack of new stream events during stable playback is not itself failure. An observation older than 12 seconds is marked stale; the timeline's 15-second guard is an additional boundary. These intervals and process costs are implementation choices to measure with the real performance budget, not measured performance claims.

## Time, identity and artwork

Positions are normalized into Int64 milliseconds at the boundary. Adapter seek accepts **microseconds**; the `media-control` CLI, which is not shipped, accepts seconds. Overflow, negative values, NaN/infinity and missing values are rejected. An absent time is never represented by zero.

MediaRemote source elapsed/time pairs are rebased against a simultaneous wall/monotonic pair at the fresh read. A quiet source may legitimately repeat an old source anchor. A missing or implausible timestamp while playing yields no usable position. Pause freezes the actual elapsed value; sleep/wake invalidates in-flight observations and requires fresh reads. Source instances, track generations and seek anchors are distinct. Late optional metadata retains the generation and fingerprint; a new recording or restarted process changes it.

Ordinary runtime line synchronization uses fresh real anchors with `coarseSourceAnchor` and `expectedErrorMS=nil` when independent error is unknown. The word renderer receives a verified/error-bounded anchor only through the optional real-evidence profile below. Units such as microseconds do not certify source accuracy.

Artwork is fetched only for the selected recording and committed only if its session/generation still matches. Spotify requests require HTTPS and official Spotify CDN domains and are bounded to 8 MiB. The in-memory cache holds at most 16 MiB / 24 items. Missing artwork remains missing; it is not synthesized or replaced by an unrelated cover.

## Optional word-clock qualification

`PlaybackClockQualification.json` is optional. Search order is the user's `Application Support/HOLDSNOW/LyricTile` directory followed by app resources; the most recent matching record wins. At most 64 KiB / 32 records per file is read. Reload occurs when the controller starts. **No production qualification file has been created in this remote implementation.** An absent, invalid, expired or mismatched record keeps real line synchronization working.

The root object has `schemaVersion: 1` and `records`. Each record must contain every field below. This is a field specification, not a fabricated passing report.

| Field | Required value/evidence |
|---|---|
| player | appleMusic / spotify / qqMusic / netease |
| playerVersion, playerBuild | Actual CFBundleShortVersionString and CFBundleVersion, exact match; unknown rejected |
| systemBuild | Actual `kern.osversion`, exact match |
| adapterRevision | `holdsnow-appleevents-v1` for Apple/Spotify; pinned MediaRemote commit above for QQ/NetEase |
| dataOrigin | `real_player` |
| referenceKind | `independent_position_reference`; a second read from the same source is not sufficient |
| evidenceSHA256 | SHA-256 of the real report/trace manifest |
| measuredAt, expiresAt | ISO-8601 UTC dates; not future-dated, not expired, interval ≤90 days |
| sampleCount, recordingCount | At least 100 independent evaluable calibration points over at least 10 real sessions |
| referenceUncertaintyMS | Nonnegative independent-reference uncertainty upper bound |
| positionErrorP95MS | Observed absolute position error P95 **plus** reference uncertainty upper bound; >0 and ≤250 ms |

To generate this file on the real Mac: export the actual environment and source traces; collect independent audio/timecode/UI reference points as specified in `Research/2026-11-26/docs/MACOS27_ACCEPTANCE.md`; exclude insufficient-reference points and annotate their exclusion; compute the conservative P95 and sample/session coverage; hash the evidence manifest; fill the exact actual build/version/revision and expiry fields; encode the schema with these measured values. Do not insert placeholders, a synthetic test profile, zero uncertainty without evidence, or values inferred from timestamp units. Physical output-route delay and lyric authoring error remain separately recorded; the profile qualifies the measured position source, not universal acoustic alignment for every audio route or Spotify Connect session. Native bridge changes affecting timing must bump `holdsnow-appleevents-v1`.

## Local diagnostic export and testing

`await PlaybackController.diagnosticReport()` returns bounded JSON containing actual observed players, their versions/builds/process starts, current raw MediaRemote metadata (without artwork), source timestamps/units, runtime anchor health, and the last 64 control attempts. It is explicitly invoked and does not upload or persist anything by default. `readback_confirmed` is distinct from `dispatch_attempted_unconfirmed` and rejection before dispatch. Observed system owner before/after a command is useful evidence but cannot establish an absolute absence of a dispatch race.

Fixture tests cover unit conversion/overflow, NDJSON split UTF-8/full/null/restart behavior, explicit capability gating, source timestamp rebase, generation versus seek, process identity, global route refusal, stale/changed selection, readback outcomes, qualification expiry/build mismatch, cover URL scope, concurrent pipe draining and timeout reaping. Run them using the package's macOS Swift 6 test command. Hosted compilation and fixture test results must be recorded separately from the four installed-player acceptance runs. No installed-player success should be inferred from these tests.

## Bounded collection from the actual signed application

`PlaybackController.collectDiagnostics(player:seconds:outputDirectory:)` is a static async throwing API for the application's explicit `--diagnostics` branch. The normal GUI does not start it. A pinned collection reads only that selected player; it does not request Apple Events access to unrelated native players. It launches no music app and sends no transport operation. Use the same complete installed application bundle as the GUI, including its signed helper; verify the actual TCC attribution during the local installation test.

After the application's CLI integration is built, a 120-second QQ observation run can be launched through Launch Services using a new, explicit output directory:

```sh
open -n /Applications/LyricTile.app --args --diagnostics --player qqMusic --seconds 120 --output "$HOME/Desktop/LyricTile-QQ-R001"
```

`appleMusic`, `spotify` and `netease` select the other adapters. Direct execution of `LyricTile.app/Contents/MacOS/LyricTile` with the same arguments gives the CLI's success/error exit status, but the local test must confirm that macOS attributes Automation access to the intended signed application. Do not substitute an unsigned standalone probe when qualifying the release package.

The API accepts 1…3600 seconds and a local absolute directory that is absent or empty; it refuses overwriting logs. Newly created directories use mode 0700 and files 0600. The combined stream log limit is 128 MiB. It returns `DiagnosticCollectionResult` after the observation window and bounded cleanup, with actual counts, elapsed time and distinct recording identities. On cancellation it stops and reaps its helpers and finalizes available logs. A caller handling SIGINT/SIGTERM should cancel and await the task before exiting. If no real recording metadata was observed, logs are retained and the API throws `noRealPlayback`; an empty collection is not reported as successful playback support.

The output contains:

- `environment.json`: actual system build, running-player versions/builds/process starts, app identity/version/build, executable SHA-256 where available, SIP query result, requested duration and explicit missing package SHA when not supplied by packaging.
- `events.ndjson`: complete real snapshots with selection/generation, source-normalized time and monotonic stamps, a paired wall-clock microsecond stamp, runtime capabilities, permission/error state, and artwork byte count rather than cover bytes.
- `source.ndjson`: bounded raw/current source diagnostics in the same record order. A raw report is read immediately after the corresponding update; it can contain a later observation, so timestamps remain separate and must not be blindly joined as an atomic measurement.
- `summary.json`: snapshot count, snapshots with an actual recording, observed players, distinct recording identities, elapsed duration and whether the requested window completed. `independentReferenceProvided` is always false for this observer-only collector.

Use actual player controls and lifecycle operations while the capture runs to observe pause, seek, switching, browser media focus and recovery. This observer does not perform the transport test sequence on the user's behalf. One line is not one recording/session, and a 120-second capture is not 120 acceptance samples. Repeated source values and smoother projected positions are not independent timing reference points; no acoustic P95 or passing word qualification is computed by this command. Associate the logs with separately collected independent-reference evidence and the exact signed package hash before making a release qualification claim.
