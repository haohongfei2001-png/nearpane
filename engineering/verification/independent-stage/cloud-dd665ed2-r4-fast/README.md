# dd665ed2 fast: no R4 input; actual observation delivery exceeds 750 ms

Run [45736296714](https://github.com/haohongfei2001-png/nearpane/actions/runs/45736296714),
source `dd665ed2b9fe46731d518e811e8f98c948d59227`.

The early source receipt records **162 Rust passed**, **172 Swift passed and
1 skipped**. The original Swift log explicitly ran and passed both tests in
`IndependentStageDockFreshnessTests`; the timing fix was not merely compiled.
The foundation Host built. This fast VM's raw foreign-window controller returned
**FOREIGN_ENGINE_PASS**, including both yellow-button checks, repeated switches,
same-app independence, cross-app grouping, focus and cleanup. The separate
diagnostics VM's canary-close refusal is a different receipt, not this result.

## Actual product evidence

Product **BLOCKED**, `reason=realExternalR4ButtonNotAccepted`,
`actualR4Inputs=0`, cleanup **true**. The helper ended with
`reason=accessibilityTreeIncomplete`, `issued=false`. Its last tree traversal
visited zero nodes before the existing discovery budget ended. The report also
retains an earlier panel-geometry read's AXCannotComplete (-25204), but does not
contain the complete sequence of preceding discovery attempts. No specific
button replacement or missing action support is inferred.

The new timing trace distinguishes this failure from the previous queue-time
misclassification:

| Actual observation | Read duration | Age after read end at delivery | Result |
| --- | ---: | ---: | --- |
| 607.267958–607.279101 | 11.14 ms | 1009.32 ms | Expired |
| 610.714727–610.718983 | 4.26 ms | 764.25 ms | Expired |

These observations really exceed the unchanged 750 ms bound from sampling start
through acceptance. The pending-read watchdog separately recorded a previous
actual observation aged 1625.83 ms. The eligibility withdrawals are valid under
that bound; increasing it is not the proposed fix. No R4 handler, Finder
self-reference check or product NP_LAUNCH ran.

## Next diagnostic

The first external-press Host path was inspected: it awaits asynchronous
40 ms sleeps while the controller runs, with no `waitUntilExit` or blocking
pipe read in this phase. Ordinary production gallery/window evidence code still
has synchronous native reads; source presence alone does not identify this
VM's blocking stack.

The next harness adds one external `/usr/bin/sample` observation of its exact
directly launched Host PID when the first R4 request file appears. It samples
for three seconds at a 10 ms interval, saves the original stacks and exit
status, and reaps the sampler. The Host/MainActor does not wait for it. Sampling
availability does not alter the product result or any freshness/action guard.
This is diagnostic instrumentation, not a performance qualification.

All receipts are byte-for-byte originals with artifact paths, byte counts and
SHA-256 hashes in `provenance.json`. Later physical product checks remain
NOT_RUN; neither source success nor the raw-engine pass establishes R4 success.
