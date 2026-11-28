# Exact `34f37360` source and cloud R4 evidence

Commit `34f37360144eb8e339ac81b1f901536f31853ad6` continues PR #16 on `pro/independent-stage-engine-20261126`. [Workflow run 46030907299](https://github.com/haohongfei2001-png/nearpane/actions/runs/46030907299) is the exact-head push run, created at 2026-11-27 16:07:33 UTC. This revision explicitly starts the sidebar action task at `.userInitiated`, adds native `taskPriority` trace fields, and tests priority across suspension. It does not change physical acceptance thresholds.

**Source validation passed and full release observed action priority 25, but the complete R4 switch still failed.** Full issued one real input, prepared the group, then its opening-witness read task waited 3029.316 ms before starting despite reporting priority 25. Dispatch ownership expired before the opening roster was accepted; no product HIDE or exact target focus was confirmed. Fast separately stopped before any input on an incomplete AX tree, so it did not exercise the new action-priority path. Both product cleanup results were independently confirmed.

## Outcomes and their separate scopes

| Lane | Actual result | What it establishes |
| --- | --- | --- |
| Source | `PASS`: 180 Rust, 220 Swift + 1 skip | The new priority test passed. Source semantics are verified; this does not replace native product acceptance. |
| Fast direct engine | `BLOCKED / candidateCanaryNotConfirmed`, 0 foreign-window requests, cleanup true | Candidate launch canary was not confirmed on this runner. This is not an engine PASS. |
| Fast platform-only fallback | `PLATFORM_FOREIGN_PASS`, 4 direct diagnostic writes, cleanup true | Platform mechanism result only; does not qualify the candidate or formal R4 path. |
| Fast formal R4 | `BLOCKED / realExternalR4ButtonNotAccepted`, 0 actual inputs | AX tree incomplete, helper `issued=false`; no navigation dequeue, group selection or witness occurred. |
| Fast shutdown | Released, physical return confirmed, cleanup true | All original fixture windows visible at home after two independent reads. No product HIDE occurred. |
| Diagnostics direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Candidate engine itself passed on this separate runner; no platform-only fallback and R4 `NOT_RUN`. |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Candidate engine passed; no platform-only fallback. |
| Full formal R4 | `FAIL / R4SwitchReadbackFailed`, 1 actual input, 0 confirmed selections | Navigation and relevant read tasks recorded priority 25. The initial witness rejected its opening roster after a multi-second task-queue wait and ownership expiry; no product HIDE. |
| Full shutdown | Released, two-read physical return confirmed, cleanup true | All 55/57/59 visible at original home 12 with preserved frames; exact target focus was not confirmed before cleanup. |

Cloud receipts identify kernel `26A434`, SIP disabled and `exactTarget=false`. Target-Mac setup and runtime belong in separate evidence. `qualificationGranted=false` remains unchanged.

## Source priority test passed

[source/summary.json](source/summary.json) records all checks passing, with actual counts `rust.passed=180`, `swift.passed=220`, `swift.skipped=1`. [source/swift.log](source/swift.log) ends with `Test run with 221 tests in 34 suites passed after 5.392 seconds.` The new `utilitySubmissionKeepsUserActionPriorityAcrossSuspension()` passed after 5.274 seconds. The explicit skip remains `observeSignedInactiveSiblingAcrossItsOwnMinimizeAndRestore()`.

The new test submits from a utility-priority task, observes `.userInitiated` inside the action before and after suspension, and avoids awaiting the submitter in a way that would elevate its priority before the assertion. These are the source-test semantics, not a native R4 click receipt. The early context archive omitted raw Rust stdout/stderr; the completed full archive now supplies [rust.log](source/rust.log), [rust.stderr.log](source/rust.stderr.log) and [rust.json](source/rust.json). Rust's original result is 180 passed, zero failed, finished in 0.12 seconds.

## Fast stopped before the click

