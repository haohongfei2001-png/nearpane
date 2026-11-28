# Exact `b2513db0` source and cloud R4 evidence

Commit `b2513db0585db8e08c0e0ea0019000035a969dda` remains on PR #16's existing branch. It changes only the Rust test mock's `Option` unwrapping and the Swift test's completion handshake; production source is the same as `a37b56c6`. [Workflow run 46028571636](https://github.com/haohongfei2001-png/nearpane/actions/runs/46028571636), a push run created at 2026-11-27 15:51:23 UTC, reports this exact head SHA.

**The corrected source gate passed; both formal R4 lanes still failed.** Source receipts confirm **180 Rust tests passed, 219 Swift tests passed and one Swift test skipped**. Fast reached one real external AXPress, then its first preparation returned `directoryUnavailable` after dispatch ownership expired. Full release prepared successfully, but its first witness was rejected at `physical-window-observation/window57` before any product hide. Each lane had one actual input, zero confirmed selections, and no verified target focus. Both final independent physical cleanup checks confirmed all three original windows visible at home.

## Actual lane outcomes

| Lane | Result | Scope |
| --- | --- | --- |
| Source | `PASS`: 180 Rust; 219 Swift + 1 skip | Original summary and complete Swift test log preserved. The earlier `a37b56c6` source failure remains unchanged in its own record. |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Foreign-window ABI round trips and focus checks. Formal R4 is assessed separately. |
| Fast formal R4 | `FAIL / R4SwitchReadbackFailed`, 1 actual input, 0 confirmed selections | Preparation failed before group choice; no product HIDE or exact target focus was established. |
| Fast shutdown | `released=true`, double physical return confirmed, cleanup true | Windows 55/57/58 visible at original home 12 with preserved frames. No prior product hide occurred. |
| Diagnostics direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Candidate engine itself passed; no platform-only fallback. R4 `NOT_RUN`. |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Complete release candidate build and candidate engine passed; no platform-only fallback. |
| Full formal R4 | `FAIL / R4SwitchReadbackFailed`, 1 actual input, 0 confirmed selections | Preparation succeeded; initial physical-witness boundary rejected before HIDE. Exact focus was not confirmed. |
| Full shutdown | `released=true`, double physical return confirmed, cleanup true | All 54/56/57 visible at original home 12 with preserved frames. No prior product hide occurred. |

Cloud receipts identify `kernelBuild=26A434`, `sipEnabled=false`, `exactTarget=false`. This directory does not contain target-Mac runtime evidence. `qualificationGranted` remains false and overall runtime acceptance remains incomplete.

## Source correction verified

[source/summary.json](source/summary.json) records all source checks passing: Rust, Swift, worker build, worker protocol, evidence, native diagnostic and read-only context. Its actual counts are Rust `passed=180`, Swift `passed=219`, `skipped=1`.

[source/swift.log](source/swift.log) ends with `Test run with 220 tests in 34 suites passed after 5.177 seconds.` The explicit skip is `observeSignedInactiveSiblingAcrossItsOwnMinimizeAndRestore()`. The early context artifact contained the source summary but omitted raw Rust stdout/stderr. The completed full artifact now supplies [rust.log](source/rust.log), [rust.stderr.log](source/rust.stderr.log) and [rust.json](source/rust.json). The original Rust log confirms `180 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.17s`.

## Fast: actual input followed by failed preparation

The original [product result](fast/product-result.json), [Host stderr](fast/product.stderr.log) and AXPress receipt are preserved. Native uptimes below belong to the same cloud runner; runner monotonic sampler metadata is a separate clock domain.

