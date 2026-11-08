# Session JSONL v1

Each complete newline is one JSON object. `schemaVersion=1`, a random process/session UUID,
strictly increasing zero-based `sequence`, `receivedAt` (UTC RFC3339 with milliseconds),
`receivedUptimeNS` (monotonic process-host clock) and `kind` are present on every event.
Do not order samples by the wall clock; it can be adjusted. Match raw/sanitized lines using
sessionID + sequence. Never merge sessions using display/window/Space identifiers.

| kind | Payload | Meaning |
|---|---|---|
| `sessionStart` | `config` | Source (`synthetic_fixture` / `read_only_live`), sample/interval/stability/duration/byte limits |
| `sample` | `sample`, `assessment` | One bracketed read plus online stability assessment |
| `operatorMarker` | `marker` | An operator claim, not a tool action or verified observation |
| `markerRejected` | none | Invalid, oversize or incomplete stdin; content is discarded |
| `sessionEnd` | `endReason` | `fixture_complete`, `sample_limit`, `duration_limit`, or `operator_stop` |

A missing footer, missing sequence, differing raw/sanitized sequence coverage, or partial final
line means **INCOMPLETE**. Do not retry automatically, append another run, repair by dropping
failure records, or call the partial log a completed trial. Raw-first writes are not an atomic
transaction across two files; power loss can leave one extra raw event. Retain both files.

## Raw sample

`revision` is one-based; `startedAt`, `endedAt`, `startedUptimeNS`, `endedUptimeNS` bracket
the read. `state` contains `osVersion`, `osBuild`, `boundary` (separateSpaces, topology,
inventory), `windowListStatus` and `windows` (metadata + membership). `afterBoundary`,
`afterWindowFingerprint`, `afterWindowStatus` and `observerIssues` record consistency checks.
Missing optional fields are encoded by absence; never infer a current Space/window membership.

Inventory and topology `status`: `ok`, `unavailable`, `nullResult`, `malformed`.
Membership `status`: `known`, `empty`, `nullResult`, `unavailable`, `malformed`, `notQueried`.
Malformed membership retains only successfully decoded IDs, without promoting partial IDs to
known membership. Unknown inventory/current/membership identities remain unresolved. Raw type
values are uninterpreted integers. `notQueried` indicates excluded/unknown layer or coverage.

`assessment` contains:

- `stability`: `transient`, `stable`, or `stableIncomplete`;
- `identicalSamples`, `requiredSamples`, `candidateSinceRevision`, `latestStableRevision`;
- `topologyEpoch` (advances when the sampled before-topology fingerprint changes);
- `topologyFingerprint`, `stateFingerprint` (SHA-256 of sorted-key JSON, raw-only);
- `transitionReasons` and `incompleteness` (machine-readable fixed codes).

The first samples in a stable run remain `transient` in the append-only log. A later stable
record does not rewrite them. `latestStableRevision` is absent immediately after invalidation.
An intra-sample topology change invalidates the read even when the before-topology epoch is
unchanged; the next read establishes the new epoch if that topology persists.

## Marker input contract

Required fields: `kind`, `action`, `display`.

| Field | Allowed values |
|---|---|
| kind | `baseline`, `beforeAction`, `afterAction`, `restored`, `note`, `stop` |
| action | `none`, `nativeSpaceChange`, `settingChange`, `sessionRestart`, `restore`, `visibleObservation` |
| display | `A`, `B`, `both`, `unspecified` (operator roles, not detected identities) |
| trial | Optional integer 1–100 |
| reportedSeparateSpaces | Optional boolean, kept separate from the API reading |
| operatorTimestamp | Optional UTC/offset RFC3339 with fractional seconds; raw-only |
| note | Optional UTF-8 free text, at most 4,096 bytes; raw-only |

At most 8,192 bytes before each newline; overlong data is discarded until the next newline.
Trailing non-newline data at EOF is rejected. Receipt time is observer ingestion time, which
may lag an operator action by the duration of the current read. `operatorTimestamp` is an
unverified operator claim and is not used for stability. Record markers immediately before
and after future authorized actions; no automatic correlation of a marker with an API change.

## Sanitized projection

The sanitized log is separately serialized from an explicit field whitelist, not produced
by string replacements on raw JSON. It retains time/build, limits, state statuses, public
display geometry, anonymous scope/current/Space/window relationships and assessment codes.
It excludes original display UUIDs, numeric display IDs, names, Space IDs, window IDs, PIDs,
window geometry, notes, operator timestamps, after-boundary raw state and raw fingerprints.

Display/scope/Space/window aliases are unique within their namespaces and only within this
process. Unknown display matches are `UNKNOWN`, never a fabricated alias to a main display.
Fingerprint values use HMAC-SHA256 with an ephemeral per-session key; they detect equality
only within the session. The key and alias dictionaries are not written to the sanitized file.
The sanitized stream reports `NOT_ASSESSED_BY_OBSERVER` as the behavioral verdict; this
tool does not judge or establish shared/independent desktop semantics. Use the operator's
separate, evidence-linked comparison report. A synthetic fixture is always **NOT TESTED**.
