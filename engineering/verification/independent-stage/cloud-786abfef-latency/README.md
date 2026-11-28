# R4 786abfef: timely landing and slow full confirmation work; admission and latency remain

**Real moves exercise the new confirmation budget successfully, and the final
full-lane baseline selection reaches a verified commit. Formal R4 acceptance
still fails in both lanes. Source acceptance also fails on one existing Swift
test fixture; Rust and native decoder checks pass.**

Exact tested source: `786abfef7d12e5c93be195baead315919523fb22` on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46126567734](https://github.com/haohongfei2001-png/nearpane/actions/runs/46126567734)
is terminal. The run preserves the hidden-Space backend, original window
identity checks, two complete positive views, native READBACK and Host post
confirmations. The new 650 ms positive-confirmation budget is distinct from
the unchanged 120 ms timely-membership and transient-error retry limits.

The complete [fast analysis](fast-analysis.json.gz), [full analysis](full-analysis.json.gz)
and [full interpretation](full-interpretation.json) retain event locations and
the distinction between physical observations, superseded prefixes, completed
selections and cleanup. The compressed analyses reproduce the original frozen
JSON bytes exactly.

## Exact-source gates

| Gate | Result |
| --- | --- |
| Rust raw stdout | 188 passed; zero failed or ignored |
| New move-confirmation tests | Eight functions passed, containing 34 virtual-clock combinations |
| Existing 150 ms AX-error test | Unchanged source, explicit `ok` in raw stdout |
| Native AX decoder | 25 passed, zero failed, zero window writes |
| Swift XML | 274 entries: 272 passed, one existing skip, one failure |
| Complete candidate / strict signature | PASS, with `sourceChecks=FAIL` and qualification false |
| Direct foreign-window engine | Both lanes PASS; separate from formal R4 acceptance |

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log),
[early context ZIP](cloud-source.zip) and [candidate receipt](candidate-receipt.json)
preserve the original results. The full/context Swift logs and source summary
are byte-identical. Both changed UI source files were actually compiled.

The sole Swift failure is
`aStoppedDetectorCannotPublishItsDelayedHint()` at line 61 of
`StageHostObservationSchedulingTests.swift`: the assertion requires the hint
to have started but remain blocked. Its fixture wait has an independent
two-second timeout; the test is reported failed after 2.940 seconds. The log
does not timestamp the assertion separately. The accompanying test correction uses the existing
explicit release signal, retaining the normal stop-before-release ordering,
all original assertions and the cleanup defer. The separate two-second input
responsiveness test is unchanged. This correction is not a native pass at
786ab; this head's source result remains **FAIL**.

## Real execution of the new native confirmation branch

Full has two product workers. Across their 28 `spacesMoveConfirmation` records,
every move completes with two complete positive views: 24 moves of the original
three document windows and four canary moves. All worker terminal receipts pass.
Three document confirmations exceed 120 ms after a timely ACK:

| Original window | Target Space | ACK | Complete confirmation | Positive full views |
| --- | ---: | ---: | ---: | ---: |
| PID 51016 / window 57 | 43 | 12.804 ms | 175.343 ms | 2 |
| PID 50845 / window 54 | 12 | 3.510 ms | 127.415 ms | 2 |
| PID 50845 / window 54, second worker | 12 | 53.416 ms | 181.436 ms | 2 |

Both budgets start when the original `move_window` call returns. These are
complete positive confirmations within the new 650 ms total budget, not
late placement accepted retrospectively. No move is resent to obtain them.
The original source tests also confirm that an expired transient-error retry
cannot borrow this positive-confirmation budget.

## Fast: the sixth input meets an automatic observer before its first scope

Fast receives **six real inputs and five external double physical
confirmations**. Their latencies are **1671.352, 1515.701, 1108.020, 1384.242
and 1171.593 ms**. The first four jobs normally yield confirmed prefixes to
newer choices. The fifth has complete HIDE post observations 77/78, final
observations 79/80/81, a successful health read, and then normal job return.
Its physical confirmation precedes this final verification.

The sixth input starts after that job ends. Its ordering is:

| Event | Uptime |
| --- | ---: |
| Previous navigation activity ends | 325.768891708 |
| Sixth navigation submission, `running=false` | 325.896437458 |
| Revision 187 `readOutcome` enters / metadata admission | 325.896735125 / 325.896737333 |
| Revision 187 producer is created | 325.897560583 |
| New navigation job dequeues | 325.898272917 |
| Revision 187 native sample | 325.901828958–326.151886208 |
| Navigation system confirmation | 326.082423792 |
| First witness scope reserves | 326.159314250 |
| Revision 187 task exits with an incomplete catalog | 326.173277500 |
| Witness scope ends without completing its drain | 326.178117167 |
| Navigation reports interruption | 326.182737583 |

At scope reservation, both `pendingProducer` and `pendingPublisher` are true.
The latter proves an automatic observer has already been admitted. The existing
publisher normally passes the returned snapshot to `observeEnvironment`, which
revokes the current intent on an incomplete catalog. There is no independent
publication/freeze timestamp: the exit-to-scope-end interval bounds the inferred
handoff. Nor does this trace uniquely identify who created producer 187; the
observer could have joined another direct read. It cannot identify which hint
or `changed()` call woke that observer.

The only typed issue for PID 7042 / window 87 occurs in this sample. It is absent
in the first observation and present in the second as a 66×20, active,
onscreen, ordered surface with an unhidden owner. Membership is unavailable
and AX role reads are `notRequested`. The record does not establish the
surface's purpose or a lifetime across revisions. Its unknown state must not
be replaced by an assumed role based on dimensions.

All 69 metadata scopes end; 68 drain successfully. The sole non-drained scope
is the one above. No new SHOW is issued for the failed sixth selection.

