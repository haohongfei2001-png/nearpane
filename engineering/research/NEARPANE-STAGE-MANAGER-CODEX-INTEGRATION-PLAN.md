# Nearpane — Stage Manager Rust engine integration plan

Date: 2026-11-21  
Implementation baseline: Nearpane PR #15 at `cae7220be5fa3f68b7b71ee04b031c153ff77903`  
Upstream baseline: `eugene-tea/stage-manager@69a73665488243bf78982c6d523ac4e0850c1ddb`  
Status: planned; not implemented by the research commit.

## 1. Codex mission

Extract the proven window-engine mechanisms from the pinned Stage Manager upstream into a focused in-process Rust static library, connect it to the existing Swift Nearpane Host through a narrow versioned C ABI, and preserve Nearpane's R4 product, StageGroup model, transaction ledger and window identity system.

Do not copy the upstream application. Do not redesign R4. Do not replace StageGroupStore or StageGroupCoordinator. Do not enable production switching until the full safety and lifecycle contracts pass.

## 2. Hard constraints

- Work only on PR #15 branch `codex/r4-native-candidate-20261120`.
- Pin upstream source to `69a73665488243bf78982c6d523ac4e0850c1ddb`; never pull unreviewed latest code.
- Preserve full MIT license/copyright notices and produce a source-origin manifest.
- No production UI redesign, no changes to R4 visual tokens/assets, no upstream branding/artwork.
- No separate helper process for the engine in this first implementation.
- No Swift rewrite of the low-level algorithms.
- Swift owns product group IDs, transaction intent, persistence and recovery authority. Rust owns low-level backend mechanics and per-window system operation/readback.
- Every operation uses Nearpane's process-birth/PID/CGWindowID/generation lease and intent UUID.
- No AX/CF/ObjC object pointer is persisted or treated as a stable cross-process identity.
- No panic may unwind across the C ABI.
- The Spaces backend is disabled by default until target machine qualification.
- Corner requires a functioning CGEventTap and fresh hit-test snapshot; overlay-only operation is not acceptable.
- Any incomplete inventory, ambiguous owner, stale generation, user input epoch change, display/Space topology change or system takeover aborts the transaction before the next side effect.
- No production source modification is authorized by the research delivery itself; this plan is the next implementation task.

## 3. Integration shape

Create a focused Rust crate under e.g. `Engine/nearpane-window-engine/` with `crate-type = ["staticlib"]`. Vendor only the necessary source modules from upstream. Build via Cargo for supported architectures and link the resulting static archive into the existing Swift package/Xcode build.

Expose a versioned C ABI:
- `np_engine_create(config, callbacks) -> opaque handle`
- `np_engine_destroy(handle)`
- `np_engine_probe(handle, request, result)`
- `np_engine_apply(handle, operation, request, result)`
- `np_engine_readback(handle, request, result)`
- `np_engine_restore_all(handle, scope, result)`
- `np_engine_health(handle, result)`

The exact ABI should be designed by Codex after reviewing Swift package/build integration, but it must follow:
- fixed-width C integer fields and explicit struct sizes/version;
- opaque handles, no Rust types exposed;
- stable UUIDs represented as 16-byte arrays;
- rectangles as finite double fields in a documented coordinate space;
- bounded member arrays with explicit counts;
- owned result buffers with explicit free functions, or caller-provided buffers;
- correlation/intent UUID on every request and receipt;
- explicit result categories: pass, fail, unknown, unsupported, timeout, cancelled;
- no stringly typed success state;
- no panic crossing FFI boundary (`catch_unwind`);
- callbacks must not run under internal locks;
- asynchronous operations must be cancellable and return a terminal receipt.

Rust owns a dedicated WM thread/CFRunLoop. Swift main thread only submits commands and consumes snapshots. AX calls have bounded timeouts. Do not call AX on SwiftUI/AppKit main thread.

## 4. Extraction inventory

### Phase A — vendor core geometry and engine contract

From upstream:
- `src/engine/geometry.rs`
- `src/engine/corner/park.rs`
- `src/engine/corner/sliver.rs`
- selected `src/engine/corner/park_reconcile.rs`
- selected `src/platform/window_engine.rs` concepts, rewritten to Nearpane PODs.

Deliver:
- pure geometry unit tests;
- display corner selection tests for topologies with 1, 2 and 3 displays;
- Dock/visible-frame clamping tests;
- PressGate per-button tests;
- ABI layout tests in Rust and Swift.

### Phase B — Corner backend and input shield

Vendor/adapt:
- `src/platform/ax.rs`
- `src/platform/windows.rs`
- `src/platform/corner/engine.rs`
- `src/platform/corner/sliver_tap.rs`
- `src/platform/tap_switch.rs`
- selected `src/engine/corner/corner_patch.rs` geometry/ordering only.

