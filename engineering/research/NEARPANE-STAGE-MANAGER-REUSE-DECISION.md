# Nearpane — Stage Manager upstream reuse decision

Date: 2026-11-21  
Nearpane baseline: `cae7220be5fa3f68b7b71ee04b031c153ff77903`  
Upstream baseline: `eugene-tea/stage-manager@69a73665488243bf78982c6d523ac4e0850c1ddb`

## Final decision

**Choose Option A, with a deliberately narrow extraction: vendor the upstream Rust window-engine mechanisms into an in-process Rust static library and expose a versioned C ABI to the existing Swift Host. Do not embed the upstream application/controller/model wholesale.**

The runtime architecture is:

- Swift remains the product host, R4 UI, StageGroupStore, StageGroupCoordinator, identity registry, transaction journal, persistence, tools and user-facing lifecycle.
- Rust owns the low-level visibility backends and their platform-specific mechanics: AX corner parking, corner sliver event tap, optional SkyLight Spaces backend, backend probe/health, window-server readback, and recovery worker.
- Swift passes a bounded snapshot/plan using POD records (display UUID, member UUID, process birth, PID, CGWindowID, frame, native desktop scope, generation and intent ID). Rust returns per-window operation receipts and independently observed state. No Rust internal struct crosses the ABI.
- AXUIElement/CF/Objective-C object pointers are not persisted, serialized or passed as durable cross-language identities. The Rust side reacquires and validates ephemeral AX objects against the Nearpane identity lease immediately before each side effect.
- Rust runs its own named WM thread/CFRunLoop, matching the upstream thread ownership model. The C ABI is synchronous only for bounded command submission; progress and receipts return through a callback/event queue or pollable result API. No long AX wait blocks Swift's main thread.
- Nearpane remains the sole owner of StageGroup transaction intent and durable membership. Rust must not create a competing stage directory or independent authoritative persisted group model.

The extraction must preserve upstream MIT notices and pin the exact upstream commit. It is a vendored fork, not a dependency on a moving Git branch.

## 1. Why Option A wins

The hardest and most failure-prone logic is not the high-level idea of moving a window. It is the accumulated low-level behavior:
- AX frame writes and readback under app responsiveness and macOS clamping;
- WindowServer z-order and identity reconciliation;
- session event-tap lifecycle and complete mouse-gesture suppression;
- Dock/overlay/resize-border-aware hit testing;
- Space creation, bridged window migration, membership readback and cleanup;
- per-operation retry, health strikes and fallback;
- recovery after host crash, quit, logout and partial failure.

Porting all this to Swift would discard the upstream's tested Rust implementation details and create a second independent reimplementation of exactly the subsystem Nearpane is missing. The static library keeps the code in-process, avoids a new helper executable and IPC hop, and permits incremental extraction behind a narrow ABI.

This is not “link the current stage-manager crate and call it done”. The current crate's library is tightly coupled to its own model/controller/configuration and is not a clean standalone engine SDK. The extraction task must create a focused `nearpane_window_engine` crate/module and explicitly separate the backend from upstream product concerns.

## 2. Architecture option comparison

| Option | Performance | Stability / lifecycle | Debugging | Signing / distribution | Maintenance | Decision |
|---|---|---|---|---|---|---|
| A. Rust static library + C ABI, in process | No IPC hop; native calls remain in same process. ABI overhead negligible versus AX/WindowServer operations. | One process; Rust WM thread owns AX/CF run loop. Crash still affects Host, so guardian/recovery must be explicit. | Rust and Swift stack traces, ABI boundary and cross-language logs; manageable with POD receipts and correlation IDs. | One app bundle; static archive/object code is included in Host signature. No extra helper identity. | Keep pinned fork and narrow upstream sync surface. | **Selected** |
| B. Rewrite engine in Swift | Similar raw API speed; no meaningful inherent performance advantage. | Easier AppKit integration but all safety edge cases must be reimplemented and re-proven. | One language, simpler debugger. | Simpler build/signing. | High reimplementation and regression cost; upstream fixes must be manually ported. | Reject |
| C. Separate Rust helper process over IPC | Extra context switch and serialization; likely small but avoidable latency. | Process isolation can protect Host from Rust panic, but introduces helper crash/restart, IPC ordering, stale leases and two-process recovery. | Distributed logs, IPC race and identity debugging more complex. | Additional executable, nested signing, launch, notarization, permissions and update coordination. | Highest deployment/lifecycle burden. | Reject as primary |
| D. Reimplement in Objective-C++/C++ or use a thin Swift/ObjC wrapper around upstream source | Native APIs accessible, but still requires a second port or a Rust runtime bridge. | Could be viable if a specific Rust API cannot be extracted; no demonstrated advantage over A. | Mixed-language debugging without retaining the upstream Rust core. | Similar to A or B depending on packaging. | More bespoke maintenance. | Reserve only for tiny platform shims |