The original [product result](fast/product-result.json) and [Host stderr](fast/product.stderr.log) preserve the complete record. The external helper receipt reports `status=UNKNOWN`, `reason=accessibilityTreeIncomplete`, `issued=false`, `processExit=2`, and zero rediscoveries. Its AX tree visited seven nodes: one foreign-app card was readable, while two later nodes returned `batchRead=-25204` with unknown role and identifier. It could not confirm the target button and correctly withheld the press.

The earlier readiness snapshot had a visible panel, a complete catalog and three fixture groups. That readiness snapshot is not authorization to issue a later input when the live AX tree is incomplete. Neither a request file nor the failed helper receipt counts as an actual click.

The product has no `R4AccessibilityButton` or `R4SwitchConfirmed` event. It opened the overview at native uptime 476.884277, entered shutdown at 487.071995, released after 4.149 ms, and confirmed the two-read physical return at 487.177327. There is no press-to-confirmed latency to compute, no product HIDE→SHOW cycle, and no target-focus acceptance result from this lane.

Five actual desktop-read tasks have `taskPriority=17` in their native traces. They are startup/automatic reads: the trace has no `navigation-submit`, no `navigation-dequeue`, no preparation and no witness. Their priorities do not establish that `.userInitiated` failed on a selected-window action, because no such action ran. [fast/timing-analysis.json](fast/timing-analysis.json) preserves the exact task records and empty navigation/witness arrays with source hashes.

This runner also recorded stale Dock observations while input discovery was pending. The event records distinguish an old saved observation becoming too old, a separate pending request, and any accepted/expired read completion. These times should not be collapsed into one claim about initial reply delivery or the cause of every AX failure.

## Full: real action priority changed, remaining queue delay did not disappear

The [full product result](full/product-result.json), [Host stderr](full/product.stderr.log), [worker trace](full/spaces-worker-375370bd-6040-428e-8b85-713d6d2dd963.jsonl), [three-second sample](full/host-main-thread.sample.txt), and [derived timing analysis](full/timing-analysis.json) preserve this separate runner's observations.

| Full-lane event | Native uptime / measured duration |
| --- | --- |
| Successful external AXPress | 1438.351892; `issued=true`, `axError=0`, exact fixture button 55 |
| Navigation submit → dequeue | 1438.370824 → 1438.371583; 0.759 ms queue wait |
| Observed action priority | `navigation-dequeue.taskPriority=25` |
| Preparation complete | 1439.379778; 1005.499 ms, `final-group-binding` |
| Opening-read task created | 1439.436759, revision 7 |
| Opening-read task started | 1442.466075; **3029.316 ms task queue** |
| Saved Dock observation expired | 1442.468983; ownership withdrawn at 1442.469595 |
| Opening-read task ended | 1442.836345; body 370.147 ms, recorded `taskPriority=25` |
| Initial witness rejected | 1442.839821; `opening-roster`, 3405.144 ms, bindings 0 / claims 0 / sequence 0 |
| Activation interrupted | 1442.840382 |
| Shutdown | 1447.231932 → 1447.237319; released after 5.378 ms |
| Two-read physical cleanup confirmed | 1447.396385 |

The priority field is an actual trace observation, not merely a configured value: dequeue records 25 and relevant read revisions 4–7 also record 25. Revision 4 was already in flight before the action; its later priority observation should not be described as proof of its priority at creation. The source change successfully reached a real selected-window action in this lane, but priority alone did not eliminate the three-second wait before revision 7 started.

Preparation used the `final-group-binding` branch, with two directories and six physical reads. Its 1005.499 ms must not be compared as the same work as the earlier runs' `existing-group-binding` preparation. The first directory call was 351.592 ms, comprising prior wait 43.291 ms plus fresh phase 308.292 ms; the second was 179.785 ms with no prior wait.

The first witness's opening directory was 3400.801 ms, entirely in its fresh phase. Its aligned task spent 3029.316 ms waiting to start and 370.147 ms in the body. The native helper observation within that body was 79.731 ms, so neither the full fresh duration nor the full task-queue wait can be attributed to that helper's native observation.

