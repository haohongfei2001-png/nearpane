# Nearpane 5.22 — Post-P0 Installed Evidence Reassessment

Date: 2026-11-20  
Current PR #15 head at review time: `0158ed0921dc6a8756fee8ac3af787196b200fac`  
Installed signed fallback candidate: `b55ed965428b32de09e33b3ff5f6360848ac7bd2`  
Installed OS: macOS 27.0 (26A428), arm64, one physical display  
PR state: open, Draft, not merged, not releasable.

This addendum supersedes earlier P0/P1/P2 status assumptions where they conflict with the newer installed evidence. It does not authorize production feature enablement or user-facing release.

## 1. Current-state correction

The user supplied PR HEAD `6237c68`. GitHub subsequently advanced the actual PR branch to `0158ed0` (two commits ahead, 14 changed files), adding active-display preview and Split View geometry work. The latest commit is:

https://github.com/haohongfei2001-png/nearpane/commit/0158ed0921dc6a8756fee8ac3af787196b200fac

The successful Actions run `44748705580` is for `6237c68`, not `0158ed0`. The latest head currently has no Actions run returned by the repository endpoint; its visible combined status contains a Vercel failure. Do not describe the prior run as validation of the current head.

The installed package and PR source are also different objects:
- Installed candidate: `b55ed96`, archive SHA-256 `c671f70f48a4422fe86101b34bd505b6e3de9e13a524589d2c72e7fe28090052`.
- Current PR head: `0158ed0`.
- Installed Host reports permissions allowed, `canSwitch=false`, `canMove=false`, and the official installation path is `/Applications/Nearpane.app`.
- The candidate is not notarized. The package gate still lists 13 binaries missing complete distribution signature fields.

Sources:
- PR: https://github.com/haohongfei2001-png/nearpane/pull/15
- Current status: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/native-spaces/STATUS.md
- Installed candidate: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/quarantined-build-candidate/candidate.json
- Installation continuity: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/quarantined-build-candidate/installation.json
- Package gate: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/quarantined-build-candidate/package-gate.json
- Previous CI run: https://github.com/haohongfei2001-png/nearpane/actions/runs/44748705580

## 2. P0 — switch protocol: short-run navigation is demonstrated; safe completion is not

### Evidence that did pass

On signed candidate `96a3e3d`:
- One adjacent round trip independently landed 2/2.
- One alternating sequence independently landed 10/10.
- The 10-switch run had 480 post-dispatch WindowServer reads.
- The best observed first-stable-target latency in that run was P50 172.15 ms / P95 231.0 ms.

However, that run's physical-display blackout result was UNKNOWN for all 10 switches. It therefore passed the navigation subtest, not the complete P0 product contract.

### New late-change evidence

In run 18, one additional physical switch produced:
- 194 consecutive visible presentation samples, maximum gap about 16.67 ms, no uncovered interval and no timing failure.
- The physical target image and independent target Space readback agreed.
- A different foreground process became frontmost 2.377519 seconds after AXPress.
- The target Space was still active when that foreground handoff was first observed and remained the target through the last independent read at 3.179823 seconds after AXPress.
- The next press was not issued. At the next admission check, the active Space no longer matched the expected target. The current Space was then read as pre-existing Space 6.
- Eight hardware input counters were unchanged.
- The test record explicitly states there was no continuous independent observation between the last completed read and the next admission check. Causal attribution is UNKNOWN.

The run therefore proves a single visually complete landing followed by an unexplained foreground handoff and a later observed Space drift. It does **not** prove that the Dock gesture itself caused the later Space change, and it does not identify the external process or system mechanism. Do not label this a confirmed Dock overshoot or a confirmed empty-Space yank.

Sources:
- 10-switch recomputation: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/11-adjacent-round-trip/readback.json
- Full phase ledger: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/phase-status.json
- Run 18 result: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/18-late-space-change/results.json
- Late-change readback: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/18-late-space-change/late-change-readback.json
- Continuous visual receipt: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/18-late-space-change/ten-01-visual.json
- Raw action timeline: https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/18-late-space-change/actions.jsonl

### Source-level diagnosis: a post-confirmation observation gap

The current action helper:
- requires only 0.85 seconds of stable target observation before returning `confirmed`;
- records foreground PID changes only inside that single action's `run()` loop;
- creates `SpaceNotificationTimes` as a local per-action observer;
- does not retain a post-confirmation watcher that spans the period after the action reply and before the next selection.

The acceptance harness did catch the late foreground handoff and blocked the next press, but the production action state machine had already returned `confirmed`. The missing layer is not another gesture encoding guess: it is a persistent, independent post-transition drift monitor and a stronger completion/admission contract.

### P0 decision

**Keep the macOS 27.0 build 26A428 adapter disabled. Do not dispatch another production gesture on this build until the diagnostic observer is implemented.** The installed fallback correctly reports `canSwitch=false` and directs users to native Mission Control.

