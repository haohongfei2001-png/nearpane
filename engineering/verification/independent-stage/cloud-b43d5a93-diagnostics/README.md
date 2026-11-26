# Active deminiaturization converges after the old observation margin

Original diagnostics receipts from
[run 45726209534, job 139596608798](https://github.com/haohongfei2001-png/nearpane/actions/runs/45726209534/job/139596608798),
revision `b43d5a93797c993cf7f7561711d799dd714e3fe1`,
[artifact 15074487920](https://github.com/haohongfei2001-png/nearpane/actions/runs/45726209534/artifacts/15074487920).
The downloaded ZIP SHA-256 was independently checked against GitHub's digest.
`provenance.json` hashes the three byte-for-byte original files retained here.
The actual host was **26A434, SIP disabled**. This is separate from the user's
target Mac and grants no target qualification.

The initial six visible registrations and own-panel launch passed. The first
never-hidden foreign window was genuinely minimized, retained its original AX
identity, moved into hidden Space **15**, and received one AX deminiaturization
request after the minimized hidden-membership checks. The new observations
distinguish the extra Space from a return to a managed desktop:

| Elapsed after AX request | Forward memberships | CG onscreen / frame | Original AX minimized |
| --- | --- | --- | --- |
| 7 ms | `[15]` | false / `[120,386,250,202]` | true |
| 194 ms | `[15]` | false / original frame | unavailable, AXCannotComplete |
| 404 ms | `[15,16]` | true / `[439,530,512,203]` | unavailable, AXCannotComplete |
| 589 ms | `[15,16]` | true / `[120,386,363,202]` | false |
| 621 ms | `[15]` | false / original frame | false |
| 653 ms | `[15]` | false / original frame | false |

Every row independently confirms original hidden Space 15 contains the window,
and the fresh complete managed catalogue is `[[1,0],[12,0]]`. Both managed Spaces
exclude the window in reverse membership. Space 16's raw reported type is **3**;
this is diagnostic information, not authorization based on a private constant.
There is no observed return to home Space 12. There **is** actual temporary CG
onscreen visibility and changed geometry during the system transition. Those
samples do not pass hidden verification, and this receipt must not be described
as uninterrupted invisibility.

The original membership, visibility, geometry and minimized state have converged
by the 621 ms row. The subsequent row is already at 653 ms, beyond this revision's
**650 ms** completion deadline. The final operation returns **UNKNOWN / detail
217 (Readback)** after **703 ms** overall. These membership-log rows are not a
replacement for the two complete retained-witness view checks or a passing
operation receipt. The recorded result remains **FAIL / initialYellowButtonFailed**;
the later group-switch and second yellow-button checks are **NOT_RUN**.

The next implementation gives active deminiaturization a separate **1000 ms**
completion budget to include the measured animation and two complete reads.
Passive AX health remains **650 ms** and Space move acknowledgement **120 ms**.
It repeats neither the migration nor the AX request, preserves immediate failure
for actual managed membership or loss of the original hidden membership, and
still requires two final complete views with exclusive original hidden membership,
CG offscreen, the original geometry and minimized=false. A synthetic regression
models a 600 ms transition with actual intermediate visible geometry and 20 ms
per AX read; it verifies that complete settled reads occur after 650 ms, before
1000 ms, with only one move and one AX write. This regression is not a native PASS.

The first original-engine release passed. All three foreign windows were verified
on their original home and geometry, the empty owned Space was destroyed, and two
independent reads restored the complete original Space inventory. **cleanup=true**
does not promote the failed yellow-button operation. A subsequent native receipt
must establish success under the new active-completion budget.
