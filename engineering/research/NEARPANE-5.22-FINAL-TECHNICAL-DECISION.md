> **Route superseded 2026-11-26.** [Current independent replacement decision](NEARPANE-INDEPENDENT-STAGE-DECISION.md) governs. Keep the observations below as historical evidence; do not reactivate Apple Native Integration, Corner, shields, or a fallback on their basis.

# Nearpane 5.22 — Final Technical Decision

Date: 2026-11-20  
Research baseline: PR #15 evidence through commit `6f85f73bc6b64290308ac610e342702f989a9f66`; historical installed-contract evidence at `12bfe74bf34c64a25f1292959be119f9be74c272`.  
Scope: architecture and implementation decisions only. No production source changes are authorized by this research delivery.

## Executive decision

Nearpane must be built as a **public-API-first AppKit product with isolated, version-gated private-API adapters** for the two capabilities Apple does not publicly expose: global Spaces control and cross-Space window migration. Private adapters must be fail-closed, independently verified, and replaceable. They are not suitable for Mac App Store distribution. Developer ID + notarization is the only realistic primary distribution route while these features remain core.

Do not treat the existing 5.22 (90) candidate as releasable. The current PR #15 state is Draft. The newest window-roster correction (source `365fdc40c19853e4fa4343f9f20c240c85b7583b`) passed a narrowly scoped installed test: 0 → 2 → 0 real window cards, with no phantom Space rows. It does not supersede the earlier failed interaction contracts.

### Final architecture (single recommendation)

1. **SystemInventory** — read-only snapshot of displays, Spaces, windows and lifecycle; public CoreGraphics/AX first, private SkyLight metadata adapter second. Never make UI decisions from an incomplete private snapshot.
2. **StableIdentity** — process birth + PID + CGWindowID + generation + display/Space identity. AXUIElement handles are ephemeral, never durable identity.
3. **SpaceSwitchCoordinator** — one serialized adjacent transition at a time; versioned Dock gesture adapter; independent landing confirmation; no burst dispatch and no predicted-index success.
4. **WindowFocusCoordinator** — exact AX target, raise/activate, then independently prove focus and test input; never substitute app activation for window focus.
5. **WindowMoveCoordinator** — private bridged operation adapter, async state machine, and independent destination-membership confirmation; no UI optimism.
6. **ToolHost** — independent modules for Riftlet capture/attachment, translation/wordbook, and Saytile audio/transcription; common permission, lifecycle, event and persistence contracts, but no shared mutable feature state.
7. **LifecycleCoordinator** — display/Space topology, fullscreen, Split View, Stage Manager, sleep/wake, lock/unlock, permissions and app relaunch invalidation.
8. **EvidenceLedger** — every side effect carries intent UUID, source identity, target identity, dispatch result, independent observation, timeout and cleanup result. A dispatch receipt is never a completion receipt.

R4 is frozen. Its design files remain the visual authority; no visual redesign or replacement of the R4 token/asset set is part of this technical plan.

## 1. Evidence baseline and limits

### Direct project evidence

- PR #15 is open and Draft. The 5.22 (90) installed contract on macOS 27.0 build 26A428 / arm64 / one physical display recorded 0/50 eligible Space choices. Nine scored row selections on the final candidate: 0 pass, 9 fail. A later choice observed an unexpected Space; cause explicitly unknown.
- Same-app two-window input: one pass, one fail on an intermediate candidate; final TextEdit attempt: one intent, zero confirmed input, therefore UNKNOWN.
- Cross-Space move capability returned `canMove=false`; zero drag inputs were dispatched. The runtime probe recorded `sky=1 operation=0 class=1 selector=1`.
- Translation service dispatch was confirmed, but no translation bubble appeared; wordbook persistence was blocked.
- Browser attachment test was blocked because the isolated Chrome guest profile did not expose an editor. No attachment, click, submit or send event occurred. This is a harness/environment block, not proof that the product upload route failed.
- Voice: two cold-start Chinese phrases passed; one full-screen transition/finalization case remained UNKNOWN.
- Native fullscreen entry passed; return, Split View and multi-display were not completed. Hidden capture stop and sidebar restoration passed. Performance P95 was not measured.
- Newer 5.22 (90) window-roster correction: official signed Host on macOS 27.0, 0/2/0 cards across empty/open/closed controlled windows; Swift 520/520 and Python 32/32. The independent empty-roster classifier itself reported INCONCLUSIVE for empty checkpoints, so the result proves the UI's 0-card rendering and controlled two-window display, not exhaustive discovery of every possible off-screen/system window.
- New candidate `365fdc4` passed Developer ID deep signature verification and launch, but was not notarized. The package gate records missing distribution signatures for multiple helpers and Sparkle executables; clean-Mac install and notarization are NOT_TESTED.

