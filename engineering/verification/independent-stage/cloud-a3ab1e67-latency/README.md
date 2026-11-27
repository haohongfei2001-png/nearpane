# a3ab1e67: startup admission block before the first R4 input

Exact source: `a3ab1e675e9250f7b5f5f56b12d28c0facfbfd0d` on the existing PR #16
branch. [Run 46012254457](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457)
has completed all lanes. **The full release R4 result is UNKNOWN because product
restore was not confirmed; the fast R4 result is BLOCKED before input.** The full
build and signature pass while source checks fail as recorded below. These
original results do not qualify subsequent code changes.

## Observed outcomes

| Layer | Actual result |
| --- | --- |
| Fast foundation/debug Host build | PASS |
| Fast direct foreign-window engine | PASS, 26 hide/restore requests, cleanup confirmed |
| Fast formal R4 product | BLOCKED, `fixtureGroupsNotReady`, zero actual R4 inputs |
| Fast product/fixture/CI-owned desktop cleanup | Confirmed |
| Full Rust source tests | 166 PASS |
| Full Swift source tests | 205 tests, one recorded issue; FAIL |
| Other full source checks | Worker/protocol, evidence classifiers, read-only context and native diagnostic tests PASS |
| Separate diagnostic engine | FAIL, `repeatedSwitchFailed`, six hide/restore requests; cleanup confirmed |
| Complete release runtime | UNKNOWN, `productionRestoreIncomplete`; one real R4 input, one sibling physically hidden |

No R4 click-to-hide latency can be reported because this fast run never reaches
a real button press. Merge/split, yellow routing, cold hidden preview, system
handback, crash/restart and lifecycle product cases remain `NOT_RUN`.

## Startup stall and missing sample

The first catalogue physical read takes approximately **72.610 ms**, but its
result is already **12.454 seconds old** in the failure snapshot. The Dock
observation likewise takes approximately 2.475 ms but is processed 12.614 seconds
after its start. The ordinary observation at uptime 348.464372875 is processed
at 361.078532875 and correctly rejected as expired. This is a delayed delivery /
Host-processing observation; the available evidence does not identify the exact
blocking function.

`lastReadiness` has no snapshot and no fixture groups. The later failure snapshot
has revision 1 and original window lifetimes, but it is stale and no visible
group is bound. The preview metrics show zero counted capture starts and delivered frames. The
capture counter increments only after asynchronous stream construction returns,
so these counters do not exclude an in-progress SCStream constructor. No sample
attributes this startup stall to SCStream.

The original sampler receipt is explicitly `NOT_RUN`, reason
`firstR4RequestNotObserved`. Sampling began only on a real R4 request in this
revision. There is no main-thread stack for this startup block and no new
witness phase-duration receipt. Preserve that limitation instead of inferring
that the first-input chain ran.

## Source failure is separate

Swift compilation finishes in **265.61 seconds**. The executed test run then
finishes in **4.696 seconds**; it is not an unbounded AsyncStream test hang.
All prior `DesktopPreviewContinuityTests` failures and the slow window-hint
scheduling test pass in this run.

The single remaining failure is
`StageHostCaptureSchedulingTests.coldCaptureConstructionAllowsTheInputActorToProgress`
at line 14: `result.progressed && !result.mainThread`. The test currently uses a
two-second semaphore wait for a main-actor callback while other Swift tests run
concurrently. The combined assertion does not say which operand failed. It is
not evidence, on its own, that stream construction executed on the main thread.
The original logs are preserved, and subsequent changes must verify a bounded,
deterministic scheduling test without simply raising a time limit.

## Separate diagnostic variance

The diagnostic VM passes initial visible bindings, launch canary, initial yellow,
foreign round trip, same-app independence and cross-app grouping. Its first
repeated-switch scenario fails after six hide/restore requests; cleanup is
confirmed. The separate fast VM passes all direct engine checks and 26 requests.
Both receipts retain their own results. Neither the diagnostic failure nor fast
engine success is substituted for a formal product result, and no cause is
assigned to the UI source changes from this variance alone.

## Provenance

- Cloud OS: macOS 27.0.1 / build 26A434 / Apple Silicon / SIP disabled.
- Jobs: fast `140550440263`, diagnostics `140550440726`, full `140550440809`.
- [Fast artifact 15203979492](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457/artifacts/15203979492): 24,306,302 bytes; independently checked SHA-256
  `16c8cf33eda7c3da656f63392fe391352e4e51d7f070cd7850ff52c9304cdc3f`.
- [Full-source context 15203444688](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457/artifacts/15203444688): 22,465 bytes; independently checked SHA-256
  `ea383fdf3aa4f3e0adc7e0d020d9ac4ef9574c94da5644e86ffa85027582b80f`.
