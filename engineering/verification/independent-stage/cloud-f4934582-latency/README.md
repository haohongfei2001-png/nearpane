# Cloud f4934582: source passes; fast restoration remains unconfirmed

**The sampled fast lane issues one real R4 input and confirms no complete switch. Its final status is `UNKNOWN / productionRestoreIncomplete`: Host cleanup/release is false even though independent physical return reads and CI workspace cleanup are true. The unsampled full lane also confirms no switch and exits at `current-intent` before creating a product session or witness.** All lanes are terminal; no product PASS is claimed.

Exact source `f4934582e3b3634117b4d44ca2debbdd0e3adac4`, tree `0d0e2527010fea8b50d1fde5dbcb5af035ef0958`, parent `6d05807917e54b57f462e7882e34300e55cde3b4`, original PR #16 branch. [Workflow 46048445707, run 58](https://github.com/haohongfei2001-png/nearpane/actions/runs/46048445707) was created at `2026-11-27T18:18:17Z`.

## Source tests: functions and parameter cases are distinct counts

[The original source summary](source/summary.json) records **180 Rust passed, 228 Swift passed and one skipped**. [Swift stdout](source/swift.log) reports **229 tests in 37 suites**, completed in **6.838 s**. The new `onlyAnActualSampleAfterBothEntryClocksCanReplaceTheFreshRead(mode:)` test function explicitly passes **all 16 parameter cases**, in **6.638 s**:

`afterEntry`, `beforeEntry`, `wallClockOnly`, `uptimeOnly`, `equalWallClock`, `equalUptime`, `otherSession`, `wrongRevision`, `incompleteCatalog`, `cappedInventory`, `backwardsNativeTime`, `futureWallClock`, `epochChanged`, `sessionUnavailable`, `observationStopped`, `actionCancelled`.

The parameter executions must not be added to the framework's function count as 16 extra test functions. [The original Swift XML](source/swift.xml), obtained from the full artifact, contains **229 `<testcase>` function entries: 228 without failure/error/skip and one skipped; zero failures and errors**. The new parameterized function is exactly **one** XML entry, with time `6.638093958`. Its 16 parameter executions are established separately by stdout. [Rust stdout](source/rust.log) and [C identity stdout](source/r4-file-identity.log) are also retained; C records **13 passed, zero failed, zero window writes**, and the strict C compile receipt passes. Source PASS is separate from product runtime acceptance.

## Sampled fast product

[The original product result](fast/product-result.json) records `actualR4Inputs=1`, `dispatchAttempted=true`, zero `R4SwitchConfirmed` events, and final **`UNKNOWN / productionRestoreIncomplete`**. Before cleanup, its recorded status/reason is **`FAIL / R4SwitchReadbackFailed`**.

The external helper issues an actual AXPress at **626.865932083**, receipt uptime **626.888668875**, selecting window **49 / PID 14256**. It records `issued=true`, `axError=0`; request discovery is not used as the input timestamp.

At the last selection read, all three fixtures are visible at home **12**. The read expects exact focus on PID 14256/window 49 but observes front PID **365**. The queried fixture application's focused-window attribute is 49, which does not establish foreground focus. Windows 51 and 53 fail the required hidden-state comparison.

This lane records one completed witness and no `witness-read-rejected` or `rosterRejection` event. Its after-action trace contains no `reusedPrior=true` result. Thus it does not provide a positive runtime instance of the new pending-read reuse branch or the rejected-roster snapshot diagnostic. Original [Host stderr](fast/product.stderr.log) and worker logs preserve the backend and release timeline; no specific roster failure is inferred from a later snapshot.

All **three** recorded after-action directory calls complete and report `reusedPrior=false`. The only prior sample, revision **3**, begins at native uptime **626.819867833**, with wall-clock `sampledFrom=1795803832.263053`. Both precede that action's corresponding entry boundaries, **626.894002958** and **1795803832.337188**, by approximately **74.135 ms**; the sample also begins before the actual external press. It is correctly rejected for reuse, and the action receives a new real revision **4**. Native and wall-clock values are compared only within their own clock domains. This negative runtime case does not demonstrate a production speedup from a positive reuse hit.

The first witness completes from **627.177792** to **627.996122**, **818.329 ms**. Activation reports unavailable at **631.697459**, **3701.337 ms** after that completed witness. This is a later activation/backend interval, not an initial roster rejection. A concurrent automatic revision-7 read records `readerAwaitMS=3546.607`, but it is not consumed by an explicit `readAfterAction` call and is not counted as direct selection waiting.

## Cleanup scopes remain separate

| Receipt scope | Actual fast result |
| --- | --- |
| Product `cleanup` | **false** |
| Host shutdown `released` | **false** |
| Independent physical `shutdownReturnReadback.confirmed` | **true**, two observations |
| Fixture quit commands | Both exit 0 |
| CI workspace cleanup | **true** |