Requirements:
- AX position request followed by independent AX + CGWindow readback;
- account for macOS clamp, visible frame, Dock and menu bar;
- maintain a current parked-window set bound to Nearpane live identity generations;
- publish a fresh front-to-back CGWindowList subset to the tap thread;
- tap callback performs no blocking AX or WindowServer call;
- include left/right/other down, drag and up events;
- PressGate swallows the whole gesture consistently;
- skip Nearpane overlays, transparent windows, Dock click-through regions and non-parked windows;
- treat stale inventory/tap-disabled/tap-unavailable as a loss of qualification;
- preserve original geometry and exact user-minimized state;
- restore all owned windows on quit, panic, process shutdown and recovery handoff.

The corner patch is optional presentation support only. Do not make it a prerequisite for input safety and do not treat it as input safety.

### Phase C — Spaces backend (behind disabled feature flag)

Vendor/adapt:
- `src/platform/spaces/ffi.rs`
- `src/engine/spaces.rs`
- `src/platform/spaces/engine.rs`
- `src/platform/spaces/probe.rs`
- `src/platform/spaces/landing.rs` only after core hide/show correctness is proven.

Requirements:
- dynamic lookup of every required symbol and Objective-C bridge class/selector;
- correct route/ABI for classic and bridged calls;
- one stage Space per Nearpane StageGroup per native Desktop and display;
- original Desktop mapping tracked by live native identity, never by array index;
- move hidden members out of every visible Desktop and read back `SLSCopySpacesForWindows`;
- restore members to the exact intended Desktop and read back again;
- never show a hidden stage Space to the user;
- handle companion panels and same-app siblings;
- probe and runtime health as described in the audit;
- restore/cleanup every created Space on partial failure, quit and crash recovery.

The `SLSOrderWindow` technique is unrelated and must not be used as a substitute.

Target compatibility gate: physical macOS 27.0 build 26A428 with SIP Enabled, Developer ID-signed Nearpane installed at its real path. No compatibility claim before that gate passes.

### Phase D — Nearpane transaction adapter

Integrate with:
- `Sources/NearpaneCore/StageGroupCoordinator.swift`
- `Sources/NearpaneCore/StageGroupStore.swift`
- `Sources/NearpaneSpaceAction/WindowWitness.swift`
- `Sources/NearpaneSpaceAction/Inventory.swift`
- `Sources/NearpaneOrdinaryWindowController/WindowMonitor.swift`
- `Sources/NearpaneOrdinaryWindowController/FocusCurrentWindow.swift`

Define one ownership rule for AX writes. Avoid the existing Swift monitor/driver and Rust worker concurrently writing the same AX window. The Swift side obtains the qualified transaction snapshot, sends an immutable operation plan, and Rust revalidates process birth/PID/CGWindowID/frame/owner before each write. The Rust receipt is not accepted as success until Swift's independent observer confirms the postcondition.

Keep Nearpane's existing write-ahead log and compensation policy. The Rust library must not persist a second authoritative group directory. Rust may persist only backend recovery metadata required to restore OS objects after the Swift Host dies; that metadata must reference the Nearpane intent/member lease and be reconciled against the Swift journal on next launch.

### Phase E — guardian and recovery

Port the mechanisms from:
- `src/platform/safety.rs`
- `src/platform/guardian.rs`
- `src/engine/recovery.rs`
- `src/engine/leftovers.rs`

Design a signed, minimal recovery worker only if in-process cleanup cannot meet crash safety. This is the one justified exception to the no-helper-first rule, and must be a separate design review. First implement:
- durable restore intent before each hide;
- bounded retry and explicit unknown state;
- bring-all-back on graceful quit and panic;
- launch-time scan for windows left in known park zones;
- no restoration of a window whose identity cannot be strongly matched;
- never restore based only on reused CGWindowID or PID;
- retain unresolved records for user-visible recovery instead of guessing.

A guardian process is not automatically copied wholesale. Its IPC, code-signing identity, crash-loop and takeover semantics must be reconciled with Nearpane's existing Host/helper model.

## 5. Acceptance matrix

### Gate 0 — source extraction and build
- [ ] Fixed upstream commit recorded.
- [ ] Every vendored file mapped to upstream path and original blob SHA.
- [ ] MIT notices retained.
- [ ] Cargo dependency license audit recorded.
- [ ] Rust static library builds for all supported architectures.
- [ ] Swift/C ABI size/version tests pass.
- [ ] No UI, R4 or StageGroup schema regression.
- [ ] No panic crosses FFI.

