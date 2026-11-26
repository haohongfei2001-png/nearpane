# Nearpane — independent Stage Manager replacement

Current authority, 2026-11-27 (Asia/Shanghai). Baseline: PR #15, `6ac5eb63c97b7597e662770bac485be61f571bb8`.
Work branch: `pro/independent-stage-engine-20261126`.

## Product contract

Nearpane replaces Apple's Stage Manager. R4 flat, real-window thumbnails are its only stage interface.
The selected group contains real windows on the current ordinary desktop. Other groups leave that
desktop's work area by entering process-owned hidden Spaces. A card restores the original windows,
layout and exact focused member. Group identity is `Display → ordinary Desktop → StageGroup → window
(PID, process birth, CGWindowID, retained AX lifetime)`; applications are not the unit of dispatch.

Same-app windows may be in different groups; different apps may share one group. R4 merge, detach,
member selection and the existing screenshot, voice and file modules remain. Yellow minimize is an
event to retire the exact enrolled window and restore it through R4. Pre-existing Dock-minimized
windows retain their prior state. System desktop gestures, Mission Control, App Exposé, fullscreen,
Split View and desktop reveal remain system interactions.

Corner parking, wallpaper/shield masking, pointer interception to simulate invisibility, and Apple
native-strip mirroring are not product routes or fallbacks. Old receipts and recovery code are historical
evidence, not permission to choose one of those routes. A failed independent engine restores its owned
windows and stops scheduling; it does not silently activate another backend.

## Decision and its evidential boundary

**Implement route B: an independent hidden-Space scheduler.** Keep the existing Swift R4 and group
coordinator, Rust static library, and C ABI. This reuses implemented window identities, journalled group
switches, exact-window focus and geometry operations, and real preview ownership instead of replacing
the working product modules. The same Rust static library runs in a small sealed, bundled AppKit worker
so it retains the original AX leases and WindowServer connection when the Swift Host exits. Private
anonymous pipes carry the existing C request/receipt layout; EOF or parent exit enters release-only
cleanup and refuses to destroy an occupied Space. There is no second engine or same-process fallback.
Worker SIGKILL and WindowServer restart remain separate physical experiments, not inferred guarantees.

This is an implementation decision, not a claim that the complete macOS 27 product has passed.
The compiled candidate and the release qualification are separate paths. An explicit, separately
identified candidate application runs the complete Host and R4 with a separate profile. The automated
acceptance copy additionally restricts dispatch to enrolled fixture PIDs. Neither form manufactures a
passing qualification or overwrites `/Applications/Nearpane.app`.

### Current verification checkpoint

The latest completed source/full-package checkpoint is
`350e848cc30106c32156ddba2c222ab639ab141f`: **166 Rust /174 Swift pass, one explicit skip**.
Complete workspace, companion resources and strict/deep ad-hoc bundle signatures pass. The full,
fast and diagnostics VMs independently pass the normal foreign-window engine and cleanup. These
are hosted **27.0.1 /26A434 /SIP disabled** results, not target qualification.
[Full candidate and original result](../verification/independent-stage/cloud-350e-full/README.md).

The350e fast VM issues one confirmed AXPress, then a real native-context total age
of901.886ms withdraws dispatch before the group job or witness. The full VM stops
during external button discovery with AXCannotComplete/windowListRead=-25204,
before input. Both independently confirm cleanup. Their complete Host samples
identify repeated session reads during SwiftUI rendering, task identity and gallery
request construction. The following presentation correction reuses already observed
display/session/permission state for rendering while actual actions, capture and
pixel admission retain their fresh native checks. It does not widen750ms or
retry an already issued action. [Separate fast originals](../verification/independent-stage/cloud-350e-r4-fast/README.md).

The preceding8805 fast product input confirms the actual button's AXWindow is the retained panel, issues exactly
one successful AXPress and completes the first witness with three actual windows and three managed
members. The real Dock sample then arrives at total age 1133.81 ms, so ownership is withdrawn before
NP_LAUNCH. The full VM stops before input when its last retained-panel canonical identity read is
unconfirmed. Its original receipt lacks that inner call's error and does not prove a wrong window
or an AX timeout. Both product runs confirm cleanup; neither is a successful R4 switch.
[Separate fast originals](../verification/independent-stage/cloud-8805-r4-fast/README.md).

