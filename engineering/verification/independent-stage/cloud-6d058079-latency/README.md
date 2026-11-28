# Cloud 6d058079: first R4 selection confirmed; second selection fails

**The sampled fast lane completes one formal R4 selection with both sibling windows physically hidden, then fails the second selection. The unsampled full lane fails its first selection at the initial witness's opening roster. Neither product lane passes.** Source checks pass, and all three lanes' direct-engine and cleanup receipts are retained separately.

Exact revision `6d05807917e54b57f462e7882e34300e55cde3b4`, tree `95a196ba008a1b0f4f0be2b7b1e434f9c43c5e16`, original PR #16 branch. [Workflow 46045583443, run 57](https://github.com/haohongfei2001-png/nearpane/actions/runs/46045583443) was created at `2026-11-27T17:55:41Z`. These cloud results are separate from the target Mac, whose same-revision run encountered an explicitly locked session.

## Source gate

[The original source summary](source/summary.json) records **180 Rust tests passed, 227 Swift tests passed and one skipped**. [The Swift log](source/swift.log) ends with **228 tests in 36 suites, 9.956 s**. The extra ownership/inventory checks comprise two test functions and three executed cases:

| New test | Actual native result |
| --- | --- |
| `utilityParentRunsOwnershipReadAtTheRequestedPriority(duringUserAction:)` | Passed with both `false` and `true` cases; 9.771 s |
| `differencesNameOnlyChangedFieldsAndBoundTheirTraversal()` | Passed; 0.022 s |

The source summary also records C file-identity build/test, worker build/protocol, read-only context and evidence checks PASS. The full artifact supplies [original Rust stdout](source/rust.log) and [C file-identity stdout](source/r4-file-identity.log); the latter records **13 passed, zero failed, zero window writes**, with the strict compile receipt also retained. Test counts are actual receipts, not the anticipated count, and source PASS does not imply runtime PASS.

## Sampled fast lane: one complete selection out of two actual inputs

[The original product result](fast/product-result.json) records **`FAIL / R4SwitchReadbackFailed`**, `actualR4Inputs=2`, one `R4SwitchConfirmed` event and cleanup=true. Both external helper receipts record `issued=true` and `axError=0`.

| Event | Native uptime / result |
| --- | --- |
| First external AXPress, select window 54 | 417.416685000 |
| First formal R4 callback | 417.496735167 |
| First physical confirmation read | 424.726870083–424.729937167 |
| Second physical confirmation read | 424.853999042–424.855868958 |
| `R4SwitchConfirmed` | 424.858710583; **7442.020792 ms press-to-double-read** |
| Second external AXPress, select held window 56 | 426.348532875 |
| Second formal R4 callback | 426.520387333 |
| Recorded witness rejection during the second selection | 431.153655500; `opening-roster`, sequence 25, bindings 3 / claims 1 |

Both first-selection observations show window **54 / PID 8117** visible at original home **12**, window **56 / PID 8117** hidden on Space **33**, and window **57 / PID 8124** hidden on Space **34**. Every recorded frame and visibility comparison matches. This is physical HIDE evidence accompanying the formal confirmation, not just an animation or an issued input.

The second selection has no `R4SwitchConfirmed`. Its last recorded read expects focus on window 56 but observes front PID 8117 with focused window 54, so exact focus does not match. All three windows are back at home 12 by that read. That final state alone does not identify the second action's SHOW sequence or its precise rejection cause; the original [Host stderr](fast/product.stderr.log) and worker receipts retain the full timeline for analysis. One completed selection must not be promoted to complete interaction or stability acceptance.

## Independent engine and cleanup

The [fast engine result](fast/engine-result.json), [full engine result](full/engine-result.json) and [diagnostics engine result](diagnostics/engine-result.json) each record **`FOREIGN_ENGINE_PASS`**, **26 hide/restore request attempts**, cleanup=true and no platform-only fallback. This direct-engine result remains separate from formal R4 product acceptance. Diagnostics does not issue a product R4 input.

Fast Host shutdown runs from 434.690928875 to 434.693398500, **2.469625 ms**, with released=true. Two subsequent physical observations confirm all three fixtures visible at home 12 with preserved frames. Both fixture quit commands exit 0. [CI workspace cleanup](fast/ci-workspace-cleanup-receipt.json) independently reports cleanup=true and restores the original current desktop. Positive cleanup does not change the second-selection failure.

