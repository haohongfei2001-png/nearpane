# Exact `a37b56c6` cloud R4 evidence

This record belongs only to commit `a37b56c6ac7ad2240405d23a33f02459dffb9a7a`, on PR #16's existing `pro/independent-stage-engine-20261126` branch. [Workflow run 46026731386](https://github.com/haohongfei2001-png/nearpane/actions/runs/46026731386) started at 2026-11-27 15:38:41 UTC. These are cloud macOS receipts, separate from the target Mac and from subsequent test corrections.

**Neither product lane completed its first R4 selection.** In fast, one real external AXPress reached the formal sidebar, one sibling was physically hidden, and target focus was independently confirmed; the other sibling remained visible at the unchanged acceptance deadline. Full release reached preparation but its initial witness was rejected after dispatch ownership expired, before canary or HIDE. Both products remain `FAIL / R4SwitchReadbackFailed`, each with one actual input and zero `R4SwitchConfirmed` events. Both shutdowns confirmed all original windows visible at home with two physical reads; fast additionally proves restoration after a real hide. Source validation also failed.

## Results by lane

| Lane | Actual result | Physical scope and limit |
| --- | --- | --- |
| Source | `FAIL`: Rust test compile exit 101; Swift test exit 1 | Rust has three E0609 errors in the new test mock. Swift compiled and ran 220 tests in 34 suites, reporting one issue and one explicit skipped test. No claim of 180 Rust / 219 Swift tests passing. |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Direct ABI foreign-window round trips, independent focus and cleanup. These are separate from formal R4 input. |
| Fast formal R4 | `FAIL`, 1 actual input, 0 confirmed selections | Target 54 remained visible at home 12 with exact focus verified; sibling 56 was hidden on Space 33; window 57 remained visible at home 12. |
| Fast shutdown | `released=true`, physical return confirmed, cleanup true | All windows 54/56/57 visible on original home 12 with frames preserved in two independent reads; worker closed with zero owned Spaces. |
| Diagnostics direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Candidate engine itself passed. No platform-only fallback was used. R4 was `NOT_RUN`. |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 request attempts, cleanup true | Release candidate built successfully despite the independent source-test failure. No platform-only fallback. |
| Full formal R4 | `FAIL`, 1 actual input, 0 confirmed selections | Initial physical witness rejected after Dock observation expired; all three windows remained visible. Exact focus was not confirmed. |
| Full shutdown | `released=true`, physical return confirmed, cleanup true | All 55/57/58 visible at original home 12 with preserved frames in two reads. No product HIDE had occurred. |

The cloud receipts identify kernel `26A434`, SIP disabled, and `exactTarget=false`. `qualificationGranted` remains false. No interaction polish, stability acceptance, desktop gesture acceptance, or release qualification follows from these partial results.

## Source failure is independent from the runtime result

[source/summary.json](source/summary.json) records Rust `FAIL / exit 101` and Swift `FAIL / exit 1`. Worker build, worker protocol, evidence, read-only context and native diagnostic checks passed. The early context artifact did not contain the Rust logs; the completed full artifact now supplies the original [rust.stderr.log](source/rust.stderr.log), [rust.log](source/rust.log), and [rust.json](source/rust.json).

Rust failed to compile the test target: `src/spaces/tests.rs:287` accesses `changed.number`, `changed.pid`, and `changed.birth` while `changed` is an `Option<spaces::Window>`, producing three `E0609` errors. No Rust tests ran successfully in this source gate. This diagnosis is now present in the exact cloud artifact, independent of the separate target-Mac reproduction. The production library/worker and full candidate builds still succeeded.

[source/swift.log](source/swift.log) contains:

```text
inputChangedDuringTheFinalPhysicalReadCannotPublishItsResult()
StageHostGroupProjectionTests.swift:243:13
Expectation failed: delivered.wait(timeout: .now() + 2) == .success
Test run with 220 tests in 34 suites failed after 8.447 seconds with 1 issue.
```

The explicit skip was `observeSignedInactiveSiblingAcrossItsOwnMinimizeAndRestore()`. The recorded failure is the existing two-second semaphore assertion, not a compiler failure or a passing source gate. Later corrections to test synchronization and the Rust mock do not change this commit's recorded failure.

## Fast input, partial HIDE, and confirmed restoration

Raw receipts: [product-result.json](fast/product-result.json), [product.stderr.log](fast/product.stderr.log), [actual AXPress result](fast/r4-press-c8e34eda-c813-46cd-9cf8-e65a29763605.result.json), and [worker trace](fast/spaces-worker-6138d6a2-5025-4502-af70-c277f755ebb7.jsonl).

Times in the following table are native `ProcessInfo.systemUptime` seconds from this one cloud runner. The `R4AccessibilityButton` event is a later acknowledgement; actual input is the helper receipt's `inputUptime`.