- [Diagnostics artifact 15203859213](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457/artifacts/15203859213): 1,451,061 bytes; independently checked SHA-256
  `3c7c38f06336eb27650fc1da275c829122664a0c5f2f8b563802cbd9d9dc4579`.
- [provenance.json](provenance.json) maps preserved byte-for-byte originals to
  artifact entry names and hashes. Application binaries and archives are omitted.

Original evidence: [fast runtime](fast/runtime-summary.json),
[product receipt](fast/product-result.json), [product log](fast/product.stderr.log),
[unexecuted sampler receipt](fast/host-main-thread-sample.json),
[fast engine](fast/engine-result.json), [diagnostic runtime](diagnostics/runtime-summary.json),
[diagnostic engine](diagnostics/engine-result.json),
[full source summary](full-source/summary.json), [Swift test log](full-source/swift.log),
[Swift build log](full-source/swift.stderr.log).
Each runtime lane also retains raw engine logs, fixture exits and CI-owned
workspace cleanup receipts.

## Continuation

Investigate the initial catalogue / Host processing stall with a separate bounded
startup sample, while retaining the actual-press sample. Correct the capture
scheduling test's coordination, preserve the 750 ms ownership freshness limit,
and rerun the same production path on the changed commit. Use newly added
witness phase timings only when actual witness reads execute. The completed full release runtime is appended below, retaining the original
fast, source and diagnostic results intact.


## Completed full runtime: one real hide, incomplete restore

[Full artifact 15206345777](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457/artifacts/15206345777)
is 52,708,786 bytes; independently verified SHA-256
`7811c23b25ed8446ecc16633fa1fdef83d433288c3f98207ee0d0141a00591d0`.
The inner candidate ZIP is 25,426,673 bytes, SHA-256
`c9b2f6e80c7706a72799020aa17967ce239c18569378572e908ceac69acae932`.
The candidate receipt retains `sourceChecks=FAIL`, `fullBuild=PASS`, and
`bundleSignature=PASS`; this build is not a qualified release.

The full lane's direct engine passes all checks and 26 hide/restore request
attempts, including confirmed engine cleanup. Its formal R4 run issues **one real
AXPress**. The last independent readback confirms target window 53 focused at
home on Space 12, same-app sibling 55 genuinely offscreen on hidden Space 33,
and other-app sibling 56 still visible at home. This is a partial physical
transition, not a completed group switch.

The group begins at uptime 1203.864622917; new bindings arrive at 1206.179086125.
Eleven witness reads follow. Their directly instrumented phases total:

| Phase | Total across 11 reads | Median per read | Range per read |
| --- | ---: | ---: | ---: |
| Complete witness | 4,624.113 ms | 431.042 ms | 283.222–556.946 ms |
| Opening directory | 1,927.876 ms | 152.783 ms | 120.876–255.435 ms |
| Binding | 131.839 ms | 2.581 ms | 1.597–103.976 ms |
| Physical windows | 708.526 ms | 48.474 ms | 40.586–118.439 ms |
| Closing directory | 1,855.874 ms | 139.867 ms | 119.311–289.002 ms |

Opening and closing directory work account for approximately 82% of measured
witness duration. These are exact phase receipts for this run, not a throughput
benchmark or a comparison across different VMs. The main-thread sample is mostly
idle (58 of 66 samples waiting in the run loop), consistent with substantial
asynchronous directory work; it does not provide per-suboperation attribution.

The pre-cleanup product result is `FAIL/R4SwitchReadbackFailed`. The final product
result becomes **`UNKNOWN/productionRestoreIncomplete`, cleanup=false**. The
worker log records a `release-member` fault, status 2/detail 206, for hidden
window 55. Later the worker observes parent exit and reports `released`, owned 0,
engine destroyed. That terminal worker result is preserved but does not replace
the missing independent physical restoration proof. Fixture exits and CI-owned
desktop cleanup are confirmed separately. The product cleanup must remain
unconfirmed; no crash/restart or lifecycle product qualification follows.

Original full receipts: [runtime](full/runtime-summary.json),
[product](full/product-result.json), [R4 press](full/r4-press-result.json),
[phase timings](full/product.stderr.log), [main-thread sample](full/host-main-thread.sample.txt),
[worker log](full/worker.jsonl), [worker identity](full/worker-lifecycle.json),
[engine](full/engine-result.json), [candidate](full/candidate.json),
[fixture exits](full/fixture-cleanup.json),
[CI-owned desktop cleanup](full/ci-workspace-cleanup-receipt.json).
