# d230e38c: first R4 latency fix, incomplete native result

Exact tested source: `d230e38c0cc384b820c4ed2cdb5223f777eef7d4`, on the existing
PR #16 branch `pro/independent-stage-engine-20261126`.

This folder preserves original results from [run 46010109426](https://github.com/haohongfei2001-png/nearpane/actions/runs/46010109426).
The fast and full runtimes and source step have finished. **Both formal R4
product paths fail.** The full release build and signature pass, while source
tests fail as recorded below. No subsequent-fix pass is claimed. The separate
diagnostic job passed.

## Current result

- Fast foundation/debug R4 Host build: PASS.
- Fast formal R4 product: **FAIL**, `R4SwitchReadbackFailed`; one actual external
  `AXPress`, error 0. Product, fixture and CI-owned desktop cleanup are confirmed.
- The first R4 action reaches fresh bindings, worker setup and eight completed
  physical witnesses. Exact target focus eventually verifies, but both siblings
  are still visible on their original ordinary desktop at the last readback.
- The activation's later `interrupted` result occurs after the runner's eight-second
  physical-state deadline and may reflect acceptance cleanup cancellation. It is
  not independently identified as a new ownership failure.
- Full source: Rust **166 PASS**; Swift run reports **204 tests with four issues**.
  Worker/protocol, evidence classifiers, read-only context and native diagnostic
  checks pass. The failed source step prevents qualification even if another
  build or runtime subsequently succeeds.
- Merge/split, yellow routing, cold hidden preview, system handback, crash/restart
  and lifecycle product checks remain `NOT_RUN` in the fast result.

## Observed latency and remaining setup work

| Fast-lane event | Uptime (seconds) |
| --- | ---: |
| Production card press | 686.835215417 |
| Group job begins | 686.889603167 |
| New three-window bindings | 688.795627250 |
| Worker configured | 688.855790125 |
| First complete witness | 689.635337167 |
| Eighth complete witness | 695.002555667 |
| Activation reports interruption | 695.003079125 |

Bindings take approximately 1.906 seconds after group-job entry. Earlier in the
same run, before the successful press, one 4.381 ms Dock read arrives 2,195.091 ms
late and is correctly rejected by the existing 750 ms freshness boundary.

The original sample now places **16 of 26 main-thread samples** in
`DesktopWindowGallery.run` -> `WindowFrameStream.init` -> `SCStream.init` ->
CoreAudio audio-clock initialization. This is evidence for remaining synchronous
stream-construction work, not a precise elapsed-time attribution. Eight completed
witnesses and verified focus are progress beyond the previous admission failure;
they do not establish that real window scheduling is complete. Different runs
and build modes are not treated as a controlled speed comparison.

## Exact Swift failures

Original output is preserved in [full-source/swift.log](full-source/swift.log).

- `DesktopPreviewContinuityTests.cappedInventoryKeepsTheReadOnlyCardOnlyOnItsVerifiedDesktop(changedHome:)`:
  readiness expectation fails for both `changedHome=false` and `true` at line 38.
- `DesktopPreviewContinuityTests.aSpaceNotificationRetainsOnlyPresentationUntilTheNextConfirmedRoster`:
  expected lifetime is absent at line 119.
- `StageHostObservationSchedulingTests.aSlowWindowNumberHintDoesNotBlockTheInputActor`:
  `observed.finished && !observed.mainThread && observed.responsive` fails at line 28.

These are executed test failures, not compilation errors or passes inferred from
an expanded filter. Subsequent source changes need their own exact-commit run.

## Separate engine failure

The fast lane's direct engine test passes initial visible bindings, initial yellow,
foreign round trip, same-app independent windows, cross-app grouping and all three
A-to-B-to-C-to-A cycles. The later `yellow-button-retire` returns status 2/detail 218.
The original worker stderr records `health-owned-readback` status 2/detail 206 for
window 56 on hidden Space 27, with zero complete observations, elapsed 320 ms and
budget 650 ms. Engine cleanup confirms all original windows and zero owned Spaces.
This failure predates the product launch and is recorded independently from the
formal R4 latency result; its cause is not assigned to the new UI changes.

## Provenance and original receipts

- Cloud OS: macOS 27.0.1 / build 26A434 / Apple Silicon / SIP disabled.
- Fast job: `140543151847`; full job: `140543151879`; diagnostic job: `140543151515`.
- [Fast artifact 15202788287](https://github.com/haohongfei2001-png/nearpane/actions/runs/46010109426/artifacts/15202788287): 24,420,795 bytes; independently verified SHA-256
  `4a656f8918c8609de0c921166a95cb9a25f51ed35f3c441a19728d62dfc44c3e`.
- [Full-source context artifact 15204032126](https://github.com/haohongfei2001-png/nearpane/actions/runs/46010109426/artifacts/15204032126): 25,458 bytes; independently verified SHA-256
  `02dd5840bfa48d46a40c0d97b05b617b9c3e892e782f0ad86302987c134ec61a`.
- [provenance.json](provenance.json) maps every preserved byte-for-byte original
  to its artifact entry and SHA-256. Archive binaries are not duplicated here.
- [Fast runtime](fast/runtime-summary.json), [product result](fast/product-result.json),
  [R4 input](fast/r4-press-result.json), [phase log](fast/product.stderr.log),
  [main-thread sample](fast/host-main-thread.sample.txt), [worker log](fast/worker.jsonl).
- [Engine result](fast/engine-result.json), [engine phases](fast/engine.log),
  [engine diagnostics](fast/engine.stderr.log), [worker lifecycle](fast/worker-lifecycle.json),
  [fixture cleanup](fast/fixture-cleanup.json), [CI workspace cleanup](fast/ci-workspace-cleanup-receipt.json).
- [Full source summary](full-source/summary.json), [Swift build stderr](full-source/swift.stderr.log),
  [read-only console context](full-source/windowserver-context.json).

## Continue on the same PR

Complete the initial-roster/observer corrections and remove stream construction
from the input actor, retaining current identity and freshness checks. Run the
same exact-commit full and fast product paths. Require actual sibling hiding,
restoration and focus with confirmed cleanup before proceeding through the
existing broader interaction/stability scenarios and release qualification.
The complete d230 full runtime is appended below without replacing the original
fast-lane and source failures.


## Completed full release runtime

The [full artifact 15203674146](https://github.com/haohongfei2001-png/nearpane/actions/runs/46010109426/artifacts/15203674146)
is 52,695,623 bytes; independently verified outer SHA-256:
`dc72b22cce114545815e38991fea785905cedbe88b38c6190503c53de2f09049`.
The inner complete candidate ZIP is 25,419,936 bytes, independently verified
SHA-256 `7bbeea0558eecd9364f51e3f293774ba6015a359c34996bf02c77e2c2e040776`.
Its original build receipt correctly retains `sourceChecks=FAIL`, alongside
`fullBuild=PASS` and `bundleSignature=PASS`.

The full lane passes all engine checks and 26 hide/restore request attempts with
confirmed cleanup. Its one actual R4 press fails at the opening-roster witness,
before backend activation. Group entry is at uptime 1329.280775500, fresh group
at 1331.583306667, worker configured at 1331.767361875, opening-roster rejection
at 1333.522519375 and activation error `incomplete` at 1333.545830208.
The failure snapshot reports incomplete catalogue, approximately 980.621 ms
sample duration and 1,575.620 ms sample age. These timings do not establish
which individual catalogue operation exhausted the budget.

The full main-thread sample is mostly idle (109 of 134 samples in the run loop).
Among the remaining samples, witness and current-intent checks repeatedly reach
`WindowContentPreview.sessionAvailable`. This complements the fast lane's stream
construction sample; it does not replace either observation. Product, fixture
and CI-owned desktop cleanup are confirmed. Later product scenarios remain
`NOT_RUN`.

Original full receipts: [runtime](full/runtime-summary.json),
[engine](full/engine-result.json), [product](full/product-result.json),
[R4 press](full/r4-press-result.json), [phase log](full/product.stderr.log),
[Host sample](full/host-main-thread.sample.txt), [candidate](full/candidate.json),
[fixture cleanup](full/fixture-cleanup.json),
[CI-owned desktop cleanup](full/ci-workspace-cleanup-receipt.json).