| Event | Uptime | Meaning |
| --- | ---: | --- |
| External AXPress | 367.550747 | Complete receipt: `issued=true`, `axError=0`, exact button/panel evidence retained. |
| Navigation submit | 367.588668 | No existing running selection. |
| Navigation dequeue | 367.589203 | Submit-to-dequeue 0.536 ms. |
| System confirmation | 367.591240 | Dispatch still available and selection current. |
| Group job start | 367.591734 | Formal group-selection work began. |
| Preparation complete | 367.878468 | Existing binding accepted; preparation 286.593 ms. |
| Group choice configured | 367.949965 | Session available and permitted. |
| Last failed physical switch readback | 375.661341 | Focus verified; 56 hidden; 57 still visible; overall `verified=false`. |
| Shutdown entered | 375.731535 | Acceptance failure starts release and return, without extending the switch budget. |
| Activation interrupted | 375.745786 | Recorded after shutdown started; this cancellation is not evidence of an earlier independent worker fault. |
| Shutdown exited | 377.013795 | `released=true`, elapsed 1282.256 ms. |
| Two-read return confirmed | 377.565996 | All three fixtures visible at original home 12, frames preserved. |

The final switch read's focus evidence confirms front PID 8146 and focused window 54, with unchanged front application. That valid focus fact does not make the incomplete visibility state pass. The later shutdown double read establishes actual restoration after a real hide; it is not a successful second user selection or a completed R4 cycle.

The product worker completed its launch canary. Two matching home samples were observed at 67 ms and 112 ms; both had `focusSame=1`, `focusReadError=0`. There were zero missing-Role samples. This lane therefore does not exercise the new read-only recovery for `AXCannotComplete`, even though the ordinary canary path passed. The final worker receipt reports `engineDestroyed=true`, `pendingDrained=true`, status 0 and `owned=0`.

## Scheduling evidence

[fast/timing-analysis.json](fast/timing-analysis.json) is a derived extraction with original source hashes and trace arrays. The raw stderr is retained byte-for-byte. It distinguishes actual read tasks from callers joining an existing task.

The initial preparation took 286.593 ms, with its one `first-directory` await taking 279.702 ms. Its underlying after-action directory wait was 275.626 ms: prior in-flight work 126.298 ms and the fresh phase 149.320 ms. Initial dispatch and queue delivery were therefore fast in this lane.

The prominent later delay is actual read revision 10:

| Segment | Duration |
| --- | ---: |
| Task created to task started | **1499.353 ms** |
| Task execution body | 154.144 ms |
| Awaited reader inside that body | 152.152 ms |
| Native helper begin after reader request | 100.369 ms |
| Native helper observation | 41.160 ms |
| Native end to reader return | 10.623 ms |
| Associated after-action directory call | 1771.347 ms: prior 99.677 + fresh 1671.663 ms |

The task was created at 370.520128 and started at 372.019481. The new trace directly identifies scheduling wait before this task begins; it does not identify the synchronous operation or executor responsible. The three-second sampler began earlier, but there is no timestamped capture-completion receipt establishing coverage of the entire wait. Its nominal duration and later reaping time cannot establish a complete explanation of the 1.499-second interval.

Across 25 after-action directory calls, total measured duration was 4918.928 ms, comprising 376.903 ms prior wait and 4541.940 ms fresh phase. Median fresh phase was 113.437 ms, maximum 1671.663 ms. Across 32 actual read tasks, median task-queue wait was 0.279 ms and maximum 1499.353 ms. These are sums/distributions of observations, not end-to-end wall-clock switch latency.

Twelve complete witnesses were recorded, with no overlap in their measured intervals. Their total duration was 6635.391 ms: opening directories 3097.228 ms, binding 1410.778 ms, physical windows 538.874 ms, closing directories 1588.512 ms. The largest binding segment alone was 1382.760 ms. These facts do not prove that the idle refresh gate has passed held-selection acceptance: this first activation never completed and no later held choice ran. The final witness completed after shutdown had already entered, before the activation reported interruption.

`nativeBeginAfterRequestMS` includes scheduling, any reader preparation and process startup. `nativeEndToReturnMS` includes helper completion, IPC, decoding and scheduling. Neither field by itself isolates hashing, a single native API, or main-actor work. No freshness limit, navigation deadline, or physical acceptance threshold was relaxed for this record.

## Full release: quick preparation, expired dispatch before first HIDE

Raw [full product result](full/product-result.json), [full stderr](full/product.stderr.log), [full worker trace](full/spaces-worker-096dfa2e-b0ce-4614-8121-f4c61eda1087.jsonl), and [derived full timing analysis](full/timing-analysis.json) preserve this separate runner's result.

The real AXPress occurred at native uptime 1090.441162. Navigation submitted at 1090.450761 and dequeued at 1090.451337, a 0.576 ms queue wait. Preparation succeeded at 1090.597981 after 132.364 ms. Its directory call and the initial witness's opening directory call had no prior wait: fresh durations were 128.656 and 196.543 ms. For the two actual tasks aligned to those calls, task-queue time summed to 2.534 ms and group projection to 0.711 ms. This evidence does not attribute the later multi-second failure to those two directory operations.