Host shutdown runs from **635.129012458** to **635.335601875**, **206.589417 ms**, with release unconfirmed. The independent physical return receipt subsequently confirms all enrolled windows at home, but that narrower observation does not change Host cleanup to true. The original final `UNKNOWN` result is preserved, not reduced to its pre-cleanup failure or replaced by the positive physical/CI receipts.

The original worker log records **`release-pending`, status 2, detail 225, flags 128, owned 1**: a canary resource has not received confirmed release. Fixture windows being at home does not prove that owned resource is gone. CI cleanup is an outer cleanup receipt and does not retroactively confirm the Host's failed release.

## Unsampled full product: exits at current intent before witness

[The full product result](full/product-result.json) records **`FAIL / R4SwitchReadbackFailed`**, one actual external R4 input and zero completed switch confirmations. The helper issues the input at **1152.456887167**, selecting window **53 / PID 39515**.

Selection preparation succeeds at **1155.370630458**, step `existing-group-binding`, duration **2860.694875 ms**. The only after-action directory call completes at revision **5** in **2758.554708 ms**: **1914.894958 ms** waiting on a prior read, then **843.606375 ms** for a new read. It reports `reusedPrior=false`. The prior revision **4** native sample begins at **1152.547403667**, before this action's native boundary **1152.594376750**. Its wall-clock sample likewise precedes its wall-clock boundary. The sample is approximately **46.973 ms** too early for this action and is correctly not reused; the fact that it begins after the external press does not make it later than the subsequent action-read boundary.

The Host then enters group choice and completes its installed-environment attestation. Group choice exits at **1155.411466667**, `completed=false`, **`lastPhase=current-intent`**. The recorded rejection is approximately **2954.580 ms after the actual input**, before the later acceptance shutdown. The navigation issue reports an operation already in progress, but that message alone does not prove another input or job occurred. This lane records no product session creation, witness event, backend HIDE/SHOW or `rosterRejection` event. It is not an initial-roster rejection or evidence of spending the whole acceptance deadline in that stage.

The last product read finds all three fixtures visible at home 12; the target application reports focused window 53, but front PID **370** does not match target PID 39515, so exact focus fails. Full shutdown runs from **1160.676918500** to **1160.686838292**, **9.919792 ms**, with released=true and cleanup=true. Two independent physical home observations, fixture quits and [CI cleanup](full/ci-workspace-cleanup-receipt.json) also pass. Those cleanup receipts do not establish a HIDE→SHOW round trip for this uncompleted selection.

Full explicitly records `hostSampling=disabledByRequest`; all four sampler metadata files say `NOT_RUN / diagnosticsDisabled`, and no full sample text is manufactured. [The candidate receipt](full/candidate.json) identifies the exact release candidate; its ZIP is hashed in provenance and omitted from git.

## Direct engine and platform fallback

[The fast direct-engine result](fast/engine-result.json) and [full direct-engine result](full/engine-result.json) are each **`FOREIGN_ENGINE_PASS`**, with **26 hide/restore request attempts** and cleanup=true. They do not replace their later R4 product results.

The diagnostics job is green, but [its direct-engine result](diagnostics/engine-result.json) is **`BLOCKED / candidateCanaryNotConfirmed`**, with **zero foreign-window hide/restore requests**, cleanup=true and the functional checks NOT_RUN. [The original engine log](diagnostics/engine.log) records launch-canary operation 8 returning status **4**, detail **214**, owned **2**, unverified. Its [stderr](diagnostics/engine.stderr.log) identifies `restore-member` as the failed canary step. A later cleanup release is verified with owned=0, and CI cleanup succeeds.

The separate [platform diagnostic result](diagnostics/platform-result.json) is **`PLATFORM_FOREIGN_PASS`**. Product R4 is NOT_RUN on this diagnostics lane. Platform fallback PASS, direct-engine BLOCKED and product NOT_RUN are intentionally separate recorded outcomes.

## Sampling, artifacts and remaining gate

Fast uses one main action sample shared by the confirmed-press and selection-preparation triggers; both metadata files reference [the same sample text](fast/host-main-thread.sample.txt). Runner-observed capture markers are **627.166086750–631.519100083**. `reapedMonotonic=635.639522541` is later process collection, not capture completion. Native input/event uptimes and runner observations retain their own clock labels.

The late queue sampler is `NOT_RUN / noObservedR4ReadQueueDelay`. Startup metadata and stderr are preserved; the omitted startup sample text remains in its verified artifact with its hash recorded. A shared trigger is not represented as an additional physical sample.

[provenance.json](provenance.json) records source context artifact **15223274101**, fast **15223278954**, diagnostics **15222183947** and full **15224446395**, with exact-head ZIP hashes and per-file original paths/hashes. No binary or candidate ZIP is committed.

Both product lanes are terminal without a complete R4 switch. Neither records a positive `reusedPrior=true` hit or a rejected-roster snapshot, so the new source tests do not become production branch coverage by implication. The remaining gates are actual complete switching, confirmed backend restoration and exact focus under the unchanged deadlines, with the observed fast canary/release and full current-intent failures kept distinct. These results do not grant interaction, stability or release acceptance.