| Event | Native uptime | Interpretation |
| --- | ---: | --- |
| External AXPress | 425.087795 | Successful complete receipt; exact live button semantics retained; zero rediscoveries. |
| Navigation submit | 425.124068 | No prior selection running. |
| Navigation dequeue | 425.124808 | Queue wait 0.740 ms. |
| Group job start | 425.133880 | First preparation begins. |
| Dock observation expired | 429.255877 | Native old read 426.079928–426.081618; a new read was pending. |
| Preparation exits | 429.339498 | 4204.704 ms total; first-directory await 4204.188 ms returned no result; `directoryUnavailable`. |
| Shutdown enters | 433.409376 | Failed physical acceptance proceeds to cleanup without extending the original budget. |
| Shutdown exits | 433.412731 | Released, 3.339 ms. |
| Double physical return confirmed | 433.928907 | All three original windows visible at home 12, frames preserved. |

The preparation trace has `cancelled=false`, but `epochMatches=false`, `appearanceMatches=false`, and no retained group lifetime. The stale Dock observation's own native work took 1.690 ms; it was 3174.259 ms past its native end at the expiration check. That age does not identify when the old observation was first delivered. The separate pending request began at 429.134338. This record does not assign the stall to a specific native API, the main thread, or a QoS policy without corresponding trace evidence.

[fast/timing-analysis.json](fast/timing-analysis.json) contains the exact task and directory trace extraction. The after-action directory call took 4202.147 ms: **4057.079 ms waiting for prior work**, followed by a 145.004 ms fresh phase that returned unavailable. The prior actual task, revision 3, began before the press and completed at 429.133065:

| Revision 3 segment | Duration |
| --- | ---: |
| Task queue | 0.617 ms |
| Task body | 4139.331 ms |
| Awaited reader | 1395.042 ms |
| Native observation inside the reader | 1194.287 ms |
| Group projection | 71.317 ms |
| Directory observation callback | 0.307 ms |
| Remaining processing | **2672.665 ms** |

These are nested measurements; the native observation must not be added again to the reader total. Revision 4 subsequently reached its entry guard and exited without a reply after the epoch was invalidated. Thus the 145 ms fresh phase is not evidence of a successful new native snapshot. This lane's long prior task differs from `a37b56c6` fast's 1.499-second task-queue outlier despite identical production source, and should remain a separate observation.

The sample has only 16 main-thread observations; seven include `readNow` → `sessionAvailable` → `SLSessionCopyCurrentDictionary`. That is a specific sampled stack, but sparse sampling does not establish that this single native call consumed all 2.673 seconds of remaining processing. No witness or product worker trace was produced, and no launch-canary recovery branch was exercised by the formal R4 path.

The final switch read shows all three windows still visible on home 12. Target window 55 was expected in PID 8511, while the front PID remained 358, so `focus.verified=false`; a focused-window-number field alone is insufficient. Both sibling visibility checks failed. The absence of a complete selection means there is no press-to-confirmed latency or successful HIDE→SHOW cycle to report.

The shutdown receipt independently confirms two complete physical reads and a successful return/release. Since no product hide was observed, this cleanup result establishes that the original windows are safe and visible, not that restoration following a user selection has been accepted.

## Full release: preparation succeeded, initial witness rejected

[Full product result](full/product-result.json), [Host stderr](full/product.stderr.log), [worker trace](full/spaces-worker-98542321-cb60-49ab-bca8-e84be8016e3a.jsonl), [sample](full/host-main-thread.sample.txt), and [derived timing analysis](full/timing-analysis.json) preserve this lane separately from fast.

Preparation succeeded in 197.389 ms. Its directory call and the opening directory call of the first witness had zero prior wait, with fresh durations of 194.618 and 328.493 ms. For the two actual tasks aligned to these calls, task-queue time summed to 0.535 ms and projection time to 0.715 ms. The long wait for a prior task observed in fast therefore did not repeat at this preparation boundary.

The initial witness ran from 1249.034723 to 1253.435224, **4400.501 ms**, and rejected at `physical-window-observation`, window 57 / PID 43216, with `bindings=3`, `claims=0`, `sequence=0`. Activation reported interruption at 1253.436729. This was a rejected initial witness, not a completed witness or successful selection.

