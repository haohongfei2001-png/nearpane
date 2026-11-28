# dccee047: real reader abort and a separate closing-roster refusal

Tested commit: `dccee047cc4c915732456299a345022fecded8bb`, tree
`340156e6af905f05d99f43be668c9b70067556e3`, on the original PR #16 branch.
[Workflow 46137081160](https://github.com/haohongfei2001-png/nearpane/actions/runs/46137081160)
finished with both formal R4 lanes failing. Source tests, the complete candidate,
and its strict signature passed. **Release qualification is false.**

This commit adds diagnostics around the original reader exchange, child process,
native read phases and target AX-list refusal. It changes no query, window
identity rule, retry, permission, or existing timeout. The next commit's
`acceptedWindowCount` fix was not executed by this run.

## Source and build boundary

The [source audit](source-gate-audit.json) checks the early context ZIP against
the complete run's original XML and native logs: **300 Swift functions = 299
PASS + one existing skip; Rust 188 PASS; native C 25 PASS with zero window
writes**. The existing reader transport suite executes nine functions and ten
parameter cases without changed assertions. These tests did not execute the
native `Reader.windowList` writeback that later aborts in FAST.

FAST builds the foundation Host with `NEARPANE_FOUNDATION_ONLY=1` and `debug`;
FULL builds the complete candidate with `release`. The original build script
passes each configuration to `swift build --build-system native -c` and packages
that configuration's reader. No explicit exclusivity override was found in the
checked workflow, package and build scripts. This documents different build
configurations; it does not prove which compiler optimization explains the
different runtime results. FAST timings are not release performance benchmarks.

## FAST: 37 actual Swift exclusivity aborts, no R4 input

The first failure is in `product.stderr.log`, lines 14–48. The Swift runtime
reports overlapping accesses in `Reader.windowList` and `Fatal access conflict
detected`. The original child wait status is **6 / SIGABRT**. The parent then
records `response-header-read`, zero-byte EOF, zero header/payload bytes and
`completeFrameReceived = false`. No complete-frame decoding or helper throwing
failure handler was reached; a fatal runtime trap bypasses those catches.

Across the lane, **37** such aborts are followed by matching header EOF failures.
The final, additional child is canceled during cleanup: `CancellationError`,
`request-header-write`, raw wait status 9. It is not counted as a 38th crash.
There are **zero real R4 inputs, zero formal Host worker operations and no
member-layout coverage**. The independent Controller passes separately.

The source-level cause is the optional-chain writeback:

```swift
result.census?.acceptedWindows = result.windows.count
```

Its mutation of the value-type `result` overlaps the right-hand-side read.
The subsequent one-file fix reads the count into a local before opening the
mutable access. That fix requires the following exact-head runtime, not this
source-test result, to establish recovery of real enumeration.

Host cleanup takes **1.851 ms** and independent double home/frame checks pass.
See [FAST interpretation](fast-interpretation.json), the
[compressed full analysis](fast-analysis.json.gz),
[raw-file manifest](fast-raw-manifest.json) and
[frozen-byte verification](fast-freeze-verification.json).

## FULL: HIDE receipt succeeds; the second complete confirmation does not

FULL obtains **28 decoded task results from one reader**, with no exclusivity
trap, parent transport failure, helper failure or target AX-list rejection.
It records **one actual R4 input, zero external physical confirmations and zero
settled selections**. The separate independent Controller passes.

The document HIDE for window 57 actually executes. Its native membership ACK
is **3.994 ms**, and two complete native positive views finish in **77.210 ms**.
The Host receives a successful HIDE receipt in **132.756 ms**, retaining one
owned window. READBACK passes and the first complete post-witness, sequence 7,
passes. The second complete confirmation fails at its closing roster; therefore
the HIDE transaction is not counted as committed.

The exact failure is `product.stderr.log` line 363, uptime
`1016.417889083`. Its opening revision 20 samples at
`1015.892551875–1016.016111083`. All three intervening retained physical
observations complete; their states equal the preceding complete states and
their focus agrees on PID 36156 / window 55. Those observations have not passed
the closing roster, foreign-focus and Coordinator checks.

Closing revision 21 samples at `1016.212896208–1016.409019333`, then reports only
`windowRosterChanged`:

| Existing enumeration counters | First sample | Second sample |
| --- | ---: | ---: |
| Public CG rows | 40 | 36 |
| Expanded rows | 44 | 40 |
| Eligible surfaces | 28 | 24 |
| Accepted windows | 21 | 19 |
| Owner-rejected rows | 7 | 5 |
| Owners checked / accepted | 9 / 3 | 7 / 3 |
| Unavailable owners | 0 | 0 |

This is neither an empty enumeration nor rejection of every owner. The raw
record does not identify the two disappearing accepted windows, so it cannot
establish that they were harmless surfaces. The completed physical observations
cannot substitute for the failed second confirmation.

All 24 instrumented physical observations complete. The largest measured actor
entry wait is **0.123 ms** and return-to-MainActor wait is **0.162 ms**. These
measurements do not support attributing this lane's failure to actor queueing.

## Recovery remains explicit

The first automatic RELEASE takes **139.027 ms** and fails with status 2,
detail 206, one window still owned. The native trace reports
`spacesBindingFailure phase=target-not-listed, axError=0, first=2, second=0`.
In the exact C source, `first` means the complete AX-list count and `second`
means `allowMinimized`; they are not two list counts. The second complete
confirmation cannot find the original target. The move had one positive view,
so this is not a deadline-expiry diagnosis.

A later RELEASE passes in **66.635 ms**, owned count reaches zero, and final
external double home/frame/visibility checks pass. The failed initial recovery
remains a separate failure fact. See [FULL interpretation](full-interpretation.json),
[compressed analysis](full-analysis.json.gz),
[analysis manifest](full-analysis-manifest.json),
[raw-file manifest](full-raw-manifest.json),
[publication audit](full-publication-audit.json) and
[Dock-delivery audit](full-dock-delivery-audit.json).

## Reproducible evidence

Each source/FAST/FULL artifact was downloaded once by its assigned owner.
Provider SHA-256 values and all 10 / 74 / 435 extracted raw files were checked
against their original ZIP members. The compact runtime archive contains 84
byte-verified original JSON/log/XML/native-test entries; it does not include
candidate application binaries.

- [Artifact metadata](artifact-api-metadata.json), [provenance](provenance.json),
  [run](workflow-run.json), and [jobs](workflow-jobs.json).
- [Original source context ZIP](cloud-source.zip),
  [Swift XML](source/swift.xml), [Rust log](source/rust.log),
  [C decoder log](source/binding-attributes.log), and
  [candidate receipt](candidate-receipt.json).
- [Original runtime archive](runtime-traces-dccee.tar.gz) and its
  [member/hash manifest](runtime-traces-manifest.json).

The target Mac is offline. Exact-target GUI acceptance, later R4 interactions,
stability acceptance and release remain unfinished.
