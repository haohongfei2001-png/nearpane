# Nearpane StageGroup Performance and Quality Standard

Date: 2026-11-21. Applies to every future visibility provider and StageGroup release.
Reference: Apple Stage Manager on the same physical Mac and same macOS build.
Evidence baseline for this supplement: PR #15 HEAD `76d9ca80e1a10f57d0916c8555fa5199d376d4ba`; hosted run 44865492229 (macOS 26.7.2 / 25G332 and macOS 27.0.1 / 26A434, both SIP Disabled). Target macOS 27.0 / 26A428 with SIP Enabled was not tested.

## 1. Definition of success

A switch succeeds only when target windows are visible in the intended layout, inactive windows are not composited or input-receivable, the designated window owns keyboard focus, and no bystander or native system state changes. Dispatch return codes, animation callbacks and thumbnails are not success evidence.

## 2. Paired benchmark protocol

Run Apple Stage Manager and Nearpane on the same Mac/build with identical applications, documents, window geometry, display topology, refresh rate, scaling, power mode, input device and warm/cold state. Alternate test order. Capture at least 100 valid transitions per direction per system. Retain raw samples and exclusions.

Workloads:
- 2 groups × 1 window;
- 3 groups × 3 windows across two apps;
- same-app sibling windows in different groups;
- 2-window composite group;
- 5-window load;
- unmanaged bystander and pre-minimized user window;
- single display and two physical displays;
- 60 Hz and supported high-refresh mode.

Record hardware, OS build, display configuration, app versions, signing identity, permissions and fixture revision. Physical-Mac results cannot be replaced with hosted CI timing.

## 3. Metric thresholds

Use monotonic timestamps and publish P50/P95/P99. Document percentile calculation. Absolute limits are guardrails; relative Apple comparison remains mandatory.

| Metric | Definition | Target |
|---|---|---|
| Input → first target frame | Physical click to first captured target-group frame | P50 ≤100 ms; P95 ≤150 ms; P99 ≤250 ms; P95 ≤1.2× Apple +20 ms |
| Input → interactive | Click to exact focus plus real input witness | P50 ≤150 ms; P95 ≤220 ms; P99 ≤350 ms; P95 ≤1.2× Apple +30 ms |
| Group settled | Click to all target windows in final geometry and outgoing windows absent | P95 ≤250 ms; none >500 ms |
| Frame continuity | Display frame intervals during animation | P95 ≤1.25× nominal interval; no unexplained gap >50 ms; dropped frames ≤1% |
| Visual correctness | Blank, stale, wrong-group or inactive-window flash | Zero wrong-group frames; no blank >1 frame; zero inactive flash |
| Focus correctness | Intended window is actual receiver | 100% over 1,000 transitions; zero wrong-window input |
| Mouse isolation | Click at inactive window's former bounds | Zero inactive-window deliveries |
| Layout | AX and CG geometry vs saved geometry | ≤1 physical point per edge after scale conversion |
| Dock | Window tile count / app icon state | Zero Nearpane-induced changes |
| Bystanders | Unmanaged windows and user-minimized windows | Zero geometry, visibility, focus or membership changes |
| Native ownership | Spaces, fullscreen, Split View, Mission Control, Stage Manager | Zero unrequested mutations; immediate write suspension on takeover |
| CPU | Incremental engine CPU | Idle mean ≤1%; switch burst P95 ≤20% of one core over 1 s; no sustained >5% |
| Memory | Incremental resident memory | ≤100 MB steady-state; no monotonic growth over 30-minute cycle |
| Recovery | Sleep/wake, display hot-plug, app crash/relaunch | Reconcile ≤2 s after stable notifications; zero unowned hidden windows |
| Reliability | End-to-end transitions | 10/10 qualification, 50/50 stress, 1,000/1,000 soak; zero safety failures |

If Apple baseline is slower than an absolute threshold, report both; do not silently weaken the standard. If a metric cannot be measured equivalently, mark NOT_COMPARABLE.

## 4. Instrumentation contract