The new full Host samples retain the complete stacks. Fast has 10 of 86 main-thread observations
in the initial witness: opening-roster role reads, original-window binding and physical observation.
This identifies synchronous UI-actor work, not a quantitative allocation of the 1133.81 ms delay.
The Dock reader already runs on its own actor. The previous 3437 full sample independently identified
the two synchronous physical rebinding passes (104/114 samples), which 8805 moves off MainActor.
Fast already had bindings this time; it does not prove that cold rebinding was physically exercised.
Every await still rechecks current input/epoch, cancellation, directory and ownership before use.
Observed presentation state cannot replace a fresh permission check for actions or pixel
admission; original-AX checks and the750ms dispatch boundary remain intact.

The target Mac became reachable again on 2026-11-26 at 19:13 UTC. Its clean isolated clone was
fast-forwarded to 8805; the daily installation and working checkout were preserved. The actual
**27.0 /26A428 /SIP enabled** runtime created and independently verified three foreign windows.
Own-panel home discovery then obtained the same complete home4 at 3 and208 ms, but rejected the
second read against its120 ms discovery budget. There were **zero foreign hide/restore requests**
and no hidden Space creation. The original panel, fixture windows and Space inventory were
completely restored and both fixture processes exited normally. This is an executed pre-migration
engineering blocker, not a negative hidden-Space API result. The next source correction separates
own-panel discovery timing from real mutation acknowledgement and adds actual phase durations.
[Target originals and exact hashes](../verification/independent-stage/target-8805-panel-home/README.md).

The follow-up `350e848cc30106c32156ddba2c222ab639ab141f` now **passes the complete
normal foreign-window engine on the actual target27.0 /26A428 /arm64 /SIP enabled**.
It obtains34/34 verified receipts,10/10 checks and26 actual hide/restore requests across
two independent fixture apps/three windows: same-app independence, cross-app combinations,
three A→B→C→A cycles, first and later yellow actions and exact focus. First release returns
owned0; two complete final reads restore every original frame/home and the exact16-entry
Space inventory. Both fixtures exit0. The first and later yellow actions finish two
complete hidden/offscreen/nonminimized reads at925/927ms. Own-close actually encounters
Readback217 and recovers inside its existing observation loop.166 Rust regressions also
pass on this target, and the separate350e cloud source run passes166 Rust/174 Swift, one skip.
[Decisive SIP-enabled foreign-engine originals](../verification/independent-stage/target-350e-engine/README.md).

This confirms the route's foreign-window mechanism on the requested target, without claiming
all third-party applications or the formal R4 path. A second350e product invocation finds the
console locked with loginwindow foreground and correctly performs zero foreign moves. Its
product preflight also exposes Foundation canonicalizing existing output to/tmp while an
absent profile's parent remains/private/tmp. Canonicalizing both real parents fixes that
read-only configuration error; exact PID and directory scope constraints remain. The original
blocked invocation stays blocked and its fixture cleanup succeeds. No locked-session UI input
is attempted after that condition is identified.
[Separate original blocked run and path/console probe](../verification/independent-stage/target-350e-product-preflight/README.md).

Committed6e5b205d isolates retained original-AX reads from the UI actor. A narrow
immutable AX receiver crosses executors, while the mutable owner, monitor and writers remain
on MainActor; per-window read/write phases exclude concurrent native access. All original
window/owner/lifetime/claim/home/lease/permission checks remain before and after awaits.
Initial role enumeration, initial binding's full read and ongoing observations use this path.
The input helper now logs exact canonical read errors and may rediscover only an explicitly
incomplete pre-action read in its original6s budget; no issued action is repeated. These
source changes still require their own Swift code-generation and actual product results.

The existing lifecycle experiment now creates a window that has never been captured, selects a
real R4 card to hide it, then enables pictures within the original five-second pending interval.
A cold-preview PASS requires the original real held image and two physical reads of that same
hidden Space before any restore; blank images or a later successful restore cannot qualify it.
Main R4, crash/restart, cold-preview and lifecycle prerequisites remain separately NOT_RUN until
executed. Their completed source code is not promoted into a native result.

