# Nearpane 5.22 — Codex Implementation Plan

Date: 2026-11-20  
Decision authority: `NEARPANE-5.22-FINAL-TECHNICAL-DECISION.md`  
Visual authority: PR #13 R4. Do not redesign.

## Execution contract

Codex implements the architecture in this document. It must not reopen broad technical research or select among competing approaches. If repository source contradicts a named assumption, stop that subtask, record the exact file/symbol/build evidence, and propose the smallest decision amendment before coding. Never silently choose an alternate private API.

Work is documentation and implementation planning only in this handoff; this plan authorizes subsequent Codex implementation but this research branch contains no production source changes.

## Required architecture and module boundaries

Create or consolidate these logical modules using existing project naming where possible:

- `SystemInventory`: immutable display/Space/window snapshots.
- `StableIdentity`: process/window generations and reconciliation.
- `SpaceSwitchCoordinator`: serialized state machine and version adapter.
- `DockGestureAdapter`: macOS 26 / 27 event serialization only.
- `BridgedMoveAdapter`: Objective-C runtime wrapper for bridged window operation.
- `WindowFocusCoordinator`: AX focus request and verification.
- `CaptureAttachmentProvider`: adapter to Riftlet's implementation.
- `TranslationRequestService`: service bridge, translation, panel and persistence.
- `SpeechSessionCoordinator`: capture buffer, ASR, finalization and recovery.
- `LifecycleCoordinator`: display/Space/fullscreen/sleep/permission invalidation.
- `EvidenceLedger`: immutable per-action receipts.

Map these boundaries to current concrete source paths before modifying. Keep a path-to-module map in the PR. Do not create parallel implementations if a current module already owns the capability.

## P0 — Native Spaces switching (must land first)

### Goal
One reliable adjacent switch in each direction on the supported macOS build, with correct stable Space landing and no delayed yank.

### Root cause / evidence
The installed contract scored 0/50 and 0/9 supplemental confirmed landings. macOS 27 requires the serialized Dock/IOHID payload used by current ISS/noswoosh implementations; direction depends on natural-scroll preference, and stale predictions/intermediate notifications can overshoot. Empty-desktop activation can trigger Dock window-follow behavior.

### Implementation
1. Inventory and document current `NPSendAdjacentSwipe`, `GestureSerialization.c`, `ActionInventory`, `NativeSpaceAction`, helper protocol, action receipts and OS detection.
2. Implement a single versioned `DockGestureAdapter`. macOS 26.6+ low-travel path; macOS 27 serialized payload path. Do not use subnormal progress. Do not claim enhanced 26.0–26.5 support.
3. Compute direction from stable ordered Space identities on pointer display. Apply natural-scroll inversion in one tested function.
4. Replace prediction-as-truth with observation. Lock the coordinator during transition. One event sequence per action.
5. Add empty destination guard modeled on noswoosh, but do not change global Dock preferences.
6. Log intent UUID, display UUID, source/target Space IDs, event fields, phase timestamps, Dock notifications, active Space snapshots, focus owner and cleanup.
7. Implement bounded timeout and UNKNOWN state; never retry automatically.

### Test gates (strict order)
- Pure unit tests: direction × natural scrolling × display selection × boundary clamp × version payload serialization.
- Protocol tests: event field values, phase order, companion event, serialized payload byte layout.
- Physical installed candidate: one adjacent switch, independent readback; one reverse switch. Both must pass before any repeated run.
- Then 10 alternating adjacent switches with no wrong landing, duplicate landing, empty-space yank or black screen.
- Then 50 alternating switches; 50/50 independently confirmed. Record P50/P95/P99 and all event receipts.
- Test empty destination, full-screen adjacent Space, auto-rearrange on/off, Stage Manager on/off, pointer on each display, keyboard focus on a different display, natural scroll on/off.
- Only after 50/50 can non-adjacent navigation be enabled as a sequence of separately confirmed adjacent actions.

### Failure / rollback
Any wrong Space, unknown receipt, Dock wedge, black surface, or delayed yank disables the adapter for that OS build and returns to native macOS controls. No global preference changes. Preserve logs and restore topology/focus.

### Definition of done
One adjacent round trip PASS; 10/10 alternating PASS; 50/50 PASS on the signed installed candidate. No UI reports success until independent stable Space ID confirmation.

## P1 — Cross-Space window migration

### Goal
Move exactly one selected window between ordinary user Spaces without moving sibling windows, losing the window or lying about completion.