### Gate 1 — Corner geometry and input safety
- [ ] Corner selection and park/clamp tests pass for all supported display layouts.
- [ ] Two apps, three windows, same-app sibling windows and unmanaged bystander.
- [ ] Parked window sliver and resize-border clicks produce zero receiver markers.
- [ ] Down/drag/up sequence is wholly swallowed for each mouse button.
- [ ] Active-stage window, Dock bar, wallpaper, menu bar, notifications and Nearpane overlay remain clickable.
- [ ] Tap failure, secure input, stale snapshot and tap timeout are surfaced and revoke switch qualification.
- [ ] Real CGWindowList Z-order and owner-side event markers agree.
- [ ] 10/10 isolated transitions, then 50/50 stress, zero wrong input.
- [ ] User-minimized windows and Dock tile count unchanged.
- [ ] Quit/crash/relaunch restores all owned windows.

### Gate 2 — Spaces probe and runtime correctness
- [ ] Exact target macOS 27.0 / 26A428 / SIP Enabled probe passes.
- [ ] Classic and bridged API route selected by actual verified behavior, not symbol presence alone.
- [ ] Hide/show membership readback passes for every member.
- [ ] Same-app sibling, modal panel, Dock, Command-Tab and app activation.
- [ ] Mission Control keyboard, gesture, hot corner and Dock entry.
- [ ] App Exposé, fullscreen, Split View, two physical displays and topology changes.
- [ ] Runtime health fallback restores all windows before changing backend.
- [ ] Crash, logout/login and SkyLight connection loss recover without orphaned windows.

### Gate 3 — Nearpane product integration
- [ ] R4 UI unchanged; existing StageGroupStore schema preserved.
- [ ] StageGroupCoordinator remains sole transaction authority.
- [ ] Exact member focus and actual keyboard marker pass.
- [ ] Full group A→B→C→A with bystander unchanged.
- [ ] User interruption invalidates the in-flight generation.
- [ ] Partial dispatch leaves a durable recovery record; no speculative replay.
- [ ] 10/10, 50/50, then 1,000/1,000 soak.

### Gate 4 — performance
- [ ] Paired Apple/Nearpane physical-Mac benchmark, at least 100 valid transitions per direction.
- [ ] P50/P95/P99 for input→first frame, input→interactive and group settled.
- [ ] WindowServer/replayd CPU, Nearpane CPU, memory and display-link gaps.
- [ ] 60 Hz and high-refresh, one and two physical displays.
- [ ] Use existing `NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md`.
- [ ] No performance score can override a safety FAIL/UNKNOWN.

### Gate 5 — distribution
- [ ] Developer ID deep signature check of app and every embedded code object.
- [ ] Hardened Runtime entitlements reviewed.
- [ ] Notarization and Gatekeeper assessment on exact final artifact.
- [ ] Clean-user install, first launch, permissions, upgrade, downgrade/rollback.
- [ ] No Mac App Store claim while private SkyLight API is required.
- [ ] PR #15 remains Draft until all required gates and product acceptance pass.

## 6. Rollback strategy

- Feature flag defaults to existing read-only behavior; no new production window writes.
- Corner backend can be disabled independently of R4 UI and StageGroup directory.
- Spaces backend has a separate flag and remains off until Gate 2 passes.
- On backend failure, stop new actions, restore only windows with verified Nearpane ownership, keep unresolved journal entries, and revoke the active group's success state.
- Preserve previous signed install and profile data. Do not delete legacy verification evidence.
- Never automatically retry an unknown dispatch after process restart.

## 7. Required implementation report

Codex must update:
- `engineering/research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md` with completed/blocked gates;
- `engineering/research/NEARPANE-STAGE-MANAGER-REUSE-DECISION.md` only if evidence forces a decision change;
- `engineering/research/NEARPANE-STAGE-MANAGER-UPSTREAM-AUDIT.md` only for corrected upstream facts;
- a per-build machine-readable acceptance receipt and raw event/input logs;
- `THIRD-PARTY-NOTICES.md` and vendored source manifest.

Do not mark a gate passed from unit tests, CI-only tests or successful API return codes. Physical signed-host evidence is required for the real window-management claims.

## 8. Final Codex start instruction

> Implement the Nearpane Stage Manager engine integration strictly from `engineering/research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md`. First refresh PR #15 branch and verify HEAD; pin upstream `eugene-tea/stage-manager@69a73665488243bf78982c6d523ac4e0850c1ddb`. Use the selected Option A: focused in-process Rust static library with versioned C ABI. Preserve R4 UI, StageGroupStore, StageGroupCoordinator, identity leases, transaction journal and exact focus path. Default to Accessibility Corner with the complete CGEventTap/PressGate input shield; Spaces remains disabled unless exact macOS 27.0 build 26A428 with SIP Enabled passes the launch probe, real membership readback, runtime health, lifecycle and recovery tests. Do not copy the upstream app, UI, model/persistence, icon or artwork. Keep all upstream MIT notices and produce dependency license audit and file-origin manifest. Work gate-by-gate; stop and report blockers instead of weakening safety criteria. No release, notarization, PR merge or Draft-to-ready transition. Report real physical-host results separately from CI and unit tests. A visibility or input-safety failure means no production StageGroup switching.