The retained Dock native observation ran from 1439.290604 to 1439.292670, 2.066 ms. At the expiry check it was 3176.313 ms past its native end and a separate request was pending. This is saved-observation age, not proven initial-delivery delay. Ownership was withdrawn before the witness rejected its opening roster. No completed witness, product launch-canary event or product HIDE was observed: the worker contains only `ready` and `closed`.

At the last physical switch read all fixtures 55/57/59 remained visible on home 12. Front PID 406 did not match target PID 48253, so exact focus was false despite a focused-window-number field of 55. Shutdown then confirmed all home placements and preserved frames twice. This is successful cleanup after a failed activation, not a passing user switch or restored selected-window cycle.

The complete candidate built successfully. Its omitted ZIP is 25,694,469 bytes, SHA-256 `1a70cc88ec1e9bdb2606cae4a4e16d627627bf8a45324f10f5b563d835db154a`; [full/candidate.json](full/candidate.json) retains build metadata.

## Samplers preserve the no-input distinction

The [actual-press sampler metadata](fast/host-main-thread-sample.json) is `NOT_RUN / successfulR4PressNotObserved`. The [selection sampler metadata](fast/host-selection-preparation-main-thread-sample.json) is `NOT_RUN / groupSelectionJobNotObserved`. No three-second action or preparation sample was launched, and no request-file discovery was misreported as input.

Only the separate one-second startup sampler ran. Its [metadata](fast/host-startup-main-thread-sample.json) and [raw startup sample](fast/host-startup-main-thread.sample.txt) are retained. That startup sample does not cover a selection task. Runner `*Monotonic` metadata and native `systemUptime` fields remain separate; `reapedMonotonic` means process collection during cleanup, not capture-window end.

Full did have a complete successful AXPress receipt. Its action and selection triggers shared one three-second sample with their own trigger evidence and `sharedWith=host-main-thread`; both raw metadata files are retained. The full startup sample text is omitted with hash and artifact location. Native queue timestamps and sampled stacks must be compared with actual sampling coverage, not with the later `reapedMonotonic` value.

The full sample contains 24 main-thread observations, 16 in run-loop waiting. Nine samples on a `user-initiated-qos.cooperative` worker include preparation's physical reads through `StageHostAccess.currentSurface` and AX/CG; additional work also appears at user-initiated QoS. This corroborates the observed priority on some actual work, but does not identify one synchronous main-thread operation accounting for the entire queue delay. There is no timestamped capture-completion marker in sampler stderr. Neither its nominal three-second duration nor its later reaping time establishes full coverage of the 3029.316 ms queue interval. App Nap, process throttling and other scheduling explanations remain hypotheses.

## Provenance

| Artifact | ID | ZIP bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Early full source context | 15214802094 | 25,063 | `fa3a4326ad631dd31c03ec29d028674eca0ed0df6242e01da3a75dce943522b6` |
| Fast | 15215006048 | 24,591,963 | `58e5aca19a4b4830c0a6ada864d223fd45b5d66e53bb71443b9f33ba9c443d94` |
| Diagnostics | 15214756101 | 1,460,749 | `4be1eb5b1f56c273ff4272d8507af599e58f3e8daf5c3d2bf30f2513840848c7` |
| Full | 15215477441 | 53,300,771 | `ff5e393dc3f3fc32475825d8e29a6392d91a2fa68bb5d17f4b83d6242a218e2d` |

[provenance.json](provenance.json) records each copied raw archive entry, artifact ID, byte size and SHA-256, plus the derived timing-analysis hash. Engine, platform and product receipts remain separate. Fixture cleanup and CI workspace cleanup originals are retained for both completed lanes. No application binary or ZIP is checked in.

## Remaining acceptance

The source gate and actual selected-window priority are verified, while the multi-second read-task queue delay remains. Identify the work or scheduling condition occupying that interval, preserve all current freshness and physical proof requirements, then complete real hides, restoration on later selection and exact focus within the existing bounds. Interaction refinement, repeated-cycle stability and release remain later work.
