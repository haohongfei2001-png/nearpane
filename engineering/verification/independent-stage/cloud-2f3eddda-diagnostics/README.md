# Native regression passes with measured AX health recovery

Original receipts from
[run 45734124458, job 139623104672](https://github.com/haohongfei2001-png/nearpane/actions/runs/45734124458/job/139623104672),
revision `2f3eddda042e4280d80c3880127422c3819b6ebd`,
[artifact 15077848759](https://github.com/haohongfei2001-png/nearpane/actions/runs/45734124458/artifacts/15077848759).
The downloaded ZIP SHA-256 matches GitHub's digest. `provenance.json` hashes
the three byte-for-byte original receipts retained here.

This **26A434 / SIP-off diagnostics VM** reports **FOREIGN_ENGINE_PASS / verified**.
All 34 engine receipts verify, including six initial bindings, both real yellow
actions, the foreign round trip, same-app independence, cross-app combination,
all three A→B→C→A cycles and final release. Focus and all ten reported checks
pass. There are 26 engine hide/restore requests. The first release reaches zero
ownership; two independent final reads confirm every window's original home and
frame and the complete original Space inventory. **cleanup=true**.

The new health trace makes the actual timing explicit for the already-hidden
same-app sibling, window 55 in hidden Space 27:

| Health elapsed | Actual retained-witness result |
| --- | --- |
| 167 ms | AXCannotComplete; one bounded total recovery deadline of 1000 ms |
| 482 ms | AXCannotComplete again; deadline is not extended |
| 645 ms | Two complete positive observations; health recovers without a move |

This VM recovers just before the previous 650 ms limit. It demonstrates the
actual two-read recovery under the updated code, **not** a native observation
using the extra 350 ms allowance. The earlier different VM's persistent
health-unavailable failure remains a failed receipt. The synthetic timed
regression separately covers two blocking transport failures plus complete
read costs that take recovery beyond 650 ms.

The first active deminiaturization completes its two full original-witness
observations at **874 ms**, and the later one at **629 ms**, both before their
1000 ms limit. Both still require exclusive original hidden membership, real
CG invisibility, original frame and minimized=false. Temporary visible system
animation and extra non-managed membership are never accepted as final hidden
state.

The raw controller uses its existing 4000 ms ticket limit. This lane therefore
does not verify the production transport's separate 3000 ms mini / 2000 ms
health request limits or its R4 interaction path. Those require their own
product receipts. The original result explicitly retains **R4ProductPath=NOT_RUN**
and **qualificationGranted=false**, with no claim for the user's 26A428 / SIP-on
Mac or another job's behavior.
