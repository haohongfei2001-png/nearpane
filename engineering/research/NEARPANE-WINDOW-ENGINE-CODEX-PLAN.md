# Nearpane Window Engine — Codex Implementation Plan

Date: 2026-11-21. Target PR #15 branch `codex/r4-native-candidate-20261120`, starting HEAD `3304e464efe92d4e4791532c23ebb52eb6658c6d`.
This plan is not authorization to mutate foreign windows.

## 0. Binding decision

Read [Final Architecture](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md) and [Performance Standard](NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md).

Do not implement speculative hide/show. Proven facts:
- AXMinimized has Dock side effects.
- Corner parking allows real mouse events to hit the parked window.
- AgentDesk's SIP-enabled foreign-window SLS ordering/move/alpha tests did not produce the requested effects.
- AgentDesk's hidden display relies on private virtual display interfaces and separate app processes; it does not solve same-process sibling grouping.

The requested Stage Manager replacement is not technically qualified. Separate safe architecture work from a future research gate.

## 1. Phase A — Preserve the safe baseline

- Keep PR #15 Draft.
- Keep production group visibility writes disabled.
- Preserve failed isolation receipts verbatim.
- Retain same-display exact-window selection and custom tiling only under their independent contracts.
- Keep wallpaper reveal as a separate verified handoff.
- Do not alter Dock/WindowManager preferences, SIP, native Spaces or user display topology.
- Do not notarize or publish this research candidate.

Deliver a short status entry linking the architecture and performance documents.

## 2. Phase B — Architecture boundary refactor (no OS side effects)

Only proceed with separate user authorization.

Formalize:
- DisplayDescriptor / DisplayTopologyGeneration
- StageGroupID / StageGroupMemberID
- WindowRuntimeLease (process birth + PID + CGWindowID + generation + owner + live AX witness)
- VisibilityProvider + explicit capability result
- VisibilityObservation with independent source timestamps
- WindowTransitionIntent + WAL
- RecoveryDisposition: restored / user-owned-change / unknown / recovery-required

Rules:
- Never persist AX objects or rely on CGWindowID alone.
- Never infer hidden state from dispatch status.
- No fallback to AXMinimized, off-screen, corner, app hide or virtual display.
- Capabilities must specify exact OS build, security posture, window class and qualification receipt.
- Unsupported is a normal state; UI must not describe it as success.

Add tests for PID/CG ID reuse, relaunch, AX invalidation, stale topology, user-minimized windows, same-app siblings, duplicate membership, WAL interruption, crash ambiguity and user input superseding pending intent.

No foreign-window mutation calls in this phase.

## 3. Phase C — Isolated visibility PoC (separate research authorization)

Before coding, submit a concise experiment design and exact private-symbol/ABI hypotheses grounded in primary source or reproducible source. No shotgun selector probing.

Environment:
- macOS 27.0 (26A428), SIP enabled;
- isolated login session and disposable signed fixtures;
- two sibling windows in one process, third managed window in another process;
- one unmanaged bystander and one pre-minimized user window;
- independent CG/AX/owner/focus/input/Dock observers;
- cleanup receipt and before/after snapshots.

Only test a genuinely new evidence-backed candidate. Do not repeat AXMinimized or corner parking as candidate solutions. Do not claim AgentDesk's virtual display solves same-process sibling grouping.

Zero return code without observable effect = FAIL. Missing observer = UNKNOWN. If no candidate has a defensible authority/ABI model, report NO-GO.

Deliver one atomic JSON receipt, video and cleanup proof. Do not touch the everyday login session.

## 4. Phase D — Production adapter, only after all gates pass

1. Exact identity leases and owner validation.
2. Provider capability negotiation and OS-build allowlist.
3. Single-window hide/show transaction with WAL.
4. Independent hit-test and focus proof.
5. Same-app sibling separation.
6. Group transition with bystander and Dock preservation.
7. 10-cycle and 50-cycle installed-host tests.
8. Sleep/wake, app relaunch, crash and display hot-plug recovery.
9. Paired Apple Stage Manager benchmark.
10. Signing, hardened runtime, notarization, clean install/upgrade/rollback.

No phase skips its predecessor.

## 5. Acceptance matrix

| Contract | Required evidence | Gate |
|---|---|---|
| Arbitrary foreign-window hide/show | AX + CG + independent frame + input | 100% |
| Same-process sibling separation | Two windows of same PID in different groups | 100% |
| No pointer hit on inactive window | Physical click + receiver marker | 0 wrong deliveries |
| Exact focus | AX + CG key evidence + input marker | 100% |
| Dock unchanged | Before/after inventory | 0 changes |
| Bystanders unchanged | Geometry, visibility, focus, membership | 100% |
| User-minimized preserved | Original state remains user-owned | 100% |
| Native Space unchanged | Independent before/after readback | 100% |
| Crash recovery | Kill Host at every WAL boundary | No unowned hidden window |
| User interruption | New input invalidates pending intent | 100% |
| Cycles | Same signed installed Host | 10/10 then 50/50 |
| Performance | Paired Stage Manager benchmark | Standard document |
| Lifecycle | Two displays, hot-plug, sleep/wake | 100% |

Any FAIL blocks the provider. UNKNOWN remains blocked. Not run remains NOT_RUN.

## 6. Prohibited shortcuts

- Do not change Dock or WindowManager defaults.
- Do not disable SIP or install Dock scripting addition.
- Do not use click-through overlays as hidden-state proof.
- Do not park windows off-screen or in corners.
- Do not use AXMinimized as a substitute.
- Do not hide an entire app when only one sibling belongs to the inactive group.
- Do not map StageGroups to native Spaces without a new product decision.
- Do not automate Stage Manager UI.
- Do not trust return codes, selectors, stale IDs or a single observer.
- Do not report PASS without signed installed-host artifact and independent evidence.

## 7. Handoff

The next Codex task is not “implement StageGroup hiding.” It is either:
- separately authorized architecture-boundary refactoring with all foreign-window writes disabled; or
- separately authorized isolated PoC for a genuinely new visibility mechanism.

Without that authorization, make no code changes. Correct status: logical StageGroup architecture exists; production visibility is BLOCKED; native-grade replacement is not demonstrated.
