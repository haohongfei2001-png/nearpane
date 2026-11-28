# R4 ac252b5a: the owned-member handoff works; two different boundaries remain

**The fast lane restores the second clicked window and completes that selection.
Its next SHOW fails when the first complete positive native observation exceeds
the existing 120 ms confirmation deadline. The full lane performs all ten
baseline thumbnail selections with ten external physical confirmations, then
checks the held-group projection before the final selection has finished.
Both formal R4 results remain FAIL.**

Exact tested source: `ac252b5a76a44c3c3ac12ff4e8c69e6d32dc7856`, on the original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46124060416](https://github.com/haohongfei2001-png/nearpane/actions/runs/46124060416)
is terminal. This head carries the original owned-member choice from a still
clickable current card into the existing stage navigation queue. Dequeue uses
the original held-selection, fresh witness and Coordinator checks. It neither
retains an ordinary appearance for a hidden window nor turns the captured
selection identity into a write permit.

The complete derived records are retained as byte-preserving deterministic gzip:
[fast analysis](fast-analysis.json.gz) and [full analysis](full-analysis.json.gz).
[Comparison](comparison.json) is a small summary; the analyses retain the
original event locations and nested timing details.

## Exact-source and candidate results

| Gate | Result at ac252 |
| --- | --- |
| Rust | 180 passed; zero failed or ignored |
| Native AX attribute decoder | 25 passed; zero failed; zero window writes |
| Swift XML | 274 entries: 273 passed, one existing gated skip, zero failed |
| New owned-member selection tests | Three functions / 28 executed cases passed |
| Complete candidate build / strict bundle signature | PASS; qualification remains false |
| Direct foreign-window engine, both lanes | PASS; separate from formal R4 acceptance |

The new tests cover exact member identity without an image, whole-group capture
admission, and actual navigation-queue ordering/revocation. Their fresh held
samples are fixtures; the native runtime results below establish the exercised
production paths separately. Original [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log),
[source audit](source-gate-audit.json), [early context ZIP](cloud-source.zip), and
[candidate receipt](candidate-receipt.json) are preserved. The full Swift log,
stderr and source summary match the early context artifact byte for byte.
These runner results do not grant exact-target qualification or establish a
release-ready product.

## Physical confirmations, settled prefixes and full commits

| Observation | r4-fast | full |
| --- | ---: | ---: |
| Actual external AX thumbnail presses | 3 | 10 |
| External double physical confirmations | 2 | 10 |
| Successful native HIDE / SHOW | 3 / 1 | 11 / 9 |
| Failed native SHOW | One, status 4 / detail 214 | None |
| Complete witnesses | 35 | 160 |
| Metadata scopes reserved / drained / ended | 27 / 27 / 27 | 121 / 121 / 121 |
| Normal superseded selections | 1 | 9 |
| Explicit successful activation exit | Second selection | None before cleanup |
| First true failure | Third selection's SHOW confirmation | `crossAppSourceNotHeld` before group editing |

A physical confirmation checks actual visibility, home/frame constraints and
exact focus twice. It can precede the Host's full post reads and final directory
commit. A superseded selection can retain a fully confirmed prefix for the newer
choice without committing its target group. The existing Core branch requires
`verifiedDirectoryCommit=false`, sealed primitive entries, two complete prefix
reobservations and health/ownership checks. Such a prefix is neither a failed
window write nor a completed group selection.

### Fast: the previously blocked second input now completes

The second press targets FixtureA window 56 at uptime `1955.398494208`.
The old current card still has no ordinary appearance, and its original group
guard would reject the click. The new route records:

| Event | Uptime |
| --- | ---: |
| `owned-member-selection-queued` | 1955.399395542 |
| Existing navigation submission, `running=true` | 1955.399531000 |
| Earlier selection settles its prefix and reports superseded | 1955.633123167 |
| New selection dequeues | 1955.633351292 |
| `owned-member-selection-enter` | 1955.747214375 |
| SHOW window 56 returns PASS | 1956.138147250 |
| External double physical confirmation | 1956.869038875 |
| `owned-member-selection-exit completed=true` | 1957.133946000 |

The SHOW is followed by its READBACK and complete post witnesses 21/22. Exact
focus on window 56 passes complete witnesses 24/25. HIDE of window 54 then passes
READBACK and post witnesses 27/28; final verification uses witnesses 29–31.
The second input reaches external confirmation in **1470.543 ms** and its
recorded internal completion in **1735.452 ms**. The earlier selection's
`completed=false` and superseded event are the expected queue handoff, not this
run's first failure.

The first input's external latency is **1660.574 ms**. There is only one
successful successive-input latency sample in this lane; these values are not
a population performance claim.

## Fast first failure: one complete positive view consumes the 120 ms deadline

The third real press selects the actual held-group button for FixtureB
`pid=51361, window=57`. It reaches navigation dequeue in **14.059 ms**. SHOW
intent `E9892784-4025-4240-8A73-BB21C4E3C351` runs from uptime
`1958.562460417` to `1958.744904750` and returns `status=4, detail=214`, after
**182.279 ms**. Its maximum recorded worker-poll queue delay is **0.014 ms**.

The raw worker's first complete post-move `view` is **positive**, ending at
`geometry-and-visibility` after **167.657 ms**. It includes both original-window
observations and the forward/target, other-space, desktop and geometry checks.
The main measured costs are:

| Native measurement | First original-window observation | Second original-window observation |
| --- | ---: | ---: |
| Complete `see` | 122.687 ms | 43.572 ms |
| AX binding total | 121.772 ms | 40.620 ms |
| Window-list read | 17.290 ms | 40.073 ms |
| Identity scan | 102.578 ms | 0.441 ms |
| Attribute batch | 1.896 ms | 0.094 ms |
| Binding began uptime | 1958.574485083 | 1958.700321000 |
| Binding ended uptime | 1958.696257375 | 1958.740941250 |

This is not an attribute-batch failure or a measured worker scheduling timeout.
The first full view already exceeds the exact-head `moved()` deadline. That code
starts its 120 ms clock after `move_window` returns, counts the first matching
view, then checks the deadline before another full observation. The trace has
no second complete post-move view before detail 214. Two `see` calls within one
view do not satisfy the required two complete views.

**The existing trace does not prove landing within 120 ms.** Membership is read
after the slow first `see`, and there is no explicit move-return timestamp.
The later positive view cannot retroactively establish timely landing. This
distinction constrains the next correction.

There is no PASS ACK, subsequent READBACK, full post-witness pair, new focus,
next HIDE or commit for this failed third SHOW. The first fault is preserved
independently from subsequent restoration in the [fast analysis](fast-analysis.json.gz)
and [raw runtime archive](runtime-traces-ac252.tar.gz).

### A separate, still unattributed scheduling gap

Before that SHOW, witness 33 reports an opening-directory interval of
**706.820 ms**. Its scope is already drained at uptime `1957.461263208` and the
after-action boundary is `1957.461671667`, with no prior read. Revision 79 is
not created until `1958.132281750`: a **670.610 ms** gap before producer creation.
Once created, its native sample takes **22.778 ms**, task-queue delay is
**1.454 ms**, and task-exit-to-caller resumption is about **0.398 ms**.

The current trace cannot identify what occupies the pre-creation interval.
It must not be labelled as native sampling time, a metadata-gate defect, or
CFPreferences latency without another observation. The accompanying UI
diagnostics time the original call entry, admission, single session check,
audit creation and request construction; they add no native queries.

## Full: ten physical selections, then an early dependent-phase check

The full lane does not reproduce fast's native failure. All **115** worker
terminal requests pass: 11 HIDE, 9 SHOW, 44 READBACK, 49 health, one launch and
one release. Across 273 native `view` records, the maximum is **54.174 ms**.
There is no incomplete directory or worker health/lease fault in this lane.

First-input external latency is **2319.962 ms**. The next nine external
confirmation latencies are **1449.753, 1778.495, 1772.966, 2311.065, 1431.610,
1373.185, 1407.575, 1454.965 and 1459.827 ms**; their median is **1454.965 ms**.
All nine earlier selections settle and yield to the next real input. Their
superseded records must not be counted as nine full commits.

The final selection returns to window 54. The relevant terminal ordering is:

| Observation | Uptime |
| --- | ---: |
| Exact focus on window 54 passes witnesses 155/156 | 1538.781289 / 1538.844345 |
| HIDE window 57 returns PASS | 1539.012677500 |
| Corresponding READBACK returns PASS | 1539.028959458 |
| Tenth external double physical confirmation | 1539.074013958 |
| Full HIDE post witnesses 158/159 pass | 1539.114325 / 1539.171857 |
| HIDE scope ends | 1539.173617875 |
| Acceptance starts Host shutdown after `crossAppSourceNotHeld` | 1539.230175042 |
| First final-verification witness 160 completes | 1539.233870750 |
| Following fresh-directory read is rejected | 1539.243475625 |

At this head, `selectR4` records its external confirmation, saves the panel,
calls `feed.changed()` and sleeps a fixed 120 ms. After the baseline loop it
immediately requires `heldGroups.first` for the cross-app source. The Host
projects held groups after activation completes or its confirmed prefix yields.
The final selection is still finishing when that dependent check runs.

There is no separately timestamped `heldB` guard event or held-array dump at
that instant. Source order and the recorded verification/shutdown sequence
support this boundary explanation. The error before cleanup is explicitly
`crossAppSourceNotHeld`; the later fresh-directory rejection and navigation
error occur **after shutdown begins** and are cleanup cancellation, not an
earlier failed window operation. Group editing remains `NOT_RUN`.

## Accompanying corrections and their unverified scope

The changes prepared from these results have **not** been exercised by this
workflow. The next exact-head native build and formal R4 run remain required.

1. **Separate timely membership acknowledgement from complete positive
   observation.** The one issued move must obtain explicit forward/target and
   old-space-exclusion acknowledgement within 120 ms. Two full observations of
   the same original binding then have an explicit **650 ms total positive
   confirmation budget**. Both clocks start when the same `move_window` call
   returns. The second full view must also finish within that budget, with
   scope/observation authority rechecked. This is a deliberate change to move
   confirmation timing semantics; the already existing 650 ms passive-health
   budget did not previously authorize it. Transient-error retries retain the
   original 120 ms limit. The move is never resent, and missing or late landing
   does not become acceptable through a later positive AX view.
2. **Measure the pre-creation gap.** Existing directory trace records gain
   timestamps around the original short-circuit session check and request
   preparation. Pending admission, guards, publication and native query counts
   remain unchanged. No cause for the 670.610 ms gap is assumed.
3. **Wait for actual completion only at dependent acceptance boundaries.**
   The final singleton-cycle selection and `holdCombinedForSplit` can wait for
   the existing navigation lane to become idle. They retain the same ownership
   epoch and the newly accepted selection generation, require no navigation
   issue, and check the actual verified active group and exact selected member.
   Settlement must occur within `pressedAt + 8 seconds`; it gets no new timeout
   after physical confirmation. `R4SelectionSettled/Unsettled` records the
   separate endpoint. Earlier rapid selections, their original 120 ms pacing,
   physical readback checks and latency measurements remain unchanged, as do
   the original held-group guards.

These changes do not make the ac252 formal R4 result pass, do not establish
target-machine qualification and do not authorize release.

## Restoration and evidence integrity

Fast automatically releases its owned windows after the failed SHOW:
`1958.893403250 → 1959.216348833`, **322.835 ms**, PASS with zero remaining owned
windows. Its later terminal Host shutdown takes only **2.956 ms** because that
release already happened. One incomplete background directory appears during
restoration, after the first fault; it is retained as recovery evidence and is
not reassigned as the SHOW failure.

Full shutdown takes **1168.482 ms**. Its native release takes **214.159 ms**
within that interval and passes. Both lanes independently confirm all three
original windows at home with frames and visibility preserved on two external
reads. Their final ledgers are empty. These cleanup receipts do not prove an
earlier selection committed; no separate intermediate WAL timestamps are
claimed.

[Provenance](provenance.json) and [provider metadata](artifact-api-metadata.json)
tie every result to this source and workflow. The original
[workflow run](workflow-run.json), [jobs](workflow-jobs.json),
[fast manifest](fast-raw-manifest.json), [full manifest](full-raw-manifest.json),
[fast freeze verification](fast-freeze-verification.json), and
[full freeze verification](full-freeze-verification.json) are retained.
All 95 fast and 480 full raw files were compared byte for byte with their
provider ZIPs. The selected archive contains 136 original files, each checked
against its provider ZIP and then checked again after archiving.

| Evidence | Provider artifact ID | SHA-256 |
| --- | ---: | --- |
| fast ZIP | 15254598772 | `d747b913ba0c3176d03af6d81e444ca369c0f211ca34839c03a65d2f6694139d` |
| full ZIP | 15255137795 | `c07fce2413e7728fe25aa028936f98d2f0eae56d238eb86eed700f43f4b60e23` |
| source-context ZIP | 15255147826 | `eb8f097ab0b06b11b7b9e6d559b4e5de2c3f6b613875a7ec8b9891266b228301` |

The [runtime archive](runtime-traces-ac252.tar.gz) is 373,429 bytes, SHA-256
`6156f3a8a52ce9164fb95c1f4f9c0bb359816ea6a601c35d380d8b00ba0cbaf8`.
Its [manifest](runtime-traces-manifest.json) maps archive paths such as
`ac252/fast/independent-runtime/runtime/product.stderr.log` to original ZIP
members and hashes. Both analysis gzip streams have modification time zero and
an empty embedded filename; decompression reproduces the frozen JSON bytes
exactly. Compressed and original hashes are listed in provenance. No second,
large duplicate timeline is stored alongside them.