### Implementation
1. Replace function-symbol dependency with runtime validation of `SLSBridgedMoveWindowsToManagedSpaceOperation`, `initWithWindows:spaceID:`, `performWithWMBridgeDelegate`.
2. Verify class, selector, method signature, ABI and OS/build support before enabling.
3. Create immutable typed CGWindowID list and strongly retain operation/context through asynchronous lifetime.
4. Serialize per window. Revalidate PID birth, CGWindowID and source Space immediately before dispatch.
5. Await operation signal if available, then independently read target Space membership until confirmed.
6. Protect same-app sibling window set and ensure only intended ID changes membership.
7. Handle close, process exit, drag cancel, timeout and app restart as explicit terminal states.
8. Initial support only ordinary user Space to ordinary user Space. No full-screen/Split View/Stage Manager migration.

### Tests
Unit: invalid IDs, PID reuse, generation mismatch, empty list, duplicate IDs, timeout, cancellation.  
Installed integration: one window move and reverse move; two same-app sibling windows where only one moves; close during drag; cancel before dispatch; close during async move; app relaunch; unsupported full-screen and tiled destinations rejected.  
Run 10 and then 50 moves only after single round trip passes. Every result independently verified.

### Rollback / done
If class/selector/ABI validation fails, capability remains false. If move completion cannot be independently observed, remain BLOCKED. No fallback to compatibility-ID spoofing or SIP-disabled scripting addition. Done only after exact target and sibling invariants pass on installed candidate.

## P2 — Window identity, inventory and focus

### Goal
No phantom rows, no omitted proven-visible windows, exact window keyboard focus.

### Implementation
1. Introduce `WindowIdentity` with PID birth, CGWindowID and generation; ephemeral AX reference.
2. Build reconciler from CoreGraphics window inventory + per-app AX window lists + Space membership adapter.
3. Mark membership confidence explicitly. Unknown membership never becomes a fabricated Space row.
4. Reconcile window close and PID/window ID reuse. Invalidate thumbnail and AX references on generation change.
5. Focus sequence: identity revalidate → app activate → AXRaise if supported → wait AXFocusedWindow → verify CGWindowID → fixture input marker → read target content.
6. Keep AXMainWindow and AXFocusedWindow separate.
7. Retain the latest 0→2→0 roster behavior and expand controlled tests to windows from different apps, same app, minimized, hidden, off-screen, fullscreen and newly opened/closed.

### Tests
- Property tests for identity reuse and reconciliation.
- AX timeout, unsupported raise, stale UI element and process birth changes.
- Two same-app windows, alternate focus 10 times, verify unique input markers.
- Inventory completeness compared to independent fixture window set; never infer completeness from UI count alone.

### Done
No missing independently proven visible fixture windows; no duplicates; no stale cards after close; 10/10 exact keyboard focus with target-document content proof. If AX cannot focus a target, report unsupported rather than false success.

## P3 — Riftlet capture and AI attachment

### Goal
One capture engine, safe attachment to fresh authenticated AI conversations, no accidental send.

### Implementation
1. Map and reuse Riftlet's capture, selection, image encoding, attachment and retry logic. Nearpane provides UI only.
2. Define `CaptureAttachmentProvider` contract with capture UUID, display/window identity, region geometry, scale, image hash and lifecycle.
3. Prove region coverage and coordinate transform. Add multi-display/Retina/rotation tests.
4. Implement browser adapters for Chrome, Edge and Safari with Apple Events + Accessibility; no browser extension.
5. Domain adapters for ChatGPT, Claude, Gemini and DeepSeek detect login, fresh conversation, editor and upload controls.
6. Use user's existing signed-in browser profile only with explicit authorization. Never use guest profile absence of editor as feature failure.
7. Attach synthetic image; wait for rendered attachment chip/thumbnail and upload-complete state; assert no send-related events. Stop.
8. Bind every browser operation to exact process/window/tab identity. Handle delayed upload, dialogs and tab navigation.

### Tests / Done
Matrix: 3 browsers × 4 services where supported; authenticated and unauthenticated states. Include multi-dialog, duplicate upload, upload cancellation, slow upload, editor absent and browser restart. For a supported authenticated path, fresh conversation + attachment visible + send event count zero. Unsupported combinations are documented; no fake pass.

## P4 — Translation, wordbook and Saytile

### Translation
- Make NSServices callback a small, fast ingress adapter.
- Persist request UUID/text hash and hand off to host; don't display UI from service callback process.
- Add trace points for service registration, callback, request receipt, translation availability, translation result, anchor resolution, panel creation/order, visible frame and persistence commit.
- Use TranslationSession / LanguageAvailability after availability check.
- Present through AppKit non-activating NSPanel/popover with explicit anchor fallback, key behavior and deactivation lifecycle.
- Wordbook transaction includes term, language pair, translation, timestamp, provider/model version; read back after relaunch.

Tests separately assert: service invoked, request received, translation completed, panel visible, wordbook committed, restart readback. One cannot substitute for another.