### Evidence classification

- **Direct evidence:** project receipts and test logs linked below; source code of yabai, ISS and noswoosh; Apple API documentation.
- **Multiple independent support:** Dock swipe synthesis is the common path in InstantSpaceSwitcher/noswoosh/ISS; bridged move operation is present in yabai and reported by DockDoor on macOS 26.4.1.
- **Inference:** why Nearpane's earlier switch attempt reached an unintended Space; why its selector route produced no translation panel; why W01's second input failed. Logs are insufficient to prove a unique cause.
- **Requires final physical validation:** all private API adapters, macOS 27.0 build-specific IOHID payload, bridged migration completion, browser attachment flows, translation bubble visibility, audio finalization under fullscreen and multi-display behavior.

## 2. P0 — Native Spaces switching

### Decision

Replace the current `NPSendAdjacentSwipe` event construction as the authoritative implementation with a **versioned Dock-swipe adapter modeled on the current ISS/noswoosh protocol**, retaining the public CGEvent posting mechanism but isolating all undocumented event fields and IOHID serialization in one module.

- macOS 26.6+: use the validated low-travel synthetic Dock swipe path, with a non-subnormal signed progress value. Do not use `FLT_TRUE_MIN` on Apple Silicon.
- macOS 27.x: use the DockControl event plus companion gesture event and the serialized IOHID payload/augmentation used by ISS. macOS 27's Dock validates payload structure; older event construction can silently do nothing.
- macOS 26.0–26.5: do not use the zero-travel optimized path. Use a normal native swipe/keyboard-equivalent path or mark enhanced switching unsupported until the version is explicitly validated. Do not claim support from 26.6 evidence.
- Space discovery and active Space observation use a separate read-only adapter. Keep stable Space IDs; never persist an array index as identity.
- Resolve target by current ordered Space snapshot on the pointer's display (matching native display semantics), not by keyboard focus display. Re-read topology before every action.
- Only adjacent transitions. A non-adjacent request becomes a bounded sequence of single adjacent transitions, each independently confirmed and cancellable. Never accelerate a multi-hop burst.
- Keep the Dock's real gesture phases and companion event protocol. Never post arbitrary CGS direct-space mutation as the normal path.
- For empty destination Spaces, implement a guarded activation strategy modeled on noswoosh's empty-desktop-yank investigation: after a confirmed landing with no eligible focus target, ensure the app with no windows owns activation so an off-space app cannot order a window and trigger Dock's follow rule. This behavior is private/behavioral and must be independently validated; do not disable Dock auto-swoosh preferences globally because that also breaks Dock icon follow semantics.

### Failure diagnosis

The current project data does **not** establish one proven root cause. It establishes a failed contract. Plausible contributing causes, ranked:
1. macOS 27 event protocol mismatch: serialized IOHID payload is required; legacy event construction may be accepted by CGEventPost but ignored by Dock.
2. Direction/progress sign mismatch: natural-scrolling preference changes the Dock's interpretation; subnormal progress can lose sign on Apple Silicon.
3. Multi-hop or stale-prediction race: Dock notifications and CGS active Space can report intermediate hops while the animation is still running. Treating either as final can overshoot.
4. Display routing mismatch: target display should follow pointer display semantics, not infer from frontmost app or keyboard focus.
5. Empty-desktop follow behavior can move away after an initially correct landing.

The unexpected `Space 2000` must not be called a confirmed target ID or attributed to one of these causes. The evidence shows a setup/cleanup checkpoint whose current value was 2000 and a separate foreign-arrival observation with unknown cause. Codex must correlate raw event timestamps, active display, stable Space IDs, Dock notifications and WindowServer observations before assigning a cause.

### Required state machine

`idle → snapshot → validate target → dispatch one gesture → await settling → independent active-Space readback → stable confirmation → success`; any mismatch, topology mutation, timeout or process restart transitions to `failed/unknown`, blocks further gestures and captures a diagnostic bundle. Never auto-retry an unknown action because it may duplicate a real transition.

