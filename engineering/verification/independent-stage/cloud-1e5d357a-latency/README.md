# R4 1e5d357a: source passes; initial observations still stop real input

**The exact-source gate and complete release build pass. Both real R4 lanes
receive one button press and confirm zero completed switches. The unsampled
release run stops at an inconsistent opening window roster; the sampled fast
run stops after a Dock observation becomes stale during delayed scheduling.
Neither reaches managed-window HIDE/SHOW, so neither tests whether the AX batch
fix resolves the previous 5e3a SHOW/health failures.**

Exact source: `1e5d357a6649fc8afb64b97334769bc00eef9379`, continuing the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46109176116](https://github.com/haohongfei2001-png/nearpane/actions/runs/46109176116)
is terminal. The hidden-Space route, main branch and qualification table are unchanged.

## Native source and package results

| Check | Original result |
| --- | --- |
| Rust | 180 passed, zero failed |
| Swift XML | 249 entries: 248 passed, one existing gated skip, zero failed |
| DesktopOverviewReaderTests | Nine functions / ten executed cases passed, including both malformed-frame parameters |
| Native AX batch decoder | 25 passed, zero failed, zero window writes |
| Complete application and strict bundle signature | PASS; `qualificationGranted=false` |
| New exact-source target Mac execution | NOT_RUN; the connector stopped responding after the earlier 5e3a source run |

The sole skipped Swift function is the existing environment-gated signed native
minimize fixture, not a reader test. The native C reader fixture fixes the prior
cloud-only cold interpreter startup problem without changing production read
timeouts. Cancellation still has a one-second completion bound and a separate
MainActor heartbeat; the 0.2-second timeout, exact child reap, partial frames,
invalid snapshot, queued cancellation and idle reclaim cases execute.

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log) and [native decoder stdout](source/binding-attributes.log)
retain the actual counts. The early [cloud context archive](cloud-source.zip)
and final full artifact have byte-identical Swift stdout/stderr and source summary.
[Candidate receipt](candidate.json) identifies this exact complete build.

## Unsampled full: opening roster changes before binding

The actual external R4 press reaches the original witness. Its first fresh
directory read reports `catalogComplete=false`, with precisely:

- `windowRosterChanged`
- `windowIdentityOrBounds:pid=50087,window=86`

The native sample runs from uptime **1445.330313 to 1446.305597**, **975.28 ms**.
The witness rejects at `opening-roster`, sequence **0**, bindings **0**, claims
**0**, after **1279.38 ms**; navigation fails at **1446.348052**. Input-to-Host
rejection is **2218.07 ms**, which is not a successful switch latency.

PID 50087 is FixtureB. The configured document windows remain 53, 55 and 56;
FixtureB's original document is 56. Its final state has `lastCreatedSequence=0`,
`lastCreatedIndex=-1` and `lastFocusSequence=0`; the fixture's scripted create
operation only applies to FixtureA. Thus window 86 is not a registered document
creation by the acceptance script. The artifact does not identify its role or
geometry, so it is not labelled a tooltip, transient panel or harmless surface.

The source reader compares two CG rosters. A number present only in the closing
roster has no matching opening identity/bounds and must make that sample
incomplete. The same compound identity/bounds guard can also reject a missing
birth, changed owner or dimension no larger than one point; the retained artifact
does not establish which subcondition failed for window 86. Later readiness
returns `catalogComplete=true`, but this initial
witness has already rejected the click. No original AX member is bound and no
managed-window write is issued. This is not evidence of a Rust landing or health
regression. [Full analysis](full-analysis.json) retains original paths and facts.

The follow-up is narrowly scoped to this pre-binding phase: while the original
selection remains current, a known roster-change-only opening sample may request
one genuinely new complete sample. It cannot authorize from the incomplete
sample, ignore another issue, extend to an existing binding or post-write path,
or loop until a desired answer appears. The subsequent identity, scope, physical
and two-observation checks remain required. That follow-up needs its own native
results and is not a PASS in this checkpoint.

## Sampled fast: callbacks arrive after dispatch becomes unavailable

The real AXPress is at **484.437784**. Selection preparation completes, and the
first witness completes at **485.439025**. All three worker requests succeed:
launch, health and release. The earliest Host rejection is the old Dock sample
expiring at **488.897711**, followed by dispatch eligibility becoming false.

| Recorded interval | Actual measurement |
| --- | ---: |
| Dock task created 486.596728 → started 488.879200 | 2282.47 ms queued |
| Dock native read 488.889264 → 488.897315 | 8.05 ms; ordinary context |
| Last accepted Dock sample age at rejection | 3472.76 ms |
| Directory revision 7 native sample | 76.96 ms |
| That native sample's end → Host return | 3307.83 ms |
| Launch request's maximum poll-task queue wait | 1037.55 ms |

The new Dock reply arrives at **488.989196** after its generation is invalidated.
Activation then stops at **489.028180**; navigation records supersession at
**489.031460**. There is no `spacesHealthReadFailed` or `spacesLeaseFault` and no
managed-window `spacesBindingTiming` in this product worker.

External sampling covers **485.023359–488.953966**, overlapping the queue gap.
Its main-thread aggregate contains only 24 samples, predominantly run-loop
waiting, and has no per-sample uptime. It does not identify a single synchronous
stack occupying that entire interval. The overlap remains an observation
limitation, not proof that the profiler caused every delay.

The subsequent workflow makes external Host sampling opt-in for fast runs via
`sample_fast_host`; complete release already disables it. Native phase traces
remain available. This removes an extra measurement variable, not a product
permission or freshness check. [Fast analysis](fast-analysis.json) includes the
precise original event locations and sample limits.

## What the batch actually demonstrates

The fast lane's independent direct engine passes and executes 335 real binding observations:
four-attribute batch median **0.080 ms**, maximum **10.567 ms**; complete binding
median **1.096 ms**, maximum **56.450 ms**. The slowest binding is dominated by
its **54.576 ms AXWindows list** read. Per-attribute errors/types and the retained
original window checks are exercised through the actual native implementation.

Those measurements belong to the direct-engine sequence. Both R4 runs stop
earlier, so no new successful R4 latency can be compared with the previous
[5e3a release result of 1906.94 ms](../cloud-5e3a7ea4-latency/README.md).
The full lane's separate direct engine records 331 bindings: batch median
0.122 ms / maximum 0.758 ms, complete binding median 1.584 ms / maximum 20.065 ms.

## Cleanup and original evidence

Both product runs record cleanup=true, Host released=true and two independent
home/geometry/visibility confirmations for all three fixture documents. Since
neither product reaches a managed-window HIDE/SHOW, these cleanup observations
do not establish a new product hide/restore round trip. Direct-engine restoration
and the earlier 5e3a product restoration remain separately recorded evidence.

[Provenance](provenance.json) and [artifact metadata](artifact-api-metadata.json)
retain exact source, run IDs and provider/download hashes. The
[41-file original trace archive](runtime-traces-1e5d.tar.gz) has SHA-256
`f086551e5d831eb7a666aa8ba85dcde0fed513e520052bb7a2324ae3909101f7`;
the [manifest](runtime-traces-manifest.json) records each original file's hash.
Full artifact **15249587027** has ZIP SHA-256
`cb2ddefaf47f18036ac86a3e25403387396b6d792a53ed76bcc40eda21c109a0`.

The core real R4 chain remains incomplete. Group editing, new/closed windows,
application exit, native system handoff, crash recovery and release remain later
gates; source and direct-engine passes cannot replace them.
