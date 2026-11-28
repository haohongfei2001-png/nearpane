# Deminiaturization temporarily adds another Space membership

Original diagnostics receipts from
[run 45722428165, job 139583780099](https://github.com/haohongfei2001-png/nearpane/actions/runs/45722428165/job/139583780099),
revision `48c2ab44991c7dd3c7bf751ada2a2fe4a8ce5767`,
[artifact 15072299465](https://github.com/haohongfei2001-png/nearpane/actions/runs/45722428165/artifacts/15072299465).
The downloaded archive SHA-256 was independently verified against GitHub's
reported digest; copied original files are hashed in `provenance.json`.
This is build **26A434, SIP disabled**, separate from the target Mac.

Launch and all six initial visible registrations passed. The first never-hidden
window's retained original AX object again reported AXDialog while truly
minimized and passed the original-identity checks. The engine then migrated it
to hidden Space **15**, passed its minimized hidden-membership checks and issued
one AX deminiaturization request.

The new actual completion observations are decisive:

| Elapsed after the AX request | Window memberships | Hidden Space 15 contains window | Original home 12 contains window | Result |
| --- | --- | --- | --- | --- |
| 2 ms | `[15]` | true | false | Original AXMinimized is still true |
| 25 ms | `[15, 16]` | true | false | This revision immediately rejects any additional Space |

Operation 14 returned **UNKNOWN / detail 207 (Membership)** after about **54 ms**.
The 650 ms observation budget was not exhausted. These receipts **do not show a
return to the original home**. They also do not establish Space 16's type or the
original window's CG visibility at that moment: the view check stopped first
at AXMinimized=true, and no subsequent view check ran after the extra membership
triggered rejection. Calling this a confirmed desktop escape or a proven
animation-only Space would exceed the recorded evidence.

The follow-up records a fresh complete managed-desktop catalogue with its types,
reverse membership of every managed desktop, original CG visibility/frame and AX
minimized state. The optional SLSSpaceGetType read is diagnostic only; an absent
symbol creates no new product gate, and no private numeric type authorizes a
transition. A non-managed extra membership can only remain an unfinished
read-only observation while the original hidden membership persists in both
directions and every managed desktop excludes the window. Positive managed
membership or loss of the original hidden membership fails specifically. No
Space move or AX request is repeated. Final success still requires two complete
original-witness observations with exclusive original hidden membership, true
CG invisibility, unchanged geometry and minimized=false inside the 650 ms budget.

The recorded outcome remains **FAIL / initialYellowButtonFailed**; later group
and yellow checks are NOT_RUN. The first original-engine release returned all
three fixtures to their original home and geometry, destroyed the owned empty
Space, and restored the full original Space inventory in two independent reads.
**cleanup=true** does not promote the failed operation. The new classification
and final original-hidden-only result require a subsequent native run.
