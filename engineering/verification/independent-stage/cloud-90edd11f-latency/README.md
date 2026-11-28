# 90edd11f — confirmed singleton switching, separate join and input failures

This is evidence for exact revision **90edd11f53d78c021f27d66e3a49194f0fa42174**
on the original PR #16 branch. It does not qualify a later patch or a release.

- [Workflow 46141059803](https://github.com/haohongfei2001-png/nearpane/actions/runs/46141059803): FAST and FULL fail their runtime gates; diagnostics passes.
- [Source audit](source-gate-audit.json): actual Swift 310 functions in 51 suites,
  **309 PASS + one existing skip**, Rust **188 PASS**, native C **25 PASS** and
  `windowWrites=0`. The ten new Swift functions / 44 parameter cases actually
  execute successfully. Candidate construction and strict signature pass.
- **Formal R4, exact-target acceptance, stability and release remain incomplete.**
  These cloud measurements do not establish release performance.

## What the revision changes and what ran

The revision adds one narrowly scoped fresh-directory retry to a held-card's
initial no-write preparation, tied to the original current selection, owner,
metadata scope and retained identities. It also records the actual failed
preparation's selected-window facts and preserves incomplete census diagnostics.
It retains original physical, closing-roster and Coordinator confirmation rules.

Neither lane records `held-opening-directory-staged` or its retry event. The new
branch is covered by the source tests, **not by a native runtime retry in this
run**. Successful ordinary held selections must not be presented as native
coverage of that branch. The extra read's real latency is therefore unmeasured.

## FAST: ten physical switches and final settlement, then a join refusal

[FAST interpretation](fast-interpretation.json) and the
[losslessly compressed full analysis](fast-analysis.json.gz) preserve the
per-input, per-witness and per-worker observations.

- Ten actual external inputs produce ten double physical confirmations. The
  tenth reaches `R4SelectionSettled` at uptime **565.245599**, with the expected
  group/member, exact focus, current ownership and idle navigation.
- Reader returns **424 complete protocol responses** from one persistent helper.
  There is no Swift exclusivity crash, transport/service error or witness refusal.
- All **134 worker requests** return status 0; **28 native moves** have two
  complete positive observations. All **186 Host witnesses** and **558 physical
  wrappers** complete. A complete protocol response is not itself a complete
  desktop roster, transaction or release qualification.
- Join preparation succeeds and the directory contains both original members
  (windows 54 and 57). Activation of that combined group then fails; this is
  **not a failure to prepare the join directory**.
- The new session's HIDE and READBACK pass. Post-witnesses 10 and 11 are complete.
  Witness 12 completes at **570.751903**, followed by the first final semantic
  comparison's `.incomplete`; source control flow bounds this rejection to
  **570.751903–570.755138**. Witnesses 13/14 belong to compensation, not further
  successful final confirmations.
- The old trace does not identify which final predicate failed. Whole-window
  equality, saved stack, parked state and active layout are candidates, **not
  established root causes**. No failed worker or physical read explains it.

The join navigation job takes **8900.623 ms**, including **3401.332 ms** of
compensation before reporting the error. This recovery time cannot be counted as
normal join latency. The member button, split and later lifecycle gates are not
reached. The earlier member-button bounds fix consequently has no new AX input
coverage from this run.

### FAST timing and scope

This lane uses a **debug foundation**. Its ten external physical confirmations
have p50 **2355.258 ms**, maximum **3360.517 ms**. The first ten navigation jobs
span **30772.533 ms** in total:

| Component | Aggregate | Relationship |
|---|---:|---|
| 157 complete witnesses | 20896.193 ms | Includes the four phases below |
| Opening directory | 6479.500 ms | Witness phase |
| Binding | 616.848 ms | Witness phase |
| Physical observations | 7656.951 ms | Witness phase |
| Closing tail | 6143.815 ms | Witness phase; not all directory IPC |
| Worker requests | 4581.951 ms | Separate requests in the same jobs |
| Unchanged permit checks | 1589.562 ms | Already nested inside witnesses |

Repeated complete witnesses dominate these jobs. The largest permit check per
singleton job is only **5.351–28.798 ms**; a universal 500 ms permit explanation
is contradicted by this same trace. Across all 558 physical wrappers, maxima are
**4.089 ms actor queue**, **48.463 ms native work**, and **15.239 ms return**.

Join has a distinct isolated long tail: witness sequence 5 takes **1486.367 ms**,
with **1376.326 ms** in its closing tail and only **60.279 ms** in physical reads.
Closing directory revision 371 has native duration **53.001 ms**, returns to
`afterAction` at **567.606440**, and the witness completes **1288.095 ms** later.
The nested permit checks total **969.507 ms**, with one **544.928 ms** maximum.
The existing closing metric also includes roster, permission and lifetime/gallery
work; attributing that entire tail to Reader IPC is incorrect. Later cleanup
projection work is not the cause of the earlier rejection.

FAST Host shutdown takes **248.859 ms**. Independent double home/frame/visibility
checks pass, and the final owned ledger is empty. Successful recovery does not
erase the earlier join failure.

## FULL: six physical switches, then an issued AX action has no success reply

[FULL interpretation](full-interpretation.json),
[full analysis](full-analysis.json.gz),
[publication audit](full-publication-audit.json) and
[Dock delivery audit](full-dock-delivery-audit.json) retain this lane independently.

FULL records **seven issued external actions, six successful AX replies, six
double physical confirmations and six navigation submissions**. The first five
confirmed prefixes are normally superseded by newer selections. The sixth
navigation job passes its final witnesses and health check and returns normally.
There is no final-cycle `R4SelectionSettled`, because the cycle stops on input 7.

The seventh Controller receipt, `r4-press-d2220fcc-a7d8-47a2-bdea-249d44654f99.result.json`,
preserves `status=BLOCKED`, `issued=true`, `axError=-25204`; Host's copied summary
records `status=UNKNOWN` and process exit 2. **These are two different recorded
status fields, not interchangeable originals.** Input is at **1222.82852025**,
and the action returns at **1223.174761208** (**346.241 ms**). The configured
per-element attribute timeout is 250 ms. Enabled, owner, window, retained element
and inside-panel checks pass before issue. The discovery and final button frames
differ, but both are within the retained panel. No seventh navigation submission
is observed before cleanup.

The prior job ends **180.508 ms before** this input, so its continued execution
cannot explain the action error. No failed witness, worker or physical wrapper
precedes the failure. Apple documents that
[AXUIElementPerformAction can return CannotComplete when messaging fails or the app has not yet responded](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction),
and that the error does not necessarily establish action failure. This trace
does not prove non-delivery, identify the underlying cause, or authorize repeating
an already-issued action. No successful seventh switch is claimed.

The first physical switch takes **6609.459 ms**; the next five take
**1430.838–1785.687 ms**. Initial costs include a **1502.483 ms** first witness,
**1105.985 ms** binding phase, four opening role awaits totaling **600.103 ms**,
and a **1292.005 ms** launch canary. These are separate nested and non-nested
measurements, not one established AX or actor scheduling cause.

All **73 worker requests**, **99 complete witnesses** and **297 physical
observations** pass; **16 native moves** retain two positive complete views.
Reader returns **225 decoded replies** from one helper. One cleanup cancellation
reaps the helper with status 9 after the terminal input failure; it is not counted
as a prior crash. The first selection's preparation succeeds, despite revision 4's
partial roster, with the original appearance and group lifetime matching; the
previous 7c8 first-preparation failure is not reproduced here.

All **75 metadata scopes** drain/end. A continuous **16.406 s** navigation lane
contains **19 actual publications**; maximum retained native-begin age is
**7977.499 ms**, below the original 12 s threshold. This is not evidence for
removing freshness checks or indefinitely retaining a snapshot.

FULL Host cleanup is **542.574 ms**, including successful RELEASE **250.019 ms**
with owned count 0. Independent double home/frame/visibility, fixture and
workspace cleanup pass. Join/split, yellow-button routing, native desktop and
fullscreen/system-interaction gates, window lifecycle and crash recovery remain
unexecuted in this lane.

## Follow-up scope and evidence boundaries

Source inspection separately proves a stack-ordering gap: existing restoration
of stack precedes HIDE/PLACE, although those primitives do not promise to preserve
non-focused member order. A later repair moves the same original stack work after
those primitives and preserves early exact focus, final exact focus, WAL,
preflights and double post confirmations. A model regression can establish that
gap; it cannot identify the unlogged 90edd predicate.

Further trace-only changes record the first actually evaluated false final
predicate and break the original permit checks into timed phases, without
additional native reads or re-evaluated conditions. **None of those later
changes is built or exercised by this run.**

The later external-input harness gives the one validated retained button action
a separate **1 s acknowledgement timeout**, checking the setter before issue.
Attribute reads remain 250 ms; discovery remains 6 s and is checked again before
the action. It does not resend an issued action or accept UNKNOWN as success.
Action start/return and setter status are recorded separately. The physical
readback deadline is tightened to **original input + 8 s** (previously that wait
started with its call after the acknowledgement); the final settlement already
used input + 8 s. This avoids adding acknowledgement time to the physical budget.
It is a harness correction, not an established fix for the unobserved cause of
the seventh action error or a claim of improved product performance.

The exact target Mac was offline at the last device check; exact-target GUI
acceptance remains NOT_RUN.

## Immutable source and runtime provenance

[Provider artifact metadata](artifact-api-metadata.json),
[copy/compression provenance](provenance.json),
[workflow](workflow-run.json), and [jobs](workflow-jobs.json) identify exact sources.

| Lane | Artifact | Bytes | SHA-256 of original ZIP |
|---|---:|---:|---|
| Source | 15261912198 | 37594 | `e4633d094f3c58f2b12e9b0bfc634e252bf563d3ee7be5033f5e69c191fc4349` |
| FAST | 15262550066 | 26200747 | `7372f52487b6f6e7fbf94101d8859bf216637262a4d6458a6280a4f18fb118d9` |
| FULL | 15262865638 | 54300802 | `95ade973d67b9cfbdd413c2f1d32c6950395c391c3ecf88ed5cf04c559c8b736` |

Each artifact is downloaded once. **10 source, 132 FAST and 464 FULL raw files**
are byte-checked against their original ZIPs. The
[raw trace archive](runtime-traces-90edd1.tar.gz) preserves **154 original files**,
with each archive member verified against the original ZIP and
[SHA-256 manifest](runtime-traces-manifest.json). The large analyses are compressed
deterministically and decompressed byte-for-byte before publication.

Also retained: [original source ZIP](cloud-source.zip),
[Swift XML](source/swift.xml), [Rust log](source/rust.log),
[native C log](source/binding-attributes.log), [candidate receipt](candidate-receipt.json),
[FAST raw manifest](fast-raw-manifest.json),
[FAST freeze](fast-freeze-verification.json),
[FULL raw manifest](full-raw-manifest.json), and
[FULL analysis freeze](full-analysis-manifest.json).
