# Target 60cf sampled diagnostic: real input, preparation rejected

**This diagnostic trial issues one real external R4 AXPress but confirms no selection.** Preparation rejects its first physical read after 563.380 ms, before any product witness/backend activation. The product remains `FAIL / R4SwitchReadbackFailed`; the separate direct engine again fails later yellow-button handling. All cleanup receipts and original target context are confirmed.

Revision `60cf3219901c6997db400a1d08e143ddd011d0a0`, target build **26A428**, **SIP enabled**, `exactTarget=true`. This is a **separate sampled trial**, not the preceding unsampled target run. [The trial receipt](trial/result.json) records start `2026-11-27T17:40:27.356462Z`, runtime **68.712511 s**, and final context verification at `17:41:37.550646Z`. Its wrapper remains `UNKNOWN`, runtime exit 1. The repeated [source-build receipt](source-build/result.json) identifies the same exact candidate; it does not represent another build or another unit-test run.

## Actual input and first failure

[The original external-input receipt](runtime/product/r4-press-f3fa7da9-af60-4a24-81fc-aba698b929a6.result.json) records **`issued=true`, `axError=0`**, for `current-desktop-window:85912:121955`, at native uptime **798371.127666375**. This is an external AXPress, not a claimed physical pointer gesture. The [fixture-scoped product result](runtime/product/product-result.fixture-scope.json) records **one actual R4 input and zero `R4SwitchConfirmed` events**.

The original [Host stderr](runtime/product.stderr.log) gives the following native sequence:

| Event | Recorded value |
| --- | --- |
| User activity begin | 798371.1515094584 |
| Navigation dequeue | 798371.1520422917; priority 25, `userActivity=true` |
| Preparation first-directory await | 508.944042 ms; result present |
| First physical read, window 121955 | 40.141083 ms |
| `stagePhysicalReadRejected` | 798371.7102532501; `step=final-continuity` |
| Preparation exit | 798371.7292758334; 563.379583 ms, completed=false |
| User activity end | 798371.7299856667; `completionHolds=0` |

The preparation exit still records `cancelled=false`, `epochMatches=true`, `appearanceMatches=true`; its step is `first-physical-read`. It does not reach a complete product witness or backend activation. The activity has one matched begin/end and ends with the rejected preparation, rather than remaining open until the later acceptance timeout.

The existing `final-continuity` label covers four checks. This artifact does **not** identify which failed. The accompanying diagnostic AX number-attribute error must not be promoted into the failed condition; a more specific cached guard result is required. The 40.141 ms physical-read await is measured, but it does not identify a particular underlying read, predicate or scheduling cause.

At the last switch read, all three fixtures remain visible on original home 4. Exact focus is false: expected PID/window are 85912/121955, while the foreground remains original PID 75829. A matching focused-window number queried in a background process is not a foreground-focus confirmation. No completed product HIDE/SHOW chain is demonstrated.

## Separate direct-engine outcome

[The original engine result](runtime/engine-result.json) is `FAIL / yellowButtonFailed`, with **25 hide/restore request attempts**, cleanup=true, **eight checks PASS, one FAIL, one NOT_RUN**. Initial yellow-button handling, foreign round trip, same-app/cross-app behavior and repeated switching pass; the later yellow-button check fails, and final focus-restoration checking is not run.

[The engine log](runtime/engine.log) contains **33 operation receipts**, 32 verified with status 0. The 25 write attempts comprise 12 HIDE, 11 RESTORE and two HIDE_MINIMIZED operations; **24 have verified receipts**. The unverified later `yellow-button-retire` receipt is operation 14, status 2/UNKNOWN, detail 217, `verified=false`, duration **1.120921 s**, at native uptime **798364.9194435**. There are 66 successful independent-readback events with two observations each. These are request/readback counts, not low-level move-syscall counts. The direct-engine failure and the later product preparation rejection are separate observations.

## Two physical samples, explicit sharing

Both original sample texts are retained:

- [Startup sample](runtime/product/host-startup-main-thread.sample.txt): 193,457 bytes.
- [Actual-action sample](runtime/product/host-main-thread.sample.txt): 196,495 bytes.

The press sampler and selection-preparation sampler refer to the **same** action sample, with `sharedWith=host-main-thread`. Their separate trigger metadata does not create a second physical action sample. The late read-queue sampler is `NOT_RUN / noObservedR4ReadQueueDelay`.

The main capture's progress markers are observed by the runner at monotonic **798371.570690875** and **798374.963614**; reaping is later at **798381.430093375**. Startup marker observations are **798368.245344375** and **798369.343978041**. These are runner observations of progress output, not exact native source timestamps; nominal sample duration or reaping cannot establish capture coverage of a specific source interval. Sampler metadata and stderr are preserved with both physical texts. This diagnostic run is not a controlled sampling A/B experiment with the preceding target trial.

## Cleanup and original environment

Engine cleanup confirms release/destruction and two physical observations with the original inventory restored. Product shutdown separately reports `released=true`, **2.057667 ms**, cleanup=true, and two successful physical return observations for all three fixtures at home 4 with preserved frames. Both [fixture quit commands](runtime/fixture-cleanup.json) exit 0.

The wrapper records original front PID/birth preserved with `foregroundRestoreRequested=false`, original ordinary desktop 4 preserved, and unchanged preferences. `preferenceWrites=0`, `desktopNavigationInputs=0`; hardware counters remain equal and `newHardwareInput=false`. These positive cleanup/context receipts do not convert the failed first selection into acceptance.

## Original and fixture-scoped evidence

[provenance.json](provenance.json) records **34 source originals**, original target paths, sizes and SHA-256 hashes. **32 files are byte-for-byte copies.** Only the two wider-roster JSON documents are published as named derivatives:

| Original | Published derivative |
| --- | --- |
| `runtime/summary.json` | [summary.fixture-scope.json](runtime/summary.fixture-scope.json) |
| `runtime/product/product-result.json` | [product-result.fixture-scope.json](runtime/product/product-result.fixture-scope.json) |

In each document, only `lastObservedReadiness.roster` and `lastReadiness.roster` change, nested under `productReceipt` in the runtime summary. The original `runtime/config.json` supplies fixture PIDs **85912 and 85915**. Each array retains its three fixture entries in original order and removes 17 non-fixture entries from 20 original entries. The four arrays therefore omit 68 entry occurrences across repeated snapshots, not 68 distinct windows.

All other JSON values remain unchanged, including `windowCount=20` and the original readiness/eligibility fields. Restoring only the listed arrays reproduces the original JSON values. The provenance identifies exact changed pointers, original hashes and derived hashes without retaining removed entries in the public directory. Full unfiltered JSON and transport exports remain in scratch and the original target paths. No screenshot or user-window content is included.

## Next verification boundary

The accepted input establishes that this trial progressed beyond both the old direct-parent path refusal and the preceding panel-verification refusal. The next unresolved product boundary is the specific final-continuity check during the first physical preparation read. Keep the measured failure, unchanged acceptance requirements and two independent cleanup scopes when evaluating subsequent diagnostics or fixes. This record claims no later fix PASS.
