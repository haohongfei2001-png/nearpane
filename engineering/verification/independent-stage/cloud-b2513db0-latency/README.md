# Exact `b2513db0` source and cloud R4 evidence

Commit `b2513db0585db8e08c0e0ea0019000035a969dda` remains on PR #16's existing branch. It changes only the Rust test mock's `Option` unwrapping and the Swift test's completion handshake; production source is the same as `a37b56c6`. [Workflow run 46028571636](https://github.com/haohongfei2001-png/nearpane/actions/runs/46028571636), a push run created at 2026-11-27 15:51:23 UTC, reports this exact head SHA.

**The corrected source gate passed; the fast formal R4 chain still failed.** Source receipts confirm **180 Rust tests passed, 219 Swift tests passed and one Swift test skipped**. Fast reached one real external AXPress, then its first preparation returned `directoryUnavailable` after dispatch ownership expired. There were zero confirmed R4 selections, no observed product hide, and no verified target focus. Final independent physical cleanup confirmed all three original windows visible at home. Full release runtime remains pending in this initial record.

## Actual lane outcomes

| Lane | Result | Scope |
| --- | --- | --- |
| Source | `PASS`: 180 Rust; 219 Swift + 1 skip | Original summary and complete Swift test log preserved. The earlier `a37b56c6` source failure remains unchanged in its own record. |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Foreign-window ABI round trips and focus checks. Formal R4 is assessed separately. |
| Fast formal R4 | `FAIL / R4SwitchReadbackFailed`, 1 actual input, 0 confirmed selections | Preparation failed before group choice; no product HIDE or exact target focus was established. |
| Fast shutdown | `released=true`, double physical return confirmed, cleanup true | Windows 55/57/58 visible at original home 12 with preserved frames. No prior product hide occurred. |
| Diagnostics direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Candidate engine itself passed; no platform-only fallback. R4 `NOT_RUN`. |
| Full release runtime | `PENDING` | Source gate passed, full candidate build running; no full product outcome inferred. |

Cloud receipts identify `kernelBuild=26A434`, `sipEnabled=false`, `exactTarget=false`. This directory does not contain target-Mac runtime evidence. `qualificationGranted` remains false and overall runtime acceptance remains incomplete.

## Source correction verified

[source/summary.json](source/summary.json) records all source checks passing: Rust, Swift, worker build, worker protocol, evidence, native diagnostic and read-only context. Its actual counts are Rust `passed=180`, Swift `passed=219`, `skipped=1`.

[source/swift.log](source/swift.log) ends with `Test run with 220 tests in 34 suites passed after 5.177 seconds.` The explicit skip is `observeSignedInactiveSiblingAcrossItsOwnMinimizeAndRestore()`. The early context artifact contains the source summary but omits raw Rust stdout/stderr; those can be appended from the terminal full artifact. This distinction does not turn the summary's actual Rust PASS into a claim that an unavailable raw test log was inspected.

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

## Sample handling and provenance

[host-main-thread.sample.txt](fast/host-main-thread.sample.txt) retains the actual-press sampling window. Its [physical sampler metadata](fast/host-main-thread-sample.json) and [selection trigger metadata](fast/host-selection-preparation-main-thread-sample.json) preserve each trigger's evidence. The preparation trigger shares the still-running actual-press sample through `sharedWith=host-main-thread`; only one physical process ran for that window. The complete successful AXPress result, not request-file discovery, authorizes the actual-press trigger.

`reapedMonotonic` records when the sampler was collected during cleanup; it is not the end of its capture window. The startup sample text is omitted with its original hash and archive entry, while its metadata is retained. Raw files are unchanged; any later derived timing analysis must preserve its source hashes and mark inferred attribution explicitly.

| Artifact | ID | ZIP bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Early full source context | 15214256155 | 25,333 | `abe26d221f323d58e05d8ac0500a1c445702a59bfe31ada7da9e8cf18b013a13` |
| Fast | 15213447215 | 24,673,435 | `3c61ebd7d26b87e571801262f90640d584bf0a40fec2b3b0352c6311cc4ac1b4` |
| Diagnostics | 15213920913 | 1,460,803 | `b80b893f5cba5a60d7e499eb13407c7416d5e4f4828b98e775f8d0f7eb16b635` |

[provenance.json](provenance.json) lists each raw archive entry, artifact ID, byte size and SHA-256. Fixture cleanup and CI workspace cleanup receipts are retained for each completed runtime lane. Archives and application binaries are omitted from the repository.

## Remaining work

Append the terminal full artifact and its exact runtime outcome. The source correction is verified; the remaining product requirement is still actual R4 selection → all required real hides → restoration on later selection → exact focus within existing bounds. Stable repeated cycles and interaction refinement follow only after that complete chain is observed. No freshness, witness, ownership or cleanup requirement was weakened for this run.
