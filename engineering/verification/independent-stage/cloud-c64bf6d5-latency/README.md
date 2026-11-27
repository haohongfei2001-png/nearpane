# Exact c64bf6d5 cloud R4 evidence

**Status: source PASS; both sampled fast and unsampled full R4 FAIL after one actual input and zero confirmed selections each.** Both Hosts confirm that all enrolled windows returned to their original desktop. Full also confirms CI-created desktop removal; fast's separate desktop removal remains unconfirmed and must not be reported as a complete cleanup PASS. Direct-engine success remains a separate result from the product R4 path.

Revision: `c64bf6d587247e512fb72c50a666d8e41c539e04`; tree: `24a1e22e7d432ab10868aea80057c59e004f1cbd`. Original PR #16 branch: `pro/independent-stage-engine-20261126`. [Workflow run 46037621099](https://github.com/haohongfei2001-png/nearpane/actions/runs/46037621099), created `2026-11-27T16:55:18Z`.

These are cloud macOS receipts, not target-Mac qualification. The direct-engine receipt records build `26A434`, SIP disabled and `exactTarget=false`. No threshold or acceptance rule is relaxed. This revision declares a short, explicit user activity for accepted sidebar jobs and their independent release tail; these observations do not establish App Nap as the cause of previous delays.

## Source gate

[The original source summary](source/summary.json) reports **180 Rust tests passed; 225 Swift tests passed and one skipped**. [The original Swift log](source/swift.log) ends with 226 tests in 34 suites passing after 6.976 seconds, including all five new activity lifecycle tests. [Raw Rust stdout](source/rust.log) from the terminal full artifact confirms 180 passed, zero failed, in 0.15 seconds; stderr and process result are also preserved. The source gate also passes evidence checks, worker build/protocol, native diagnostic and read-only context checks. It does not execute product R4 operations. [The complete candidate receipt](full/candidate.json) reports full build and bundle signature PASS for this exact revision.

## Native lanes

| Lane | Direct engine | Formal product R4 | Cleanup |
| --- | --- | --- | --- |
| diagnostics | `FOREIGN_ENGINE_PASS`; 26 hide/restore request attempts | `NOT_RUN` | Engine and CI-created desktop cleanup confirmed |
| fast, sampling enabled | `FOREIGN_ENGINE_PASS`; 26 hide/restore request attempts | `FAIL / R4SwitchReadbackFailed`; one actual external AXPress, zero `R4SwitchConfirmed` | Host window return confirmed; CI-created desktop removal unconfirmed |
| full, sampling disabled by request | `FOREIGN_ENGINE_PASS`; 26 hide/restore request attempts | `FAIL / R4SwitchReadbackFailed`; one actual external AXPress, zero `R4SwitchConfirmed` | Host window return and CI-created desktop removal confirmed |

The engine attempt count includes rejected or unverified requests by definition; it is not a count of successful R4 actions. None of the three lanes uses a platform-only fallback. See [diagnostics engine](diagnostics/engine-result.json), [fast engine](fast/engine-result.json), [full engine](full/engine-result.json), their runtime summaries, and the raw Host product results. Runtime summaries may add runner context; raw Host results remain byte-for-byte originals.

### Fast: actual input and activity lifetime

The independent helper records a real `AXPress` at native uptime **480.9825846667**, `issued=true`, `axError=0`, with the retained panel and exact button identity verified. The Host records one product input for `singletonCycle/0`, window 52/PID 9371. No confirmed selection appears in the product events. The last acceptance read at 488.99014525 confirms exact focus on window 52/PID 9371, but windows 54/PID 9371 and 55/PID 9378 remain visible on home 12 when they should be hidden. Exact focus alone therefore does not satisfy the transition.

The opt-in trace records one matching activity begin/end pair for job `315C1257-0747-41D0-8F51-F3F3EED3EC87`:

| Native event | Host/system uptime |
| --- | ---: |
| Activity begin | 480.9929853750 |
| Navigation dequeue, `taskPriority=25`, `userActivity=true` | 480.9944008333 |
| Acceptance shutdown enter | 489.0909932500 |
| Group activation returns `interrupted` | 489.3299506250 |
| Group-choice exit | 489.3300912500 |
| Activity end, `completionHolds=1` | 489.5732388750 |
| Shutdown exit, `released=true` | 489.6081162500 |

The activity end follows the navigation work's exit and covers its retained release tail. It ends once; the activity is not tied to the durable dispatch hold indefinitely. The activation interruption occurs after acceptance shutdown starts and must not be mislabelled as an earlier standalone failure.