Record per transition:
- intent UUID, monotonic input sequence, physical click time;
- source/target group IDs and per-window runtime lease;
- dispatch start/end and return code;
- independent AX, CGWindow, owner, focus and input observations;
- first target frame and last outgoing frame;
- geometry before/after;
- Dock count before/after;
- display topology and native Space snapshots;
- CPU, memory and WindowServer resource samples;
- cancellation, timeout, rollback and recovery outcome.

Use ScreenCaptureKit or equivalent independent capture for frame timing. Use a separate fixture app to write unique per-window input markers. The observer must not be the actuator.

A frame does not prove focus. AXFocusedWindow does not prove a real key event. A successful AX call does not prove hit-test isolation.

## 5. Result classification

- PASS: all required independent observers agree and thresholds pass.
- FAIL: any required condition is contradicted.
- UNKNOWN: evidence missing, ambiguous or stale.
- NOT_RUN: not executed.
- NOT_COMPARABLE: equivalent measurement unavailable.

No aggregate score can turn a FAIL, UNKNOWN or NOT_RUN safety condition into PASS.

## 6. Release gate

Require:
1. Isolated single-transition provider contract.
2. Same-app sibling and bystander isolation.
3. 10/10 and 50/50 signed installed-host cycles.
4. 1,000/1,000 soak with zero wrong input, Dock side effect or unrecovered hidden window.
5. Same-device paired Apple benchmark with raw data and P50/P95/P99.
6. Physical multi-display, sleep/wake, hot-plug, fullscreen, native Split View and user-driven Space change.
7. Signing, notarization, clean install, upgrade and rollback.

Any visibility or input-safety failure keeps full StageGroup switching disabled.


## 7. Visibility-provider safety standard — 76d9ca8 supplement

The following is a hard safety gate in addition to the timing and resource targets above.

- Pixel coverage is not input isolation. Every former inactive-window hit region must be exercised with a real pointer event and an owner-side receiver marker.
- A panel's `ignoresMouseEvents` state must be recorded. `true` means click-through; it cannot count as an input shield. With `false`, independently prove that the panel was frontmost at every test point and that the underlying fixture received zero mouse events.
- A non-activating panel must preserve both the actual key window and the real keyboard receiver. `canBecomeKeyWindow == false` alone is not focus proof.
- Record the global level and per-window Z-order before, during and after every transition. Verify the target active windows remain above any shield and every inactive window remains below it. Any unobserved window creation, sheet, menu, popover or activation invalidates the trial.
- Capture exclusion is not visibility control. ScreenCaptureKit exclusion must be tested for stale frames, startup/reconfiguration latency, display changes, protected content, and Screen Recording permission; it cannot be used as evidence that source windows left WindowServer or hit testing.
- Mission Control, Space changes, Stage Manager, full-screen and Split View must be tested as system takeovers. A shield that vanishes after the transition begins is not evidence of atomic pre-transition removal.
- Repeat on each physical display, across scale/refresh/color-space changes and hot-plug, with recovery proving that no source window is left masked or exposed incorrectly.
- Same-app sibling windows, cross-app windows, modal sheets, app menus, popovers and system notifications are mandatory workload classes, not optional edge cases.

### Current candidate disposition

| Candidate | Visual result | Pointer safety | Focus/Z-order/lifecycle | Decision |
|---|---|---|---|---|
| AXMinimized with minimize-to-app-icon enabled | AX trial BLOCKED before action; two-window Dock click observation restored only A1 | Not qualified | Same-app/two-group test NOT_RUN | NO-GO / UNKNOWN details |
| Non-activating Occlusion Shield | Plausible pixel cover only | Conditional on race-free panel being top hit target; not proven | Global Z-order and system transient lifecycle not guaranteed | NO-GO primary provider |
| External SLSOrderWindow | No hide effect in five external connection modes on both tested builds | Target remains hit-testable | Owner control is local-only | FAIL |
| Owner-process SLS positive control | Ordered out in CG readback | Test point isolated while ordered out | AppKit visibility disagrees; restoration click check failed | Diagnostic only |

No performance benchmark can override these safety failures. Do not benchmark a provider until it passes the single-transition safety gate.