Codex must implement, without enabling dispatch:
1. A long-lived read-only monitor owned by the Host or a dedicated observer process, independent of the action helper's local stack.
2. Timestamped observations of active Space UUID/ID, display UUID, frontmost PID and process birth, bundle/signing identity, focused CGWindowID, that window's Space membership, Dock/WindowManager process identity, `NSWorkspace.activeSpaceDidChangeNotification`, and HID counters.
3. Separate terminal classifications: `landed`, `settled`, `unexpectedForegroundHandoff`, `unexpectedSpaceDrift`, `userSuperseded`, `unknown`. Do not collapse frontmost-app change into Space change.
4. A targeted diagnostic run with continuous observation for at least 10 seconds after one confirmed landing. Ten seconds is a diagnostic capture window, not a proposed user-visible animation delay.
5. Correlate whether the external frontmost process owns a window in another Space and whether WindowManager/Dock follows it. If the external process cannot be identified, keep causal attribution UNKNOWN.
6. Once the cause is explained and a candidate fix exists, run one adjacent round trip with visual and independent state proof. Then a single 10-action run where every action has visual proof and continuous observation through the next action admission. Only after all 10 pass may the 50-action contract begin.
7. For automated 10/50 runs, preserve an independent watcher across action boundaries. A new physical user input supersedes the test and must stop it without attempting to restore an older focus or Space.

The 10/10 navigation-only result and the one visually valid run must never be combined into a synthetic 10/10 pass. The 50-action contract remains NOT_RUN.

## 3. P1 — move backend has a concrete source/ABI mismatch

The runtime ABI receipt on this build reports:
- `SLSBridgedMoveWindowsToManagedSpaceOperation` class present.
- `initWithWindows:spaceID:` present with encoding `@32@0:8@16Q24`.
- `performWithWMBridgeDelegate` present with encoding `v16@0:8`.
- `SLSPerformAsynchronousBridgedWindowManagementOperation` legacy export absent.
- Zero operation instantiations and zero dispatched moves.

The current Nearpane `Sources/CNativeSpaceActions/NativeSpaceActions.m` still requires the missing `SLSPerformAsynchronousBridgedWindowManagementOperation` export via `dlsym`, and calls that function pointer. It does not invoke the available `performWithWMBridgeDelegate` selector. Thus `NPMoveAvailable()` remains false for a directly evidenced reason.

The source-backed route for this build is DockDoor's Objective-C method-IMP call:
https://github.com/ejbills/DockDoor/blob/c5be55e9fca3d2bf5ed89b886f6967062c137295/DockDoor/Utilities/PrivateApis.swift

The pinned yabai implementation instead calls the missing asynchronous exported function:
https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/space_manager.c

Decision:
- Implement a non-dispatching ABI adapter that checks class, initializer, selector and exact method encodings.
- For the macOS build where the selector exists and the export does not, prepare the `performWithWMBridgeDelegate` typed IMP invocation, with an immutable correctly typed window array and a strongly owned operation context.
- Do not infer completion from the selector's void return. Require independent destination Space membership and same-app sibling invariants.
- Keep actual move dispatch disabled until P0 is qualified and the P1 single-window round trip is separately authorized by the acceptance gate.
- Do not add compatibility-ID spoofing or SIP-disabled fallbacks.

Project receipts:
- https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/move-abi.json
- https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/Sources/CNativeSpaceActions/NativeSpaceActions.m

## 4. P2 — exact focus remains UNKNOWN, not passed

The prior installed W01 trial recorded one AXPress as issued and acknowledged, but no independently verified document marker. Its status is UNKNOWN because the enrolled TextEdit process was not registered with Launch Services; this prevents the fixture from proving the intended target identity and content readback. The subsequent final admission attempt did not dispatch a product press: a physical input counter changed before the isolated session was admitted, so the harness correctly stopped and preserved the newer focus.

Do not call this a successful focus operation or a definitive product-focus failure. The exact outcome remains unproven.

Next test requirements:
- Use a fixture app that is correctly registered with Launch Services and whose signing identity/process birth are independently enrolled.
- Open two windows of the same app with unique per-document marker strings.
- Verify the target window's identity, AXFocusedWindow, CGWindowID mapping and actual document content.
- Alternate focus 10 times without relying on app PID activation or card highlight.
- If any physical input occurs, classify the trial BLOCKED/user-superseded and preserve the new focus. Do not replay or restore.
- Do not repeatedly use TextEdit with a signature slice workaround as a substitute for stable app enrollment.

Receipts:
- https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/quarantined-build-candidate/window-and-focus/w01-results.json
- https://github.com/haohongfei2001-png/nearpane/blob/0158ed0921dc6a8756fee8ac3af787196b200fac/engineering/verification/native-spaces/5.22-p0/quarantined-build-candidate/final-input-admission/admission-readback.json

## 5. P3–P6: distinguish offline qualification from real installed acceptance

### P3 — Riftlet capture and AI attachments

The 96-case Chrome/Edge × four-service suite and two browser-process cold-restart cases passed in isolated synthetic-page fixtures. The fixture suite exercised 16 exact previews, 8 upload cancellations and 72 pre-write refusals; send, submit and Enter remained zero. The two restart cases prove process-generation and stale-target refusal across actual browser process restarts, but the pages were local fixtures, not authenticated production services. No real upload completion was established.