### What is established

1. At `9509bd0`, Nearpane's own panel entered hidden Space 5643 and returned to ordinary desktop 4 on
   macOS 27.0 / 26A428, SIP enabled. Dual membership reads, destruction and cleanup were recorded.
   [Original experiment](../verification/window-engine/single-version-26A428/RESULTS.md),
   [raw panel cycle](../verification/window-engine/single-version-26A428/11-formal-panel-cycle.json).
2. That run executed **zero third-party window actions**. Its admission/Host restrictions blocked them.
   Subsequent unexecuted trials are not a negative WindowServer result.
   [External admission](../verification/window-engine/single-version-26A428/11-external-admission.json).
3. Upstream has advanced from the fixed v1.9.1 through v1.9.2 to **v1.10.0**,
   `204d8de1ac2b682d147389c31a07b0a485ef9368`, published2026-11-26 at17:23:02UTC.
   The actual118-file incremental diff has been audited. Hidden bridge/create/destroy/masks,
   engine selection and own-panel probe semantics are unchanged; notification and Cmd-Tab
   ordering changes supply specific compatibility cases, not a new renderer-decoupling route.
   Corner screenshot/cover performance claims are not imported into Nearpane.
   [Release](https://github.com/eugene-tea/stage-manager/releases/tag/v1.10.0),
   [fixed incremental audit](INDEPENDENT-SPACES-SOURCE-AUDIT.md#v1100-delta-audit).
4. Its hidden-Space route uses `SLSSpaceCreate`, bridged add/remove (`options=7` to hide,
   `options=0xf` to return), `SLSCopySpacesForWindows`, reverse membership and `SLSSpaceDestroy`.
   `SLSBridgedMoveWindowsToManagedSpaceOperation` serves ordinary managed-desktop movement; it is not
   interchangeable with the hidden-Space add/remove route.
5. Upstream's launch probe tests its own window, its engine selection can fall back to Corner, and
   some Mission Control/activation handling temporarily parks windows in a corner. None of those is
   inherited as product success or as a fallback. The useful v1.9.2 fixes concern home-desktop identity,
   lifecycle, reactivation and display topology; their mechanisms need individual adaptation.
6. This repository previously set the product Spaces route to unavailable and selected Corner only.
   The candidate constructor, transport, Core session, independent physical witness and R4 Host now
   have an explicit Spaces path. A successful launch still does not qualify a foreign window.
7. At `bdedf131c94a85621cd24b8969ebbb3564afe0b1`, the production platform atoms moved two windows
   belonging to two separate fixture processes from ordinary Space 12 into hidden Space 13 and back.
   All four moves passed two complete physical observations of all three fixtures; the same-app sibling
   remained at home. The hidden Space was confirmed empty, destroyed, and the original Space inventory
   restored. [Original foreign-window evidence](../verification/independent-stage/cloud-bdedf131-platform/README.md).
   This establishes foreign-process hidden-Space movement on **26A434 / arm64 / SIP disabled**. It does
   not qualify the target SIP-enabled Mac, the Rust state machine, or R4. The normal engine controller
   stopped before its canary because the controlled fixture did not become foreground. Separately,
   removal of the CI-created ordinary Desktop 12 was not confirmed in that run; overall cleanup is not
   promoted by the successful hidden-Space transaction.
   The `e630b6bc` diagnostic independently repeated both foreign cycles on the original ordinary home 1,
   through hidden Space 12, with confirmed cleanup and **zero ordinary-desktop initialization inputs**.
   [Replication and full artifact reference](../verification/independent-stage/cloud-e630b6bc-diagnostics/README.md).
   This removes dependence on the CI bootstrap from the platform mechanism result, without assigning a
   synthetic ordinary UUID or promoting it to a state-machine/product qualification.
8. At `5607d3b3cddc6711514b16ce3fc7f431b03cd7db`, the normal candidate Rust engine itself passed
   its own launch canary, the independently observed foreign-window round trip, same-app separation,
   and a visible cross-app combination. This is stronger than the earlier platform-only result.
   Repeated switching then failed because the common receipt layer treated the Spaces session's
   aggregate `OWNED` flag as if the restored target were still hidden. The backend had recorded
   `ShowVerified`; another group's member remained owned. The corrected receipt contract retains
   that other member's ownership while accepting the target's verified home return. The original
   run remains a failure, with nine hide/restore request attempts including a later rejected cleanup
   request; its R4 path was not executed. [Normal-engine evidence](../verification/independent-stage/cloud-5607d3b3-full/README.md).
   A separate `afa7b8f8` run reached the canary but returned membership detail 207. The omitted
   upstream own-panel `CATransaction.flush()` has been restored and conditional phase diagnostics
   added; neither change is claimed to have resolved that run before a new physical result exists.
9. The subsequent `bbc08a09` normal-engine diagnostic passed its launch and all three A→B→C→A
   cycles, including 22 verified hide/show requests. The aggregate-ownership correction is therefore
   physically exercised. Yellow-button adoption was then refused because an earlier health read had
   already stopped scheduling; release failed an AX/minimized-state read and a same-app sibling
   remained in hidden Space 24. This is a real cleanup failure, not a reporting-only issue. The original
   failure and retained window are preserved in [the diagnostic evidence](../verification/independent-stage/cloud-bbc08a09-diagnostics/README.md).
   Precise health/AX diagnostics and bounded release retries retain the original lease and never
   substitute an unknown attribute with a false value. The separate full `81669d13` R4 run confirmed
   a complete catalogue, three distinct groups and the visible formal panel; its button search still
   stopped before any R4 input. Neither result grants a complete product or target-machine qualification.
10. Launch is not yet stable across hosted runs: the separate bbc full VM and the next `3bcb0640`
    diagnostic passed own-panel hidden-view but could not confirm the initial return. The latter's
    bounded, same-engine release completed physical cleanup, with zero foreign requests. Source
    audit identified an error classification defect: an unavailable or inconsistent CG observation
    was called Identity, prematurely ending the existing readback loop. The adapter now distinguishes
    Readback from a positively different PID/birth/window/original witness. It still requires two
    positive observations within the original deadline and never repeats the move. More precise
    diagnostics accompany this correction; its role in the observed failure requires a new run.
11. The `1d7402d4` diagnostic again passed launch and three full group cycles. The actual minimized
    request returned MinimizedOrAX before its precise failing precondition was recorded. Cleanup
    exposed a real, temporary AX CannotComplete on the original hidden A1 object; a second release
    on the same engine completed all physical restoration and destruction checks. Yellow behavior
    remains failed. Separately, the full `3bcb0640` product received its first real R4 AXPress, but
    subsequent state did not confirm a switch and no worker/WAL was created. Product entry and
    minimum-state diagnostics are being completed; neither input success nor recovery success
    substitutes for successful R4 scheduling.
12. The `32f22cd4` trace identifies the earliest yellow-time health fault: the original hidden A1
    object reports AX CannotComplete and is immediately latched restore-only. The subsequent
    correction preserves this specific AX error across C/Rust and retries only its observation,
    on the same witness, within the original 650 ms budget, requiring two complete positive reads.
    Positive changed state remains a fault. The next `33d65484` diagnostic actually recovered
    from that error with two complete reads, without latching the engine or repeating a move.
    Yellow adoption then reached its original binding checks and exposed a different, precise
    problem: the actually minimized window no longer reported the standard AX subrole. This
    is not an absent window or a failed hidden-Space operation. The next implementation retains
    the original standard AX object for every visible participant, including the active group
    before its first hide, and carries it through restoration. An actual minimized state on that
    same lifetime may admit a temporary subrole transition; a newly discovered unknown or
    dialog window cannot. Native validation must include yellow both before and after normal
    group switching. [Original health and binding evidence](../verification/independent-stage/cloud-33d65484-diagnostics/README.md).
13. The full `33d65484` candidate passed 155 Rust and 162 Swift cases, with one explicit Swift skip,
    the complete app build, and its strict bundle signature. This VM also passed launch and three
    normal-engine group cycles; yellow failed and cleanup passed. The R4 external client's actual
    AX reads timed out before it issued an input: `actualR4Inputs=0`. That cannot be called a failed
    handler or a successful product switch. Bounded external discovery now replaces the ineffective
    wait on the local hosting view's empty child list. [Original candidate and input receipts](../verification/independent-stage/cloud-33d65484-full/README.md).
14. The next `3e197761` diagnostic confirmed all six initial foreign-window readback registrations:
    three windows, two positive samples each, flags 45 and zero hidden ownership. The first current
    window, before any HIDE/SHOW, retained the exact original AX object through minimization. Its
    actual temporary subrole was **AXDialog**, which the initial AXUnknown allowance rejected.
    No foreign mini move was issued and cleanup passed. The narrow follow-up permits that observed
    dialog state only on the already registered standard object with the same positive identity,
    true minimization and false fullscreen checks. Newly discovered dialogs remain ineligible.
    [Original registration, subrole and cleanup receipts](../verification/independent-stage/cloud-3e197761-diagnostics/README.md).
15. The `44bc3759` diagnostic accepted that actual original-object AXDialog transition, moved the
    minimized foreign window into hidden Space 15 and passed the engine's hidden-membership check.
    After one AX deminiaturization request, its reused 120 ms Space observation deadline expired
    during real minimized/AXCannotComplete observations. Cleanup passed; the first yellow operation
    still failed. The follow-up separates the AppKit completion observation into a 650 ms budget,
    keeps the same witness and single write, and stops on any positive return to the original home
    or another Space. [Original boundary and cleanup](../verification/independent-stage/cloud-44bc3759-diagnostics/README.md).
16. In the separate full `44bc3759` VM, a real R4 AXPress reached current-card selection, the fresh
    complete group directory, worker creation and a configured session. All three actual window
    previews rendered. Activation then returned incomplete before any NP_LAUNCH reached the worker;
    physical windows stayed at home and cleanup passed. This narrows the failure to the initial
    Swift witness/prelaunch boundary, not the hidden-Space API. Read-only phase diagnostics now
    distinguish original binding, AX/CG geometry, membership, actual focus and a successfully
    returned witness from later coordinator checks. [Original product, worker and screenshot](../verification/independent-stage/cloud-44bc3759-full/README.md).
17. At `48c2ab44`, yellow's one deminiaturization request produced forward memberships `[15,16]`
    while original hidden 15 still contained the window and home 12 did not. The previous rule
    stopped on any extra membership after about 54 ms. This does not prove desktop escape or the
    type of Space 16. The next implementation observes the complete managed catalogue and every
    managed reverse membership. Additional non-managed membership remains unfinished, never PASS;
    actual managed membership or loss of the original hidden membership stops. Final completion
    still needs two original-witness samples with exclusive original hidden membership, true CG
    invisibility, unchanged frame and minimized=false, with no repeated move or AX write.
    [Original membership and cleanup evidence](../verification/independent-stage/cloud-48c2ab44-diagnostics/README.md).
18. The full `48c2ab44` R4 trace identifies `focused-window-identity` as its first failed physical
    read: the actual front process was Finder, whose focused object was AXScrollArea with no CG
    window number. No NP_LAUNCH occurred. The source correction requires the exact system Finder,
    an original AXScrollArea whose parent is that application, a positively absent containing
    window and its exclusion from the complete AXWindows list. The same original AX element and
    process generation must persist. Unknown focus is not converted to desktop focus. Swift and
    the C canary use this same positive structural proof; the next native run must establish that
    the observed object actually has this structure. [Original exact phase](../verification/independent-stage/cloud-48c2ab44-full/README.md).
19. The `b43d5a93` diagnostic positively excludes the extra Space 16 from the complete managed
    catalogue and reports raw type 3. During the actual system animation the window is temporarily
    CG-onscreen with changing geometry; those samples are not hidden PASS. By 621 ms the observed
    fields have converged to exclusive hidden 15, offscreen, original frame and minimized=false;
    the next observation at 653 ms exceeds the then-current 650 ms budget, so the operation still
    fails. The following source gives this active completion 1000 ms for the measured animation
    and two complete original-witness reads. Health remains 650 ms and Space acknowledgement
    120 ms, with no repeated write or relaxed final state. [Actual convergence and failed operation](../verification/independent-stage/cloud-b43d5a93-diagnostics/README.md).
20. The `b43d5a93` early source run passes 160 Rust and 169 Swift cases, with one explicit skip.
    Its separately labelled foundation/debug R4 run receives a real press but loses dispatch
    eligibility and its navigation epoch while awaiting native system confirmation, before the
    group-choice Host or worker starts. It does not exercise the Finder correction. The next
    read-only trace records the actual Dock reading interval, reason and ownership transition;
    the 1.265-second interval alone is not sufficient to infer a cause. [Original fast-run boundary](../verification/independent-stage/cloud-b43d5a93-r4-fast/README.md).
    The complete release build independently reproduces the same pre-worker withdrawal during
    a 1.400-second system confirmation, with three real previews subsequently rendered and cleanup
    confirmed. Build and strict bundle verification pass; product scheduling does not.
    [Complete candidate and separate release receipt](../verification/independent-stage/cloud-b43d5a93-full/README.md).
21. The `9cec081f` normal-engine diagnostic passes every required engine check on the **same**
    26A434/SIP-disabled VM: initial visible registration, the first never-hidden window's real
    yellow button, third-party round trip, same-app separation, cross-app combination, three full
    B/C/A cycles, the later yellow button and focus. Its 34 operation receipts are verified,
    including 26 actual hide/restore requests. The first/later minimized completion each obtains
    two full original-witness observations at 700/654 ms. The first release returns every surviving
    window and restores the full original Space inventory in two reads. This is actual
    `FOREIGN_ENGINE_PASS`, not inference from a successful CI job. It still supplies no R4 product
    or target-SIP-enabled qualification. [Original complete engine result](../verification/independent-stage/cloud-9cec081f-diagnostics/README.md).
22. The `9cec081f` complete release independently passes source, build, signature and normal-engine
    checks. Its real R4 press passes the signed-Dock check in 12.09 ms, reaches the worker and
    identifies a different Finder desktop representation: the top-level AXScrollArea is included
    in the full AXWindows list and AXWindow returns another AXScrollArea reference. The old
    unlisted/empty predicate rejects it. Self equality and exact list count are not established
    in that original receipt. The next Swift/C branch requires actual CFEqual to the original
    object and exactly one occurrence before recognizing this listed form.
    [Original actual structure and complete candidate](../verification/independent-stage/cloud-9cec081f-full/README.md).
23. The separate `9cec081f` debug run stops before input: the final button attributes return
    **AXCannotComplete (-25204)**. It does not prove a replaced SwiftUI object. The next helper
    batches the same six attributes, preserving per-field errors and all identity/frame checks;
    only a still-unissued transient read may rediscover within the original six-second budget.
    AXPress remains a single, non-repeated action. The acceptance's synchronous native readback
    also moves off the UI actor, with immutable samples and read/delivery timestamps, so testing
    does not itself occupy the actor being measured. This is a confirmed source isolation issue,
    not proof that it caused the older b43 timing failures.
    [Original no-input result](../verification/independent-stage/cloud-9cec081f-r4-fast/README.md).

Cold Host startup now has a read-only reconciliation path for a completed Spaces worker. A durable
record binds the original owner, nonce, boot, Host and worker generations before the first launch.
On the same boot, exact worker destruction and both process exits precede two independent window/home
and hidden-Space observations; only then can the old ledger be retired. A positive new boot separately
retires the former WindowServer's authority. No saved CG number recreates an old AX writer. The unified
crash test includes same-profile relaunch and another real R4 selection; implementation and actual
restart acceptance remain distinct until that path runs.

An explicit current R4 card click can establish new session bindings after that old authority has
ended. It first obtains a fresh complete ordinary-desktop roster; if any live participant needs a
new binding, two independent physical reads validate the entire current scope before atomically
binding its new lifetimes. A partly present saved group is rejected without partial mutation;
wholly absent historical groups are retained. The same click then continues through normal group
selection. An already bound click keeps its fast path. A missing current group projection no longer
silently downgrades a Spaces selection to ordinary focus. This source path still needs its own
real R4 input and physical scheduling receipt.

### Route A: not a product dependency

The discovered Apple integration follows existing native thumbnails through AX/gesture routes.
It does not independently disable their rendering and edge activation. Apple's documented recent-app
setting still allows edge reveal. An AX action's success return does not prove a group changed; upstream
has recorded successful-return/no-effect cases. These mechanisms cannot satisfy the product contract.

This evidence does **not** establish that a private decoupling mechanism can never exist. The remaining
question is executable research, isolated under [native-stage-decoupling](../../tools/native-stage-decoupling/README.md).
Its runtime/selector inventory and reversible edge sweep classify contrary observations as REJECTED and
missing evidence as INCONCLUSIVE; absence of AX nodes is never a decoupling PASS. Product code has no
dependency on a hypothetical strip-suppression interface.

The Pro session has now executed the read-only inventory on the actual 27.0 / 26A428 / arm64 / SIP-on
Mac. SkyLight, WindowManagement and WindowManager loaded; 394 runtime classes and the inherited
bridged-operation ABI were recorded. The two migration operations are Objective-C classes, not C
symbols. The asynchronous `performWithWMBridgeDelegate` returns void and takes no explicit argument;
the synchronous superclass method returns an object. Swift strip-gesture/layout symbols were present,
but no callable rendering/edge-suppression separation was proved. Preferences were unchanged throughout.
[Machine receipt](../../tools/native-stage-decoupling/evidence/macos-27.0-26A428-inventory.json).

Hosted controls now provide actual negative evidence for two concrete renderer hypotheses.
At `a73454a1` on macOS 27.0.1 / 26A434 / arm64 / SIP disabled, both `AutoHide=true` and
`LeftStripMaximumRowCount=0` produced native tilted thumbnails corroborated by AX members,
onscreen CG surfaces and captured pixels. AutoHide exposed them on left-edge dwell; the zero-row
setting left them rendered even at baseline. Each experiment retained 13 observations and restored
preferences, fixtures, pointer and foreground. [Original receipts and two decisive crops](../verification/independent-stage/cloud-a73454a1/README.md).
This rejects those two configurations, not every possible private separation mechanism and not a
substitute for a 26A428/SIP-on acceptance result.

## Runtime and system coordination

- The engine owns only the precise windows it enrolled. The original ordinary desktop is retained for
  each hidden member; hidden-Space IDs never replace the user's ordinary-desktop identity.
- Each actual move must be read back through both space membership directions and independent CG/AX
  visibility and geometry. No API status, mock, own-window probe or CI compile substitutes for that readback.
- The ordinary catalogue can still see a hidden window in CG's all-window list. It excludes that row only
  after two inclusive membership queries agree on exclusively non-managed Spaces, reverse membership
  confirms the exact window, and both CG observations are offscreen. Missing/empty membership alone
  remains incomplete. This prevents the Host from revoking its own correct hidden group while retaining
  all ordinary-desktop and window-identity requirements.
- CG's all-window list also contains allocated, unmapped surfaces. A separate exclusion requires two
  actual empty inclusive Space arrays and two complete CG onscreen, AppKit active and AppKit all-Spaces
  inventories that all omit the unchanged PID/birth/window identity. A missing CG `IsOnscreen` key is
  unknown, never false; an independent complete onscreen enumeration supplies negative evidence.
  This only excludes a surface from that sample's work-window roster. It cannot retire an owned window,
  release an AX lifetime or clear recovery ownership.
- Restore first; then destroy only an empty owned Space. Partial/uncertain moves retain recovery ownership.
- System overview handling returns windows to their real ordinary desktop and does not park them in corners.
  Fullscreen and native split windows remain outside ordinary group management.
- Blank-desktop reveal keeps inactive groups in their real hidden Spaces while pausing new group,
  arrival and minimize actions. It does not return hidden windows into the native reveal animation.
  Fresh ordinary-context and two physical visibility reads reopen scheduling; this grants no focus
  transfer. An actual desktop change, native overview or session suspension still returns ownership
  to the system even if wallpaper reveal had already paused dispatch.
- Returning from system navigation resumes the group of the independently verified focused window in the
  same serialized R4 action lane. A newer input supersedes it. Retained read-only AX objects reconnect
  ordinary sidebar appearances after two observations; old file leases are released before reacquisition.
- Restore preserves geometry and reads the current WindowServer stacking order. A group keeps its last
  visible order; only a changed order causes exact-window focus/raise operations, ending with the selected
  member. This implementation still requires physical group-order verification.
- Cached thumbnails retain the original window lifetime. They are pictures of actual windows, not a masking
  mechanism. A stale picture cannot authorize a new window mutation.

## Verification and delivery

Unified entry: `python3 scripts/acceptance/independent-stage/run.py OUTPUT --scope all`.
The source phase compiles/tests Rust, Swift Core/Host/UI and the C ABI. In `--scope all`, the same entry
then builds the complete embedded application, seals its separate workspace package, and supplies the
full application to product acceptance. The runtime phase
creates two independently owned fixture applications, one with two windows and one with one window,
and verifies foreign-window hide/return, bystanders, same-app independence and recovery. Product R4
acceptance is recorded separately; it may not be inferred from the low-level trial.

Results are appended here and under `engineering/verification/independent-stage/` after execution.
The target foreign engine and its yellow actions now have completed350e receipts. Formal R4,
native overview, physical gestures, product yellow routing and crash/lifecycle paths remain **NOT_RUN**
until their own completed results exist; engine-only evidence does not qualify them.

No unsigned/ad-hoc remote candidate is advertised as a notarized install. Existing signatures, installed
daily builds and uncommitted work in other checkouts are preserved.

### Executed checkpoints

- macOS source checks: the 147 Rust cases passed on the target Mac and on the hosted macOS runner.
  A synthetic own-panel wait originally depended on wall-clock CPU scheduling; its fake clock is now
  deterministic while the real 120 ms deadline is unchanged. Swift production modules and the complete source-check step then passed at `2a0cfbe9`. The complete
  embedded release also compiled and passed resource verification; the later workflow signature check
  incorrectly treated the Host inside its resource-bearing bundle as a standalone executable. The
  corrected whole-bundle package verification passed at `283831ef`, including the sealed native
  worker and complete workspace ZIP. Original receipts and checksum are in the evidence index.
- Hosted `283831ef` runtime stopped at the ordinary-desktop preflight before canary/enrollment;
  foreign writes were zero and fixtures exited normally. Product investigation found an obsolete
  exact-build read gate and a managed-only membership query in its physical witness. The read shim
  now attempts current arm64 Darwin 26 ABI-family symbol/shape reads, and the physical witness uses
  mask 15 to include classic hidden Spaces. Write qualification remains independent. Subsequent
  diagnostics distinguish the raw native topology, C parser refusal and product cleanup result.
- Hosted `85762ae0` passed source, full workspace packaging and strict/deep signature verification.
  Its raw WindowServer dictionary proved a real GUI with a single initial ordinary desktop whose
  native UUID was empty. Foreign writes remained zero; product cleanup now passed independently.
  [Original terminal receipts and candidate](../verification/independent-stage/cloud-85762ae0/README.md).
  The next CI-only preparation uses actual Finder/Mission Control/Dock operations to initialize a
  native desktop, never a generated identity. An uninitialized inactive desktop may remain in the exact
  topology but cannot become the current or retained home. Target-machine runs do not perform this CI setup.
- The first target runtime at `da51f75` obtained AX permission and independently read three real windows
  in two fixture processes twice. `NP_LAUNCH` then stopped with detail 217 before any third-party write.
  [Original receipt and log](../verification/independent-stage/target-da51f75/README.md).
- The controller's event-loop defect was reproduced with the same own-panel code: manual run-loop pumping
  failed preparation, whereas a real `NSApplication.run` succeeded at prepare/open/read/close. A subsequent
  main-queue reentrancy issue was corrected by running the controller scenario on a worker and reserving
  the main queue for AppKit. These are harness defects, not negative foreign-window migration results.
  [A/B receipt](../verification/independent-stage/target-own-panel-runloop-20261126.json).
- Hosted Actions uses macOS 27.0.1 / 26A434 with SIP disabled. Its source/build and available GUI receipts
  are useful but cannot substitute for the target 27.0 / 26A428 / SIP-on result.

The definitive latest result and candidate commit will be recorded in
[`engineering/verification/independent-stage/`](../verification/independent-stage/) when the running
source, full-package and controlled foreign-window experiments complete.
