# R4 ef5c91c4: preparation admission passes; Dock delivery and launch remain

**Exact-source tests pass. FAST completes ten real selections through external
physical confirmation and settles the final selection. Full stops at its first
launch canary, before any document HIDE/SHOW. Formal R4 acceptance remains FAIL
in both lanes, and release qualification remains false.**

Tested source: `ef5c91c41020398443573db065f0f6fd2b8d9558`, on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46130289030](https://github.com/haohongfei2001-png/nearpane/actions/runs/46130289030)
is terminal. The hidden-Space backend, original window identity/geometry checks,
WAL, 750 ms Dock freshness, 12-second directory freshness and native 120/650 ms
limits are retained.

The [fast analysis](fast-analysis.json.gz), [fast interpretation](fast-interpretation.json),
[full analysis](full-analysis.json.gz), [full interpretation](full-interpretation.json)
and [full publication audit](full-publication-audit.json) preserve source locations
and distinguish actual input, physical observation, committed selection and cleanup.
Both compressed analyses reproduce their frozen JSON bytes exactly.

## Source and complete-candidate gates

| Gate | Exact ef5 result |
| --- | --- |
| Swift XML | 282 functions: 281 passed, one existing skip, zero failures |
| New preparation-gate suite | Eight functions / 15 parameter cases actually passed |
| Stopped-detector fixture | PASS after 3.991 seconds with explicit release |
| Separate two-second input-response fixture | PASS; its original responsiveness assertion remains |
| Rust raw stdout | 188 passed, zero failed or ignored |
| Native AX decoder | 25 passed, zero failed, zero window writes |
| Full candidate / strict signature | PASS; sourceChecks=PASS; qualificationGranted=false |
| Direct foreign-window engine | FAST and full PASS independently of formal R4 |

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log),
[early context ZIP](cloud-source.zip) and [candidate receipt](candidate-receipt.json)
retain the original evidence. The four changed UI sources and two changed test
files have actual native compilation records. Full/context Swift stdout, stderr
and source summary are byte-identical. The eight prior native confirmation
functions and unchanged 150 ms AX-error test also explicitly pass in Rust stdout.

## FAST: all ten physical selections, final true settlement

FAST records **10 actual R4 button inputs and 10 external double physical
confirmations**. Across all ten, physical confirmation has a **2086.931 ms median**
and **2720.798 ms maximum**; the nine subsequent switches have a **2075.104 ms
median**. The raw report's nearest-rank P50 over all ten is also 2075.104 ms;
the conventional ten-sample median above averages the middle two observations.
The first nine jobs safely hand confirmed prefixes to
newer choices; they are not nine additional final commits. The last singleton
selection records `R4SelectionSettled` at uptime **1213.049953792**, with a
**2741.434 ms** press-to-settlement interval, unchanged ownership epoch, current
new selection, idle navigation, verified active group and exact selected member.
The approximately two-second switching latency remains unfinished work.

The worker has **116 successful terminal requests**: 11 HIDE, nine SHOW,
44 READBACK, 50 health, one launch and one release. All 24 native move
confirmations contain two complete positive views; the largest is 95.597 ms
with a maximum ACK of 32.212 ms. This run does not exercise the over-120 ms
positive-confirmation branch already demonstrated by 786ab.

All **158 complete witnesses** and **118 metadata scopes** finish successfully;
there is no witness rejection before the later edit failure.

### Preparation priority and continuous publication are actually exercised

All ten opted-in submissions/dequeues have an explicit initial-observation
completion. Nine observer waits enter and exit. There are **41 actual observer
publications**, each complete and fresh at assignment. The maximum interval
from the **previous snapshot's native beginning to the next publication** is
**2095.954 ms**, well inside the unchanged 12-second bound. This measures the
age of the snapshot that remains displayed between publications, rather than
only checking the new snapshot after it arrives. Wall-time interval estimates
remain conditional on the absence of an unobserved clock jump.

The new creator provenance records 316 metadata-owner producers, 40 observer
producers and three direct producers. The former ac252 670.610 ms pre-creation
gap is not reproduced. The largest pre-creation interval is 177.386 ms at
startup revision 2; the original single session-check envelope accounts for
177.333 ms of it. No internal CFPreferences attribution is inferred.

## FAST's first failure is a completed Dock read awaiting actor delivery

After the final settled selection, edit preparation normally returns the two
held windows: RELEASE runs from **1213.070536417 to 1213.256498750**, PASS with
owned=0. The later 4.351 ms terminal Host shutdown is a separate event and must
not replace this real release duration.

The first revocation is the following ordering, preserved in the runtime trace:

| Event | Uptime |
| --- | ---: |
| Last accepted Dock read begins / ends | 1214.026302208 / 1214.030135250 |
| Next poll requested | 1214.808362458 |
| New native Dock read begins / ends, ordinary | 1214.895883292 / 1214.897883958 |
| Timer rejects the old read as 957.509 ms old | 1214.984103250 |
| System ownership changes to sampleExpired | 1214.984526375 |
| Direct directory revision 359 rejects at entry | 1215.072169500–1215.072487125 |
| New Dock result reaches MainActor, old generation | 1215.072639000 |
| Third edit-preparation read returns epoch mismatch | 1215.078045125 |

The new native read took about 2.001 ms, but its callback arrived 174.755 ms
after completion. Its native begin was only about 88.220 ms old when the timer
expired the previous result. `sameGeneration=false` follows that revocation;
it does not show that the new physical Dock read saw an overview. No earlier
incomplete catalog or witness rejection explains this failure.

Revision 357 has a 578.297 ms **asynchronous** group-projection envelope.
Revision 358 has a 269.660 ms native read and a further 266.900 ms before the
reader returns, with a 742.886 ms whole producer interval. These overlapping
timings do not identify one synchronous MainActor block or establish App Nap.

There is also a concrete acceptance-path difference: the real context menu
submits edits through the navigation queue with user activity, explicit-input
checks and current-job identity. At this source, the acceptance helper directly
awaits `IndependentStageGroupEditing.perform` for join/detach. The last actual
selection's user activity ends at **1213.014198875**; the subsequent edit trace
has `dispatching=false` and priority 17. It is a handler input, not a pointer
gesture. The next patch makes these handler inputs share the production queue
and separately adds a one-shot handoff for an already completed exact Dock poll.
Neither later change was executed in this artifact.

## Full: distinct launch-canary refusal before document movement

Full records **one actual R4 input, zero external physical confirmations and
zero settled selections**. One witness completes in **282.343 ms** with three
original bindings. The subsequent launch canary fails with status 2 / detail
229 (`ProbeFocus`), before any document HIDE/SHOW request.

In `spaces-worker-8deb7b75-6dae-4503-9ec3-edfa8f9002b6.jsonl`, line 17 records
the Finder desktop window-list count/array errors **-25204 (AXCannotComplete)**
and roleError=0; line 18 records the failed focused-desktop structure; line 21
records `panel-home` detail 229. The third panel call queues for 0.083 ms and
takes 314.161 ms. The complete launch operation, including earlier calls and
failure cleanup, takes 505.585 ms. The original **650 ms home-discovery budget
is not exhausted**: this is a focus-structure refusal, not that deadline or a
document move-confirmation timeout.

The initial preparation gate completes at **1095.057959**. Revision 7 publishes
357.151 ms later, with a native-begin age of 17.469 ms; revision 8 also publishes
during the same navigation activity. All eleven full-lane publications are
fresh when assigned. This lane is only **969.578 ms** long, so it does not supply
long-lane freshness coverage. FAST's later phases are not imported into it.

Canary finish succeeds with owned=0. Full Host cleanup, original home/frame/
visibility and independent double readback pass. Join/split, system interaction,
lifecycle and crash gates are **NOT_RUN** in full. FAST also has no successful
join or split and has not reached the subsequent lifecycle gates.

## Integrity and remaining qualification

[Provenance](provenance.json), [artifact API metadata](artifact-api-metadata.json),
[workflow run](workflow-run.json), [jobs](workflow-jobs.json),
[fast raw manifest](fast-raw-manifest.json), [full raw manifest](full-raw-manifest.json),
[fast freeze verification](fast-freeze-verification.json) and
[full analysis manifest](full-analysis-manifest.json) preserve exact identities.
Each provider artifact was downloaded once; **130 FAST and 435 full files**
match their original ZIP members.

The [runtime archive](runtime-traces-ef5.tar.gz) contains **128 original files**,
all compared with their ZIP members and checked again after archiving. Its
size is **366,855 bytes**, SHA256
`2ed651668866fec67994609dbd705b37415f4a6ed1db48abe08b388722e38e92`.
The [archive manifest](runtime-traces-manifest.json) maps every member to its
provider ZIP. The complete candidate ZIP's verified SHA256 is
`755f35ff786329941872dce6a8aabeb718bd4954eece095fd57218955c59fe1b`.

Both lanes finish their original-window cleanup. Continuous formal R4 acceptance,
latency completion, later interactions and exact-target GUI acceptance remain
incomplete; source and cleanup success grant no release qualification.
