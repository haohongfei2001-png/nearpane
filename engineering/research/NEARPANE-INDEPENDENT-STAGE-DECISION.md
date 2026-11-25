# Nearpane — independent Stage Manager replacement

Current authority, 2026-11-26. Baseline: PR #15, `6ac5eb63c97b7597e662770bac485be61f571bb8`.
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

### What is established

1. At `9509bd0`, Nearpane's own panel entered hidden Space 5643 and returned to ordinary desktop 4 on
   macOS 27.0 / 26A428, SIP enabled. Dual membership reads, destruction and cleanup were recorded.
   [Original experiment](../verification/window-engine/single-version-26A428/RESULTS.md),
   [raw panel cycle](../verification/window-engine/single-version-26A428/11-formal-panel-cycle.json).
2. That run executed **zero third-party window actions**. Its admission/Host restrictions blocked them.
   Subsequent unexecuted trials are not a negative WindowServer result.
   [External admission](../verification/window-engine/single-version-26A428/11-external-admission.json).
3. Upstream has advanced from v1.9.1 `69a73665488243bf78982c6d523ac4e0850c1ddb` to v1.9.2
   `19e6e490bc91e65cef6a782075b5450e3159fd2d`.
   [Release](https://github.com/eugene-tea/stage-manager/releases/tag/v1.9.2),
   [fixed implementation](https://github.com/eugene-tea/stage-manager/tree/19e6e490bc91e65cef6a782075b5450e3159fd2d/src/platform/spaces).
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

## Runtime and system coordination

- The engine owns only the precise windows it enrolled. The original ordinary desktop is retained for
  each hidden member; hidden-Space IDs never replace the user's ordinary-desktop identity.
- Each actual move must be read back through both space membership directions and independent CG/AX
  visibility and geometry. No API status, mock, own-window probe or CI compile substitutes for that readback.
- Restore first; then destroy only an empty owned Space. Partial/uncertain moves retain recovery ownership.
- System overview handling returns windows to their real ordinary desktop and does not park them in corners.
  Fullscreen and native split windows remain outside ordinary group management.
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
Until a result is actually recorded, it is **NOT_RUN**, including third-party success, native overview,
yellow minimize, physical gestures, normal/crash recovery, and end-to-end R4 operation on the target Mac.

No unsigned/ad-hoc remote candidate is advertised as a notarized install. Existing signatures, installed
daily builds and uncommitted work in other checkouts are preserved.

### Executed checkpoints

- macOS source checks: the 147 Rust cases passed on the target Mac and on the hosted macOS runner.
  A synthetic own-panel wait originally depended on wall-clock CPU scheduling; its fake clock is now
  deterministic while the real 120 ms deadline is unchanged. Swift production modules and the complete source-check step then passed at `2a0cfbe9`. The complete
  embedded release also compiled and passed resource verification; the later workflow signature check
  incorrectly treated the Host inside its resource-bearing bundle as a standalone executable. The
  corrected whole-bundle package verification is tracked in the evidence index.
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
