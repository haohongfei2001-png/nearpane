# R4 987215dc: real window effects confirmed; initial publication and later identity checks still stop the chain

**The complete release lane receives two actual R4 inputs and obtains two
external physical confirmations. The second transaction subsequently fails
during its final confirmation, so continuous R4 operation remains FAIL. Fast
exercises the existing initial retry, but the original intent is revoked before
the fresh complete directory can finish validation.**

Source: `987215dcbc79f1b50e22ceed1fc707b526acf3df`, original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46115081664](https://github.com/haohongfei2001-png/nearpane/actions/runs/46115081664)
is terminal. Both lanes disable external Host stack sampling. This head adds
14 diagnostic lines to the directory task-exit event; it changes no product
authorization, deadline, retry or window operation.

## Native source and package gates

Exact source passes **180 Rust**, **258 Swift with one existing gated skip**
(259 XML entries), and **25 native AX decoder checks with zero window writes**.
The initial retry's 43 parameter cases, persistent reader's ten cases and catalog
evidence codec's eight cases all pass. The complete release build and strict
signature pass. Early source logs and the full artifact's source logs are
byte-identical and identify this exact revision/build run.

[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log) and [decoder stdout](source/binding-attributes.log)
are preserved. Exact-target GUI acceptance remains NOT_RUN while its connector
is unavailable. These gates do not grant release qualification.

## Fast: the first incomplete sample revokes its own allowed retry

One actual AXPress produces no physical switch. Selection preparation succeeds.
The first witness's directory revision 5 reports exactly `windowRosterChanged`
and `windowIdentityOrBounds:pid=19941,window=79`.

The new bounded evidence shows window 79 absent from the first CG sample and
present in the second: PID 19941, frame **66 x 20 at (126, 392)**, visible, active,
ordered and owned by an unhidden application. Both membership observations are
unavailable, and its role was not requested. PID 19941 also owns authorized
documents 53 and 55, but 79 is not an authorized document. Its role is unknown;
the evidence does not classify it as a tooltip or a harmless surface.

| Event | Uptime / duration |
| --- | --- |
| Actual AXPress | 776.353698 |
| Revision 5 native sample | 776.517355–777.256694; 739.339 ms |
| Existing initial retry starts | 777.466073 |
| Revision 6 native sample | 777.534397–778.500686; 966.290 ms |
| Fresh directory returns to caller | 778.523048 |
| Original-intent guard rejects | 778.523610 |

Revision 6 is complete, with six rows and no catalog issues. It has not passed
the remaining cross-sample identity/frame/membership checks: the earlier current
guard rejects because ordinary Host revision changed from 0 to 1 and the permit
reports `restoring-management/native-catalog`.

Source inspection explains a specific publication race. Foreground and background
callers can share the same pending read. Before returning, `readNow` mutates
lifetimes and group projections; the observer can then publish the same incomplete
snapshot and pass it to `observeEnvironment`, which freezes the current intent.
The fresh retry result cannot repair that invalidated intent. The trace has no
freeze stack or snapshot-assignment timestamp, so this causal ordering is an
inference from code and events, rather than a directly recorded stack trace.

The failed witness lasts **2024.227 ms**, of which the two native samples total
**1705.628 ms**. Click to rejection is **2169.912 ms**, not a successful switching
latency. No role binding, focus, managed HIDE or SHOW is reached. A release of an
empty worker is cleanup, not recovery of hidden windows. [Fast analysis](fast-analysis.json)
contains exact event sources and the bounded row facts.

The following product fix is limited to this already-authorized first prebinding
retry: retain the actual incomplete result for validation while staging its
shared side effects/publication. A result-specific immutable marker must survive
a late observer; subsequent incomplete reads and all bound-window checks keep
their original failure behavior. Old published data must never authorize a write.

## Full: HIDE, SHOW and focus work; the second transaction does not settle

The two external physical confirmations occur **2183.082 ms** and **4398.461 ms**
after their respective actual inputs. These two samples are not a population
latency claim. Across the product sequence, the original worker returns PASS for
**three HIDE requests, one SHOW and nine health requests**.

The second input restores document 53. SHOW returns PASS in **109.839 ms**, and
its two complete witnesses pass. Focus 53 then passes both full confirmations,
sequences 22 and 23. HIDE of the former document 51 returns PASS in **219.903 ms**,
and the engine's post-witness, sequence 25, completes.

The coordinator's next required full read stops in its opening roster, before
re-observing physical windows. Candidate enumeration has completed; one retained
candidate and one unbound candidate have been visited. The unbound candidate's
role-access path throws the localized ownership error. Its identity and exact
subcondition were not recorded. The **19.762 ms** role interval includes task
queue and actor resumption; it is not proof of an AX role timeout.

The second external physical confirmation is at **1917.038439**. The failed
post-read is recorded at **1917.451456**, **413.018 ms later**, and navigation
fails at 1917.466223. A third button attempt is not issued
(`buttonMissingOrAmbiguous`). Thus two externally observed window states do not
establish two fully committed transactions. [Full analysis](full-analysis.json)
retains this distinction and the exact sequence map.

The only incomplete catalog recorded in this lane is revision 73, after the
first failure and during RELEASE. It concerns authorized document 51 returning
from unknown membership to known home 12, with its same birth/frame and restored
on-screen/active/ordered flags. This recovery observation cannot explain the
earlier unbound-role failure or an older run's unidentified candidate.

## Remaining cost and recovery

Each opening and closing roster in sequences 19–24 records four raw candidates,
two retained candidates and two awaited role queries, despite a final roster of
two windows. Each complete witness therefore makes four such role queries. This establishes
that the final roster size cannot identify the cost of excluded candidates.
For example, sequence 22 records **163.427 ms** of opening role queries and
**131.213 ms** across 21 whole-witness `unchangedPermit` checks, within its
**698.225 ms** total witness. These are nested elapsed intervals, not additive
click partitions or CPU samples. No permission check is removed on this evidence.

The original worker RELEASE takes **185.530 ms**. Final shutdown later takes
**2.337 ms**, which is not the full recovery cost. Host release and independent
two-read original home/geometry/visibility confirmation pass. Fixture termination
is recorded separately. Later group editing, lifecycle and crash gates remain
NOT_RUN after the core R4 failure.

[Provenance](provenance.json), [artifact metadata](artifact-api-metadata.json),
[workflow jobs](workflow-jobs.json), [comparison](comparison.json) and
[click timelines](click-timelines.json) preserve exact source and attribution.
All three downloaded ZIP hashes match provider digests. The original
[53-file trace archive](runtime-traces-9872.tar.gz) is **196,948 bytes**, SHA-256
`20440b4c578773e076cbfbe025227a8a927e524f419707a9d3e1d19a363892c3`;
its [manifest](runtime-traces-manifest.json) hashes every member.
The [source archive](cloud-source.zip) retains the early source gate logs.
