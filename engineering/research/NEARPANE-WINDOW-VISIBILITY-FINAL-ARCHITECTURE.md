# Nearpane Window Visibility — Final Architecture Decision

Date: 2026-11-21. Baseline: PR #15, `codex/r4-native-candidate-20261120`, HEAD `3304e464efe92d4e4791532c23ebb52eb6658c6d`.
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