### Evidence and sources

- ISS implementation: https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c (event fields, DockControl type, phases, velocity, companion gesture, macOS 27 augmentation and prediction suppression).
- noswoosh implementation and findings: https://github.com/mmathys/noswoosh (macOS 26.6+ / 27 support, 26.0–26.5 compositing caveat, natural-scroll sign, Apple Silicon progress, empty-desktop yank and macOS 27 payload).
- yabai Space metadata and movement: https://github.com/asmvik/yabai/blob/master/src/space_manager.c
- Project receipt: https://github.com/haohongfei2001-png/nearpane/blob/12bfe74bf34c64a25f1292959be119f9be74c272/engineering/verification/native-spaces/5.22-90-installed-contract/RESULTS.md

## 3. P1 — Cross-Space window migration

### Decision

Use `SLSBridgedMoveWindowsToManagedSpaceOperation` with `initWithWindows:spaceID:`, invoking the operation object's `performWithWMBridgeDelegate` selector through Objective-C runtime dispatch, **only after runtime class and selector validation**. This is preferred over parsing a private function address from SkyLight's Mach-O. The operation class itself is private; this is not a public or stable API.

The current probe `sky=1 operation=0 class=1 selector=1` means: SkyLight framework present; the implementation's expected exported/dynamically resolved operation function unavailable; Objective-C class and selector appear present. It does **not** prove that the operation is safely invocable, that its ABI is correct, or that it will complete. The present implementation is unusable because its selected function entry point is absent, not because the class/selector are absent.

### ABI and lifetime contract

- Build the window list as an immutable CFArray of correctly typed CGWindowID/CFNumber values; validate count > 0 and reject stale IDs before allocation.
- Validate class and selector at runtime; verify method signature/argument count and return convention using the Objective-C runtime before invocation. Do not guess an ABI from a symbol name.
- Create the operation with a strong owner; retain the CFArray and operation for the complete asynchronous operation lifetime. Do not release the operation immediately after scheduling unless the observed contract proves the callee retains it.
- Keep a per-operation context containing operation UUID, target Space stable ID, exact window identities, process birth, original Space membership and timeout. Serialize operations per window and per display.
- Do not treat method return or successful scheduling as completion. Poll/observe independent Space membership and window identity until all requested windows are in the target Space and none of the protected siblings moved. Capture failure/timeout as UNKNOWN, not PASS.
- If the operation object exposes a completion delegate/callback, use it only as a scheduling/operation signal; still require independent WindowServer membership confirmation.
- If the operation is unavailable or validation fails, return unsupported. Do not fall back to old compatibility-ID spoofing, undocumented workspace reassignment, SIP-disabled scripting addition, or stale `SLSMoveWindowsToManagedSpace` guesses.

### Product constraints

- Only ordinary user Space → ordinary user Space is initially in scope. Fullscreen, Split View/tiled, Stage Manager-managed windows and cross-display transitions remain unsupported until individually demonstrated.
- Same-app sibling windows must be protected by exact ID set, not PID-only targeting.
- Drag cancellation before dispatch is a no-op. Cancellation after dispatch cannot claim rollback until membership readback proves rollback. If the source window closes or PID birth changes, abort verification and mark unknown.
- Layout is a later independent action; a moved window is not considered laid out merely because the migration operation was scheduled.

### Evidence

- yabai implementation: https://github.com/asmvik/yabai/blob/master/src/space_manager.c
- yabai declarations: https://github.com/asmvik/yabai/blob/master/src/misc/extern.h
- DockDoor maintainer validation: https://github.com/ejbills/DockDoor/issues/855
- Secondary technical comparison: https://github.com/ndelanhese/volta/blob/main/Engine/macos-spaces-research.md
- Project capability receipt: `spaces/final-extra/D01.json` and `move-availability.txt` in the installed-contract evidence.

## 4. P2 — Window inventory and exact focus

### Unified identity

`WindowIdentity = { pid, processBirth, cgWindowID, generation, bundleID, displayID, spaceID }`. Fields other than PID/CGWindowID may be unavailable; absence must be explicit. CGWindowID is UInt32 and can be reused. PID can be reused. Every refresh must reconcile identity with process start/birth and current WindowServer/AX evidence.

### Inventory pipeline

