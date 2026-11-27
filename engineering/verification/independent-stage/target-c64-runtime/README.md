# Target c64: engine PASS, R4 input blocked at parent identity

**The exact target build and direct foreign-window engine checks pass. The formal R4 product path remains BLOCKED with zero actual inputs.** The acceptance helper refuses its direct-parent identity check before issuing AXPress. A separate read-only native path probe reproduces the underlying path-string identity defect: Foundation's `/tmp` path and the kernel's `/private/tmp` path identify the same file, while their raw strings compare unequal.

Primary revision: `c64bf6d587247e512fb72c50a666d8e41c539e04`, original PR #16 branch. Target receipts report kernel build **26A428**, **SIP enabled**, and `exactTarget=true`. These target results are separate from the cloud `26A434` lanes. The runtime took place on **2026-11-27 UTC**; the `20261128` directory suffix does not replace the recorded UTC timestamps.

## Build and focused source verification

[The build receipt](build/result.json) verifies a clean checkout, fast-forward to the exact revision, and the candidate's executable/helper hashes. Actual results are:

| Step | Result | Duration |
| --- | --- | ---: |
| Full release build | Exit 0 | 263.914413 s |
| Candidate package | Exit 0 | 2.577886 s |
| Strict/deep bundle signature verification | Exit 0 | 0.065913 s |
| NativeSidebarNavigationTests build and run | Exit 0 | 168.825104 s |

The target test scope is **NativeSidebarNavigationTests: 26 tests, zero failures/errors/skips**, including the five new activity lifecycle tests. [The original XML](build/navigation-tests.xml) records test execution of 0.204132125 seconds; [the original log](build/navigation-tests.log) includes the build and tests. These are focused state tests, not the complete cloud Swift/Rust suite or a successful target R4 transition.

## Target runtime outcomes

[The trial receipt](trial/result.json) records runtime start `17:05:55.097802Z`, terminal context `17:07:00.433858Z`, and acceptance runtime duration **63.977198 s**. The runtime exits 1 and the wrapper status remains `UNKNOWN` because the product input was blocked. The engine and product scopes must be read separately.

### Direct engine: actual counts and physical evidence

[The engine result](runtime/engine-result.json) is **`FOREIGN_ENGINE_PASS / verified`**, with cleanup=true, three enrolled fixture windows, and all **10 summary checks PASS**. It records **26 hide/restore request attempts**. [The original engine log](runtime/engine.log) independently contains **34 operation receipts**, all `status=0` and `verified=true`:

| Operation | Numeric operation | Receipts |
| --- | ---: | ---: |
| Launch canary | 8 | 1 |
| Initial readback | 2 | 6 |
| HIDE | 3 | 12 |
| RESTORE | 5 | 12 |
| HIDE_MINIMIZED | 14 | 2 |
| Release owned Spaces | 13 | 1 |

The 12 HIDE, 12 RESTORE and two HIDE_MINIMIZED receipts account for the 26 write-request attempts; all 26 report verified results. The log also has **68 successful independent-readback events**, each with two observations, for **136 recorded observations**. Low-level native move syscalls are not individually counted by these artifacts, so 26 is not presented as a syscall count.

The checks cover initial retained visible bindings, launch canary, first yellow-button handling, a foreign-window round trip, same-app independence, a cross-app group, repeated switching, later yellow-button handling, fixture-owned exact focus restoration, and cleanup. These checks invoke the candidate engine directly. They do not constitute production R4 input or acceptance.

### Product: ready fixtures, zero issued inputs

The [fixture-scoped product result](runtime/product/product-result.fixture-scope.json) records `BLOCKED / realExternalR4ButtonNotAccepted`, **`actualR4Inputs=0`**, and `dispatchAttempted=false`. The last readiness snapshot has three distinct fixture groups, complete/fresh catalog, visible R4 panel, ordinary desktop 4, native Stage Manager off, `permitsStageEngine=true`, and `windowDispatchEligible=true`.

[The original external-input result](runtime/product/r4-press-efd555bb-7e35-4874-a72c-2e035b41dc19.result.json) is more precise about the boundary: **`UNKNOWN / directAcceptanceParentUnconfirmed`, `issued=false`, `axError=-25200`, process exit 2**. Request discovery and fixture readiness do not count as a click. This trial cannot establish thumbnail-to-HIDE/SHOW timing, navigation activity coverage, or product focus switching because no formal R4 input was issued.

Sampling was disabled by request. All four Host sampler metadata files record `NOT_RUN / diagnosticsDisabled`. Their status does not imply an observed click or a completed action.

## Read-only reproduction of the parent-path defect

[The native probe result](trial/r4-path-probe.json) and [its original source](trial/r4-path-probe.m) record the same executable through three observations:

| Observation | Path string | Device | Inode |
| --- | --- | ---: | ---: |
| Foundation | `/tmp/nearpane-c64-target-trial/r4-path-probe` | 16777233 | 311133345 |
| Invocation | `/tmp/nearpane-c64-target-trial/r4-path-probe` | 16777233 | 311133345 |
| Kernel `proc_pidpath` | `/private/tmp/nearpane-c64-target-trial/r4-path-probe` | 16777233 | 311133345 |

All three `stat` operations succeed, report regular files, and resolve to the same real path. Nevertheless, `rawStringMatchesFoundation=0`. This reproduces a false file-identity rejection by raw path-string equality on the target and explains the specific pre-input boundary that requires correction. The probe itself performs no window operation and is not a rerun of the blocked R4 action.

### Later comparator selftest: separate source scope

Three additional originals record a subsequent **read-only C file-identity comparator selftest**. They are associated with exact source-file hashes, rather than attributed to the immutable c64 source tree:

| Source file | SHA-256 |
| --- | --- |
| `r4-file-identity.h` | `8e0a2fd88ab38f60903e0d77ce0257029d2135c8f8402f0ae3ef95f75288bd40` |
| `r4-file-identity-selftest.c` | `8321aba6e0239312206aafee812c47e507270dbce657a0fd0d773cced5b62efa` |

[The original selftest result](trial/r4-file-identity-result.json) records native strict compilation exit 0, execution exit 0, **13 passed / zero failed / zero window writes**, and total duration **0.609313 s**. [The standalone selftest output](trial/r4-file-identity-selftest.log) preserves the same counts. This verifies the comparator test cases; it does not change c64's zero-input product result into a PASS or establish the later production helper's end-to-end behavior.

## Cleanup and preserved target context

The direct-engine cleanup record confirms release/destruction and two successful physical observations of all three fixture windows at original home 4, with original Space inventory restored. The product separately records shutdown `released=true` after **1.872208 ms**, `cleanup=true`, and **two successful physical return observations** at home 4 with preserved frames. Both fixture `ownedWindowQuit` commands exit 0 in [the original cleanup receipt](runtime/fixture-cleanup.json).

The before/after trial receipts confirm the original ordinary desktop 4, original foreground process identity, and preference values remain the same. `foregroundRestoreRequested=false`, `preferenceWrites=0`, `desktopNavigationInputs=0`; hardware input counters are unchanged and `newHardwareInput=false`. The engine's fixture focus preparations and controlled AX operations remain explicitly recorded in its own scope. Successful cleanup of a zero-input product trial is not a completed R4 hide/restore chain.

## Raw originals, fixture-scoped derivatives and exact provenance

[provenance.json](provenance.json) inventories **35 source originals**: the initial 32 build/runtime/probe files, plus the three later comparator-selftest files. Every original was independently checked against its exported byte count and SHA-256 before this directory was written. **33 files are copied byte-for-byte. Two JSON files are intentionally published only as named fixture-scoped derivatives**:

| Original document | Published derivative | Changed arrays |
| --- | --- | --- |
| `runtime/summary.json` | [summary.fixture-scope.json](runtime/summary.fixture-scope.json) | `/productReceipt/lastObservedReadiness/roster`, `/productReceipt/lastReadiness/roster` |
| `runtime/product/product-result.json` | [product-result.fixture-scope.json](runtime/product/product-result.fixture-scope.json) | `/lastObservedReadiness/roster`, `/lastReadiness/roster` |

The fixture PID set is taken from the original `runtime/config.json` at **`fixtures[*].pid`**: 83088 and 83094. Each of the four listed arrays originally has 19 entries; each derivative retains the same three fixture entries in the same order and removes the other 16 entries. This is 64 removed entry occurrences across four arrays, including repeated snapshots, not a claim of 64 distinct windows.

Every JSON value outside those four arrays is unchanged. In particular, original `windowCount=19` and readiness/completeness/eligibility fields remain original observations; the shorter published array must not be interpreted as a complete desktop inventory. Reconstruction of just the original arrays verifies semantic equality of every other field. The provenance records each original remote path/hash/size, each derived hash/size, exact JSON pointers, and removal counts, without publishing removed entries.

The two complete unfiltered JSON originals and the export payload remain in the original target paths and the current scratch export. They are not included in this public evidence directory. No screenshots or user-window content are included. The original export and its manifest are hash-identified in the provenance, rather than confused with derived public documents.

## Remaining acceptance boundary

The target engine mechanism is demonstrated under this exact target environment. The next product gate is to run the corrected, fully identified acceptance helper and obtain a real external R4 input, then prove actual sibling hiding, selected-window restoration and exact focus through the unchanged product readback requirements. The comparator selftest and the c64 source tests do not substitute for that run. Cloud scheduling failures and this target pre-input identity defect remain separate evidence tracks.
