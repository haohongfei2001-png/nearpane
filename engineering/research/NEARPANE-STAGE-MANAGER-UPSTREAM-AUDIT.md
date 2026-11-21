# Nearpane — Stage Manager upstream source audit

Date: 2026-11-21  
Nearpane repository: `haohongfei2001-png/nearpane`  
Nearpane PR: #15, branch `codex/r4-native-candidate-20261120`  
Nearpane audited HEAD: `cae7220be5fa3f68b7b71ee04b031c153ff77903`  
Upstream: [eugene-tea/stage-manager](https://github.com/eugene-tea/stage-manager)  
Upstream fixed commit: `69a73665488243bf78982c6d523ac4e0850c1ddb`  
Upstream release: `v1.9.1`, MIT

## 1. Executive findings

The upstream repository is a real, substantial Stage Manager alternative, not a proof-of-concept. It implements a shared stage model/controller and two interchangeable window-visibility backends:

- **Corner / Accessibility**: moves inactive windows to a carefully chosen display corner; macOS leaves a small visible sliver. A separate session-level CGEventTap makes those slivers inert. A wallpaper-derived corner patch hides the visual residue.
- **Spaces**: creates a private per-stage Space and moves windows into/out of it through SkyLight private APIs. It verifies every operation and can fall back to Corner.
- The app also has an optional third mode that follows Apple's Stage Manager rather than hiding windows itself. This is not a visibility backend to transplant into Nearpane's own stage-group product.

The reusable asset is the **window-engine boundary plus the detailed safety/platform algorithms**, not the complete application. Upstream's pure Rust model, settings, strip UI, stage persistence, updater, and product semantics should not replace Nearpane's existing R4 UI or StageGroup model.

**Default decision:** Corner / Accessibility remains the production default. Spaces is opt-in and may be selected only after a launch probe and ongoing health checks pass on the actual machine. A failed Spaces health check must restore all windows and switch to Corner for the rest of that process run.

**Integration decision:** use a focused in-process Rust static library with a narrow C ABI (Option A, constrained extraction), not a separate helper process and not a wholesale Swift rewrite. Details are in the reuse decision and Codex plan.

## 2. Version and provenance verification

GitHub was refreshed during this audit:

| Item | Verified value |
|---|---|
| Upstream default branch | `master` |
| Latest release | `v1.9.1`, published 2026-11-18 |
| Fixed research commit | `69a73665488243bf78982c6d523ac4e0850c1ddb` |
| Fixed commit message | `1.9.1: the mode in Settings, Mission Control showing every stage in the Spaces mode, and fixes` |
| Current `master` | same commit |
| Compare result | `identical`, ahead 0, behind 0 |
| Repository license metadata | MIT |
| Upstream Cargo package | `stage-manager` 1.9.1, Rust 2024 edition, rust-version 1.88 |

The release commit and current default branch therefore agree with the supplied fixed research baseline. This audit does not silently mix a later upstream tree into the fixed source review.

Primary references:
- [Fixed commit](https://github.com/eugene-tea/stage-manager/commit/69a73665488243bf78982c6d523ac4e0850c1ddb)
- [v1.9.1 release](https://github.com/eugene-tea/stage-manager/releases/tag/v1.9.1)
- [MODES.md](https://github.com/eugene-tea/stage-manager/blob/69a73665488243bf78982c6d523ac4e0850c1ddb/docs/MODES.md)
- [STRATEGIES.md](https://github.com/eugene-tea/stage-manager/blob/69a73665488243bf78982c6d523ac4e0850c1ddb/docs/STRATEGIES.md)
- [ARCHITECTURE.md](https://github.com/eugene-tea/stage-manager/blob/69a73665488243bf78982c6d523ac4e0850c1ddb/docs/ARCHITECTURE.md)
- [UX-SPEC.md](https://github.com/eugene-tea/stage-manager/blob/69a73665488243bf78982c6d523ac4e0850c1ddb/docs/UX-SPEC.md)
- [DEVELOPMENT.md](https://github.com/eugene-tea/stage-manager/blob/69a73665488243bf78982c6d523ac4e0850c1ddb/docs/DEVELOPMENT.md)

## 3. Upstream architecture: what is actually reusable

The architecture document describes three execution contexts:

1. AppKit main thread: application run loop, status item, strip panels.
2. Window-management thread: CFRunLoop, AXObservers, AX reads/writes, pure Rust engine model and controller.
3. Helpers: capture workers, configuration watcher, guardian process, control socket.

The pure half under `src/engine` consumes observations and produces actions. The platform half under `src/platform` executes them. The `WindowEngine` trait is the central abstraction. The controller, window inventory, rules, state persistence and safety protocol are shared across visibility engines.

Important upstream paths:
- `src/platform/window_engine.rs`: `WindowEngine` contract, motion/show/restore/health semantics.
- `src/engine/engine_choice.rs`: pure engine choice and health-strike policy.
- `src/platform/controller.rs`, `src/platform/wm_thread.rs`, `src/platform/conductor.rs`: orchestration and thread ownership.
- `src/engine/recovery.rs`, `src/platform/safety.rs`, `src/platform/guardian.rs`: crash, quit and stranded-window recovery.
- `src/platform/windows.rs`, `src/platform/ax.rs`: WindowServer and AX observation.
- `src/engine/window_match.rs`, `src/engine/stale_handle.rs`, `src/engine/stale_activation.rs`: identity/lifecycle reconciliation.

The interface is more sophisticated than simple hide/show. It models hidden geometry, whether a window is currently hidden, whether it is kept out of view, whether focus must wait until show, animation choreography, bring-all-back, recovery ownership, and backend health. Nearpane should preserve that conceptual contract while translating the state model into Nearpane's own stable member IDs and transaction ledger.

### Critical adaptation boundary

Upstream's engine is not a standalone reusable crate in its current form. Its Cargo package builds a binary and a library, but its source modules use upstream-specific `Model`, `WindowId`, `Display`, `AxElement`, `ParkedFile`, settings, logging, controller, and guardian protocols. A direct link of the current library does not give Nearpane a clean generic API. Extraction must create an explicit adapter boundary; it must not expose upstream internal Rust structs as a long-lived ABI.

## 4. Accessibility Corner Engine

### 4.1 Actual park algorithm

Sources:
- `src/engine/corner/park.rs`
- `src/engine/corner/park_reconcile.rs`
- `src/platform/corner/engine.rs`
- `src/platform/ax.rs`
- `src/platform/windows.rs`

The backend requests a position near a selected corner through AX. It does not assume the requested position is the final position: macOS clamps the window so a title-bar sliver remains on-screen. The pure geometry code accounts for:

- full display frame versus visible frame;
- bottom/side Dock placement and auto-hide;
- menu-bar/title-bar minimum visibility;
- all four corners;
- adjacent-display topology, selecting a corner not exposed by another screen;
- the actual clamped position and shadow/visible residue;
- a restore frame that must never itself be classified as parked.

The implementation distinguishes the window's requested park rectangle from the actual frame reported by WindowServer. It tests both full-frame and visible-frame park zones because a bottom Dock changes the coordinate boundary.

This is materially better than moving a window to a guessed offscreen coordinate or assuming AX setter success proves the resulting state.

### 4.2 Why the corner patch does not solve input leakage

`src/engine/corner/corner_patch.rs` builds a small opaque panel over the parked windows' visible slivers. It draws the desktop wallpaper from the wallpaper image/file path; it is not a screenshot of the whole screen and is not the input-security mechanism.

The patch accounts for:
- actual sliver bounds from the WindowServer list;
- window-shadow reach beyond the frame;
- a stable patch rectangle rather than repainting for every sliver;
- z-order and ordering failures;
- transient desktop icons and windows entering/leaving the corner;
- switch-time coverage and removal;
- avoiding full-screen spaces and stand-down states.

A panel can cover pixels while still allowing pointer events through. Therefore visual coverage cannot be used as proof that the parked window cannot be clicked.

### 4.3 Exact input-isolation algorithm

Sources:
- `src/engine/corner/sliver.rs`
- `src/platform/corner/sliver_tap.rs`
- `src/platform/tap_switch.rs`

The upstream algorithm is explicit:

1. **Cheap spatial prefilter**: `Shield::may_hit` checks whether the press is inside one of the active display corner zones. Most pointer events pass without a WindowServer query.
2. **Fresh z-order snapshot**: the WM thread publishes a recent on-screen list near the corner zones. The callback never performs a blocking AX/WindowServer query. If the snapshot is missing or older than `SEEN_FRESH` (one second), it fails open and logs an unjudged press.
3. **Exact hit test**: `Shield::hits` uses front-to-back CGWindowList entries (CGWindowID, PID, bounds, alpha and layer). It skips the app's own panels, transparent overlays and Dock portions that are click-through; Dock bar hit regions are separately read through AX. It includes invisible resize borders, not just the nominal window rectangle.
4. **Only the parked window is swallowed**: a press is suppressed only if the actual frontmost grab target is in the model's parked-window set. An active-stage window, wallpaper, Dock bar, menu bar extra, or unrelated window is allowed to receive its event.
5. **Whole gesture gate**: `PressGate` tracks left/right/other buttons independently. If a down event is swallowed, the matching drag events and up event are also swallowed. It never drops only the down and lets the app receive a drag/release without its beginning.
6. **Session-level event tap**: `CGEventTapLocation::SessionEventTap`, head-inserted, filters left/right/other mouse down, drag and up. The tap runs only while parked windows exist and the shield is enabled. It is disabled when the backend is inactive.
7. **Tap failure is visible**: if the tap cannot be created, the log says parked windows remain pressable. Secure input handling does not pretend the tap is active when macOS has disabled it.

This is the answer to the prior Nearpane mouse-through failure. The old approach established only that a visual panel covered the sliver. The upstream implementation additionally owns the session mouse event stream and decides, using a fresh z-order snapshot, whether the underlying target is one of its parked windows. The entire mouse gesture is then consistently filtered.

**Nearpane must not copy only the patch or only the event callback.** The required unit is park geometry + live parked identity set + fresh z-order publication + Dock/overlay-aware hit test + PressGate + tap lifecycle + independent real-event acceptance tests.

### 4.4 What to reuse and what to adapt

Reuse closely:
- pure park geometry and corner selection;
- full/visible display-frame distinction and clamp/reach-in logic;
- sliver zone geometry;
- hit-test algorithm, resize-border handling, Dock-bar handling and per-button PressGate;
- tap activation/deactivation state machine;
- wallpaper patch geometry and ordering/recovery logic as a reference.

Adapt:
- display identity must map to Nearpane physical display UUID, not upstream ScreenKey serialization;
- parked membership must map to Nearpane member UUID + live process birth/PID/CGWindowID/generation, never just a recycled CGWindowID;
- use Nearpane's existing inventory and transaction epoch to publish snapshots;
- preserve Nearpane's existing user-minimized state and recovery ledger;
- use Nearpane's R4 side-panel/transition visual layer, not upstream strip/card artwork;
- patch may be omitted if R4's own visual presentation can conceal the residue, but input Tap is not optional if the Corner backend is used;
- the callback must remain nonblocking; stale snapshots must revoke the write/switch qualification, not silently count as safe operation.

## 5. Spaces Engine

Sources:
- `src/engine/spaces.rs`
- `src/platform/spaces/engine.rs`
- `src/platform/spaces/ffi.rs`
- `src/platform/spaces/probe.rs`
- `src/platform/spaces/landing.rs`
- `src/engine/engine_choice.rs`

### 5.1 Actual mechanism

The upstream Spaces backend uses the WindowServer's private SkyLight interface, loaded dynamically from:

`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`

The FFI layer uses `dlopen`/`dlsym` for symbols including:
- `SLSMainConnectionID`
- `SLSCopyManagedDisplaySpaces`
- `SLSCopySpaces`
- `SLSCopySpacesForWindows`
- `SLSSpaceCreate`
- `SLSSpaceDestroy`
- `SLSShowSpaces` / `SLSHideSpaces`
- `SLSSpaceAddWindowsAndRemoveFromSpaces`
- `SLSMoveWindowsToManagedSpace`
- `SLSSpaceSetTransform` / `SLSSpaceGetTransform`
- `SLSGetActiveSpace`

It supports two routes:
- classic C functions such as `SLSSpaceCreate` and `SLSSpaceAddWindowsAndRemoveFromSpaces`;
- bridged Objective-C operation classes such as `SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation`, constructed with the documented selectors in the private runtime and executed with `performWithWMBridgeDelegate`.

This is **not** the same technique as `SLSOrderWindow`. It creates/manages actual window-server Spaces and moves a window's membership. It is not merely changing a window level or asking the current connection to order one window out.

### 5.2 Mapping and lifecycle

- One classic Space is created per stage per native Desktop when that stage first hides there.
- The stage Space belongs to the creating SkyLight connection and is destroyed/cleaned up with that connection.
- A hidden window is moved into its stage Space, out of every Desktop; its original Desktop is tracked separately.
- A show operation moves it back onto its Desktop and out of every other Space.
- The engine reads back membership with `SLSCopySpacesForWindows`; a successful return code alone is not treated as completion.
- The Space is not shown as a user-visible Desktop. Showing an unmanaged Space would expose it on every Desktop, so the hidden stage Space remains hidden.
- Windows that are already minimized/ordered out and not present in a Space are not mistaken for a successful move.
- Window panels/companions, Dock activation and Command-Tab behavior require special handling because an app activation can cause macOS to move to another Desktop if that app has no window on the current Desktop.
- Mission Control/App Exposé is special: the upstream v1.9.1 temporarily lends hidden-stage windows onto the Desktop while Mission Control is open, then moves them back. Gesture/hot-corner/Dock-opened Mission Control may receive those windows late (up to two seconds). It is not perfect parity.
- Fullscreen, multi-display, display topology and user-driven Space changes are explicit lifecycle conditions, not incidental cases.

### 5.3 Launch probe and ongoing health

The launch probe in `src/platform/spaces/probe.rs` checks required symbols and bridged selectors, creates a tiny transparent panel, creates a trial Space, moves the panel into it, reads its membership, restores it to the Desktop, reads again, destroys the trial Space and closes the panel. Each step is bounded (the source documents a 40 ms per-step limit).

The health model in `src/engine/engine_choice.rs` and `src/platform/spaces/engine.rs`:
- verifies hide/show membership after each operation;
- retries one failed readback;
- treats a recovered retry as a strike;
- fails the engine on an unrecovered miss or three strikes within the configured 60-second window;
- brings windows back before installing Corner as the backend for the rest of the run;
- exposes probe/fallback reason through diagnostic state.

The important pattern is **capability probing plus readback plus runtime health**, not OS-version allowlisting and not trusting symbol presence.

### 5.4 macOS 27.0 / 26A428 / SIP Enabled compatibility

**Not established by the upstream evidence.**

The fixed upstream source documents its probe/measurements on macOS 27.2 and other live tests, but it does not supply a verified receipt for Nearpane's exact target combination: macOS 27.0 build 26A428 with SIP Enabled. A successful probe on another 27.x build or on a SIP-disabled host is not evidence for this target.

The upstream design does not require SIP to be disabled as a stated precondition, but its use of undocumented SkyLight symbols and bridged operations is inherently build-sensitive. SIP status, library load, symbol presence, selector availability, bridge permissions and actual window membership must all be tested on the exact signed Nearpane host on the target OS. Do not claim compatibility until then.

Required target test:
- exact macOS 27.0 build 26A428, SIP Enabled;
- signed Developer ID build launched from the real install path;
- probe all required classic and bridged operations;
- test hide/show membership for two apps, same-app siblings, modal panels and an unmanaged bystander;
- Dock, Command-Tab, Mission Control, App Exposé, fullscreen and user-driven Space changes;
- 10/10, 50/50 and 1,000-cycle soak;
- crash/quit/logout/login and connection recreation recovery;
- retain raw logs and independent CG/AX/window membership observations.

Until that is passed, Spaces is an experimental opt-in backend. Corner remains default.

## 6. Safety, recovery, and system protection

Sources:
- `src/platform/safety.rs`
- `src/platform/guardian.rs`
- `src/engine/recovery.rs`
- `src/engine/leftovers.rs`
- `src/platform/durable.rs`
- `src/engine/stale_handle.rs`
- `src/engine/stale_activation.rs`
- `src/platform/logout_watch.rs`

The upstream safety subsystem is not just a quit handler:
- a registry records each parked window and its restore geometry;
- a durable parked file records what a separate guardian must restore if the main process dies;
- the guardian is a separate process that outlives the UI process and scans all relevant Spaces;
- the recovery scan finds windows stranded in any known park zone and restores the strongest matching frame from the parked file/state; uncertain matches use a safe fallback rather than being silently adopted;
- restore writes are retried within bounded deadlines;
- a window is not considered recovered merely because a setter returned success;
- the guardian waits for stable observations before declaring a window gone or handed back;
- quit, panic, SIGTERM, SIGINT and SIGABRT paths attempt to restore all windows;
- user changes, window closure, stale handles, delayed activation and app relaunch are reconciled;
- the system distinguishes windows it owns from other windows in the same corner.

Nearpane already has a stronger product-specific write-ahead transaction ledger and live identity generation. Do not replace it with upstream's persisted model. Port the guardian/recovery *mechanisms* and connect them to Nearpane's durable ownership ledger.

System windows and protected UI:
- exclude Nearpane's own panels and overlays from the parked-window hit test;
- treat Dock's bar separately from its large transparent window;
- preserve menu bar extras, notifications, wallpaper clicks and unrelated foreground windows;
- never modify Dock/WindowServer global preferences as an implementation shortcut;
- suspend writes during Mission Control, Exposé, fullscreen, Split View, lock, logout, sleep, topology ambiguity or system Stage Manager takeover;
- if the input tap is unavailable, do not claim inactive windows are click-proof.

## 7. Performance evidence audit

### 7.1 The documented 1.9.1 comparison

The `docs/UX-SPEC.md` section “Window engines measured” reports the median of three runs on an Apple-silicon Mac with macOS 27 (dated 11-14). CPU is percent of one core.

| Metric | Corner / Accessibility | Spaces |
|---|---:|---:|
| App CPU at rest | 1.07% | 0.35% |
| App wakeups/s at rest | 4.4 | 3.6 |
| App energy, top POWER | 1.0 | 0.3 |
| WindowServer CPU at rest | 6.58% | 4.86% |
| replayd CPU at rest | 1.23% | 0.00% |
| App active time per 60 s | 500 ms | 125 ms |
| Card click → last frame in place | 862 ms (range 860–869) | 852 ms (852–857) |
| Outgoing windows gone | 225 ms | 213 ms |
| Dock-click switch | 732 ms | 748 ms |
| App CPU per switch | 113 ms | 91 ms |
| Call-window missed refreshes | 0 | 0 |

The 1.9.1 UX table rounds card-click time to approximately 860 ms / 850 ms. The approximately 700 ms Apple figure is a separately described observed Apple motion reference, not a fully paired benchmark row in this three-run engine table.

### 7.2 Measurement method and limitations

Sources: `scripts/measure_engines.py`, `scripts/measure_stages.py`, `scripts/measure.sh`.

Strengths:
- same fixture app, same display/window geometry and scratch profile;
- three runs by default in the documented 1.9.1 measurement;
- three stages, two windows per stage in the engine comparison;
- 60-second idle period after a 10-second settle;
- process CPU/wakeups via `proc_pid_rusage`;
- WindowServer/replayd CPU via process CPU time over wall time;
- `top` POWER as an Energy Impact proxy;
- 20 switch commands, WindowServer window-list reads every 1 ms, last incoming frame stable and outgoing windows gone;
- median and p90 for switch samples in the scripts;
- separate launch overlap, hidden drawing window and call-window missed-refresh scenarios;
- captures disabled in the 1.9.0 comparison to isolate engine cost.

Limitations:
- the 1.9.1 table publishes medians and ranges from three runs, not a robust population distribution;
- no p50/p90/p95/p99 table is published for the 1.9.1 card-click numbers;
- the scripts' “last frame” is the last window-server geometry observation at the intended frame, not a physically captured first visible pixel or an input-ready proof;
- `ctl switch` is a control command, not a physical click-to-interactive measurement;
- fixture drawing windows count their own display-link callbacks, not every frame WindowServer composites or drops;
- `top` POWER is used instead of privileged `powermetrics`;
- 1.9.0 capture-off measurements are not directly comparable to the 1.9.1 captures-on table;
- the approximately 700 ms Apple number is not a full same-device, same-workload, 100+ transition comparison;
- upstream's measured sample count and repeat count are insufficient to set Nearpane's release target by copying these numbers.

### 7.3 Nearpane performance target

Use Nearpane's current `NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md` as the governing release standard. In particular, distinguish:
- physical input → first target frame;
- physical input → actual focus and real input marker;
- group settled (all windows correct, outgoing windows absent);
- frame continuity;
- input isolation and bystander integrity.

Do not call the upstream 850 ms control-to-final-geometry number a user-perceived latency or treat it as a target. Nearpane's target of P50/P95/P99 and 100/1,000 transition contracts is stricter and uses independent observers.

## 8. License and distribution

The upstream repository is MIT and includes `LICENSE` with copyright “Copyright (c) 2026 Eugene Tiutiunnyk”. Preserve the complete upstream copyright and permission notice in every copied substantial source file or in an accompanying third-party notices file as appropriate. Keep a pinned upstream commit and an auditable file-origin manifest.

The Cargo manifest includes Rust ecosystem dependencies such as `objc2`, `objc2-foundation`, `objc2-app-kit`, `objc2-application-services`, `objc2-core-foundation`, `objc2-core-graphics`, `objc2-screen-capture-kit`, `objc2-quartz-core`, `objc2-image-io`, `block2`, `dispatch2`, `libc`, `serde`, `serde_json`, `toml`, `toml_edit`, `regex`, `tracing`, `anyhow`, and test-only `tempfile`. Cargo.lock pins versions, but Cargo.lock does not itself constitute a complete license clearance. Before distribution, run a machine-readable license audit (for example cargo-deny/cargo-about) over the exact extracted dependency graph and record every transitive package's SPDX expression and license file. Do not assume every transitive crate is MIT merely because the upstream project is MIT.

Do not copy upstream app icon, artwork, promotional images, screenshots, website assets or branding. Reuse code and algorithm only where licensed; Nearpane keeps its own name, UI, R4 design and assets.

Distribution:
- Static Rust code linked into Nearpane remains part of the signed app bundle and must be included in the final nested-code signing verification.
- Hardened Runtime, Developer ID signing, notarization and Gatekeeper assessment must be tested on the exact packaged app and every embedded helper/library.
- Private SkyLight usage is not made App Store-safe by MIT licensing or by Hardened Runtime. Mac App Store distribution is not a realistic target while this capability is core.
- Private APIs can change across macOS point releases. Dynamic symbol/selector lookup, runtime probe, per-operation readback and safe fallback are mandatory.
- An out-of-process helper adds another signed executable, launch/IPC/lifecycle failure modes and independent permission/identity concerns; it does not make private APIs public or App Store compliant.

## 9. Evidence boundaries and unresolved questions

1. The source and documentation are strong evidence of upstream implementation and its own reported test results, not proof that the code will work unchanged in Nearpane.
2. No evidence in this audit proves Spaces on macOS 27.0 build 26A428 with SIP Enabled.
3. No same-hardware paired Apple Stage Manager performance dataset with adequate sample count was available.
4. No dependency-by-dependency SPDX clearance has been completed yet.
5. Nearpane's current transaction/identity system and upstream's engine lifecycle must be integrated without duplicating ownership authorities.
6. The upstream project itself documents imperfections in Mission Control timing, hidden panels, Desktop identification and activation behavior. These must remain explicit acceptance cases.

## 10. Source map for implementation

| Concern | Fixed upstream source |
|---|---|
| Engine abstraction | `src/platform/window_engine.rs` |
| Backend selection and health | `src/engine/engine_choice.rs` |
| Corner geometry | `src/engine/corner/park.rs`, `park_reconcile.rs` |
| Corner hit testing | `src/engine/corner/sliver.rs` |
| Corner patch | `src/engine/corner/corner_patch.rs`, `patch_still.rs` |
| AX execution | `src/platform/corner/engine.rs`, `src/platform/ax.rs` |
| Event tap | `src/platform/corner/sliver_tap.rs`, `src/platform/tap_switch.rs` |
| Spaces pure model | `src/engine/spaces.rs` |
| SkyLight FFI | `src/platform/spaces/ffi.rs` |
| Spaces execution | `src/platform/spaces/engine.rs` |
| Spaces probe | `src/platform/spaces/probe.rs`, `src/platform/spaces_probe.rs` |
| Space transform animation | `src/platform/spaces/landing.rs` |
| Recovery | `src/engine/recovery.rs`, `src/platform/safety.rs`, `src/platform/guardian.rs` |
| Performance | `scripts/measure_engines.py`, `scripts/measure_stages.py` |
| Live acceptance | `scripts/test_stages.py`, `scripts/test-stages.sh` |