1. Enumerate candidate windows using `CGWindowListCopyWindowInfo`; treat it as an inventory source, not a complete source of private titles or every off-screen window.
2. Query each running app's AX windows and attributes with bounded timeouts. Keep AXUIElement references ephemeral.
3. Read Space membership through the private SkyLight adapter when available. Mark membership `known / unknown / stale`; do not fabricate a Space row when membership is unknown.
4. Deduplicate using full identity. Keep shared windows once. Separate user-created groups from system Space topology.
5. Keep historical screenshots only while identity generation remains valid. Invalidate on close, process birth change, display change, sleep/wake, permission revocation or stale window ID.
6. The latest 0→2→0 fix is the correct UI behavior: unknown membership means no false row; it does not mean hide a window whose presence is independently proven.

### Focus sequence

Resolve target by full identity → re-read target AX element → activate owning app → request AXRaise if supported → request focused-window transition through the owning app's AX API where supported → wait for AXFocusedWindow → verify CGWindowID mapping and frontmost app → send unique harmless test input only in the test fixture → read the target document's actual content. AXMainWindow is not equivalent to AXFocusedWindow. AXRaise is only a request, not proof.

If the app does not expose the target window through AX or does not accept raise/focus, report unsupported for that window; do not silently fall back to PID activation.

### Sources

- Apple AX focused window: https://developer.apple.com/documentation/applicationservices/kaxfocusedwindowattribute
- Apple AX main/focused attributes: https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes
- Apple AX action: https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction
- Apple Quartz Window Services: https://developer.apple.com/documentation/coregraphics/quartz-window-services
- Apple CGWindowID: https://developer.apple.com/documentation/coregraphics/cgwindowid

## 5. P3 — Screenshot capture and AI browser attachments

### Decision

Reuse Riftlet's existing capture and attachment implementation as the only capture/attachment engine. Nearpane owns presentation and routing, not a second independent screenshot stack. Create a narrow `CaptureAttachmentProvider` interface with explicit capture UUID, pixel dimensions, display ID, selection rect, origin app/window identity, file URL, content hash and lifecycle state.

- Use ScreenCaptureKit for app/window/display capture where supported; use the native system screenshot/selection workflow only where the product specifically needs user-controlled arbitrary region selection. Avoid reconstructing a fake region from a screenshot overlay.
- Region proof must compare the selected rect against the actual captured image dimensions, display coordinate conversion, scale factor, rotation and target window coverage. Require complete coverage or explicit user crop; reject partial/multi-window ambiguity.
- Browser automation is Apple Events/Accessibility/UI scripting, not a universal browser API. Use browser-specific adapters for Chrome, Edge and Safari; no extension is required, but site DOM and browser AppleScript support differ.
- For AI services, use domain adapters for ChatGPT, Claude, Gemini and DeepSeek, with explicit capability detection. Separate: browser reachable, authenticated, fresh conversation created, editor detected, attachment picker accepted file, attachment rendered/confirmed, send button not activated.
- Use only the already logged-in browser profile when the user explicitly authorizes it. Never create a new guest profile and classify its missing editor as product failure. If the browser is not logged in, stop and report environment blocked.
- The test must create a fresh blank conversation, attach a synthetic non-sensitive image, confirm a visible attachment chip/thumbnail and accessible attachment state, then stop. Never send text or click send/submit.
- Multi-window/dialog handling must bind every automation step to a specific browser process, window and tab identity. Never use global keystroke sequences without confirming the target.

### Test matrix

Chrome, Edge, Safari × ChatGPT, Claude, Gemini, DeepSeek; include existing authenticated session and fresh conversation. Unsupported site/browser combinations must be explicit. Test delayed upload, canceled picker, duplicate upload, navigation during upload, multiple dialogs, and no-send invariant.

### Evidence

- Current test was BLOCKED because the disposable Chrome guest page had no editor; no attachment or send event occurred. This is a harness block, not an upload failure.
- Apple Quartz window/capture references: https://developer.apple.com/documentation/coregraphics/quartz-window-services
- Riftlet must be treated as source of truth for current capture/attachment code; Codex should map its current provider entry points before wiring Nearpane. No new parallel capture engine is authorized.

## 6. P4 — Translation, wordbook and Saytile

### Translation architecture

Keep NSServices as the external entry point, but make the service handler a minimal adapter: validate pasteboard type and size → copy selected text into an immutable request → enqueue to the host's durable request channel → return promptly. Do not assume the service callback's process or run loop remains alive long enough to own the UI.