## Unsampled full lane: initial witness rejects the opening roster

[The original full product result](full/product-result.json) is **`FAIL / R4SwitchReadbackFailed`**, with **one actual R4 input and zero completed switch confirmations**. The external helper issues the press at **955.887626167**; the selection targets window **54 / PID 33478**. Navigation dequeues at priority 25 with `userActivity=true`. The activity begins at **955.892207250** and ends at **957.162096708**, with one completion hold recorded at its final end.

Selection preparation succeeds at **956.132620**, taking **234.217 ms**. The initial witness then rejects at **956.799897042**, step **`opening-roster`**, sequence **0**, bindings **0**, claims **0**, duration **534.278583 ms**. This rejection occurs **912.271 ms after the external press**, well before the later acceptance shutdown. The immediately preceding after-action directory read completes successfully at **956.798229542**, revision **5**, duration **517.406875 ms**, `hadPrior=false` and `priorWaitMS=0`. Its actual directory task records priority 25 and **26.763500 ms** queue time. Those task/read successes do not prove every catalog/roster predicate was acceptable to the witness.

The three dispatch-time Dock ownership polls have matching request IDs across creation/start/completion; all start and complete at priority **25**, confirm `sameGeneration=true` and `visibility=ordinary`, and queue for less than **0.7 ms**. No ownership expiry/withdrawal is recorded before this failure. That establishes the new dispatch-time priority behavior on this lane, without proving the incomplete roster was acceptable.

The original trace then records `stageActivationBeforeBackendRejected / initial-witness` and activation error `incomplete`. There is no completed witness. The worker log contains only `ready` and `closed`, with zero owned Spaces, so this lane establishes no product backend HIDE/SHOW sequence. The opening-roster step lacks a finer rejection field; the later failure-state snapshot's revision **10** must not be substituted for the rejected revision **5** to infer which roster predicate failed.

The last product read still finds all three fixtures visible at home 12. Its focus probe expects PID 33478/window 54 but observes front PID **367**, so exact focus is false even though the queried fixture application's focused-window attribute is 54. Full Host shutdown is **5.423667 ms**, released=true, followed by two confirmed physical home observations. Fixture quits and [CI workspace cleanup](full/ci-workspace-cleanup-receipt.json) also pass.

Full explicitly records `hostSampling=disabledByRequest`; all four original sampler metadata files say `NOT_RUN / diagnosticsDisabled`. There is no full sample text, and this failure is not attributed to sampling. The [candidate receipt](full/candidate.json) and provenance identify the exact release candidate; the candidate ZIP itself is not committed.

## Sampling and clock limits

Fast uses sampling. Its first confirmed external-press and first selection-preparation triggers share one actual [main action sample](fast/host-main-thread.sample.txt), as their metadata explicitly records. The observed capture markers are **417.922501458–421.173862708** in runner monotonic time. The later `reapedMonotonic=435.389598041` is process collection, not capture completion. The actual press and Host event fields use native uptime and remain identified separately from runner observations.

The late read-queue sampler is `NOT_RUN / noObservedR4ReadQueueDelay`. Startup metadata and sampler stderr are retained; the complete startup sample text remains in the verified original artifact and is hashed in provenance. No second sample text is manufactured for the shared trigger. The main sample does not cover the second selection or its later rejection.

## Artifacts and remaining work

[provenance.json](provenance.json) records exact artifact IDs, ZIP sizes/hashes, per-file SHA-256 and original artifact paths. The original artifacts are source context **15223460421**, fast **15223120735**, diagnostics **15222895382** and full **15223306790**. Original ZIPs and binaries are retained outside this compact git archive; no candidate archive is copied here.

All workflow lanes are terminal. The immediate unresolved product gate is continued real SHOW/HIDE/exact-focus behavior under unchanged acceptance deadlines, including the exact opening-roster rejection predicate on each lane's own revision. Fast and full use different build/sampling/runner conditions and are not a controlled timing comparison. Overall interaction refinement, stability and release remain unaccepted.
