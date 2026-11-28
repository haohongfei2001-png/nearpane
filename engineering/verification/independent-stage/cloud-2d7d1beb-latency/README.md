# R4 2d7d1beb: initial intent invalidation remains observable before any window write

**Exact-source tests and the complete release build pass. Both unsampled R4
lanes receive one actual input and confirm no switch. Neither issues a product
HIDE or SHOW. These failures do not qualify continuous R4 operation or release.**

Source: `2d7d1bebad792ccb04579949162cc4d8fefa6614`, original
[PR #16](https://github.com/haohongfei2001-png/nearpane/pull/16).
[Workflow 46114302429](https://github.com/haohongfei2001-png/nearpane/actions/runs/46114302429)
is terminal. This source adds failure evidence only; the hidden-Space backend,
write authorization, deadlines and existing one-time initial retry are unchanged.

## Native gates

| Gate | Result |
| --- | --- |
| Rust | 180 passed, zero failed; original stdout checked |
| Swift XML | 259 entries: 258 passed, one existing gated skip, zero failed |
| Initial directory retry tests | Seven functions / 43 executed cases passed |
| Persistent reader tests | Nine functions / ten executed cases passed |
| Catalog evidence codec | Three functions / eight executed cases passed |
| Native AX batch decoder | 25 passed, zero failures, zero window writes |
| Complete release build / strict signature | PASS; candidate qualification remains false |
| Exact-source target GUI acceptance | NOT_RUN; the target connector is unavailable |

The sole Swift skip is the existing environment-gated native minimize fixture.
[Source audit](source-gate-audit.json), [Swift XML](source/swift.xml),
[Rust stdout](source/rust.log) and [decoder stdout](source/binding-attributes.log)
preserve source verification separately from product acceptance.

## Fast: background publication revokes an in-progress witness

Fast reaches three bindings and two complete witnesses. During the third witness
(sequence 2, no visibility claims), the guard after the physical read of window
54 rejects the original intent. Ordinary Host revision has changed from 0 to 1,
and the permit reports `restoring-management/native-catalog`.

The failed witness lasts **758.754 ms**. Its opening roster retains all three
candidates without an unbound-role query. Eleven measured `unchangedPermit`
calls total **10.444 ms**; they do not explain the whole elapsed interval.
A concurrent directory read, revision 14, takes **507.750 ms** natively. These
intervals overlap and must not be added. The old task-exit trace does not retain
revision 14's catalog issues, so its exact incomplete row is unknown.

The actual click reaches the navigation queue in **39.916 ms** and is rejected
after **1878.502 ms**. These are failure timings, not completed switch latencies.
Product health passes in **14.202 ms**, and the largest worker poll queue delay
is **0.032 ms**. No managed-window write occurs. The later Dock expiration does
not explain the earlier first rejection. [Fast analysis](fast-analysis.json)
retains the original event order and its evidence gaps.

## Full: the selected appearance disappears before witness creation

Full stops earlier. After directory revision 4 returns, selection preparation's
`current()` check reports `appearanceMatches=false` and
`groupLifetimePresent=false`; its epoch still matches and the task is not
cancelled. No group binding, witness or product worker is created.

Revision 4's native sample takes **41.126 ms**. Task exit to the awaiting
`readAfterAction` caller takes **257.281 ms**. The actual click is rejected after
**378.692 ms**. The read task reports completion, but the old artifact does not
preserve that snapshot's catalog completeness or rows.

The ordinary lifetime update keeps every valid PID/birth/window identity; a
nonordinary role alone cannot remove it. Missing identity, changed identity or
another unlogged invalidation remain possibilities. The trace has one submitted
click and does not preserve all input counters, so it cannot establish a second
user input. The first Dock expiration is later. [Full analysis](full-analysis.json)
keeps these limits explicit.

## Recovery and frozen evidence

Both Hosts report released, and both independent two-read home/geometry checks
pass. With no product HIDE/SHOW, these cleanups are not managed hide/restore
round trips. Later group editing, window lifecycle and crash acceptance remain
NOT_RUN after the core R4 failure.

[Provenance](provenance.json), [artifact metadata](artifact-api-metadata.json),
[workflow jobs](workflow-jobs.json), [comparison](comparison.json) and
[click timelines](click-timelines.json) retain exact source and event attribution.
The three downloaded ZIP hashes match provider digests. The original
[48-file trace archive](runtime-traces-2d7d.tar.gz) is **161,075 bytes**, SHA-256
`d13c8817aca18daf0dddd3d610285931e9495ad419224c50e7241dcc33d1259a`;
its [manifest](runtime-traces-manifest.json) hashes every member.
The [source archive](cloud-source.zip) retains the early source gate logs.

The next diagnostic-only head, 987215dc, records bounded existing incomplete
catalog facts at every reader task exit, including results shared with the
background observer. It cannot retroactively identify these earlier missing rows.
