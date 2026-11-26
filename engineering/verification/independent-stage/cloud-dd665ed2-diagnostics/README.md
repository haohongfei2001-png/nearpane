# Own-canary close readback blocks foreign execution; cleanup passes

Original receipts from
[run 45736296714, job 139630249974](https://github.com/haohongfei2001-png/nearpane/actions/runs/45736296714/job/139630249974),
revision `dd665ed2b9fe46731d518e811e8f98c948d59227`,
[artifact 15079391859](https://github.com/haohongfei2001-png/nearpane/actions/runs/45736296714/artifacts/15079391859).
The ZIP SHA-256 matches GitHub's digest. `provenance.json` hashes the three
byte-for-byte original receipts retained here.

This **26A434 / SIP-off diagnostics VM** reports **BLOCKED /
candidateCanaryNotConfirmed**, despite the enclosing Actions job's successful
completion. The first actual fault is in the controller-owned canary's close
observation, before any foreign-window move:

1. Own panel 71 moves to hidden Space 13 and returns to original home 12;
   `hidden-view` and `restore-member` report PASS.
2. One AppKit close is issued. The next CG description reports on-screen=1,
   while the independently obtained on-screen list reports the same ID absent
   (`spacesCGReadFailure`, `onscreen-samples`, first=1, second=0).
3. The first close read propagates Readback 217 immediately from `absent()`;
   it does not continue the existing bounded close-observation loop.
   Launch returns UNKNOWN, owned=2, after 264.7 ms overall. That time includes
   the earlier complete launch sequence; it is **not** a 120 ms close timeout.
4. The first original-owner release completes in 34.7 ms with owned=0.
   Two independent final observations verify the original Space inventory
   and all three untouched foreign windows' original home, identity and frame.
   **cleanup=true**.

The original result contains **windowWrites=0**. Initial foreign bindings,
both yellow-button cases, round trip, grouping, repeated switch and focus
are all **NOT_RUN**. This is neither a foreign migration failure nor another
foreign-engine pass. The separate product jobs keep their own receipts.

The accompanying narrow source correction treats only this own-canary
post-close Readback 217 as an unfinished read within the existing 120 ms
budget. It never infers absence from an error, resends close/move, or destroys
a Space without the existing positive emptiness checks. Two complete final
observations remain required; persistent unknown retains ownership and its
Readback cause for later cleanup. Synthetic regressions cover transient
readback errors followed by two complete reads and persistent errors with
bounded failure, no destruction, and later original-owner cleanup.
This historical receipt remains BLOCKED; the correction still needs a new
native execution.

**R4ProductPath=NOT_RUN** and **qualificationGranted=false**. No claim is made
for the user's 26A428 / SIP-on Mac.
