# ff2617f5: full release completes two R4 selections; the third fails

Exact source: `ff2617f5ba8dcfde083a63903e54fd9ceaf0a5a7`, on the existing
PR #16 branch. [Run 46017442734](https://github.com/haohongfei2001-png/nearpane/actions/runs/46017442734).
**The full release Host completes two physical R4 selections, including hiding,
restoration and the exact-focus gate, then fails the third selection. Final
physical cleanup is confirmed. The fast Host fails its first selection. All
three direct engine runs pass. Swift source checks fail to compile new tests.** These receipts
describe this exact source and do not qualify the later test-only correction.

## Observed results

| Layer | Result |
| --- | --- |
| Rust source tests | PASS, 169 |
| Swift source tests | FAIL during compilation; tests did not execute |
| Other source checks | Worker build/protocol, evidence classifier, read-only context and native diagnostic checks PASS |
| Fast Host build | PASS |
| Fast direct engine | `FOREIGN_ENGINE_PASS`, 26 hide/restore request attempts, cleanup confirmed |
| Diagnostic direct engine | `FOREIGN_ENGINE_PASS`, 26 hide/restore request attempts, cleanup confirmed |
| Platform-only fallback | `NOT_RUN` in all three native lanes |
| Fast formal R4 | FAIL, `R4SwitchReadbackFailed`, one actual external R4 input |
| Fast physical product cleanup | Confirmed, with two original independent window-state reads |
| Full release build/signature | PASS |
| Full direct engine | `FOREIGN_ENGINE_PASS`, 26 requests, cleanup confirmed |
| Full formal R4 | FAIL, `R4SwitchReadbackFailed`; 3 real inputs, 2 confirmed selections, final cleanup confirmed |

The two engine passes concern direct engine acceptance; R4 is `NOT_RUN` in
those engine receipts. They do not establish the formal product input chain.
No fast formal R4 selection completes, and fast SHOW restoration, merge/split, yellow
routing, cold hidden preview, system handback and broader lifecycle cases are
not qualified.

## Fast exact first-click timing

The external press receipt records `inputUptime=541.8735919166667`, `issued=true`
and `axError=0`. The product enters `group-job-start` at 541.9128850000001,
**39.293 ms after the press**. It then records `navigation-job-failed` at
547.3651797916667, **5452.295 ms after group-job-start**.

There is no `group-bindings-fresh`, `worker-configured` or
`witness-read-completed` event in this fast run. Consequently there is no
witness phase duration or successful press-to-double-read latency to report.
The trace identifies the interval before worker admission, but it does not
identify which executor or individual native call accounts for that interval.
See [the original product log](fast/product.stderr.log),
[the product receipt](fast/product-result.json) and
[the derived timing summary](latency-summary.json).

The final independent physical readback shows target 53 and siblings 55 and
56 still visible on home desktop 12. Target 53 is the AX focused window, but
frontmost PID remains 366 rather than target PID 11834; exact focus is not
verified. No successful physical sibling hide is observed in this product
receipt.

The new shutdown trace records `released=true` in 2.648 ms. Its physical
return confirmation contains two complete independent reads of all three
windows visible on their original home with preserved frames, so product
cleanup is confirmed. Because this product run did not first establish a
hidden sibling, this cleanup does not prove a complete product HIDE→SHOW
cycle. The fixture and CI desktop cleanup receipts are retained separately.

## Startup sample and its coverage limit

Neither retained sample's main-thread stack contains the earlier synchronous
IconServices placeholder-rasterization chain. This is an observation of these
sample windows, not proof that all possible rendering stalls are gone.

The startup sample is requested at monotonic 533.912612708 for one second.
The first-request sample is requested at 536.044642958 for three seconds,
**5.829 seconds before the actual AXPress**. Its trigger is the request file,
not completion of accessibility discovery or the actual press. It therefore
does not establish coverage of the later 5.452-second group-job interval and
must not be used to place binding work on an executor. Sampler cleanup-time
`finishedMonotonic` is not a precise sampling-end timestamp.

## Source compile failures

The original [Swift compiler log](source/swift.stderr.log) records two distinct
errors in the new `StageWindowEngineTests`:

- Line 364 passes optional `entry.intent` to `Set<UUID>.contains` without
  unwrapping it; the following dictionary indexing uses the same optional.
- Line 449 embeds a throwing journal read on the right side of `&&` inside
  `#expect`, causing an unmarked throwing-operator error in macro expansion.

These test-compilation failures are separate from the already built fast
Host's native result. A later source correction requires its own source run.

## Full release: two physical selections, then a queued failure

[The original full product receipt](full/product-result.json) confirms these
states twice, with preserved frames and the exact-focus acceptance gate:

| Selection | Actual input uptime | Press-to-double-read | Independently observed state |
| --- | ---: | ---: | --- |
| 0, window 53 | 1119.428062 | 4618.169 ms | 53 visible on home 12; 55 hidden on 33; 56 hidden on 34 |
| 1, window 55 | 1126.579173 | 6989.324 ms | 55 restored from 33 to home 12; 53 hidden on 36; 56 remains hidden on 34 |
| 2, window 56 | 1134.065759 | Not confirmed | Eventually all three are visible on home 12; target focus is not verified |

`R4SwitchConfirmed` is emitted only after `waitForState(..., focus: target)`
returns two qualifying observations. The successful observation arrays retain
window states; they do not separately embed the focus diagnostic dictionary.
This is genuine partial HIDE→SHOW progress, but the complete product result
remains FAIL and the successful latencies are still seconds long.

There are 35 witness reads. The **sum of recorded durations**, not elapsed
wall time, is 14,322.221 ms. Opening and closing directory phases sum to
12,095.904 ms, approximately 84.5% of that total; binding sums to 521.242 ms.
The first witness is 562.462 ms, including 185.217 ms binding. Exact phase
values remain in [product.stderr.log](full/product.stderr.log), with aggregate
statistics in [the full timing summary](full/latency-summary.json).

### Timing and clock coverage

The helper's `inputUptime` and Host `uptime` use system uptime on this runner.
The following values are seconds in that common clock. A missing event is not
an inferred zero-duration operation.

| Event | Select 53 | Select 55 | Select 56 |
| --- | ---: | ---: | ---: |
| External press | 1119.428062 | 1126.579173 | 1134.065759 |
| Card handler trace | 1119.436782 | Not recorded for held route | Not recorded for held route |
| Navigation submit | 1119.440851 | 1126.579900 | 1134.066120, prior job running |
| Navigation dequeue | 1119.441462 | 1126.580269 | 1137.260950 |
| System confirmation | 1119.443225 | 1126.583545 | 1137.267766 |
| Group job start / fresh | 1119.443808 / 1119.551810 | Not recorded for held route | Not recorded for held route |
| Group choice entry / exit | 1119.552093 / 1125.011182 | No corresponding lifecycle event | No corresponding lifecycle event |
| R4 double-read confirmation | 1124.046233 | 1133.568500 | Absent |
| Navigation outcome | group result 1125.011324 | superseded 1137.260286 | failed 1137.268133 |

The first physical confirmation precedes group-choice completion by 964.949 ms.
The third press arrives 497.259 ms after the second physical confirmation,
while its navigation is still running. The third press waits 3195.191 ms to
dequeue. These receipts distinguish physical acceptance from navigation
completion; the harness does not wait for the latter before its next input.

The worker log records `health-connection`, status 4/detail 217, window 56,
then `spacesHealthReadFailed` with zero complete observations and 882 ms elapsed
against a 650 ms budget. **Those worker events contain no event timestamp.**
Their local order before worker closure is known; their exact location on the
Host uptime axis is not. The health elapsed field must not be presented as a
Host timestamp. This full lane has no recorded AXCannotComplete binding error.

Final shutdown returns `released=true`; two independent physical reads confirm
all original windows visible on home 12 with preserved frames. Product,
fixture and CI desktop cleanup are confirmed. Full sample text is omitted from
this compact set; original archives retain it, and sampler receipts are kept.

## Provenance

All copied JSON, logs and samples are byte-for-byte artifact entries.
[provenance.json](provenance.json) records each original path, size and SHA-256.
`latency-summary.json` is derived arithmetic, not a native receipt. No binaries
or candidate archives are included.

| Artifact | ID | ZIP bytes | ZIP SHA-256 |
| --- | ---: | ---: | --- |
| Source context | 15207780054 | 10268 | `ccbcc035fdfdfed5540376ed1dff0e649a5e5ea08f08587c3787ca99faafddd6` |
| Fast | 15207975331 | 24618506 | `aeead446e32bd5f08cfc0b3842f0e73d48df230795fe8d19c70f83e7b5a9b073` |
| Diagnostics | 15206661849 | 1458683 | `f154482ca7fb1bd32ea4c9eb6ef0b2e7f7cac09e93ec14c21fa66ac9db3087a5` |
| Full release | 15206873287 | 53240764 | `871f0105f438c9987c28b974479cfc67b9c017da4963ad72f233ad52ca118637` |

The original full candidate ZIP is 25,646,972 bytes, SHA-256
`3185c4f41a819149eb32c407bbfb324dd20a283720d489686b65e9056b0f30a6`.

The run uses cloud Apple Silicon macOS 27.0.1 / 26A434, SIP disabled. The
physical target has not been rerun. Continue the same PR and require actual
product hide, restoration, exact focus and confirmed physical cleanup before
claiming that the initial R4 chain is complete. The 750 ms ownership freshness
limit and original identity checks remain acceptance constraints.
