# R4 3f531dae: queued join and Dock handoff exercised; member bounds and roster failures remain

**Exact-source tests and the complete candidate pass. FAST reaches 12 real
selections with 12 external double physical confirmations, including leaving and
restoring a combined group. Its next member press is not issued because the
button extends outside the sidebar. Full independently stops after four inputs
on an incomplete fresh directory. Formal R4 acceptance remains FAIL and release
qualification remains false.**

Tested source: `3f531dae67108f94d2d56629799c08f347004a4d`, on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46132883604](https://github.com/haohongfei2001-png/nearpane/actions/runs/46132883604)
is terminal: FAST and full fail, diagnostics pass. This continues the hidden-Space
implementation with the original identity, authorization, recovery and freshness
checks. No target installation or release is implied.

The [FAST analysis](fast-analysis.json.gz), [FAST interpretation](fast-interpretation.json),
[full analysis](full-analysis.json.gz), [full interpretation](full-interpretation.json),
[full publication audit](full-publication-audit.json) and
[full Dock-delivery audit](full-dock-delivery-audit.json) retain raw source locations.
The two compressed analyses reproduce their frozen JSON exactly. The
[runtime archive](runtime-traces-3f531.tar.gz) and its
[manifest](runtime-traces-manifest.json) preserve 158 original ZIP-verified files.

## Source and candidate gates

| Gate | Exact 3f531 result |
| --- | --- |
| Swift XML | 296 functions: 295 passed, one existing skip, zero failures |
| New Dock handoff suite | Seven functions / 20 parameter cases actually passed |
| New shared edit queue suite | Seven functions / 11 parameter cases actually passed |
| Prior observer preparation suite | Eight functions / 15 parameter cases passed |
| Existing detector fixtures | Both pass; the original skip remains unchanged |
| Rust stdout | 188 passed, zero failed or ignored |
| Native AX decoder | 25 passed, zero failed, zero window writes |
| Complete candidate / strict signature | PASS; sourceChecks=PASS; qualificationGranted=false |
| Direct foreign-window engine | FAST and full independently PASS |

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log),
[early context ZIP](cloud-source.zip) and [candidate receipt](candidate-receipt.json)
retain the original records. Full/context Swift stdout, stderr and source summary
are byte-identical. The standalone compiler progress line for `DisplayPanels.swift`
is absent; actual compilation and execution of its new methods are established by
the linked and passing new tests, rather than by inventing a missing progress line.

## FAST: actual Dock handoff and the production edit queue

The timer consumes a completed Dock result before its suspended MainActor callback
in two actual requests. In the first, native reading begins at **1417.883256**,
the timer consumes at **1418.467195**, and the callback arrives at **1418.503872**.
The read is **583.939 ms** old at consumption, inside the unchanged 750 ms bound.
The later callback sees its generation but no longer owns the pending request.
The cleanup request independently exercises the same ordering. All 156 requests
have paired completion/consumption records; there is no duplicate consumption or
`sampleExpired`. A consume trace's `current` flag precedes the preference check;
that flag alone is not treated as final authorization.

The last singleton selection explicitly settles at **1445.773868**. The cross-app
join then uses the same `IndependentStageGroupEditing.enqueue` helper as the UI:
submit **1445.774043**, dequeue **1445.775358** with priority 25 and user activity,
system confirmation **1445.819193**, activity end **1448.347461**, and external
double join confirmation **1448.731239**. The acceptance helper awaits the queue
ticket before its existing directory and physical checks. This proves the shared
production handler path; it does not claim a pointer drag gesture or a completed
split. The editing job does not opt in to the selection-only preparation gate.

## FAST latency still requires work

| Segment | Input to external double physical confirmation |
| --- | ---: |
| First singleton | 7059.903 ms |
| Following nine singleton selections | Median 2017.906 ms; range 1855.165–2100.699 ms |
| Leave combined group | 5216.669 ms |
| Restore combined group | 6108.214 ms |

Physical confirmation is earlier than final transaction completion. The leave
job runs from dequeue to activity end for **7235.961 ms**, including 13 complete
witnesses occupying **5343.784 ms** and 16 worker requests occupying **1159.616 ms**.
The restore job runs for **7678.619 ms**, including 18 complete witnesses occupying
**6066.046 ms** and 14 worker requests occupying **691.472 ms**. These witness and
worker intervals do not overlap in these jobs. Their other gaps remain explicit
in the interpretation rather than being assigned to an unmeasured cause.

Restore waits **672.380 ms** from input to dequeue; activity ends **8350.999 ms**
after input. The physical 6108.214 ms reading is therefore not an 6108.214 ms
commit. Worker poll queue peaks are below 0.2 ms in these segments. The expensive
witnesses include asynchronous work and actor resumption; their wall-clock
envelopes are not evidence of continuous main-thread occupancy or App Nap.