The initial witness then failed after 4466.307 ms, at uptime 1095.116761, with `bindings=3`, `claims=0`, `sequence=0`, `step=physical-window-observation`, window 55. It is a rejected witness, not a completed witness. Shortly before that failure, `dispatch-dock-observation-expired` was logged at 1095.023614: the retained native Dock read ran from 1091.605490 to 1091.608533 (**3.043 ms**), but was already **3415.081 ms past its native end** when expiration was reported. A subsequent read was pending. Dispatch eligibility was withdrawn at 1095.023811, before the witness rejected and activation reported `interrupted` at 1095.120468.

These events establish stale dispatch evidence and initial physical-witness rejection. They do not identify which operation caused the elapsed interval, and they do not prove that the original Dock reply itself was first delivered only at expiry. The source deadline remains unchanged. Native timestamps, callback/expiration timestamps and sampled stacks must be distinguished when attributing the delay.

The preserved [full main-thread sample](full/host-main-thread.sample.txt) has 35 main-thread samples, 29 under the normal run loop wait. A separate background stack contains 24 samples through `NativeSidebarNavigation.submit` → witness → `StageHostPhysicalReader` → AX/CG, on a `utility-qos.cooperative` worker. This is direct evidence of where those sampled portions executed, not proof that a synchronous main-thread hotspot consumed the entire interval. App Nap, QoS and contention remain hypotheses until separately measured; the sample alone cannot establish any of them as the cause.

The product worker trace contains only `ready` and `closed`; no launch-canary event or product HIDE was issued. Therefore the Finder Role recovery branch was not exercised here. At the final switch read, the front PID was 381, while the expected fixture PID was 36786; `focus.verified=false` even though a window-number field read 55. All three windows 55/57/58 were still visible at home 12. Shutdown took 3.144 ms and the two subsequent physical reads confirmed the unchanged home and frames. This is confirmed cleanup, not a successful HIDE→SHOW round trip.

The full candidate ZIP is omitted from the repository: 25,694,048 bytes, SHA-256 `e55ca42b9e544201f696eef4f0a9b5258360fcb2f11a9a2ea4adc670fb9af14e`. Its build metadata remains in [full/candidate.json](full/candidate.json).

## Sampling and provenance

Within each lane, the actual-press and preparation triggers shared **one physical sample process**. Each selection report has its own complete `group-job-start` evidence and `sharedWith=host-main-thread`; both logical reports name the same lane's `host-main-thread.sample.txt`. The fast trigger distinction remains in [host-main-thread-sample.json](fast/host-main-thread-sample.json) and [host-selection-preparation-main-thread-sample.json](fast/host-selection-preparation-main-thread-sample.json); corresponding full metadata is retained as well. The more diagnostic full sample text is checked in. Fast sample text is omitted with its original hash and archive location, because its nominal duration and reaping metadata do not establish full coverage of the later 1.499-second scheduling wait.

The sampler started only after a complete, successful external AXPress receipt, not when a request file first appeared. `sampleLaunchMonotonic` and other `*Monotonic` fields are runner-process monotonic metadata; native uptime fields are retained separately. `reapedMonotonic` records process cleanup, not the end of the captured sample window. The separate startup sampler metadata is retained; its larger raw text is omitted here with SHA-256 and original artifact path in provenance.

| Artifact | ID | ZIP bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Early full source context | 15212419563 | 25,050 | `41027c5603c89ff26cbf8648783b8c010169968d2bd17f9a77d41fbfffd00c83` |
| Fast | 15210994424 | 24,676,397 | `a20840d71b625119512f22e7f69c53656a587eaca1662ef0a817730c5ea48d70` |
| Diagnostics | 15212656234 | 1,460,676 | `af4d43cc00bfd9f1f487573068671ea367006a0487e0e2359261e946f90859c0` |
| Full | 15213392016 | 53,298,105 | `4a98902cd0a4a16a47c38e0a83ca7ac40b95f2c52d40623d795d8c0e1862d39a` |

[provenance.json](provenance.json) records each copied raw file's archive entry, artifact ID, size and SHA-256, plus derived analysis hashes. Archives and candidate binaries are not checked in. Original fixture and CI workspace cleanup receipts are retained separately for all three runtime lanes; ordinary-desktop creation is CI preparation and does not confer target-environment qualification.

## Outstanding acceptance

1. Run the corrected source tests on their new exact commit; this record remains failed.
2. Resolve the remaining delayed activation/read work using evidence that covers its actual interval, then complete real R4 selection → all required hides → next selection restoration → exact focus within existing bounds.
3. Demonstrate held-selection refresh behavior and repeated complete cycles, with independent physical cleanup retained, before overall interaction refinement, stability acceptance or release.
