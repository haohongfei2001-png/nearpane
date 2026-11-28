# 5a1cfbc6: source passes; full R4 completes one selection, then rejects the next

Exact source: `5a1cfbc614545256e35057ac5234ae48dc7116ef`, on the existing
PR #16 branch. [Run 46018370133](https://github.com/haohongfei2001-png/nearpane/actions/runs/46018370133).
This revision fixes the two test-compilation errors from ff2617f5. **Source
checks pass. All three direct engine runs pass. The fast formal R4
attempt is BLOCKED before issuing a click because the retained accessibility
element changes its reported role and loses its identifier. Full release R4
confirms its first physical selection, rejects the second before the backend,
and confirms complete physical cleanup. The product result remains FAIL.**

## Original results

| Layer | Actual result |
| --- | --- |
| Rust source tests | PASS, 169 |
| Swift source tests | PASS, 215 passed and 1 skipped; 216 cases reported by Swift Testing |
| Other source checks | Worker build/protocol, evidence classifier, read-only context and native diagnostic checks PASS |
| Fast Host build | PASS |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 hide/restore request attempts, cleanup confirmed |
| Separate diagnostic engine | `FOREIGN_ENGINE_PASS`, 26 hide/restore request attempts, cleanup confirmed |
| Platform-only fallback | `NOT_RUN` in all three native lanes |
| Fast formal R4 | BLOCKED, `realExternalR4ButtonNotAccepted`, zero actual R4 inputs |
| Fast product physical cleanup | Confirmed by two complete independent window-state reads |
| Full release build/signature | PASS |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 requests, cleanup confirmed |
| Full formal R4 | FAIL, `R4SwitchReadbackFailed`; 2 actual inputs, 1 confirmed selection, final cleanup confirmed |

Engine acceptance and product acceptance remain separate. The fast formal product
run does not provide a press-to-witness duration, actual sibling hide, SHOW
restoration or exact focus switch. Broader product cases remain `NOT_RUN`.

## Exact pre-press failure

The initial readiness snapshot has a complete catalogue, three distinct
fixture groups, an ordinary desktop with a system UUID, and window dispatch
eligibility. This differs from the invalid ordinary-desktop state of d668's
fast lane.

The external accessibility helper traverses seven nodes and finds exactly one
matching target button, `current-desktop-window:11673:53`. Its first read has
role `AXButton`, the expected identifier, enabled state, press action, matching
window/panel ownership and a frame inside the R4 panel.

Immediately before pressing, the retained element reports role `AXStaticText`
and identifier read status `-25212`. The receipt preserves
`sameOriginalElement=true`, `prePressEvidenceChanged`, `issued=false`, and zero
rediscoveries. The helper therefore does not issue AXPress. This is an observed
accessibility-identity/readback problem during discovery; it does not establish
the cause of the view update or justify acting on the changed element.

The unmodified [external helper receipt](fast/r4-press-5824f825-3175-44db-816a-5161a37b2d91.result.json)
and [product receipt](fast/product-result.json) preserve the before/after
fields. There is no group job or worker witness to time in this lane.

The new shutdown trace has `released=true`, duration 7.865 ms, followed by
`shutdownReturnReadback.confirmed=true` and two independent reads confirming
all three windows visible on their original home with preserved frames.
Product, fixture and CI desktop cleanup are confirmed. As no product hide was
first established, cleanup alone does not demonstrate a HIDE→SHOW cycle.

Both startup and first-request samples are preserved. The request-file trigger
does not prove that an actual click occurred; here the helper explicitly
withholds it. Samples must not be used to attribute a nonexistent worker
witness or unobserved binding interval to an executor.

## Full release: successful initial hide, second initial-witness rejection

The first external AXPress is at uptime 653.2394898333333. The full product
records `R4SwitchConfirmed` at 656.7915893333334, **3552.096 ms** after the
press. Two independent physical reads show window 53 visible on home 12,
window 55 hidden on Space 33 and window 56 hidden on Space 34, with frames
preserved. The record follows the exact-target-focus `waitForState` gate.

The first group-choice call completes at 657.5509081666667, 759.319 ms after
physical confirmation; its group-job result follows at 657.551029. The second
press is at 658.4607289583333, after that completion. It dequeues immediately
at 658.461909 and confirms ordinary ownership at 658.46574475. Unlike ff2617f5's
third input, this attempt is not delayed by a running prior navigation job.

The explicit rejection is `stageActivationBeforeBackendRejected`,
`step=initial-witness`, at 659.26731320833335; `navigation-job-failed` follows
at 659.2727073750001. No worker nonzero-status fault or AXCannotComplete binding
failure is recorded. The final attempted-selection readback has all original
windows visible on home 12, while AX focus remains on 53 instead of target 55.
The second selection is not confirmed.

Twenty witness durations sum to 4541.218 ms; opening/closing directory phases
sum to 3803.234 ms, approximately 83.75%. Binding sums to 243.025 ms. The first
witness is 521.747 ms with 163.668 ms binding. The 18th and 19th read intervals
overlap, so summed durations must not be equated with elapsed wall time. See
[the original full log](full/product.stderr.log),
[the product receipt](full/product-result.json), and
[the derived timing summary](full/latency-summary.json).

Shutdown releases successfully in 1.612 ms and independently confirms all
three original windows visible on home 12 in two complete reads. Product,
fixture and CI desktop cleanup are confirmed, following an actual earlier
hide. This supports recovery in this run, not stable repeated selection or
complete interaction acceptance. Full sample text remains in the original
workflow archive; sampler receipts are preserved in this compact set.

## Provenance and limits

All copied JSON, logs and samples are byte-for-byte artifact entries.
[provenance.json](provenance.json) lists original paths, sizes and SHA-256 values.
No archive, binary or candidate ZIP is retained in this compact directory.

| Artifact | ID | ZIP bytes | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| Source context | 15206643387 | 24112 | `a22ab997e6156254a151bb8e2f735ecf31b24e9d4560b8b3fd867f4e85178806` |
| Fast | 15207321651 | 24603378 | `e9c9a70fcae354fc0b6514a383eaa7eeff114a7a4db954c83a9a312a4d0898e7` |
| Diagnostics | 15206891925 | 1455435 | `c8fe063a6ed36efe884176e8b4a453707b1179d5226d8ec0a167d4467794ae6a` |
| Full release | 15208640088 | 53234194 | `dc8aed3a2881d534fb47cec58c0fa0a114d2ee0bd4e126f01ef5a7eaa0eb7e31` |

The original full candidate ZIP is 25,646,818 bytes, SHA-256
`69a2f781357c00fa142aa8f05d04d8089cf5c18c7110ca85d0b06ef661261b8b`.

These are cloud Apple Silicon macOS 27.0.1 / 26A434, SIP-disabled results, not
a new physical-target run. Retain the same PR and require an actual formal R4
press followed by independently verified hide, restore, focus and physical
cleanup before advancing the core-chain claim. Source PASS and direct-engine
PASS remain useful but narrower evidence.
