# Target 6d05: build passed; runtime admitted a locked session

**The exact target release builds and signs, but this runtime is blocked before any R4 input. Both before/after context receipts explicitly record `session.screenLocked=true`.** The wrapper admitted that locked session; these results do not establish a regression in R4 switching or the new ownership-poll scheduling.

Revision: `6d05807917e54b57f462e7882e34300e55cde3b4`, original PR #16 branch. The target records kernel build **26A428**, SIP enabled and `exactTarget=true`. This directory remains separate from cloud fast/full results.

## Exact build

[The original build receipt](source-build/result.json) confirms the exact source revision and a clean checkout, then records:

| Step | Result | Duration |
| --- | --- | ---: |
| Full release build | Exit 0 | 258.850068 s |
| Package | Exit 0 | 2.524876 s |
| Strict/deep signature verification | Exit 0 | 0.269442 s |

Build receipts include candidate executable/helper hashes. This target build does not record a new unit-test suite, so cloud source-test counts are not attributed to it.

## Locked session and wrapper gap

[Context before](trial/context-before.json) and [context after](trial/context-after.json) both contain:

```json
{"loginDone": true, "onConsole": true, "screenLocked": true, "userID": 501}
```

The current Space is ordinary desktop **4**, and hardware secure-input/pressed flags are false. Those other observations do not establish an unlocked, interactive session. [The trial receipt](trial/result.json) nevertheless records `runtimeStarted=true`; the wrapper did not reject the explicit locked-session condition before starting fixtures and runtime. The previously recorded 60cf target contexts did not contain the `screenLocked` key, so its new explicit true value must not be ignored or replaced by a default.

This archive does not contain an unlock attempt or a successful subsequent unlocked rerun. The next target trial needs a naturally unlocked session and a preflight that rejects an explicit locked state before fixture/runtime startup.

## Actual runtime outcomes

The wrapper starts at `2026-11-27T18:00:37.244127Z`, records **43.925628 s** of runtime, and finishes context verification at `18:01:22.309060Z`. Runtime exit is 1; the wrapper status is `UNKNOWN` and cleanup is confirmed.

| Scope | Original result | Actual work |
| --- | --- | --- |
| Direct engine | `BLOCKED / controlledFixtureFocusUnavailable` | One fixture focus command; `setupAXWrites=0`, `windowWrites=0`; no hide/restore request |
| Formal R4 product | `BLOCKED / fixtureGroupsNotReady` | `actualR4Inputs=0`, `dispatchAttempted=false`; no click or completed switch |
| Product feed/readiness | `snapshotAvailable=false` | Zero fixture groups; target ordinary/group lifetimes unavailable |

The [original engine result](runtime/engine-result.json) reports no engine operation pass; its cleanup check is PASS and other functional checks are NOT_RUN. The [original product result](runtime/product/product-result.json) records an opened R4 overview but no usable snapshot or fixture groups. It has no `lastObservedReadiness` or readiness roster. `lastReadiness` itself records accessibility trusted, panel visible and the missing snapshot; these partial flags do not supersede the explicit locked-session observation.

This run supplies no press-to-hide/restore/focus latency. The absence of product input and engine writes must remain distinct from an actual switching failure on an interactive desktop. Sampling was explicitly disabled; all four original sampler metadata files say `NOT_RUN / diagnosticsDisabled`.

## Cleanup and unchanged target context

The engine reports cleanup=true. The product reports `released=true`, a **1.727042 ms** shutdown, and two physical observations confirming all three enrolled fixture windows visible at original home **4**, with preserved frames. [Both fixture quit commands](runtime/fixture-cleanup.json) exit 0. These observations confirm cleanup of an unmoved fixture set; they do not prove an R4 HIDE→SHOW round trip.

The wrapper records `cleanupConfirmed=true`, `newHardwareInput=false`, `preferenceWrites=0` and `desktopNavigationInputs=0`. Hardware counters are unchanged. The original front-process PID/birth, ordinary desktop 4 and all recorded preference values are preserved. `foregroundRestoreRequested=false`; no restoration activation is reported.

## Originals and provenance

[provenance.json](provenance.json) inventories **24 original files / 98,243 bytes**, with each original remote path and independently checked SHA-256. All 24 are copied byte-for-byte. The export manifest and transport hashes are also recorded; the transport payload itself is not copied into git.

Both potentially sensitive readiness documents were recursively checked for a `roster` key and contain none. Consequently this run needs **no fixture-scope derivatives**; no synthetic filtering or extra fields have been added. Other target trials that do contain broader rosters remain separately scoped in their own archives. Build records use `source-build/` to avoid the repository's generic `build/` ignore rule. No screenshots or binaries are included.