## 3. Backend decision

### 3.1 Default: Accessibility Corner

Accessibility is the default backend, matching upstream's own default. It is the correct Nearpane starting point because:
- it uses documented AX writes and CGEventTap/CGWindowList APIs for the core behavior;
- it does not require private SkyLight Space migration;
- upstream's own data shows the switch end-to-end geometry time is almost the same as Spaces (862 ms vs 852 ms in its three-run captures-on table);
- the largest idle cost is not only the Nearpane/upstream process: replayd and WindowServer account for much of the Corner overhead;
- Nearpane's target machine's Spaces compatibility is not established.

Corner is not accepted merely because AX setters succeed. Production qualification requires the entire hit-test and event-tap path, zero real pointer deliveries to inactive windows, correct Dock behavior, same-app sibling isolation, restore geometry, and crash recovery.

### 3.2 Optional backend: Spaces

Spaces is an opt-in performance/power optimization, not a presumed superior engine. It may become the preferred backend on a particular machine only after:
1. all required symbols and bridged classes/selectors resolve;
2. a real trial panel moves into a created Space and reads back there;
3. the same panel returns to its Desktop and reads back;
4. every real hide/show is independently verified;
5. Mission Control, App Exposé, Dock, Command-Tab, app activation, modal panels, fullscreen and multi-display tests pass;
6. runtime health remains good.

For Nearpane's exact target macOS 27.0 build 26A428 with SIP Enabled, compatibility is **unknown** until a physical signed-host test is run. Never infer support from macOS 27.2 or SIP-disabled CI.

### 3.3 Fallback

- If the Spaces launch probe fails: start Corner.
- If any Spaces hide/show readback fails after one retry, or health strikes cross the threshold: restore all windows from Spaces, verify them, then switch to Corner for the rest of that run.
- If Corner's CGEventTap is unavailable or its snapshot is stale, Corner must not advertise or commit safe group switching. Keep windows visible or enter an explicit read-only/paused state; do not fall back to an unsafe overlay-only mode.
- If both backends fail recovery, disable all new visibility writes and retain the recovery journal for manual/next-launch reconciliation.

This is a safety-oriented backend fallback, not a cascade of increasingly speculative hiding APIs.

## 4. What to preserve from Nearpane

Preserve unchanged in principle:
- `Sources/NearpaneCore/StageGroupStore.swift`: product-owned persistent group/member IDs, display partitioning and layouts.
- `Sources/NearpaneCore/StageGroupCoordinator.swift`: write-ahead transaction, before/after records, input epoch, ownership and recovery decisions.
- `Sources/NearpaneSpaceAction/WindowWitness.swift`: strong process birth + PID + CGWindowID + AX identity + same-app sibling inventory and independent CG/AX geometry checks.
- `Sources/NearpaneOrdinaryWindowController/WindowMonitor.swift`: existing AX observer and window lifecycle monitoring, subject to a clear single owner for AX access.
- R4 presentation, preview pipeline, exact focus path, auto-tiling and tool integrations.
- Nearpane performance standard and its PASS/FAIL/UNKNOWN/NOT_RUN definitions.

Replace or consolidate:
- the current experimental visibility driver behind `StageWindowSession` with the Rust backend adapter;
- duplicate AX frame/park code that would otherwise compete with the Rust worker;
- any overlay-only or minimized-state path that is represented as full input-safe hiding without a qualifying input isolation mechanism;
- any second authoritative group/visibility persistence model copied from upstream.

Retain as read-only diagnostics:
- existing Native Space inventory and membership reader;
- existing display topology and native Space UUID observation;
- existing exact focus and window witness paths where they do not race the Rust backend for AX writes.

Delete only after parity and migration tests prove they are unused. No bulk deletion of the archived experiments is authorized by this decision.

## 5. Reuse classification

### Directly vendor with minimal changes
- pure corner geometry: `src/engine/corner/park.rs`;
- sliver geometry, hit-test model and `PressGate`: `src/engine/corner/sliver.rs`;
- relevant event-tap implementation: `src/platform/corner/sliver_tap.rs`;
- SkyLight dynamic loading and typed FFI: `src/platform/spaces/ffi.rs`, after ABI/ownership review;
- engine choice and health policy: `src/engine/engine_choice.rs`, adapted to Nearpane result enums.