[Independent phase extraction](fast/timing-analysis.json) pairs all 24 created/start events by read session and revision, with no unmatched pair. The maximum actual queue is **175.466 ms**; no observed read queue reaches 250 ms. Explicit action reads are created and started at priority 25, while independent reads can still appear at priority 17. This single sampled run does not establish that activity declarations caused the shorter queues.

The preparation takes **1,238.836 ms** on the `final-group-binding` path, including two directories and six physical reads. Six complete, nonoverlapping witnesses then take **4,188.506 ms** in total; their opening and closing directories account for **2,906.472 ms**. The enclosing interval from the first witness end to the post-launch witness start is **2,236.644 ms**. That interval includes journal work, backend preparation and intent guards; it is not an individually measured transport call. The worker's local panel-call plus main-queue durations sum to **394.112 ms**, but existing READY/LAUNCH/HEALTH logs lack absolute boundaries, so they cannot partition the remaining enclosing interval.

The last, second focus-confirmation witness completes **238.692 ms after acceptance shutdown begins**. There is no observed external sibling HIDE before the unchanged action limit is exceeded; the controller's own canary hide/restore is a separate operation. The roster also includes Finder window 30 in the physical witness, so this is not an identical workload to earlier lanes with only three fixture windows or desktop focus represented as nil.

### Fast: two distinct cleanup scopes

[The Host result](fast/product-result.json) records shutdown duration **517.370 ms**, `released=true`, `cleanup=true`, and two successful physical readbacks for all three fixture windows at home 12 with preserved frames. [The fixture receipt](fast/fixture-cleanup.json) records both `ownedWindowQuit` commands with exit 0.

[The CI workspace receipt](fast/ci-workspace-cleanup-receipt.json) independently records **`status=FAIL`, `cleanup=false`, `reason=createdDesktopIsNotConfirmedEmptyOfOrdinaryWindows`**. It returned to original desktop 1, but temporary ordinary desktop 12 remained in the observed inventory. The outer [runtime summary](fast/runtime-summary.json) consequently reports `status=UNKNOWN / ciOwnedWorkspaceCleanupUnconfirmed`. The receipt does not identify which window prevented confirmation; this record does not invent one or treat process exit 0 as a positive removal receipt.

### Fast sampling and clock limits

The actual-press and selection-preparation diagnostics reference the same physical `host-main-thread.sample.txt`; the latter records `sharedWith=host-main-thread`. Each has its own trusted trigger evidence. The main sample and raw sampler stderr are retained here. The late queue sampler is explicitly `NOT_RUN / noObservedR4ReadQueueDelay`; this means no qualifying queue trigger was observed, not that the product passed.

The shared sample's `captureStartObservedMonotonic=481.7596535` and `captureCompletionObservedMonotonic=485.954191041` are **runner observations of capture progress markers**. `reapedMonotonic=490.02698825` is a later process-reaping event, not capture completion. These fields must not be silently mixed with native source uptime or treated as exact native event boundaries. Startup metadata and raw stderr are also retained; the large startup sample text remains in the exact-head artifact with its hash in the provenance manifest.

The main sample includes four samples of `NP_SW_POLL` through channel receive to Darwin `poll` on default-QoS cooperative queues. These are not observed 2 ms sleep or lock-wait stacks. Sample counts do not measure the backend interval or prove an effective-priority cause. Startup sampling contributes no necessary additional action-phase stack to this compact record.

## Full: actual unsampled failure and confirmed cleanup

[The raw full Host result](full/product-result.json) records a real external AXPress at **1159.820932**, `issued=true`, `axError=0`, targeting window 53/PID 38492. It records one actual input, zero confirmed selections and `FAIL / R4SwitchReadbackFailed`. At the last switch read, windows 53/55/56 remain visible on home 12. Focus is **not** verified: the expected window number is 53 but the front process is PID 352, not PID 38492.

Full records one activity begin/end pair for job `04CE3A6B-0C06-4164-8360-AA028BFD5418`: begin **1159.8354147917**, dequeue **1159.8358183333** with priority 25 and `userActivity=true`, group activation error **1164.246589**, group-choice exit **1164.2467183333**, and activity end **1164.3895314167** with one completion hold. Its **4,554.117 ms** lifetime covers the navigation work and its retained completion; it does not extend until acceptance shutdown at 1168.3353455. Here activation returns `interrupted` **before** acceptance shutdown; this ordering is different from fast and must be retained.