### Saytile
- Keep direct expression; no mode switch before speech.
- Ring-buffer audio before ready state; preserve pre-roll and first speech frame.
- Record sample metadata and audio file hash.
- Partial transcript is provisional. Finalize only after end-of-audio, recognizer final result, file flush and readback.
- Use best validated local Chinese ASR by measured CER/WER and first-phrase retention. Apple Speech on-device only when `supportsOnDeviceRecognition` is true; accuracy caveat documented. No silent cloud fallback.
- Fullscreen, sleep, input-device changes and interruptions must cause explicit pause/recover state, not data loss.

Tests: 10 cold starts per phrase, three phrases, noisy and quiet audio, first syllable retention, pause/resume, fullscreen enter/return, sleep/wake, process termination and final text/audio recovery. Require final transcript persisted and reloaded.

## P5 — Fullscreen, Split View, multi-display, lifecycle and performance

### Implementation
- One LifecycleCoordinator owns topology snapshots and invalidation events.
- Fullscreen entry and return independently confirmed.
- Split View identified as system-managed pair; no ordinary move semantics.
- Test 1/2/3/4/8-window layout with a pure deterministic planner and actual geometry snapshots.
- Test 1 and 2 displays; pointer display differs from keyboard focus display; separate Spaces on/off.
- Stage Manager classification and visibility; do not conflate with Space.
- Sleep/wake, lock/unlock, display hotplug, permission revoke/regrant, Host relaunch and helper restart.
- Hidden capture stop already passed; preserve and expand test with actual ScreenCaptureKit stream stop and cache byte counters.
- Benchmark warmed 5×20 operation batches; report P50/P95/P99, CPU, memory, frame drops, cache and recovery time. No performance claim from cold idle samples.

### Done
Every supported lifecycle transition recovers to a fresh, reconciled inventory; no stale AX/CGWindow refs; no orphan capture session; no unbounded memory; exact layout geometry and performance thresholds defined by R4 product requirements.

## P6 — Signed installed package and release gate

### Implementation
1. Fix missing distribution signatures across all helpers and Sparkle executables.
2. Enable Hardened Runtime with minimum entitlements.
3. Developer ID sign nested code inside-out; verify designated requirements and team identity continuity.
4. Notarize, staple, validate ticket, verify Gatekeeper on clean macOS 26 and 27 systems.
5. Test upgrade, downgrade/rollback, first install, permissions grant/revoke, helper replacement and Sparkle update.
6. Ensure release metadata matches the exact signed artifact SHA-256.
7. Keep PR #15 Draft until all P0–P6 contracts pass. Do not publish the candidate or call it production-ready.

### Done
All nested code signed; notarization and stapling pass; clean-Mac install and first launch pass; no unexpected permission prompts; upgrade and rollback pass; release asset byte-for-byte matches installed candidate; all required feature contracts pass.

## Integration order and parallelism

Strict dependency chain: P0 → P1 → P2 → P3 → P4 → P5 → P6.

Parallel work allowed only for isolated modules with frozen interfaces:
- P3 Riftlet provider adapter can be developed in parallel with P0, but must not merge a competing capture stack.
- P4 translation and speech can be developed in parallel with P0/P1 if their host lifecycle and EvidenceLedger interfaces are agreed first.
- P5 pure layout planner and benchmark harness can proceed in parallel.
- P1 must not integrate before P0's Space identity and stable observation interfaces are frozen.
- P2 inventory identity must be agreed before P1 and P3 browser/window routing integration.

## Required PR artifacts

Codex must update:
- `engineering/research/IMPLEMENTATION-PATH-MAP.md` — logical module to concrete source path and current owner.
- `engineering/verification/native-spaces/ACCEPTANCE.md` — tests, prerequisites, PASS/FAIL/BLOCKED/UNKNOWN semantics.
- Per-phase machine-readable JSON receipts.
- `STATUS.md` with exact commit, installed build, OS build and remaining blockers.

No single giant implementation PR. Use focused commits/PRs with explicit dependencies. Every installed candidate must be signed, source-hash bound and independently read back.

## Release invariants

- Dispatch != completion.
- AXMainWindow != AXFocusedWindow.
- PID != window identity.
- CGWindowID alone != durable identity.
- Private symbol/class presence != usable ABI.
- Move scheduled != move completed.
- Screenshot selected != correct region captured.
- File picker closed != attachment uploaded.
- Attachment visible != message sent.
- Partial transcript != final transcript.
- Service invoked != bubble visible.
- App launched != notarized.
- Tests passed != installed build passed.

## Rollback strategy

Each private adapter is independently feature-gated by OS build and runtime capability. On unknown behavior, disable that adapter, preserve diagnostics and revert to native macOS controls. Never mutate global system preferences, alter SIP, or use compatibility-ID spoofing as a fallback. Keep the last known-good signed Developer ID package available for rollback.