The host owns translation and presentation:
1. Request ID and source text hash created.
2. Translation capability/model availability checked.
3. TranslationSession or the selected provider returns result/error.
4. UI presentation coordinator resolves the selected text's screen rect from AX; if unavailable, use a clearly documented fallback anchor near pointer/center, not fabricated coordinates.
5. Show a non-activating NSPanel/popover with explicit lifecycle and close behavior. Floating level only where required; use `becomesKeyOnlyIfNeeded` and hide-on-deactivation semantics.
6. Wordbook persistence occurs in a transactional local store, keyed by normalized term + language pair + dictionary/provider version; verify after process restart.

Apple Translation framework offers TranslationSession, translationTask and LanguageAvailability; model readiness must be checked and errors surfaced. The current failure is not proven to be the Translation Framework itself: service dispatch was observed but no bubble appeared. Most likely failure domains are service provider registration/duplicate provider, interprocess handoff, host wake/activation, UI actor/runloop, anchor resolution, or panel lifecycle. Instrument each boundary separately.

### Saytile architecture

Keep direct expression as the default: recording starts without asking the user to switch input modes. The audio capture path must:
- Begin buffering before reporting ready.
- Use a ring buffer with monotonic timestamps and explicit sample format/channel metadata.
- Retain pre-roll audio and the first non-silent frame; never drop first phrase while recognizer/model warms.
- Treat partial transcript as provisional; final transcript is committed only after audio end, recognizer final result, persistence flush and readback.
- Pause/resume are explicit state transitions; interruption, fullscreen, display changes and app deactivation must not silently finalize or discard.
- Persist audio and final text atomically with request/session UUID. Recovery after crash must distinguish draft audio, finalized transcript and discarded session.
- Prefer the best tested Chinese local ASR engine as default; Apple Speech may be used only if runtime reports on-device support and the user accepts its accuracy trade-off. Apple documents that on-device mode may be less accurate and only applies when the recognizer supports it. Keep the existing alternate local model as a fallback, not an unannounced network switch.

### Sources

- Apple Translation: https://developer.apple.com/documentation/translation
- Apple NSPanel behavior: https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel and https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- Apple Speech recognizer: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- On-device recognition accuracy caveat: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- Recognition request partial/final results: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest

## 7. P5 — Lifecycle, layout and performance

One LifecycleCoordinator owns topology invalidation. Feature modules subscribe to immutable lifecycle events; they do not each maintain their own independent Space/display truth.

- Fullscreen: model the fullscreen window as a distinct Space membership; entering and returning must be verified separately. Native fullscreen entry is already observed, return is not.
- Split View: treat the two tiled windows as a system-managed pair; do not attempt ordinary move/focus semantics until the pair state is identified.
- Multiple displays: key Space ordering and active Space by display UUID; test pointer display and keyboard focus display independently. When Displays have separate Spaces is disabled, treat topology as shared.
- Stage Manager: classify as an independent window grouping/visibility state; never equate Stage Manager sets with Spaces.
- Space create/delete/reorder: use private adapters only where necessary, UUID ownership receipts and reversible cleanup. Do not change user Spaces during passive inventory.
- Sleep/wake/lock/unlock: invalidate all transient AX refs, CGWindowID caches, capture sessions, display transforms and in-flight private operations. Rebuild from fresh snapshots.
- Permissions: monitor revocation and stop capture/automation immediately; distinguish permission denied from target missing.
- Layout: one pure layout planner for 1/2/3/4/8 windows; layout is downstream of confirmed inventory and movement. Keep R4 geometry tokens frozen.
- Performance: stop ScreenCaptureKit streams and frame requests while hidden; retain only bounded thumbnails and metadata; use LRU caches with byte budgets; measure warmed 5×20 operations and P50/P95/P99, CPU, memory, dropped frames and wake cost. The current two idle memory samples are not a performance benchmark.
- Reduce Motion: respect system accessibility preference and use native animation behavior; never mutate global Dock preferences as a feature prerequisite.

## 8. P6 — Security, distribution and compatibility

### Distribution decision

Primary route: Developer ID Application signing + hardened runtime + notarization + stapled ticket + Sparkle update signing. Maintain strict signature identity continuity for the app and every privileged helper. Current 5.22 candidate has missing distribution signatures for several helper binaries and Sparkle components; it is not notarization-ready.

