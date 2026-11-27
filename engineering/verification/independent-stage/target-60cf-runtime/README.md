# Target 60cf: parent identity passed, panel verification blocked

**This exact target candidate builds and signs successfully, but the runtime remains incomplete: direct engine FAIL at later yellow-button handling; formal R4 BLOCKED before any actual input.** The product helper progresses beyond c64's direct-parent path rejection and now reports `panelIdentityOrVisibilityUnconfirmed`. Both engine and product cleanup are independently confirmed.

Revision: `60cf3219901c6997db400a1d08e143ddd011d0a0`, original PR #16 branch. Target environment is build **26A428**, **SIP enabled**, with `exactTarget=true`. This directory records the target run separately from cloud fast/full results. All recorded times below are from the original target receipts; the runtime-directory date suffix is not substituted for the UTC timestamps.

## Exact build and runtime

[The original build receipt](source-build/result.json) confirms a clean checkout and fast-forward from c64 to the exact revision. It records executable/helper hashes and these successful steps:

| Step | Result | Duration |
| --- | --- | ---: |
| Full release build | Exit 0 | 225.320788 s |
| Package | Exit 0 | 2.379347 s |
| Strict/deep signature verification | Exit 0 | 0.114390 s |

This target build receipt does not record a new target unit-test run. Source-suite counts from the cloud, or c64's earlier Navigation tests, are not attributed to this target trial.

[The original trial receipt](trial/result.json) starts at `2026-11-27T17:37:05.064401Z`, records runtime duration **58.964293 s**, and finishes context verification at `17:38:05.970903Z`. Runtime exit is 1; the wrapper reports `UNKNOWN` with cleanup confirmed.

## Direct engine: partial success followed by yellow-button failure

[The original engine result](runtime/engine-result.json) records **`FAIL / yellowButtonFailed`**, **25 hide/restore request attempts**, and `cleanup=true`. The ten summary checks contain **eight PASS, one FAIL and one NOT_RUN**:

| Check scope | Result |
| --- | --- |
| Launch canary, initial visible binding, first yellow button | PASS |
| Foreign round trip, same-app independence, cross-app group, repeated switching | PASS |
| Later yellow-button handling | FAIL |
| Focus restoration after the complete scenario | NOT_RUN |
| Cleanup | PASS |

[The original engine log](runtime/engine.log) contains **33 operation receipts**, of which **32 are verified with status 0**. It contains 12 HIDE requests, 11 RESTORE requests and two HIDE_MINIMIZED requests, totaling the 25 write attempts. **24 write requests have verified receipts; one does not.** The unverified receipt is:

| Field | Original value |
| --- | --- |
| Phase | `yellow-button-retire` |
| Operation | `14` (`HIDE_MINIMIZED`) |
| Status / detail | `2` (`UNKNOWN`) / `217` |
| Verified | false |
| Owned at receipt | 3 |
| Request duration | 1.337990 s |
| Native uptime | 798158.3406256667 |

The initial yellow-button retirement succeeds earlier; the later failed receipt must not erase that distinction. The logs also contain **66 successful independent-readback events**, each with two observations, totaling 132 recorded observations. These counts are operation and readback receipts, not a low-level native move-syscall count. The earlier passing target c64 run does not convert this later engine failure into a PASS.

## Formal product: zero inputs, later acceptance boundary

The [fixture-scoped product result](runtime/product/product-result.fixture-scope.json) is `BLOCKED / realExternalR4ButtonNotAccepted`, with **`actualR4Inputs=0`**, `dispatchAttempted=false` and cleanup=true. Its readiness snapshot records three distinct fixture groups, complete/fresh catalog, ordinary desktop 4, Stage Manager off, visible R4 panel, `permitsStageEngine=true` and `windowDispatchEligible=true`.

[The original external-input receipt](runtime/product/r4-press-17865219-5d87-492c-a169-b41253da23fc.result.json) records the precise blocker: **`UNKNOWN / panelIdentityOrVisibilityUnconfirmed`, `issued=false`, process exit 2**. It records `windowListRead=-25204`, an incomplete five-node AX traversal and zero matching buttons. Two node batch reads also return `-25204`. These are incomplete AX observations, not an issued AXPress.

The helper reaches this later panel-verification stage rather than stopping at c64's `directAcceptanceParentUnconfirmed` boundary. This is progress in the input helper's identity path, not product window-switch acceptance. With no actual input, this run establishes no press-to-HIDE/SHOW latency or production focus transition. The readiness snapshot cannot replace the later, failed live panel check.

Host sampling is `disabledByRequest`; all four sampler metadata files record `NOT_RUN / diagnosticsDisabled`. The product is blocked because of its actual input receipt, not because sampling is disabled.

## Cleanup and target context

The engine result reports cleanup=true. Its final cleanup record confirms engine release/destruction, two physical observations of all three fixtures at original home 4, and restoration of the original Space inventory. The product separately records `released=true`, a **2.501500 ms** shutdown and two successful physical return observations at home 4 with preserved frames. [Both fixture quit commands](runtime/fixture-cleanup.json) exit 0.

The wrapper records `foregroundRestoreRequested=true`; restoration is accepted, and the final front-process PID/birth matches the original. Original ordinary desktop 4 and preference values are preserved. `preferenceWrites=0`, `desktopNavigationInputs=0`; hardware counters are unchanged and `newHardwareInput=false`. These are the observed original receipts, not inferred from a successful process exit. Positive cleanup does not change either the engine failure or the zero-input product block.

## Public fixture scope and provenance

[provenance.json](provenance.json) inventories all **28 source originals**, including each original remote path, byte count and SHA-256. **26 files are copied byte-for-byte. The two documents with broader readiness rosters are published only as explicitly named derivatives:**

| Original | Public derivative | Filtered arrays |
| --- | --- | --- |
| `runtime/summary.json` | [summary.fixture-scope.json](runtime/summary.fixture-scope.json) | `/productReceipt/lastObservedReadiness/roster`, `/productReceipt/lastReadiness/roster` |
| `runtime/product/product-result.json` | [product-result.fixture-scope.json](runtime/product/product-result.fixture-scope.json) | `/lastObservedReadiness/roster`, `/lastReadiness/roster` |

The PID set comes from original `runtime/config.json` at `fixtures[*].pid`: **85676 and 85682**. Each of the four arrays has 20 original entries; the derivative retains the same three fixture entries in their original order and removes the other 17. Across four arrays, 68 entry occurrences are removed, including repeated snapshots; this is not a count of distinct user windows.

All other JSON values are unchanged, including `windowCount=20`, original readiness, eligibility and completeness fields. The published roster is consequently a fixture-scoped extract, not a complete inventory. Restoring only the original arrays reproduces the full original documents exactly at the JSON-value level. The manifest records the original and derived hashes, precise JSON pointers and removal counts without including removed entries. Complete unfiltered originals remain on the target and in the scratch export; they are not copied into this git directory.

Build records use `source-build/` so the repository's generic `build/` ignore rule cannot silently exclude them. No screenshots, binaries or user-window content are included.

## Remaining work

The next formal product gate requires a positively identified live R4 panel/button and an actual external input, followed by the unchanged physical hiding, restoration and exact-focus checks. The later yellow-button engine failure is a separate observed failure that needs its own diagnosis. Neither issue is resolved by the input-helper path comparison alone, and this directory claims no subsequent fix PASS.
