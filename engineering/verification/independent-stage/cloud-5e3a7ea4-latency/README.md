# R4 5e3a7ea4: faster real switches; later readback still fails

**The unsampled complete release candidate confirms its first real R4 switch in
1906.94 ms, versus 4798.33 ms for the corresponding d614f58d step. Its second
selection fails. The sampled fast lane confirms two selections, then fails its
third. Both current Hosts report successful release, with independent two-read
home restoration. Product acceptance and release qualification remain incomplete.**

This is the existing [PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16)
on `pro/independent-stage-engine-20261126`, with the same hidden-Space backend.
The exact tested revision is `5e3a7ea4b0adceae401ef222a79f7d1887268324`;
[workflow 46107341621](https://github.com/haohongfei2001-png/nearpane/actions/runs/46107341621)
is terminal. The comparison revision is `d614f58d06b4a23cda3ae6d381ff59fb31ca414d`,
[workflow 46053112049](https://github.com/haohongfei2001-png/nearpane/actions/runs/46053112049).
Separate runner executions are measurements of corresponding steps, not a
controlled same-machine causal experiment.

## Changes actually exercised

- The signed overview reader now keeps one read-only child alive for sequential
  requests. Every request still performs a new native sample and validates its
  session, revision, parent, structure and audit fields. Only the process and its
  verified executable are reused. Timeout, cancellation, invalid replies and
  session changes retire the exact child; idle channels are reclaimed.
- A single-use, session-bound Spaces preparation receipt moves worker health
  before the coordinator's fresh complete preflight. It removes one duplicate
  preflight per normal primitive. Durable intent, current input, original window
  identities, bystanders, real writes and two independent post-observations remain.
- Retained-card drawing compares the last complete witness instead of issuing
  synchronous AX/WindowServer reads from SwiftUI body. Clicking still obtains
  fresh authorization and physical observations.
- Dock ownership reads use a serial GCD queue rather than blocking Swift's
  cooperative executor. The original ownership/freshness checks remain.

## Actual R4 outcomes

Each duration starts at the external AXPress on the actual R4 button and ends
after two matching physical visibility/geometry/focus readbacks. An AXPress
success, a worker receipt or a rendered thumbnail alone is not confirmation.

| Lane and step | d614f58d | 5e3a7ea4 | Current result |
| --- | ---: | ---: | --- |
| Sampled fast, singletonCycle/0 | 6729.57 ms | 2820.04 ms | Confirmed, 58.1% lower elapsed time |
| Sampled fast, singletonCycle/1 | 7418.98 ms | 4862.57 ms | Confirmed, 34.5% lower elapsed time |
| Unsampled full, singletonCycle/0 | 4798.33 ms | 1906.94 ms | Confirmed, 60.3% lower elapsed time |

The baseline fast lane confirmed four of five inputs; current fast confirms two
of three. Both full runs confirm one of two inputs. These short, failed runs do
not establish a successful-cycle distribution or stability improvement. The
receipt's one-/two-sample p50/p95 fields must not be presented as a qualified
performance result.

The [comparison](comparison.json) retains aggregate readings;
[click timelines](click-timelines.json) partition each confirmed press interval
into non-overlapping elapsed segments. Nested reader measurements are explanatory
and must not be added to the outer partition a second time.

### Fast: an actual passive-health timeout

At the third selection, the original hidden window's passive health observation
consumes 1104 ms against its existing 650 ms budget, after approximately 6 ms of
preparation. It records zero complete health observations and fails with
`TIMEOUT / Readback` (detail 217); the later health request returns the sticky
`RestoreFirst` (detail 218). The latter request itself takes only 14.47 ms.

A simultaneous directory native sample takes 1152.81 ms. The available logs
establish a real slow-read interval but do not identify a particular native API
within that health read. They do not record AXCannotComplete, changed identity,
positive minimization or changed membership as the health failure.

Navigation fails at uptime 446.762. The first later Dock expiry is at 449.354;
it is not the original switch failure. The largest group-projection duration is
also after the failure, during cleanup. Ordinary projection contributes only
6.49 ms and 56.82 ms to the two successful press intervals, so this checkpoint
does not introduce another projection path.

### Full: SHOW acknowledgement remains uncertain

The unsampled release candidate's second selection submits SHOW at uptime
1250.082078 and returns at 1250.380359: status 4, detail 214 (`Uncertain`), after
297.97 ms. The existing move acknowledgement path has not obtained its required
two complete observations within the 120 ms deadline. The preceding health
request succeeds in 110.70 ms; no `spacesHealthReadFailed` is recorded. This is
distinct from the sampled fast lane's passive-health timeout.

The two preceding complete witnesses take 945.09 ms and 698.31 ms, including
native directory reads of 327.72, 186.73 and 261.74 ms. Native read latency remains
visible without external stack sampling. Navigation fails at 1250.399994;
the later Dock expiry at 1252.588 cannot explain that earlier failure.

### Reader and scheduling observations

The current fast trace contains 92 directory read exits and two overview-child
starts. The first child serves 86 native replies before a later cancellation
reaps it; the second serves five. The trace ends without a second reap event,
so no additional lifetime outcome is inferred from its absence.

Across the recorded fast directory reads, median request-to-native-start
overhead decreases from about 63.3 ms to 0.59 ms; median reader await decreases
from 114.6 ms to 42.54 ms. This establishes actual process reuse and reduced
startup overhead without treating snapshots as reusable authorization.

Fast's first successful interval also contains a 792.77 ms gap from the
revision-21 task-exit record to its awaiting caller's continuation. The native
sample itself takes 16.55 ms. No intervening JSON event identifies the blocking
work, and external stack sampling overlaps that interval. The unsampled full
first interval has only 23.41 ms total caller-continuation gaps and does not
reproduce that individual gap. No causal attribution to focus, Dock or the
sampler is claimed.

## Source tests, candidate and cleanup

| Scope | Observed result |
| --- | --- |
| Exact 5e3a7ea4 target Mac source gate, 26A428 | PASS: 180 Rust; 248 Swift passed, one skipped; native build and source checks passed |
| Target Mac actual R4 runtime in this checkpoint | NOT_RUN: graphical session locked; no GUI was launched or unlocked |
| Cloud source gate | FAIL: 180 Rust passed; 240 Swift passed, eight failed test functions, one skipped; nine issues across the reader fixture cases |
| Complete release build and bundle signature | PASS, but candidate records `sourceChecks: FAIL` and `qualificationGranted: false` |
| Current fast Host release / independent two-home read | true / true; Host shutdown 17.42 ms |
| Current full Host release / independent two-home read | true / true; Host shutdown 1.63 ms |
| Baseline full Host release / independent two-home read | false / true; the narrower external observation did not cure the failed Host release |

Recovery had already run before those final shutdown calls: operation 13 passes
in 549.19 ms (fast) and 249.36 ms (full). The 17.42/1.63 ms tail values are not
the duration of the complete restoration operation.

The cloud Swift failures are eight fixture transport timeouts and one
cancellation-timing assertion, all in `DesktopOverviewReaderTests`. Two parameter
cases belong to one test function. The same exact source passes on the target
Mac. This discrepancy does not turn the cloud source gate green and does not
establish a production reader timeout: the runtime reader actually reuses its
child through the recorded fresh samples.

The following source revision replaces the per-test Python executable with a
small native C fixture, compiled once outside transport timing. Each test keeps
an isolated executable, hash and marker directory. The cancellation test records
actual request completion off MainActor and separately proves a MainActor
heartbeat while the request is pending. Production timeouts and the one-second
cancellation bound remain. The same follow-up batches four worker AX attributes
into one request, preserves per-item errors and both full observations, and adds
bounded native phase timings. These follow-up changes require their own native
source/runtime results; this checkpoint does not claim they fix either failure.

## Original evidence and limits

- [Runtime traces archive](runtime-traces-d614-5e3a.tar.gz) contains 60 selected
  original current/baseline files; [manifest](runtime-traces-manifest.json) records
  their paths and SHA-256 hashes. Archive SHA-256:
  `81ecfff02a1d0d11a239aadb909d2ffc93450206451c0bb3402ee99c20482674`.
- [Target source archive](target-source.zip) contains original summaries, Rust and
  Swift output, Swift XML and its own manifest. It is an isolated source test,
  not a target GUI acceptance result.
- [Cloud source context](cloud-source.zip) preserves its original failed source
  summary and Swift stdout/stderr. The [candidate receipt](candidate.json) keeps
  the successful full build and signature separate from that failed source gate.
- [Provenance](provenance.json) and [GitHub artifact metadata](artifact-api-metadata.json)
  preserve run IDs, exact revisions, original ZIP hashes and source locations.
  The 25.8 MB candidate ZIP remains in the original full artifact and is omitted
  from git; its SHA-256 is
  `e49c3b5a2bbbd99e2f590300552ff6474838b4f632cdc104c152d08592134d35`.

The archives retain relative original paths. To recompute the metrics, extract
the runtime archive beside [audit_compare.py](audit_compare.py) and
[audit_timeline.py](audit_timeline.py), then run both scripts. Their original
outputs are written under the extracted `5e3a/` directory.

The next gate is a complete series of real R4 selections with correct hidden
membership, restoration and exact focus. Group editing, system handoff, lifecycle
stability and release qualification remain separate later gates. This work does
not change the backend, the main branch or the product constitution.