The rejection label covers several checks: the witness's pre-read unchanged condition, the asynchronous physical observation, the post-read unchanged condition and retained-binding comparison. The raw log contains no `stagePhysicalReadRejected` event, and all eight recorded `stageNonWindowFocusRead` events are positive. That absence is not enough to choose one of the covered conditions as the exact cause. The retained raw trace and sample are the evidence boundary; no specific native-reader failure is invented.

A source-path audit narrows the candidates without creating new native evidence: `Session.read` and `Coordinator.activate` propagate the error unchanged, while access and owner checks use different error types. The recorded `interrupted` still does not distinguish the physical observation's entry/return guards from witness unchanged/binding guards. A 3.013-second background directory task overlapped this witness, but its native interval was 1.540 seconds and its age at rejection was 2.093 seconds, within the existing 3-second/12-second directory bounds. Overlap alone is therefore not a proven directory-freshness rejection.

The only later `dispatch-dock-observation-expired` event is at 1255.567311, **2.132 seconds after** the witness rejection. It cannot be used as the initiating cause of that earlier rejection, unlike the event order in `a37b56c6` full. Its saved observation age also does not measure initial reply-delivery latency.

The product worker has only `ready` and `closed` receipts, with no launch-canary or HIDE event. The final physical read shows all three windows 54/56/57 visible at home 12. Exact focus was false: expected PID 43138, front PID 375. Shutdown then released in 29.360 ms and confirmed all original home placements and frames with two independent reads. Both engine and product cleanup are positive, but the formal R4 chain remains incomplete.

The omitted full candidate ZIP has 25,694,046 bytes and SHA-256 `480186a5e4519416bff86deb3264a7a9ee1f7e5ec453c8854650f2994a500c84`; [full/candidate.json](full/candidate.json) retains its build metadata.

## Sample handling and provenance

[host-main-thread.sample.txt](fast/host-main-thread.sample.txt) retains the actual-press sampling window. Its [physical sampler metadata](fast/host-main-thread-sample.json) and [selection trigger metadata](fast/host-selection-preparation-main-thread-sample.json) preserve each trigger's evidence. The preparation trigger shares the still-running actual-press sample through `sharedWith=host-main-thread`; only one physical process ran for that window. The complete successful AXPress result, not request-file discovery, authorizes the actual-press trigger.

`reapedMonotonic` records when the sampler was collected during cleanup; it is not the end of its capture window. The startup sample text is omitted with its original hash and archive entry, while its metadata is retained. Raw files are unchanged; any later derived timing analysis must preserve its source hashes and mark inferred attribution explicitly.

| Artifact | ID | ZIP bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Early full source context | 15214256155 | 25,333 | `abe26d221f323d58e05d8ac0500a1c445702a59bfe31ada7da9e8cf18b013a13` |
| Fast | 15213447215 | 24,673,435 | `3c61ebd7d26b87e571801262f90640d584bf0a40fec2b3b0352c6311cc4ac1b4` |
| Diagnostics | 15213920913 | 1,460,803 | `b80b893f5cba5a60d7e499eb13407c7416d5e4f4828b98e775f8d0f7eb16b635` |
| Full | 15213788391 | 53,311,108 | `a5c75f36aeb1752a3df60ee5a8bab1e41d9f813329e2b9b480fcc27f65358c67` |

[provenance.json](provenance.json) lists each raw archive entry, artifact ID, byte size and SHA-256. Fixture cleanup and CI workspace cleanup receipts are retained for each completed runtime lane. Archives and application binaries are omitted from the repository.

## Remaining work

The source correction is verified; the remaining product requirement is still actual R4 selection → all required real hides → restoration on later selection → exact focus within existing bounds. Stable repeated cycles and interaction refinement follow only after that complete chain is observed. No freshness, witness, ownership or cleanup requirement was weakened for this run. A subsequent priority patch must be assessed on its own exact native receipts, not credited with changing these results.