Still blocked:
- 12 authenticated live site/browser combinations were not attempted because no authorized isolated signed-in profile was available.
- Safari stable tab identity is not established; do not enable Safari writing.
- Real Apple Events/TCC and actual remote upload completion remain unverified.
- Do not classify the earlier guest-profile no-editor result as a product failure.

Sources:
- https://github.com/haohongfei2001-png/nearpane/blob/c886b3c1baad2e72099ace80ba5b718afe450699/engineering/verification/native-spaces/5.22-p3/QUALIFICATION.md
- https://github.com/haohongfei2001-png/nearpane/blob/c886b3c1baad2e72099ace80ba5b718afe450699/engineering/verification/native-spaces/5.22-p3/qualification.json
- https://github.com/haohongfei2001-png/nearpane/blob/c886b3c1baad2e72099ace80ba5b718afe450699/engineering/verification/native-spaces/5.22-p3/cold-restart.json

### P4 — translation, wordbook and Saytile

Offline tests demonstrate durable request handoff and wordbook persistence across relaunch, plus 41 voice tests covering first-PCM-before-ready, pre-roll/tail retention, local final persistence and scripted fullscreen/session-boundary pause. These are meaningful engineering passes.

Still blocked:
- Real installed Host NSServices dispatch and visible translation panel: NOT_RUN.
- Live Chinese translation: blocked because the test identity did not have the required model installed.
- Physical Saytile cold-start matrix: 0 of 60 requested starts; no provider accuracy ranking.
- Fullscreen return, sleep/wake, microphone change and forced-process-termination acceptance remain NOT_RUN.

Sources:
- https://github.com/haohongfei2001-png/nearpane/blob/baa28fe4b40205e1014b4f702ba1bdd80c6fce46/engineering/verification/native-spaces/5.22-p4/translation.json
- https://github.com/haohongfei2001-png/nearpane/blob/baa28fe4b40205e1014b4f702ba1bdd80c6fce46/engineering/verification/native-spaces/5.22-p4/voice.json

### P5 — lifecycle and performance

The isolated planner and benchmark accounting tests passed, but the physical benchmark was NOT_RUN: zero warmed product batches, zero native reference operations, no P95, frame-drop or wake-recovery measurement. The new 0158ed0 preview/Split View geometry code has no physical Split View acceptance yet.

Multi-display, actual Split View pair, sleep/wake, lock/unlock, and 1/2/3/4/8-window geometry remain NOT_RUN/BLOCKED.

Source:
- https://github.com/haohongfei2001-png/nearpane/blob/30595b287e66c7fb79ab0bb5999509745f0eaaaa/engineering/verification/native-spaces/5.22-p5/harness.json
- https://github.com/haohongfei2001-png/nearpane/commit/0158ed0921dc6a8756fee8ac3af787196b200fac

### P6 — package and release

The installed candidate's package gate still lists 13 nested executables/framework binaries missing required distribution signature fields. The candidate is not notarized. Clean-Mac first install, Gatekeeper, stapled ticket and Sparkle update chain are not proven. Do not publish.

## 6. Required Codex order from this point

1. **P0 diagnosis only:** keep adapter disabled; implement persistent read-only drift observer and exact process/window attribution. Do not send another gesture until the observer and single-run diagnostic are ready.
2. **P1 ABI preparation in parallel:** replace the missing-export dependency with a selector/IMP adapter and non-mutating ABI tests. Keep actual move dispatch disabled.
3. **P2 harness correction:** use a correctly registered signed fixture app; test exact window focus and content markers. Physical-input changes stop the test safely.
4. **P3 live qualification:** obtain an explicitly authorized isolated logged-in browser profile; verify actual remote upload completion, never send; keep Safari disabled until stable tab identity exists.
5. **P4 physical qualification:** verify installed Host Services/panel, install required model under the correct identity, then run the 60-start acoustic matrix.
6. **P5 physical lifecycle:** Split View, multi-display, sleep/wake, lock/unlock, layout geometry and warmed performance.
7. **P6 distribution:** resolve all 13 signature omissions, notarize/staple, clean install, upgrade/rollback and exact archive hash.
8. Keep PR #15 Draft until all core contracts pass on the exact signed installed candidate.

## 7. Non-negotiable release status

- P0: BLOCKED; 50 actions NOT_RUN; macOS 27.0 adapter disabled.
- P1: BLOCKED; zero move dispatches.
- P2: UNKNOWN/BLOCKED; no verified same-app exact-focus marker.
- P3: fixture qualification PASS; real authenticated uploads BLOCKED.
- P4: offline logic PASS; installed translation and physical speech acceptance BLOCKED/NOT_RUN.
- P5: offline planner/harness PASS; physical lifecycle and performance NOT_RUN.
- P6: BLOCKED; 13 missing distribution signatures, no notarization.
- PR #15: Draft; no merge; no public release.

This is the current technical truth. Do not upgrade any status based on compile success, AXPress acknowledgment, a short-lived Space landing, a local fixture preview, a void private-method return, or an unsigned/notarized package.