Mac App Store is not compatible with the required private SkyLight/CGS/undocumented gesture protocol. Apple's Developer Program agreement requires documented APIs for App Store distribution and prohibits private APIs. Do not advertise App Store readiness until the private adapters are removed or replaced with documented APIs.

### Compatibility policy

- macOS 26.0–26.5: conservative fallback; no unsupported zero-travel switching.
- macOS 26.6–26.7: experimental private Dock gesture path, individually tested.
- macOS 27.0: experimental private Dock gesture + IOHID serialization path, individually tested against exact build.
- Future major/minor updates: adapters default disabled until protocol smoke tests pass. A successful compile or symbol presence is not compatibility proof.
- Bridged window move: only claim macOS 26.4.1/26.6/27 after exact installed tests. Existing external reports validate 26.4.1, not every build in the family.
- Public APIs (AX, CoreGraphics window enumeration, AppKit, ScreenCaptureKit, Translation, Speech) follow SDK availability and permission requirements; test minimum deployment target separately.

Private APIs create runtime and distribution risk even if the binary passes Developer ID signing/notarization. Notarization is not Apple's endorsement of private APIs or a guarantee of future compatibility. Hardened Runtime is required for notarization and must use minimal entitlements.

### Sources

- Apple Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Apple notarization issues: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- Apple Developer Program agreement: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

## 9. What to retain, replace and remove

### Retain
- R4 visual authority and token set from PR #13.
- Latest window-roster correction at `365fdc4` and its truthful empty-state behavior.
- Existing signature continuity, install receipts, isolated-profile test harness, cleanup ledger and regression suites.
- Riftlet's mature screenshot/attachment provider; Saytile's audio persistence and local ASR adapters where verified.
- Existing evidence ledger approach and separate signed Host/action process boundary, subject to security review.

### Replace
- `NPSendAdjacentSwipe` as the final source of truth: replace with versioned event protocol adapter, stable Space identity resolver, single-step coordinator and independent landing confirmation.
- Current migration capability detection: replace the requirement for a dynamically resolved exported operation function with class/selector/ABI validation for bridged operation, then async independent confirmation.
- PID-only/window-number-only identity and activation-based focus success with full window generation identity and AX focus proof.
- Service callback-owned translation UI with durable request handoff to the host and explicit panel lifecycle.
- Duplicated Nearpane capture path with Riftlet provider integration.

### Remove after migration and tests
- Legacy predicted Space index as a success source.
- Blind multi-hop gesture bursts and optimistic state mutation.
- Compatibility-ID/SIP-disabled window-move fallbacks.
- PID-only focus fallbacks presented as exact window focus.
- Phantom Space rows when membership is unknown.
- Duplicate service providers and stale exported app copies.
- Duplicate capture, ASR and permission state machines where one shared provider can own the lifecycle.

## 10. Explicit non-passing status

Do not mark complete: S02 0/50; W01 final UNKNOWN / historical 1 pass 1 fail; D01 BLOCKED and 0 move attempts; S01 interaction roster complete discovery remains blocked/inconclusive outside controlled visible windows; S03/W02/R01 blocked; translation bubble FAIL; wordbook persistence BLOCKED; browser attachment BLOCKED; one voice finalization UNKNOWN; fullscreen return, Split View, multi-display, sleep/wake, lock/unlock, permissions revoke/restore, performance P95 and full compatibility matrix NOT_RUN/BLOCKED; notarization and clean-Mac install NOT_TESTED.

## Appendix — Project evidence links

- PR #13 R4 authority: https://github.com/haohongfei2001-png/nearpane/pull/13
- PR #14 Native Spaces base: https://github.com/haohongfei2001-png/nearpane/pull/14
- PR #15 current open Draft: https://github.com/haohongfei2001-png/nearpane/pull/15
- Historical installed contract: https://github.com/haohongfei2001-png/nearpane/blob/12bfe74bf34c64a25f1292959be119f9be74c272/engineering/verification/native-spaces/5.22-90-installed-contract/RESULTS.md
- Latest window-only installed test: https://github.com/haohongfei2001-png/nearpane/blob/6f85f73bc6b64290308ac610e342702f989a9f66/engineering/verification/native-spaces/5.22-90-window-roster/RESULTS.md
- Latest 0/2/0 receipts: https://github.com/haohongfei2001-png/nearpane/blob/6f85f73bc6b64290308ac610e342702f989a9f66/engineering/verification/native-spaces/5.22-90-window-roster/results.json
