# Nearpane Window Visibility — Final Architecture Decision

Date: 2026-11-21. Baseline: PR #15, `codex/r4-native-candidate-20261120`, HEAD `76d9ca80e1a10f57d0916c8555fa5199d376d4ba`.
Scope: research and architecture only. No production code, notarization, release, or system preference changes.

## Executive decision: NO-GO on the requested end-state

**No third-party visibility engine is currently proven to deliver arbitrary cross-process, per-window StageGroup hide/show on macOS 27.0 (26A428), SIP enabled, while preserving hit-testing, focus, Dock behavior, same-app sibling isolation, and native Space ownership.**

The selected architecture is therefore a **fail-closed StageGroup orchestration architecture with a replaceable Window Visibility Provider boundary**. The provider remains READ-ONLY / DISABLED until a new mechanism passes the hard gate below. This is the single architecture that preserves the product contract without shipping a false fallback.

This is a technical stop line, not a proposal to quietly downgrade Nearpane into a window switcher. If the provider gate cannot be passed, Nearpane must not claim to replace Stage Manager.

## 1. Verified evidence

### Current PR #15 evidence

PR #15 is open and Draft; current head is `3304e464efe92d4e4791532c23ebb52eb6658c6d`. The authoritative installed-isolation record is [5.22 (90) RESULTS](../verification/stage-groups/5.22-90/isolation/RESULTS.md):

- AXMinimized: A→B→C→A transitions isolated the managed windows, preserved exact focus/input and bystanders, but Dock window tiles rose from 1 to 3. FAIL.
- Corner parking: overlay covered the parked strip and Dock count stayed 1, but a real mouse-down reached window 54 and changed keyboard focus. FAIL.
- Native wallpaper reveal and restoration: PASS in the isolated fixture.
- 10-cycle / 50-cycle: NOT_RUN.
- Installed production Host group isolation: BLOCKED.
- Physical multiple displays: BLOCKED; hosted native Space identity: UNKNOWN.
- Local 665 tests passed. This does not prove the missing real-window visibility contract.
- Installed candidate launch was BLOCKED by missing notarization ticket; notarization was NOT_RUN.

No failure is reclassified as a pass.

### Accessibility and AppKit

Apple defines `kAXMinimizedAttribute` as the minimized-in-the-Dock state. The Dock side effect is consistent with the API contract, not merely a UI defect. AX remains useful for window discovery, geometry, focus, notifications and exact-window operations, but setter success is not state proof.

- [Apple: kAXMinimizedAttribute](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute)
- [Apple: AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h)

Apple's `NSWindow.orderOut` and `NSApplication.windows` are APIs over the owning application's own NSWindow objects. They do not expose a public cross-process handle that lets Nearpane call another application's AppKit methods.