### Restoration is separate from the sixth-input failure

The ensuing first RELEASE fails with status 2 / detail 206. Its second complete
view encounters `spacesBindingFailure phase=window-list`: `first=2` is the
requested AX window count and `second=19` is a CF type ID, not a window-count
change from two to nineteen. The original array count is not logged, so the
record cannot distinguish all possible type/count mismatches.

That restoration move has a 0.897 ms ACK, two full-view attempts and one
positive view before rejection at 138.065 ms. This is not a new 120/650 ms
timeout and occurs after the directory fault. A second RELEASE completes
with owned=0. Later automatic resume has `userActivity=false`; it is not a
seventh real thumbnail press. Final Host shutdown takes 281.314 ms, the final
ledger is empty, and two independent external reads confirm home/frame/visibility.

## Full: final selection commits, then group editing rejects another directory

Full receives **ten real inputs and ten external physical confirmations**.
The final baseline selection explicitly records `R4SelectionSettled` at
uptime **1415.728678**: the same ownership epoch, a newly accepted and still
current selection, idle navigation, verified active group and exact selected
member. Click-to-settlement is **7350.452 ms**. This does not convert the other
nine physical confirmations into nine full commits.

Two different interruptions remain distinct:

1. During cycle 5, the Dock poll at **1391.096935–1391.217784** returns
   `missingOrUnboundedDockChildren / unknown`. System ownership is revoked,
   a later witness rejects its fresh-directory stage, and the first worker
   safely releases its windows. Subsequent real input creates another worker.
   The later incomplete recovery directory is not the cause of this earlier
   Dock result. This run has six normal selection supersessions in addition
   to this system-observation interruption.
2. After the final true settlement, group-edit preparation normally releases
   the second worker at **1415.835370–1416.201317**, PASS with owned=0. Two
   `readAfterAction` calls then obtain complete revisions **347 and 348**;
   revision 347 reuses a pending producer whose native read began after the
   required boundary. The third call returns incomplete revision **349**.
   Its sole new surface is PID 51016 / window 112, visible only in the second
   observation as 66×20, without complete membership/AX role evidence.

Revision 349 is sufficient to fail `prepareHeldGroupEdit`'s final
`homeCatalog(fresh)` guard. No per-guard trace excludes simultaneous `current()`
invalidation, and the record does not require assuming earlier partial
revisions 345/346 caused the terminal interruption. The group edit's
`Plan.apply` is after that guard; the final directory remains three singletons,
with no successful `crossAppJoin` or `groupSplit` event.

All 109 full-lane metadata scopes drain and end. Of twenty foreground HIDE/SHOW
primitives, nineteen preserve preflight and two complete post witnesses. One
is cancelled after the Dock uncertainty despite successful Rust ACK/READBACK,
then safely released. **Split, yellow-button, desktop, Mission Control,
fullscreen, Split View, lifecycle and crash gates remain NOT_RUN.**

## Remaining latency is measured in full witness work

The former ac252 670.610 ms pre-creation gap does not recur. Fast's largest
pre-task interval is 99.398 ms at startup revision 2, almost entirely within
the original session-check envelope; this does not identify an internal
CFPreferences call or explain the older run retrospectively. Before the fast
fault, the 163 priority-25 creator intervals have a maximum of 0.464 ms.

Full's 350 producer creations have a median pre-task interval of **0.176 ms**,
p95 **1.561 ms**, and maximum **80.031 ms**, also before the first input.
Its maximum worker-poll queue delay is **0.181 ms**. Those measured intervals
do not explain the later multi-second selections:

| Cycle | Input to external double confirmation | Intersecting complete witnesses | Clipped witness wall time | Largest witness |
| --- | ---: | ---: | ---: | ---: |
| 6 | 5729.590 ms | 9 | 3700.923 ms | 732.852 ms |
| 7 | 5015.377 ms | 13 | 3612.978 ms | 436.074 ms |
| 9 | 5319.408 ms | 13 | 3800.362 ms | 501.783 ms |

These intervals are clipped to their actual input/confirmation endpoints and
do not add nested role, permission or directory timers a second time. Witness
sequences reset when a new worker starts; the analysis orders by monotonic
time rather than assuming global sequence uniqueness. The source establishes
what work those witnesses contain, but the trace does not uniquely separate
every IPC delay from actor scheduling.

The next observer-admission change must preserve fresh presentation and
management observations. This full run has a continuously occupied navigation
lane for about **22.895 seconds**; blocking all automatic publication until
total lane idle would violate the existing **12-second** snapshot freshness
requirement. A narrow entry-priority change must not create that regression.
It also cannot claim to repair the independent foreground revision-349 refusal.

## Integrity and qualification

[Provenance](provenance.json), [artifact metadata](artifact-api-metadata.json),
[workflow run](workflow-run.json), [jobs](workflow-jobs.json),
[fast raw manifest](fast-raw-manifest.json) and [full raw manifest](full-raw-manifest.json)
retain exact source/run identities. Each provider artifact was downloaded once
in this run; all **112 fast and 482 full files** match their ZIP members.

The [runtime archive](runtime-traces-786ab.tar.gz) contains **152 original files**,
each checked against its ZIP and again after archiving. It is **501,514 bytes**,
SHA256 `e045014eab65d07116689a05fb281328c0e0ae14d8b3431f81b61538d5c46529`.
Its [manifest](runtime-traces-manifest.json) maps every archive member back to
the provider ZIP. The [fast freeze check](fast-freeze-verification.json) and
[full analysis manifest](full-analysis-manifest.json) preserve independent checks.

Both lanes finish cleanup with the original windows at home and their frames
preserved. Cleanup success does not upgrade earlier
interrupted selections or the failed source gate. Exact-target GUI acceptance
and release qualification remain incomplete.
