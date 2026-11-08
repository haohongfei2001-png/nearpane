# P1-B preparation: read-only Spaces observer

**Behavioral testing: NOT TESTED.** This is preparation for Nearpane issue #2, based on
`beb6471fe360004425760a024636e5a63dbe87d1`. No separate-Spaces off/on experiment is authorized
by this implementation or by the example commands below. This package is an isolated CLI
experiment; it is not linked into a Nearpane production target.

Read together with the [P1 gate review](../../docs/reviews/P1-TECHNICAL-GATE-REVIEW.md),
[existing baseline](../../engineering/P1-READONLY-BASELINE-20261109.md),
[operator checklist](PREFLIGHT-RESTORE.md), [format contract](SESSION-FORMAT.md), and
[comparison template](COMPARISON-TEMPLATE.md). The baseline probe path cited by the report
is absent from this checkout; this helper follows the three documented getter signatures,
without claiming to reproduce or supersede the baseline evidence.

## Build and synthetic validation

Build target: macOS 14+, Swift 6+ (Swift 5 language mode); no external package dependencies. Tests use
the toolchain's Swift Testing framework, so XCTest/full Xcode is unnecessary. Run from the repository root:

```sh
swift build --package-path experiments/p1-spaces-behavior --scratch-path /private/tmp/nearpane-p1b-build --disable-sandbox
swift test --package-path experiments/p1-spaces-behavior --scratch-path /private/tmp/nearpane-p1b-build --disable-sandbox --disable-xctest
/private/tmp/nearpane-p1b-build/debug/spaces-observer --help
/private/tmp/nearpane-p1b-build/debug/spaces-observer fixture --output /private/tmp/nearpane-p1b-fixture-NEW
python3 experiments/p1-spaces-behavior/scripts/verify-fixture.py --binary /private/tmp/nearpane-p1b-build/debug/spaces-observer --output /private/tmp/nearpane-p1b-integration-NEW
```

`--disable-sandbox` disables only SwiftPM's nested build sandbox, which otherwise conflicts
with the enclosing Codex execution sandbox. It neither changes macOS privacy permissions
nor grants the executable privileges. Build artifacts can remain in `/private/tmp`.

`fixture` uses invented display/window/Space identities and synthetic timestamps. It exercises
the same detector, writer and sanitizer as live mode, and never constructs the live sampler.
Running without arguments, or with `--help`, reads no desktop state. Tests do not change
Spaces, settings, windows, permissions, or capture pixels.
The minimum build target is not an OS compatibility claim. No live runtime is validated by these tests.

## Future read-only observation

Only the explicit `observe` subcommand reads desktop state. A future authorized observation
can use a **new**, canonical absolute directory on local, non-synced storage:

```sh
/private/tmp/nearpane-p1b-build/debug/spaces-observer observe \
  --output /private/tmp/nearpane-p1b-session-NEW \
  --samples 120 --interval-ms 500 --stable-count 3 --max-seconds 90
```

The parent must exist. The helper rejects existing directories, repository descendants,
symlinked paths, overwrites, group/world-accessible output, and hard-linked files. It creates
the session directory at `0700` and both files at `0600`, verifies permissions while writing,
uses exclusive/no-follow creation, and syncs each event. It does not repair or delete an
existing directory. Use `/private/tmp`, not the `/tmp` symlink, in these examples.

`raw.jsonl` contains sensitive runtime identifiers, PIDs, display names, geometry and
operator notes. Keep it local/private. Titles and application names are never collected.
`sanitized.jsonl` is a whitelist projection: display UUIDs/IDs, managed scope identifiers,
Space IDs and window IDs become session aliases; display names are removed; PIDs, window
geometry and operator free text are omitted. Raw identity-bearing fingerprints become
per-session HMAC-SHA256 fingerprints with a random, unexported key. Neither identities nor
hashes should be correlated across processes, logout/login, or separate mode runs. Display
geometry, OS build, timestamps and observation relationships remain in the sanitized log;
inspect this reduced metadata before sharing it. Both files start private.

The combined log limit is 64 MiB. Hard CLI limits are 1,800 samples, 900 seconds and at least
250 ms between reads; defaults are 12 samples, 60 seconds, 500 ms, three identical samples.
The interval is an idle interval **after** a read, not a promised sampling frequency.
Markers are polled during idle time and on both sides of a read. No sleeps/retries/restarts
are used to recover a failed private call. A private API call itself cannot be preempted;
the duration limit prevents starting new reads, not a stuck WindowServer call. A crash,
signal, I/O error or log cap can leave an incomplete log, which must be retained as such.

## Observation and stability contract

- Public topology: active display IDs and UUIDs, AppKit names/frames/backing scale,
  CoreGraphics bounds/pixel dimensions/rotation/main/builtin/mirror relationships;
  `NSScreen.screensHaveSeparateSpaces`, OS version and `kern.osversion` build.
- Private inventory: only `SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, and
  `SLSCopySpacesForWindows`, using the baseline's `0x7` membership selector. The dynamic
  library handle lives through all calls. Each Copy return is consumed once using
  `takeRetainedValue`; inputs use explicit SInt32 CFNumbers. Private ABI, selector semantics,
  lifetime/leak validation and OS compatibility remain the separate **P1-A gate**.
- Window coverage: `CGWindowListCopyWindowInfo(.optionAll)` metadata in returned order;
  membership for layer-zero records with a valid ID. Nonzero/unknown layers are explicitly
  `notQueried`. Visibility is the optional reported `onscreen` flag, not inferred from
  membership. No Accessibility or screen-capture calls, including permission prompts.
- Reads are not atomic. Each sample brackets membership queries with topology/mode/inventory
  and window-list reads. A changed boundary or window list invalidates that sample.
  The original before state and the after boundary/window-list fingerprint remain in raw
  evidence. All transition samples are logged; none are silently filtered out.
- Stable means a run of repeated identical normalized states, excluding only time/revision.
  Topology/scopes sort by their identifiers; Space record order, window z-order and duplicate
  membership IDs are retained. Membership ordering alone is normalized. Default threshold
  is three consecutive matching samples. A changed state/mode/topology, operator marker,
  gap over three idle intervals, out-of-order timestamp/revision, or read over five seconds
  invalidates the previous stable revision. Inconsistent samples contribute zero to a run.
- Unknown scopes (including `Main`) are not mapped to a physical display by guesswork.
  Missing current Space, malformed records, NULL/empty/unavailable membership, unknown
  membership IDs and incomplete public metadata remain explicit. Repeated incomplete
  data becomes `stableIncomplete`, **never complete or behaviorally verified**.
- Matching brackets cannot exclude a change-and-return between reads, and three identical
  snapshots cannot prove animation completion, full window coverage or visible behavior.
  Window IDs/PIDs can be reused. All identities are short-lived observation handles;
  this helper never turns them into action targets or durable product identities.

## Operator markers

While a future observer is running, its stdin accepts JSON Lines, for example:

```json
{"kind":"beforeAction","action":"nativeSpaceChange","display":"A","trial":1}
{"kind":"afterAction","action":"visibleObservation","display":"both","trial":1,"note":"Operator-only visible result; private."}
{"kind":"stop","action":"none","display":"unspecified"}
```

The tool only records these statements; it cannot perform the named actions. Markers are
not authorization and do not certify that an action occurred. EOF is allowed for a bounded
noninteractive run. Invalid/overlong/partial lines become `markerRejected`, without logging
their contents. Every marker, including a rejected one, invalidates the stable run. If one
arrives during a sample, that sample is transient. `stop` ends polling and writes a footer;
the final in-progress sample, if any, is retained. Use the checklist before any actual actions.