[The full timing analysis](full/timing-analysis.json) pairs 11 actual created/start events. A twelfth created task has no observed start and is not assigned a fictional queue duration. The maximum queue among observed starts is **176.548 ms**; the two tasks aligned with action-directory calls queue only **10.590 ms** in total. Preparation succeeds in **347.866 ms** on `existing-group-binding`, a different path from fast's final binding preparation.

The first witness starts at **1160.2552920417** and rejects at **1164.2459752083**, after **3,990.683 ms**, with `step=physical-window-observation`, window 56/PID 38498, three bindings, zero claims and sequence zero. No complete witness exists. Its opening directory has completed by **1160.5856023333**; the remaining **3,660.373 ms** includes roster, binding and physical work, not a measured physical-read duration alone. The worker has only READY and CLOSED records, so this lane never enters the backend/canary interval observed in fast and has no external window write.

The exact inner rejecting guard remains unknown. There are no `stagePhysicalReadRejected` events and all 12 recorded Finder structure reads are positive; absence of an inner rejection event does not identify the earlier/later witness check. The next Dock-expiry log is **1,325.685 ms after** witness rejection, but a later published event alone cannot prove all earlier dynamic eligibility checks passed. Source inspection distinguishes the witness's current 12-second directory-freshness evaluation from the Dock path's already published boolean/epoch; this path does not independently recompute the retained Dock interval's 750 ms age. The record therefore preserves the unresolved alternatives: before/after witness unchanged checks, inner async observation entry/return checks, or binding equality. A cached failing guard label is needed to distinguish them without extra live queries.

The original full runtime and derived product policy both record **`hostSampling=disabledByRequest`**. All four sampler metadata files explicitly record **`NOT_RUN / diagnosticsDisabled`**, and there is no sample text. The raw Host product result is unchanged and does not gain a runner policy field. Disabled diagnostics are not absent input; the real input receipt is retained. Fast is a sampled debug Host and full is an unsampled release candidate on a different lane; this is not a controlled sampling A/B experiment.

Full shutdown returns `released=true` after **2.5015 ms**. Two independent physical reads confirm all three fixture windows at home 12 with preserved frames, and the Host reports `cleanup=true`. [The CI cleanup receipt](full/ci-workspace-cleanup-receipt.json) separately confirms `cleanup=true`, phase `cleaned`, original desktop 1 restored. Both fixture quit commands exit 0. These positive receipts do not turn the failed R4 selection into a passed hide/restore chain.

## Provenance and retained scope

[provenance.json](provenance.json) lists every copied raw artifact entry, byte size and SHA-256, the independently derived timing analysis, and the omitted startup sample hash. The artifact names and workflow metadata identify this exact head; all downloaded ZIP sizes and hashes were independently checked before extraction. No binaries or candidate ZIPs are checked into this directory. The original inner full candidate ZIP is 25,699,527 bytes, SHA-256 `0a1fe15710a19323c85b7a6143e92955e93004e5863eb2c0a8767ea4e104b578`; it remains in the full artifact.

| Artifact | Job | ID | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| source context | 140636922403 | 15219052080 | `514e54a1ef2a4b7593c8d31fbf8566201c9c4a1df25333505de479479361e7dc` |
| fast | 140636922009 | 15218592098 | `f47d0fd40bb849f3768c6266f6949ada553f7e3090ae8896b0b24773f32b5f96` |
| diagnostics | 140636922547 | 15219646024 | `733197332768595dbf9ed0e15db38a17a5f402acedee40eb30a12732385cce75` |
| full | 140636922403 | 15219113852 | `9c1020d32f9c924bacdc84dfc7d0fac879d41dc001609fd8a615c7871ecc4b90` |

## Outstanding work

1. Distinguish the unsampled full interruption's exact failing guard using cached existing results and phase labels, while preserving query count, short-circuit order and current thresholds. This directory records the pre-diagnostic failure, not a subsequent fix PASS.
2. Retain the unpartitioned backend interval as an evidence limit; if needed, instrument existing request/terminal receipt boundaries without adding native reads, actions or relaxing the current proofs.
3. Demonstrate consecutive complete product selections, real foreign-window HIDE/SHOW and exact focus confirmation, followed by positive cleanup at both Host and workspace scopes. This partial run does not pass that gate.
4. Keep target-Mac evidence separate; only after the formal chain is established proceed to broader interaction refinement, stability acceptance and release.
