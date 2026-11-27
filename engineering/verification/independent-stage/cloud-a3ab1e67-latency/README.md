# a3ab1e67: startup admission block before the first R4 input

Exact source: `a3ab1e675e9250f7b5f5f56b12d28c0facfbfd0d` on the existing PR #16
branch. [Run 46012254457](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012254457)
has completed the fast runtime, diagnostics and full source checks. **The full
release candidate build/runtime is still pending in this record.** These original
results do not qualify subsequent code changes.

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
| Complete release runtime | PENDING |

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
group is bound. The preview metrics show zero capture requests, zero streams and
zero delivered frames. Consequently this failure cannot be attributed to an
observed SCStream constructor call in this run.

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
witness phase timings only when actual witness reads execute. Append the full
release runtime when its exact-source artifact finishes, keeping these fast,
source and diagnostic results intact.