- [Apple: NSWindow](https://developer.apple.com/documentation/appkit/nswindow)
- [Apple: orderOut(_:)](https://developer.apple.com/documentation/appkit/nswindow/orderout(_:))
- [Apple: App Windows](https://developer.apple.com/documentation/appkit/app-windows)

### SkyLight / WindowServer

AgentDesk provides unusually relevant negative evidence. Its SIP-enabled macOS 26.5.2 experiment attempted foreign-window `SLSMoveWindow`, `SLSSetWindowAlpha`, `SLSSetWindowLevel`, and `SLSOrderWindow`. Expected effects on foreign windows were not observed; some calls returned zero while independent readback remained unchanged. Owner-process positive controls were distinguished from foreign-window calls.

- [AgentDesk research log](https://github.com/makors/agentdesk/blob/main/docs/RESEARCH-LOG.md)
- [AgentDesk foreign-winop source](https://github.com/makors/agentdesk/blob/main/src/experiments/foreign-winop.m)

This is direct evidence against presuming these SLS calls can manage another app's windows. It does not prove every SkyLight interface is impossible on every OS build. It does mean symbol presence, a zero return code, or an owner-process positive control is insufficient.

Yabai's documented scripting addition is loaded into Dock and requires partial SIP disablement. That deployment model is incompatible with a normal consumer Mac product. [yabai documentation](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc)

A community-reported bridged Space-move operation on newer macOS is a different capability: moving windows between managed Spaces is not equivalent to hiding a window while preserving the user's native Space ownership. It is asynchronous and carries focus-race caveats. It is not approved as the visibility engine. [Research](https://github.com/ndelanhese/volta/blob/main/Engine/macos-spaces-research.md)

### AgentDesk and virtual displays

AgentDesk's actual architecture is: private virtual display, separate app process where possible, AX window relocation, and a resident dialog mover. Its research explicitly says same-process keyboard routing cannot target an arbitrary sibling window reliably; it uses a separate process instance to solve this. Single-instance apps must be adopted/shared and are unsafe while the user is using that same app. Browsers need a CDP/extension path.

- [AgentDesk README](https://github.com/makors/agentdesk)
- [AgentDesk research log](https://github.com/makors/agentdesk/blob/main/docs/RESEARCH-LOG.md)
- [Hidden display implementation](https://github.com/makors/agentdesk/blob/main/src/hidden-display.m)
- [Dialog relocator](https://github.com/makors/agentdesk/blob/main/src/agentdesk-daemon.m)

Virtual display creation is not a public macOS capability. The common `CGVirtualDisplay*` classes are private CoreGraphics interfaces; a virtual display becomes a real display in system topology and can affect display arrangement, Spaces, menu bar, Dock, dialogs and hot-plug lifecycle. It does not separate windows inside one process.

- [go-macos/virtualdisplay](https://pkg.go.dev/github.com/go-macos/virtualdisplay)
- [Virtual display API research](https://github.com/PrimeLab-Foundation/VirtualDisplay/blob/main/docs/platform/macos-virtual-display-apis.md)

**Decision: virtual displays are not Nearpane's core visibility engine.** They solve a different isolated-agent workload and violate Nearpane's transparent topology and same-app sibling requirements.

## 2. Rejected approaches

| Approach | Failure against product contract | Decision |
|---|---|---|
| AXMinimized | Dock tile semantics; observed Dock count 1→3 | Reject |
| Off-screen / corner parking | Real mouse hit still reaches parked window | Reject |
| Click-through overlay | Covers pixels, not WindowServer hit-testing | Reject |
| App-level hide | Hides same-app sibling windows belonging to other groups | Reject |
| Public NSWindow.orderOut | Only owning app can call its NSWindow methods | Not cross-process |
| External SLSOrderWindow / move / alpha / level | AgentDesk SIP-enabled foreign-window test ineffective | Reject as presumed capability |
| Private virtual display | Changes system topology; does not isolate same-process siblings | Reject as core |
| Dock scripting addition | Requires partial SIP disablement | Reject |
| Stage Manager UI automation | Brittle and violates Apple ownership boundary | Reject |
| StageGroup ↔ native Space 1:1 mapping | Couples Nearpane groups to user-owned Spaces | Reject |

## 3. Selected architecture

```
Display Manager
  └── StageGroup Manager
        ├── Window Identity Registry
        ├── Layout Engine
        ├── Window State Persistence + WAL
        ├── Window Focus Coordinator
        ├── Window Visibility Provider [DISABLED]
        ├── Lifecycle Coordinator
        └── Crash Recovery Manager
              └── Evidence Ledger
```

The provider API is narrow: capability negotiation for exact OS build/security/window class; prepare/hide/show; independent observation; restoration of only owned effects. There is no generic hidden Boolean. The provider returns `unsupported` until its exact capability matrix is proven. The UI must not advertise full StageGroup switching meanwhile.

### Module contracts

**Display Manager**
- Physical display UUID, topology generation, mirroring, WorkRect, attach/detach, sleep/wake.
- Independent group directory per physical display.
- Unknown or mirrored topology disables writes.

**StageGroup Manager**
- Owns Nearpane group/member UUIDs and membership.
- A live window belongs to at most one group.
- StageGroup identity is independent of native Space ID.
- A group is switchable only when every required member is proven eligible in the same current system scope.

**Window Identity Registry**
- Runtime lease: signing/bundle identity + PID + process birth token + CGWindowID + generation + AX owner PID + live AX witness.
- Revalidate immediately before every side effect and after every async boundary.
- CGWindowID/PID reuse, AX invalidation, app relaunch or ambiguous owner invalidates the lease.
- Never persist AX objects or treat CGWindowID as durable identity.
- Unknown identity is observe-only until explicit rebinding.

**Window Visibility Engine**
- One provider interface; no fallback cascade.
- No AXMinimized, off-screen, corner, app-hide or virtual-display fallback.
- Must prove absence from compositing AND pointer hit-testing AND keyboard focus.
- Must preserve user-minimized state, Dock count, bystanders and same-app siblings.
- Any missing or contradictory observer means UNKNOWN/FAIL and no commit.

**Window Focus Coordinator**
- Visibility and focus are separate.
- Verify AXFocusedWindow, owner PID, CG key evidence where available, and real input witness in fixture.
- App activation is not exact-window focus proof.

**Layout Engine**
- Save normalized geometry relative to display WorkRect, original absolute frame and topology generation.
- Verify AX and CG frame readback.
- Fullscreen and native Split View remain Apple-owned.

**Window State Persistence**
- Versioned atomic store, single-writer lock and WAL.
- Record before-state, intended effect, dispatch, after-state and ownership token.
- Persist user-minimized state separately.
- Never auto-replay unknown/corrupt records.

**Lifecycle Coordinator**
- Observe app/window lifecycle, display topology, native Space changes, Mission Control, Stage Manager, fullscreen, Split View, permissions, lock, sleep/wake.
- Apple owns Spaces and system modes; stop writes and invalidate intents on system takeover.
- Never mutate Dock, WindowManager or global preferences.

**Crash Recovery Manager**
- Reconcile WAL against live windows on launch.
- Reverse only effects proven to be owned by Nearpane.
- Absence from a visible-window list is not proof that a window should be restored.
- Ambiguous/reused/relaunched/user-modified windows become RECOVERY_REQUIRED.
- Normal exit restores only provider effects with verified ownership.

## 4. StageGroup vs native Space

There is no evidence that Apple Stage Manager group IDs map one-to-one to native Space IDs. The authoritative model remains:
- Display: physical display identity.
- StageGroup: Nearpane logical collection.
- Window: uniquely witnessed live application window.
- Native Space: external read-only system context.

If any group member is in another Space, fullscreen, native Split View, detached display or ambiguous shared Space, retain the logical group but suspend group operations. Do not migrate windows to force membership.

## 5. Compatibility and distribution

| Mechanism | Private API / system requirement | Distribution consequence |
|---|---|---|
| AX | Public API; Accessibility consent | Developer ID route plausible; sandbox/review constraints apply |
| AppKit own windows | Public API | Normal supported route |
| Foreign SkyLight writes | Private, behavior unproven | No compatibility guarantee; not suitable for MAS |
| CGVirtualDisplay private classes | Private CoreGraphics | OS breakage risk; MAS private API rejection risk |
| Dock scripting addition | Partial SIP disablement | Reject for consumer product |
| DriverKit display driver | Apple entitlement/approval path | Not a normal unprivileged app capability |

No minimum macOS version can be declared for the visibility engine because no provider passed. Evidence includes macOS 26.7.2 (25G332) isolation and macOS 27.0 (26A428) physical preflight; neither is a visibility pass.

Developer ID + hardened runtime + notarization is the only plausible distribution route if a future private adapter is proven and accepted by notarization. Notarization is not API support or a compatibility guarantee. Mac App Store is not a viable route for private SkyLight/CGVirtualDisplay dependencies. Do not notarize this research candidate.

## 6. Hard gate for a future PoC

A new isolated PoC may be opened only with exact macOS 27.0 (26A428), SIP enabled, disposable signed fixtures, and independent CG/AX/owner/focus/input/Dock observers.

Fixture: two windows from one process, one third managed window from another process, one unmanaged bystander, one pre-minimized user window; add two physical displays when available.

One coherent transaction must prove:
1. Hide/show an arbitrary foreign window without minimizing.
2. No compositing, pointer hit-testing or keyboard focus while hidden.
3. Restore without app activation stealing focus.
4. Separate same-process sibling windows into different groups.
5. Zero Dock tile changes.
6. Bystander and user-minimized state unchanged.
7. Native Space membership and display topology unchanged.
8. No flash or stale frame.
9. 10 and 50 cycles, user interruption, app relaunch, crash and sleep/wake recovery.
10. Same result in signed installed Host, not only fixture process.

A zero return code without independent state change is FAIL. Missing observer is UNKNOWN. No production implementation is authorized until all pass.

Do not shotgun undocumented symbols, alter Dock preferences, disable SIP, or repeat the failed AXMinimized/corner experiments as new candidates.

## 7. Product consequence

Continue safe work on StageGroup editing, same-display exact-window selection, custom layout, composite previews, identity, per-display persistence and passive native-system handoff.

Do not claim inactive groups are hidden or that Nearpane replaces Stage Manager until the visibility provider passes. The missing capability is an OS boundary, not a missing UI feature.


## 8. Supplementary final research — PoC at 76d9ca8

Research baseline refreshed: PR #15 branch `codex/r4-native-candidate-20261120`, HEAD `76d9ca80e1a10f57d0916c8555fa5199d376d4ba`. The three PoC commits are:
- `83b09d6`: introduced three-provider visibility trials, independent observers and owner-process control.
- `225228c`: added a witnessed setup click and corrected AX availability to an explicit Boolean.
- `76d9ca8`: uses the calibrated physical-input path for both focus baselines.

Workflow run [44865492229](https://github.com/haohongfei2001-png/nearpane/actions/runs/44865492229) produced two artifacts. Both are **SIP Disabled**, and neither is the target environment:
| Artifact | OS/build | SIP | Result boundary |
|---|---|---|---|
| `visibility-macos-26` (14691403579) | macOS 26.7.2 / 25G332 | Disabled | External SLS variants fail; owner-process control demonstrates a local effect; virtual-display input isolation fails |
| `visibility-xcode-27` (14692125151) | macOS 27.0.1 / 26A434 | Disabled | Same failure pattern |
| Required target | macOS 27.0 / 26A428 | **Enabled** | **NOT RUN / UNKNOWN** for this PoC |

Do not conflate macOS 27.0.1 build 26A434 with macOS 27.0 build 26A428. Neither hosted artifact qualifies the target.

### 8.1 SLSOrderWindow and owner positive control

The test resolves `SLSOrderWindow` and transaction symbols. Five foreign-window call modes were attempted from a separate inspector connection: cold main, AppKit-loaded connection, app-main connection, independent connection, and transaction. On both hosted OS builds, each foreign-window hide attempt left the target ordered/on-screen, owner-visible and mouse-hit-testable. Direct calls returned `1000`; transaction order/commit returned non-zero values. These are **FAIL**, not successful hides.

The owner-process positive control is materially different. Calling the same order operation from the owning fixture process did remove the target from the independent CG on-screen list and produced `SLSWindowIsOrderedIn = false`; the test's independent click at the covered point went to the other fixture window, and keyboard focus remained on the keeper. This proves the primitive can affect an owner's own window in this test harness. It does **not** prove an external process can control that window.

The owner control still did not pass the complete contract: the owner's AppKit `NSWindow.isVisible` observation remained true while WindowServer ordering reported out; the full restoration click check was false. Restoration readback did recover ordered-in state, original frame, original Space membership, sibling state and the prior focused window. This is not a clean, end-to-end foreign-window provider.

The virtual-display subtest preserved topology and restored geometry/Space membership after cleanup, but moving the target to the virtual display changed native Space membership during the operation and a real click still reached the parked window. Physical multi-display and physical accidental-pointer tests were not run. It is not a valid isolation mechanism.

### 8.2 AXMinimized and the actual Dock preference

The workflow explicitly set `com.apple.dock minimize-to-application = true` for the experiment and restored the original value afterward. Its original value was absent in both ephemeral hosted accounts; the effective in-test setting was true. This matches the user's stated “Minimize windows into application icon” behavior while the experiment runs, but does not make the hosted account identical to the user's complete Dock/session configuration.

Crucially, the AXMinimized single-window test was **BLOCKED before the minimize action** because the enrolled target was not exposed at its calibrated test point. The same-app second-window case was NOT_RUN. Therefore the experiment did not establish the precise AXMinimized behavior requested.

The separate user-Dock-intervention observation did run after owner-side minimization of two fixture windows: Dock reported zero separate minimized-window tiles before, during and after; clicking the app icon restored A1 only; A0 remained minimized; no Nearpane manager write occurred after the user's click. This is a useful observation, not proof of how two logical StageGroups should reconcile. The exact two-group / same-app scenario remains UNKNOWN.

**Decision on AXMinimized: NOT ACCEPTED as the StageGroup visibility provider.** It is a user-visible minimize operation, not a neutral per-window visibility primitive; its exact same-app/two-group behavior under the user's full account configuration remains UNKNOWN. Do not ship it as a fallback or claim that the Dock preference makes it equivalent to hiding.

### 8.3 Non-activating Occlusion Shield — independent assessment

A Nearpane-owned non-activating `NSPanel` can be made not to become key/main (override `canBecomeKeyWindow` and `canBecomeMainWindow`) and `orderFrontRegardless()` is documented to bring a window to the front of its level without changing key/main status. `ignoresMouseEvents = false` allows the panel to receive mouse events; a custom `hitTest` can route events within the panel's own view hierarchy. Conversely, `ignoresMouseEvents = true` makes it transparent to mouse events. These are distinct behaviors; a panel cannot simultaneously ignore mouse events and serve as the hit-test shield.

ScreenCaptureKit's `SCContentFilter(display:excludingWindows:)` can exclude selected windows from a display capture. It is a capture filter, not a WindowServer visibility or hit-testing API. It can provide pixels for a visual cover, subject to Screen Recording authorization, stream startup/update latency, capture cadence, protected-content behavior and stale-frame risk. It does not remove the source windows from WindowServer, Dock, AX, Spaces, or input routing.

The central Z-order problem is not solved by the public API combination:
- Window levels are globally ordered; a panel at a higher level covers normal-level target windows as well as inactive windows.
- At the same level, ordering is a mutable global stack. Repeatedly ordering the active windows above the shield is a race with cross-process activation, window creation, sheets, menus, popovers and app-specific transient windows.
- Raising the shield above normal windows to guarantee coverage also covers the active group's normal windows. Lowering it to let active windows show leaves no invariant that it remains above every inactive cross-app window.
- A non-activating panel avoids taking key/main status when ordered front, but it does not make arbitrary foreign windows hidden or guarantee that activation/focus ownership never changes.
- A panel hit-test only receives events when it is actually the frontmost hit-test candidate at that screen point. It cannot change the underlying target's WindowServer state. A missed Z-order update permits click-through to the inactive target.
- Window shadows, transparent/rounded window regions, attached sheets, modal panels, app menus, system popovers, notifications and transient windows make a rectangle-only shield incomplete. Per-window shadow geometry is not a stable public occlusion contract.
- Multiple displays require per-display capture, panel lifecycle, scale/color-space handling and topology generation reconciliation. Display changes can invalidate capture and panel geometry between observation and redraw.

Mission Control is a particular problem. AppKit's `.transient` collection behavior says a panel floats in Spaces and hides in Mission Control, which is useful for not obstructing the system overview, but it is not a guaranteed pre-Mission-Control callback to atomically remove all shields and then rebuild them after the system returns. A panel disappearing can reveal the still-live windows in the overview; re-creation is asynchronous. Native Space changes, Stage Manager, full-screen and Split View remain system-owned transitions.

**Occlusion Shield classification: NO-GO as the primary Window Visibility Provider.** It may be explored later as a strictly cosmetic transition/preview layer with no claim of isolation, but it must never be used to mask an inactive window while asserting mouse safety. The combination can potentially deliver a temporarily covered image and, when correctly stacked, intercept mouse input; it cannot guarantee the invariant under arbitrary cross-app Z-order changes, nor does it make the underlying window WindowServer-hidden.

### 8.4 Three distinct visibility claims

1. **Visually occluded:** pixels are covered by a Nearpane panel or a captured image. The original window still exists and may remain exposed to system observers.
2. **Input isolated:** every pointer hit at the inactive window's former visible region is intercepted before reaching that window, and keyboard focus/input remain on the intended active window. This requires independent real-input witnesses; a screenshot is insufficient.
3. **WindowServer-hidden:** the original window is removed from the compositor/order list and no longer participates in normal screen hit-testing. This is stronger than the user-visible goal in some cases, but it is not logically the only acceptable user experience. It is only mandatory if no other mechanism can reliably provide visual correctness and input isolation across all lifecycle cases.

The current evidence does **not** prove that WindowServer-internal hidden state is a necessary product definition. It does prove that the two proposed substitutes (AXMinimized and an overlay shield) are not currently qualified to meet the full product contract.

### 8.5 Final decision and implementation boundary

A. AXMinimized under the user's Dock mode: **NO-GO as the production provider; exact same-app/two-group behavior UNKNOWN** because the AX test was blocked and the paired-window test did not run.

B. Non-activating Occlusion Shield: **NO-GO as the primary isolation architecture** for the Z-order, transient-window, Mission Control and input-safety reasons above.

C. Third-party distribution feasibility: the evidence does **not** prove that every possible ordinary third-party application architecture is impossible. It proves that the currently tested public AX/AppKit/SLS approaches have not delivered the contract, and that the only SLS positive control is owner-process-local. The ordinary app model does not grant a documented public API for arbitrary foreign-window AppKit/WindowServer visibility writes. Therefore full native-equivalent per-window isolation is **UNPROVEN and NO-GO**, not a universal mathematical impossibility theorem.

**Codex's next step is finite and explicit:** do not implement AXMinimized, corner/off-screen parking, an Occlusion Shield as a hide substitute, external SLS writes, or virtual-display parking. Keep production visibility writes disabled. Complete only the safe StageGroup architecture boundary and passive UI work already described in this plan; then stop. Do not open another visibility research loop unless a genuinely new, documented capability or Apple entitlement path is identified. No more speculative PoC variants on the same SLS/overlay/minimize hypotheses.
