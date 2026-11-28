# R4 d86660db: metadata scopes finish; the next current-card click is not queued

**Both native lanes complete the first real window switch. Each receives a
second actual thumbnail press while the first transaction is finishing, but
the old current-card handler rejects that press before navigation submission.
The metadata scheduling change is exercised successfully. Continuous R4
operation remains FAIL, with no product SHOW in this run.**

Exact source: `d86660db6c4091d7c708544d79cf14844688d907`, original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46122156556](https://github.com/haohongfei2001-png/nearpane/actions/runs/46122156556)
is terminal. This head gates ordinary metadata admission around one complete
Witness read or one Spaces visibility primitive. It drains already admitted
producers and their original publisher, then explicitly shares the read scope
through the existing preflight, write, READBACK, double confirmation and WAL
after-image. Window authority and operation budgets are unchanged.

## Native source and candidate gates

| Gate | Exact-source result |
| --- | --- |
| Rust | 180 passed, zero failures or ignored tests |
| Native AX decoder | 25 passed, zero failures, zero window writes |
| Swift XML | 271 entries: 270 passed, one existing gated skip, zero failures |
| New metadata scheduling cases | Seven functions / thirteen executed cases passed |
| Complete candidate / strict bundle signature | PASS; qualification remains false |
| Direct foreign-window engine, both lanes | PASS, separate from the formal R4 result |

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log), [decoder stdout](source/binding-attributes.log)
and [candidate receipt](candidate-receipt.json) retain the original results.
Full Swift log, stderr and source summary are byte-identical to the early
context artifact. Existing prepared-dispatch, complete-baseline, double-post,
WAL and recovery gates remain passing. Target-machine GUI acceptance is
NOT_RUN; cloud mechanism evidence does not grant exact-target qualification.

## First switch: distinguish physical visibility from transaction completion

| Observation | r4-fast | full |
| --- | ---: | ---: |
| Actual AX thumbnail presses | 2 | 2 |
| External double physical confirmations | 1 | 1 |
| Completed internal group transactions | 1 | 1 |
| First input to external confirmation | 1337.591 ms | 1550.422 ms |
| First input to transaction completion | 1670.221 ms | 1850.259 ms |
| Second input before first completion | 78.204 ms | 48.534 ms |
| Successful HIDE / product SHOW | 2 / 0 | 2 / 0 |
| Complete witnesses | 17 | 17 |
| Scope reserved / drained / ended | 13 / 13 / 13 | 13 / 13 / 13 |

In both lanes the selected original window is window 55. Its exact focus passes
the two complete witnesses at sequences 4 and 5. HIDE of window 57 passes the
original Rust READBACK and complete post witnesses 7 and 8; HIDE of window 58
passes READBACK and complete post witnesses 10 and 11. Final verification also
completes, followed by `group-choice-exit completed=true` and a handled result.
The raw journal and post sequence are retained in the runtime archive.

The external observer sees the desired physical state before the Host finishes
its own required confirmations: by 332.627 ms in fast and 299.834 ms in full
(using the original completion-event timestamps). An external confirmation is not
the internal commit point. [Comparison](comparison.json) and the
[non-overlapping click timelines](click-timelines.json) keep those endpoints
separate. These are two individual runner samples, not a population latency
claim or evidence for changing a timeout.

## The next press reaches the card immediately, then stops before submission

| Event | r4-fast uptime | full uptime |
| --- | ---: | ---: |
| Second actual AX press, window 57 | 923.065717 | 1811.026745 |
| `current-card-press` | 923.065899 | 1811.026923 |
| `choose-group` | 923.066241 | 1811.027236 |
| First transaction completes | 923.143920 | 1811.075279 |

Both second presses act on the original, enabled current-desktop AX button.
The card logs `appearancePresent=false`, `visibleGroup=none`, and zero visible
group members. `choose-group` records `lifetimePresent=false` and
`stillGrouped=false`. There is exactly one navigation submission/dequeue in
each lane, so no second SHOW or second engine post-write failure follows.
Full's second press reaches the card in 0.178 ms and the group handler in
0.492 ms. This failure occurs before the existing navigation queue.

The source explains the handoff: fresh foreground inventory correctly removes
the ordinary appearance of a now-hidden window, while the observer-published
snapshot still draws the prior current row. The Host publishes its held groups
after the first activation finishes. The second press lands between those
events. The retained AX binding, ownership and hidden-window confirmations
remain intact; ordinary appearance expiry must not be reversed to repair it.

The later complete/fresh revision 50 also lacks ordinary/group lifetimes for
the hidden windows, which is expected. That later directory does **not** prove
that the old current UI remains clickable after transaction completion. This
run has no third, post-completion press. The observed defect is the actual
pre-completion current-to-held selection handoff.

The next product change carries only the explicit original member choice into
the existing stage queue, then resolves a current held group and performs its
normal fresh witness and coordinator checks. The selected member must remain
exact even without a historical image. A partial group, changed owner or stale
identity cannot become write authority through this intent.

[Fast analysis](fast-analysis.json) and [full analysis](full-analysis.json)
preserve the original event locations and the limits of this interpretation.

## Metadata admission is exercised, including real prior publishers

Every scope in both lanes has a matching reserve, drain and end. In the first
transaction, each witness scope creates its two fresh directory reads and each
HIDE scope creates six for the original preflight and two post witnesses.
No additional producer is observed entering an acquired scope. A later idle
held-refresh witness uses the same mechanism at its own priority; those owner
reads are not background bypasses.

Full drains already admitted producer/publisher work twice in the first
transaction, taking 16.688 ms and 4.133 ms. Fast exercises a corresponding
33.727 ms drain during a later held refresh. The raw scope marks show both
pending flags true at reservation and false on acquisition. Old publication
finishes normally before foreground admission.

Fast's two HIDE scopes are held for 254.322 / 255.238 ms; full's for
253.256 / 265.962 ms. These intervals already include health, preflight, native
HIDE, READBACK and the two complete post witnesses. They must not be added to
their nested work. The scope's original `durationMS` also includes acquisition
queuing; the analysis uses event timestamps to separate reserve-to-drain from
drain-to-end.

Neither lane records an incomplete directory, rejected witness, role failure or
worker error. The original first-directory retry/staging branch is not used.
The earlier HIDE/background-directory interruption is not reproduced in this
run; ordinary incomplete results still retain their original revocation rules.

## Recovery and frozen evidence

| Recovery observation | r4-fast | full |
| --- | ---: | ---: |
| Original worker RELEASE | 128.581 ms | 135.885 ms |
| Host shutdown, including return work | 196.885 ms | 264.361 ms |
| Final worker owned count | 0 | 0 |
| Independent two-read home / frame / visibility | PASS | PASS |

Both lanes restore their two real hides, destroy the worker engine and drain
pending work. Group editing, lifecycle, system interaction and crash acceptance
remain NOT_RUN after the second-click failure. No release qualification is
granted by successful recovery.

[Provenance](provenance.json), [artifact API metadata](artifact-api-metadata.json)
and [workflow jobs](workflow-jobs.json) identify the exact source and native
runs. All three downloaded ZIP hashes match provider digests. The fast/full
raw manifests cover 90 / 440 extracted files. The selected
[100-file runtime archive](runtime-traces-d866.tar.gz) is 191,138 bytes, SHA-256
`efc6988264380fbe839e0b094ba01762bb52023632026f82a11fdf354682c0cb`;
every [manifest](runtime-traces-manifest.json) member was compared byte-for-byte
with the corresponding provider ZIP and checked again after archiving.
The [early source archive](cloud-source.zip) retains its original 32,843 bytes.