### Vendor but adapt substantially
- `src/platform/window_engine.rs`: translate the trait to a Nearpane backend contract, do not expose upstream Model types.
- `src/platform/corner/engine.rs`: use Nearpane window leases and transaction IDs.
- `src/platform/spaces/engine.rs`, `src/platform/spaces/probe.rs`, `src/platform/spaces/landing.rs`: adapt stage mapping, original Desktop ownership, readback, cleanup and lifecycle to Nearpane scopes.
- `src/platform/safety.rs`, `src/platform/guardian.rs`, `src/engine/recovery.rs`: integrate with Nearpane's ledger; avoid duplicate ownership and competing restore decisions.
- `src/engine/corner/corner_patch.rs`: use only the necessary geometry/ordering logic; do not copy upstream wallpaper or UI assets.

### Reuse as design/reference, not as production module
- upstream `Model`, `Controller`, `state.json`, stage rules, settings and app lifecycle;
- upstream strip, menu, settings, icons, update system and product artwork;
- upstream ScreenKey and app-specific persistence identity;
- upstream test control socket and fixture app implementation (Nearpane must have its own isolated fixtures).

### Dependencies and ABI risks
- Rust 1.88+ toolchain and edition 2024;
- objc2 family and Apple framework bindings;
- `block2`, `dispatch2`, `libc`;
- C ABI panic containment: no Rust panic may unwind through Swift;
- opaque engine handle, explicit create/destroy, versioned structs, fixed-width integers, explicit UTF-8 ownership, bounded arrays;
- never transfer ownership of a CF/ObjC object across the ABI without a documented retain/release contract;
- no Swift callback into Rust while holding locks or on the AX worker thread.

## 6. Performance decision

The upstream 1.9.1 three-run comparison reports 862 ms Corner vs 852 ms Spaces from card click to final window geometry. That is not a reason to select Spaces by default. The motion itself dominates the end-to-end time; the backend difference is approximately 10 ms in that measurement.

Nearpane must use its existing `NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md`, not upstream's small sample:
- 100 valid transitions per direction for benchmark comparison;
- P50/P95/P99;
- physical input to first target frame;
- physical input to actual focus and a real input marker;
- group settled and outgoing windows absent;
- 60 Hz and high-refresh modes, single and dual physical displays;
- same-app siblings, cross-app windows, modal sheets and bystanders;
- CPU/WindowServer/memory, frame gaps, Dock count and restore outcomes.

Performance cannot override a safety failure. Do not optimize or benchmark a backend before the single-transition input-isolation contract passes.

## 7. MIT, signing and notarization

Upstream is MIT. Preserve the original full license and copyright notice for copied substantial portions. Add `THIRD-PARTY-NOTICES.md` and an origin manifest mapping every vendored file to upstream path and commit. Modified files must retain notice and state that Nearpane modifications were made.

Run a dependency license audit against the exact extracted Cargo.lock graph. MIT on the top-level project does not automatically clear every transitive dependency.

Static linking does not eliminate code signing: final Nearpane.app must pass deep signature verification, Hardened Runtime requirements, Developer ID Gatekeeper assessment, notarization and clean-machine install/upgrade/rollback. SkyLight private API use remains a distribution and OS compatibility risk regardless of license.

## 8. Final answers

1. Accessibility Corner: **yes, reuse the implementation, especially the event-tap safety path; do not use overlay alone.**
2. Spaces: **yes, reuse as an optional backend, but only after exact target OS qualification.**
3. Shared WindowEngine interface: **yes.**
4. Default backend: **Accessibility Corner.**
5. Secondary backend: **Spaces, probe-gated and runtime-health-gated fallback to Corner.**
6. Directly portable: pure geometry, PressGate/hit-test, event tap, SkyLight FFI primitives and health policy.
7. Adapt: window identity, stage/desktop mapping, persistence, recovery ownership, display UUIDs, controller and ABI.
8. Nearpane code: preserve StageGroup/R4/identity/journal/focus; replace duplicate visibility execution; keep inventory read-only.
9. Non-reusable dependencies: upstream app/controller/model/persistence/UI/updater are coupled to its own product; no clean ABI currently exists.
10. Native-like performance: remove unnecessary capture and idle work, keep AX off the main thread, use event-driven updates with bounded reconciliation, minimize cross-process work, animate from R4's existing visual pipeline, and measure real input/first-frame/interactive latency against Apple on the same Mac.

## 9. Scope

This is an architecture decision only. It does not authorize production implementation, signing, notarization, release or changing PR #15 out of Draft. Implementation is defined by `NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md`.