All **161 worker terminal requests** succeed. All **36 native move confirmations**
contain two complete positive views, with maximum ACK **59.419 ms**. Document 55
confirms in **163.102 ms** and canary 87 in **229.243 ms**, actually exercising the
positive 650 ms branch while retaining the original error-retry boundary. There
is no detail 214 or worker health fault. The trace contains 200 complete witnesses
and 149 reserved/drained/ended metadata scopes. Its 60 observer publications
include 57 complete and three incomplete samples; it is not an all-complete run.

## FAST stops before issuing the next exact-member press

The thirteenth request ends at **1470.575238** with `buttonMissingOrAmbiguous` and
`issued=false`. The retained exact member is PID 39399 / window 58. Its button
exists, is enabled, supports press and matches the owner and retained panel, but
its frame **[980, 141, 67, 54]** has right edge **1047**, beyond the panel's right
edge **1024**. Thus `insidePanel=false` and no matching admissible button remains.
The final panel-frame read also reports AX error -25204. The retained tree and
`r4-12.png` show the partially clipped preview; no native member-selection failure
can be inferred because the press was never issued.

A separate background revision 460 publishes an incomplete catalog at
**1467.228989**, with a new 66×20 window 114 missing from the earlier census.
This precedes the terminal press receipt, but the receipt does not timestamp the
first discovery of the bounds problem. The two causes cannot be ordered from the
terminal receipt alone, and the layout repair does not claim to repair the
incomplete directory. The later metadata-scope rejection at **1470.908** follows
cleanup starting **1470.590703** and is not relabeled as the first failure.

## Full fails independently on a fresh foreground directory

Full records **four issued inputs, three external double physical confirmations
and zero explicit `R4SelectionSettled` markers**. The three physical intervals are
**1508.579, 1086.673 and 2567.158 ms**. The first job normally yields to a newer
selection; the second owned selection reports `completed=true`. The third has
not completed final verification when its fresh directory becomes incomplete.

After the prior HIDE scope finishes its sequence 42/43 postchecks, a foreground
metadata owner creates revision 105. Its native interval is
**1244.823376–1244.846939**, lasting **23.562917 ms**. Opening-roster validation
rejects it at **1244.870108**, around the fourth held-window input at
**1244.825548**. The fourth job subsequently dequeues and confirms the system,
but the original held/session state is already invalid and it never SHOWs window 54.

The failed snapshot reports 21 issues and zero final snapshot windows. The raw
trace preserves only the first 12 issue strings and eight typed window samples:
one displayed `windowRosterChanged` plus 11 displayed identity/bounds issues;
all eight typed samples have a second observation and no first observation,
including authorized windows 54, 56 and 57. The omitted nine issues cannot be
invented. Zero final snapshot windows does not establish an empty raw first CG
enumeration; the old trace has no complete enumeration/filter counts.

The canary and all **39 worker requests** pass. All ten native move confirmations
pass; window 57's SHOW ACKs in **34.778 ms** and obtains two complete positive
views in **277.747 ms**. There is no preceding ProbeFocus, Dock expiry or FAST
button-layout failure in this lane. Full's 43 complete witnesses and 32 metadata
scopes do not cover the later unexecuted join, split or lifecycle phases.

## Recovery and the next source change

FAST completes Host cleanup and two external home/frame/visibility reads with no
owned windows. Full's actual RELEASE runs **1244.882664–1245.125740**, PASS with
owned=0. Its later **1.296 ms** Host shutdown is a distinct event; it must not
replace the release duration. Full's double external home/frame/visibility,
worker closure, fixture and workspace cleanup checks pass.

The subsequent source makes the member button's real layout use its intersection
with the miniature canvas, while retaining the full image dimensions and cropping
by relative offset. It preserves exact-member actions, lifetime, menus and drag
handling, and retains the original unplaced-member path. The automation's
`insidePanel` guard is unchanged. Geometry tests do not substitute for the next
run's actual AX frame and issued-press evidence.

Two narrow diagnostics accompany that fix. Physical observation records separate
existing guard checks, actor queue wait, actual `StageWindowPhysicalReader.read`
wall time and return to MainActor. Incomplete directories carry counts from the
same first/second enumerations and existing owner-filter decisions. Neither adds
native queries, retries or authorization. The new optional count data has wire
validation and legacy compatibility coverage. No later source change is tested
by this 3f531 run.

The [provenance](provenance.json), [provider metadata](artifact-api-metadata.json),
[workflow](workflow-run.json) and [job records](workflow-jobs.json) distinguish
source, candidate, runtime and release evidence. The target Mac remains offline;
exact-target GUI acceptance is NOT_RUN. Formal R4 latency, complete interaction
acceptance and release qualification remain unfinished.
